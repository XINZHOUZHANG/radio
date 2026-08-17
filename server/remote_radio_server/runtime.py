"""Reusable lifecycle owner for the Hamlib control plane."""

from __future__ import annotations

import asyncio

from .gateway import RigMessageGateway, _CurrentSessionBinding
from .mock_rigctld import MockRigctld
from .rig.errors import RigProtocolError, RigReportError, RigTransportError
from .rig.launcher import RigctldLauncher
from .rig.models import CommandPriority
from .rig.safety import PttSafetyError, PttSafetySupervisor
from .rig.state import RigStateStore
from .rig.supervisor import RigNotReadyError, RigSupervisor
from .rig.transport import RigctldTransport


class ControlPlaneRuntime:
    def __init__(
        self,
        *,
        host: str = "127.0.0.1",
        port: int = 4532,
        mock_rig: MockRigctld | None = None,
        launcher: RigctldLauncher | None = None,
        hardware_tx_enabled: bool = False,
        simulated_tx: bool = False,
        ready_timeout_s: float = 5.0,
    ) -> None:
        if host != "127.0.0.1":
            raise ValueError("rigctld host must be exactly 127.0.0.1")
        if mock_rig is not None and not isinstance(mock_rig, MockRigctld):
            raise TypeError("mock_rig must be a MockRigctld")
        if type(port) is not int or not 1 <= port <= 65535:
            if mock_rig is None or port != 0:
                raise ValueError("port must be in the range 1..65535")
        if mock_rig is not None and launcher is not None:
            raise ValueError("mock endpoint and launcher are mutually exclusive")
        if type(hardware_tx_enabled) is not bool or type(simulated_tx) is not bool:
            raise TypeError("TX policy values must be booleans")
        if simulated_tx and mock_rig is None:
            raise ValueError("simulated TX requires an owned MockRigctld endpoint")
        self._host = host
        self._port = port
        self.mock_rig = mock_rig
        self.launcher = launcher
        self._hardware_tx_enabled = hardware_tx_enabled
        self._simulated_tx = mock_rig is not None
        self._ready_timeout_s = ready_timeout_s
        self.state_store = RigStateStore()
        self.session_binding = _CurrentSessionBinding()
        self.supervisor: RigSupervisor
        self.safety = PttSafetySupervisor(
            self._set_ptt,
            state_snapshot=self.state_store.snapshot,
            tx_ranges_hz=self._current_tx_ranges,
        )
        self.supervisor = RigSupervisor(
            self._new_transport,
            self.state_store,
            self.safety,
            event_sink=self.session_binding.lifecycle_changed,
        )
        self.session_binding.attach(self.supervisor)
        self.gateway = RigMessageGateway(
            self.supervisor,
            self.state_store,
            self.safety,
            session_binding=self.session_binding,
        )
        self.run_task: asyncio.Task[None] | None = None
        self.poll_task: asyncio.Task[None] | None = None
        self.watchdog_task: asyncio.Task[None] | None = None
        self._started = False
        self._closed = False
        self._close_complete = False
        self._close_lock = asyncio.Lock()

    @classmethod
    def with_mock(cls, mock_rig: MockRigctld | None = None) -> "ControlPlaneRuntime":
        endpoint = mock_rig or MockRigctld()
        return cls(port=0, mock_rig=endpoint, simulated_tx=True)

    async def __aenter__(self) -> "ControlPlaneRuntime":
        await self.start()
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.close()

    async def start(self) -> None:
        if self._closed:
            raise RuntimeError("control plane runtime is closed")
        if self._started:
            return
        self._started = True
        try:
            if self.mock_rig is not None:
                await self.mock_rig.start()
            if self.launcher is not None:
                await self.launcher.start()
            self.run_task = asyncio.create_task(
                self.supervisor.run(), name="rig-supervisor"
            )
            self.poll_task = asyncio.create_task(
                self._poll_telemetry(), name="rig-telemetry"
            )
            self.watchdog_task = asyncio.create_task(
                self._watchdog(), name="rig-watchdog"
            )
            await asyncio.wait_for(
                self.supervisor.wait_until_ready(), timeout=self._ready_timeout_s
            )
        except BaseException:
            await self.close()
            raise

    async def close(self) -> None:
        async with self._close_lock:
            if self._close_complete:
                return
            self._closed = True
            failures: list[BaseException] = []
            cancellation: asyncio.CancelledError | None = None

            async def attempt(awaitable) -> None:
                nonlocal cancellation
                task = asyncio.create_task(awaitable)
                try:
                    await asyncio.shield(task)
                except asyncio.CancelledError as error:
                    if cancellation is None:
                        cancellation = error
                    result = (await asyncio.gather(task, return_exceptions=True))[0]
                    if isinstance(result, BaseException) and not isinstance(
                        result, asyncio.CancelledError
                    ):
                        failures.append(result)
                except BaseException as error:
                    failures.append(error)

            async def stop_task(task: asyncio.Task | None) -> None:
                if task is not None and not task.done():
                    task.cancel()
                if task is not None:
                    await asyncio.gather(task, return_exceptions=True)

            poll_task, self.poll_task = self.poll_task, None
            await attempt(stop_task(poll_task))
            watchdog_task, self.watchdog_task = self.watchdog_task, None
            await attempt(stop_task(watchdog_task))
            await attempt(self.supervisor.close())
            run_task, self.run_task = self.run_task, None
            await attempt(stop_task(run_task))
            if self.launcher is not None:
                await attempt(self.launcher.close())
            if self.mock_rig is not None:
                await attempt(self.mock_rig.close())

            self._close_complete = not failures
            if cancellation is not None:
                if failures:
                    raise BaseExceptionGroup(
                        "control plane cleanup was cancelled and failed",
                        [cancellation, *failures],
                    )
                raise cancellation
            if len(failures) == 1:
                raise failures[0]
            if failures:
                raise BaseExceptionGroup("control plane cleanup failed", failures)

    def _new_transport(self) -> RigctldTransport:
        port = self.mock_rig.port if self.mock_rig is not None else self._port
        return RigctldTransport(self._host, port)

    def _current_tx_ranges(self) -> tuple[tuple[int, int], ...]:
        try:
            session = self.session_binding.ready_session()
        except RigNotReadyError:
            return ()
        return session.capabilities.tx_ranges_hz

    async def _set_ptt(self, enabled: bool) -> None:
        if enabled:
            if not (self._simulated_tx or self._hardware_tx_enabled):
                raise PttSafetyError(
                    "hardware_tx_disabled", "hardware transmission is disabled"
                )
            try:
                session = self.session_binding.ready_session()
            except RigNotReadyError as error:
                raise PttSafetyError("not_ready", str(error)) from None
            if not session.capabilities.supports_ptt_write:
                raise PttSafetyError("ptt_unsupported", "PTT is unavailable")
            await session.transport.request("\\set_ptt 1", CommandPriority.EMERGENCY)
            self.state_store.apply({"ptt": True})
            return
        transport = self.session_binding.active_transport()
        if transport is None:
            raise PttSafetyError("not_ready", "no transport is available to de-key")
        await transport.request("\\set_ptt 0", CommandPriority.EMERGENCY)
        self.state_store.apply({"ptt": False})

    async def _poll_telemetry(self) -> None:
        while True:
            try:
                try:
                    session = self.session_binding.ready_session()
                except RigNotReadyError:
                    session = None
                if session is not None:
                    await session.state_service.poll_once(
                        self.safety.ptt_on or self.safety.swr_latched
                    )
                    if self.session_binding.is_current(session):
                        state = self.state_store.snapshot()
                        if state.ptt and not self.safety.ptt_on:
                            await self.safety.reconcile_dekey()
                await asyncio.sleep(0.05)
            except asyncio.CancelledError:
                raise
            except (RigTransportError, RigProtocolError, RigReportError):
                await asyncio.sleep(0.05)

    async def _watchdog(self) -> None:
        while True:
            try:
                state = self.state_store.snapshot()
                await self.safety.evaluate(dict(state.meters).get("SWR"))
                await asyncio.sleep(0.05)
            except asyncio.CancelledError:
                raise
            except (RigTransportError, RigProtocolError, RigReportError):
                await asyncio.sleep(0.05)


__all__ = ["ControlPlaneRuntime"]
