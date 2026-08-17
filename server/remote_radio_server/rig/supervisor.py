"""Reconnect lifecycle and resynchronization for one rigctld control plane."""

import asyncio
import inspect
from dataclasses import dataclass

from .capabilities import CapabilityService
from .errors import RigError, RigProtocolError, RigReportError, RigTransportError
from .models import CommandPriority, Lifecycle, RigCapabilities
from .state import RigStateService, RigStateStore


class RigNotReadyError(RigError):
    """Raised when a write is attempted outside a fully synchronized session."""


@dataclass(frozen=True, slots=True)
class LifecycleEvent:
    lifecycle: Lifecycle
    revision: int


class RigSupervisor:
    def __init__(
        self,
        transport_factory,
        state_store: RigStateStore,
        safety,
        *,
        capability_service_factory=None,
        state_service_factory=None,
        sleep=None,
        jitter=None,
        event_sink=None,
    ) -> None:
        self._transport_factory = transport_factory
        self._state_store = state_store
        self._safety = safety
        self._capability_service_factory = (
            capability_service_factory or CapabilityService
        )
        self._state_service_factory = (
            state_service_factory
            or (
                lambda transport, capabilities, *, store: RigStateService(
                    transport, capabilities, store=store
                )
            )
        )
        self._sleep = sleep or asyncio.sleep
        self._jitter = jitter or (lambda delay: delay)
        self._event_sink = event_sink or (lambda _event: None)
        self._capabilities: RigCapabilities | None = None
        self._active_transport = None
        self._active_state_service = None
        self._ready_event = asyncio.Event()
        self._closing = False
        self._close_complete = False
        self._shutdown_complete = False
        self._run_task: asyncio.Task[None] | None = None
        self._close_lock = asyncio.Lock()

    @property
    def lifecycle(self) -> Lifecycle:
        return self._state_store.snapshot().lifecycle

    @property
    def capabilities(self) -> RigCapabilities | None:
        return self._capabilities

    @property
    def active_transport(self):
        return self._active_transport

    @property
    def active_state_service(self):
        return self._active_state_service

    @property
    def ready(self) -> bool:
        return (
            not self._closing
            and self.lifecycle is Lifecycle.READY
            and self._active_transport is not None
            and self._active_state_service is not None
            and self._capabilities is not None
        )

    def require_ready(self) -> None:
        if not self.ready:
            raise RigNotReadyError("rig is not ready")

    async def wait_until_ready(self) -> None:
        while True:
            if self.ready:
                return
            if self._closing:
                raise RigNotReadyError("rig supervisor is closed")
            await self._ready_event.wait()

    async def run(self) -> None:
        current = asyncio.current_task()
        if self._run_task is not None and self._run_task is not current:
            raise RuntimeError("rig supervisor is already running")
        if self._closing:
            return
        self._run_task = current
        delay = 0.25
        try:
            while not self._closing:
                transport = None
                try:
                    transport = self._transport_factory()
                    self._active_transport = transport
                    await self._set_lifecycle(Lifecycle.CONNECTING)
                    await transport.start()
                    if self._closing:
                        break

                    await self._set_lifecycle(Lifecycle.DISCOVERING)
                    capability_service = self._capability_service_factory(transport)
                    discovered = await capability_service.discover()
                    if self._closing:
                        break

                    state_service = self._state_service_factory(
                        transport, discovered, store=self._state_store
                    )
                    await state_service.full_refresh()
                    if self._closing:
                        break

                    if (
                        discovered.supports_ptt_write
                        and getattr(self._safety, "dekey_required", False)
                    ):
                        await self._safety.reconcile_dekey()
                        if discovered.supports_ptt_read:
                            ptt = await transport.request(
                                "\\get_ptt", CommandPriority.EMERGENCY
                            )
                            if ptt.get("PTT") != "0":
                                raise RigProtocolError(
                                    "replacement session did not confirm PTT off"
                                )
                            self._state_store.apply({"ptt": False})

                    self._capabilities = discovered
                    self._active_state_service = state_service
                    await self._set_lifecycle(Lifecycle.READY)
                    delay = 0.25
                    await transport.wait_closed()
                    if self._closing:
                        break
                    raise RigTransportError("rigctld connection closed unexpectedly")
                except asyncio.CancelledError:
                    if self._closing:
                        break
                    raise
                except (RigTransportError, RigProtocolError, RigReportError):
                    if self._closing:
                        break
                    self._unpublish_session()
                    await self._safety.transport_fault()
                    if self._closing:
                        break
                    await self._set_lifecycle(Lifecycle.DEGRADED)
                    if transport is not None:
                        await transport.close()
                    if self._active_transport is transport:
                        self._active_transport = None
                    try:
                        await self._sleep(max(0.0, self._jitter(delay)))
                    except asyncio.CancelledError:
                        if self._closing:
                            break
                        raise
                    delay = min(delay * 2, 5.0)
        finally:
            self._unpublish_session()
            active = self._active_transport
            if active is not None:
                await active.close()
            self._active_transport = None
            self._active_state_service = None
            if not self._closing:
                self._closing = True
                self._ready_event.set()
                if not self._shutdown_complete:
                    await self._safety.shutdown()
                    self._shutdown_complete = True
            await self._set_lifecycle(Lifecycle.OFFLINE)
            self._run_task = None

    async def close(self) -> None:
        async with self._close_lock:
            if self._close_complete:
                return
            self._closing = True
            self._ready_event.set()
            self._unpublish_session()
            if not self._shutdown_complete:
                try:
                    await self._safety.shutdown()
                finally:
                    # Shutdown is a terminal, exactly-once safety transition. A
                    # de-key failure is reported, but cannot be retried after the
                    # owned transport has been torn down.
                    self._shutdown_complete = True
            run_task = self._run_task
            current = asyncio.current_task()
            if run_task is not None and run_task is not current and not run_task.done():
                run_task.cancel()
                await asyncio.gather(run_task, return_exceptions=True)
            active = self._active_transport
            if active is not None:
                await active.close()
            self._active_transport = None
            self._active_state_service = None
            await self._set_lifecycle(Lifecycle.OFFLINE)
            self._close_complete = True

    def _unpublish_session(self) -> None:
        self._capabilities = None
        self._active_state_service = None

    async def _set_lifecycle(self, lifecycle: Lifecycle) -> None:
        delta = self._state_store.apply({"lifecycle": lifecycle})
        if lifecycle is not Lifecycle.READY:
            self._ready_event.clear()
        if delta is None:
            if lifecycle is Lifecycle.READY:
                self._ready_event.set()
            return
        event = LifecycleEvent(lifecycle, delta.revision)
        sink_result = self._event_sink(event)
        if inspect.isawaitable(sink_result):
            await sink_result
        if lifecycle is Lifecycle.READY:
            self._ready_event.set()


__all__ = ["LifecycleEvent", "RigNotReadyError", "RigSupervisor"]
