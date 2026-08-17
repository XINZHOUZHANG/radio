import asyncio
import unittest
from dataclasses import dataclass

from remote_radio_server.rig.errors import RigProtocolError, RigTransportError
from remote_radio_server.rig.models import Lifecycle, RigCapabilities, RigIdentity
from remote_radio_server.rig.state import RigStateStore
from remote_radio_server.rig.supervisor import RigNotReadyError, RigSupervisor
from tests.rig.helpers import DeterministicSleep


def capabilities(tag: str) -> RigCapabilities:
    return RigCapabilities(identity=RigIdentity("Test", tag, None, None, None))


@dataclass
class Attempt:
    caps: RigCapabilities
    start_error: BaseException | None = None
    start_gate: asyncio.Event | None = None
    discover_error: BaseException | None = None
    refresh_error: BaseException | None = None
    refresh_gate: asyncio.Event | None = None


class FakeTransport:
    def __init__(self, attempt: Attempt, log: list):
        self.attempt = attempt
        self.log = log
        self.started = asyncio.Event()
        self.start_gate = attempt.start_gate
        self.wait_started = asyncio.Event()
        self.terminal = asyncio.Event()
        self.terminal_error: BaseException | None = None
        self.closed = False
        self.close_calls = 0

    async def start(self):
        self.log.append(("transport.start", self))
        self.started.set()
        if self.start_gate is not None:
            await self.start_gate.wait()
        if self.attempt.start_error is not None:
            raise self.attempt.start_error

    async def wait_closed(self):
        self.log.append(("transport.wait_closed", self))
        self.wait_started.set()
        await self.terminal.wait()
        if self.terminal_error is not None:
            raise self.terminal_error

    async def close(self):
        if self.closed:
            return
        self.closed = True
        self.close_calls += 1
        self.log.append(("transport.close", self))
        if self.start_gate is not None:
            self.start_gate.set()
        self.terminal.set()

    def fail(self, error: BaseException):
        self.terminal_error = error
        self.terminal.set()

    def end_cleanly(self):
        self.terminal.set()


class FakeTransportFactory:
    def __init__(self, attempts: list[Attempt], log: list):
        self._attempts = list(attempts)
        self.log = log
        self.created = []

    def __call__(self):
        if not self._attempts:
            raise AssertionError("unexpected reconnect attempt")
        transport = FakeTransport(self._attempts.pop(0), self.log)
        self.created.append(transport)
        self.log.append(("transport.factory", transport))
        return transport


class FakeCapabilityService:
    def __init__(self, transport: FakeTransport, log: list):
        self.transport = transport
        self.log = log

    async def discover(self):
        self.log.append(("capabilities.discover", self))
        error = self.transport.attempt.discover_error
        if error is not None:
            raise error
        return self.transport.attempt.caps


class FakeCapabilityFactory:
    def __init__(self, log: list):
        self.log = log
        self.created = []

    def __call__(self, transport):
        service = FakeCapabilityService(transport, self.log)
        self.created.append(service)
        self.log.append(("capabilities.factory", service))
        return service


class FakeStateService:
    def __init__(self, transport, caps, store, log):
        self.transport = transport
        self.capabilities = caps
        self.store = store
        self.log = log
        self.refresh_started = asyncio.Event()

    async def full_refresh(self, transmitting: bool = False):
        self.log.append(("state.refresh.start", self))
        self.refresh_started.set()
        gate = self.transport.attempt.refresh_gate
        if gate is not None:
            await gate.wait()
        error = self.transport.attempt.refresh_error
        if error is not None:
            raise error
        delta = self.store.apply({"frequency_hz": 14_000_000 + len(self.log)})
        self.log.append(("state.refresh.done", self))
        return delta


class FakeStateFactory:
    def __init__(self, log: list):
        self.log = log
        self.created = []
        self.stores = []

    def __call__(self, transport, caps, *, store):
        service = FakeStateService(transport, caps, store, self.log)
        self.created.append(service)
        self.stores.append(store)
        self.log.append(("state.factory", service))
        return service


class FakeSafety:
    def __init__(self, log: list):
        self.log = log
        self.transport_fault_calls = 0
        self.shutdown_calls = 0
        self.reconcile_calls = 0

    async def reconcile_dekey(self):
        self.reconcile_calls += 1
        self.log.append(("safety.reconcile_dekey", self.reconcile_calls))

    async def transport_fault(self):
        self.transport_fault_calls += 1
        self.log.append(("safety.transport_fault", self.transport_fault_calls))

    async def shutdown(self):
        self.shutdown_calls += 1
        self.log.append(("safety.shutdown", self.shutdown_calls))


class StopAfterSleeps:
    def __init__(self, count: int):
        self.count = count
        self.calls = []

    async def __call__(self, seconds: float):
        self.calls.append(seconds)
        if len(self.calls) >= self.count:
            raise asyncio.CancelledError
        await asyncio.sleep(0)


def make_supervisor(attempts, *, sleep=None, jitter=None, event_sink=None):
    log = []
    store = RigStateStore()
    safety = FakeSafety(log)
    transport_factory = FakeTransportFactory(list(attempts), log)
    capability_factory = FakeCapabilityFactory(log)
    state_factory = FakeStateFactory(log)
    if sleep is None:
        sleep = DeterministicSleep()
    supervisor = RigSupervisor(
        transport_factory,
        store,
        safety,
        capability_service_factory=capability_factory,
        state_service_factory=state_factory,
        sleep=sleep,
        jitter=jitter,
        event_sink=event_sink,
    )
    return supervisor, store, safety, transport_factory, capability_factory, state_factory, log


async def eventually(predicate, turns=100):
    for _ in range(turns):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("condition did not become true")


class SupervisorReadinessTests(unittest.IsolatedAsyncioTestCase):
    async def test_duplicate_run_is_rejected_without_creating_another_attempt(self):
        start_gate = asyncio.Event()
        supervisor, _, safety, transports, _, _, _ = make_supervisor(
            [Attempt(capabilities("Rig-A"), start_gate=start_gate)]
        )
        first_run = asyncio.create_task(supervisor.run())
        await eventually(lambda: bool(transports.created))
        await transports.created[0].started.wait()

        with self.assertRaisesRegex(RuntimeError, "already running"):
            await supervisor.run()

        self.assertEqual(1, len(transports.created))
        self.assertEqual(0, safety.transport_fault_calls)
        await supervisor.close()
        await first_run

    async def test_direct_run_cancellation_is_not_a_fault_and_unpublishes_session(self):
        supervisor, _, safety, transports, _, state_services, _ = make_supervisor(
            [Attempt(capabilities("Rig-A"))]
        )
        run_task = asyncio.create_task(supervisor.run())
        await supervisor.wait_until_ready()
        self.assertIsNotNone(supervisor.capabilities)
        self.assertIs(state_services.created[0], supervisor.active_state_service)

        run_task.cancel()

        with self.assertRaises(asyncio.CancelledError):
            await run_task
        self.assertEqual(0, safety.transport_fault_calls)
        self.assertEqual(1, safety.shutdown_calls)
        self.assertTrue(transports.created[0].closed)
        self.assertEqual(Lifecycle.OFFLINE, supervisor.lifecycle)
        self.assertIsNone(supervisor.capabilities)
        self.assertIsNone(supervisor.active_state_service)

    async def test_full_refresh_and_shared_revision_complete_before_ready(self):
        refresh_gate = asyncio.Event()
        observed_events = []
        attempt = Attempt(capabilities("Rig-A"), refresh_gate=refresh_gate)
        supervisor, store, safety, transports, caps_services, state_services, log = (
            make_supervisor(
                [attempt],
                event_sink=lambda event: observed_events.append(
                    (event, store.snapshot().frequency_hz)
                ),
            )
        )
        run_task = asyncio.create_task(supervisor.run())
        await eventually(lambda: bool(state_services.created))
        state_service = state_services.created[0]
        await state_service.refresh_started.wait()
        ready_waiter = asyncio.create_task(supervisor.wait_until_ready())

        self.assertEqual(Lifecycle.DISCOVERING, supervisor.lifecycle)
        self.assertFalse(supervisor.ready)
        self.assertIsNone(supervisor.capabilities)
        self.assertIsNone(supervisor.active_state_service)
        self.assertFalse(ready_waiter.done())
        with self.assertRaises(RigNotReadyError):
            supervisor.require_ready()

        refresh_gate.set()
        await asyncio.wait_for(ready_waiter, 0.1)

        self.assertTrue(supervisor.ready)
        supervisor.require_ready()
        self.assertIs(attempt.caps, supervisor.capabilities)
        self.assertIs(state_service, supervisor.active_state_service)
        self.assertIs(transports.created[0], supervisor.active_transport)
        self.assertEqual([store], state_services.stores)
        ready_observation = next(
            item for item in observed_events if item[0].lifecycle is Lifecycle.READY
        )
        self.assertIsNotNone(ready_observation[1])
        self.assertEqual(
            [Lifecycle.CONNECTING, Lifecycle.DISCOVERING, Lifecycle.READY],
            [item[0].lifecycle for item in observed_events],
        )
        self.assertEqual([1, 2, 4], [item[0].revision for item in observed_events])
        self.assertLess(
            next(i for i, item in enumerate(log) if item[0] == "state.refresh.done"),
            next(i for i, item in enumerate(log) if item[0] == "transport.wait_closed"),
        )

        await asyncio.gather(supervisor.close(), supervisor.close())
        await asyncio.wait_for(run_task, 0.1)
        self.assertEqual(Lifecycle.OFFLINE, supervisor.lifecycle)
        self.assertEqual(1, safety.shutdown_calls)
        self.assertEqual(0, safety.transport_fault_calls)
        self.assertEqual(Lifecycle.OFFLINE, observed_events[-1][0].lifecycle)
        self.assertEqual(5, observed_events[-1][0].revision)

    async def test_close_during_connect_wakes_readiness_waiters_and_rejects_writes(self):
        attempt = Attempt(capabilities("Rig-A"), start_gate=asyncio.Event())
        supervisor, _, safety, transports, _, _, _ = make_supervisor([attempt])
        transport = None
        run_task = asyncio.create_task(supervisor.run())
        await eventually(lambda: bool(transports.created))
        transport = transports.created[0]
        await transport.started.wait()
        waiter = asyncio.create_task(supervisor.wait_until_ready())

        await asyncio.wait_for(supervisor.close(), 0.1)

        with self.assertRaises(RigNotReadyError):
            await waiter
        with self.assertRaises(RigNotReadyError):
            supervisor.require_ready()
        await asyncio.wait_for(run_task, 0.1)
        self.assertTrue(transport.closed)
        self.assertEqual(1, safety.shutdown_calls)
        self.assertEqual(0, safety.transport_fault_calls)
        self.assertEqual(Lifecycle.OFFLINE, supervisor.lifecycle)


class SupervisorRecoveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_reconnect_unpublishes_stale_session_until_fresh_refresh_is_ready(self):
        sleep = DeterministicSleep()
        sleep.block = True
        second_start_gate = asyncio.Event()
        second_refresh_gate = asyncio.Event()
        attempts = [
            Attempt(capabilities("Rig-A")),
            Attempt(
                capabilities("Rig-B"),
                start_gate=second_start_gate,
                refresh_gate=second_refresh_gate,
            ),
        ]
        supervisor, _, _, transports, _, state_services, _ = make_supervisor(
            attempts, sleep=sleep
        )
        run_task = asyncio.create_task(supervisor.run())
        await supervisor.wait_until_ready()
        first_transport = transports.created[0]
        first_transport.fail(RigTransportError("lost"))
        await sleep.wait_until_blocked()

        self.assertEqual(Lifecycle.DEGRADED, supervisor.lifecycle)
        self.assertIsNone(supervisor.capabilities)
        self.assertIsNone(supervisor.active_state_service)

        sleep.release_next()
        await eventually(lambda: len(transports.created) == 2)
        await transports.created[1].started.wait()
        self.assertEqual(Lifecycle.CONNECTING, supervisor.lifecycle)
        self.assertIsNone(supervisor.capabilities)
        self.assertIsNone(supervisor.active_state_service)

        second_start_gate.set()
        await eventually(lambda: len(state_services.created) == 2)
        await state_services.created[1].refresh_started.wait()
        self.assertEqual(Lifecycle.DISCOVERING, supervisor.lifecycle)
        self.assertIsNone(supervisor.capabilities)
        self.assertIsNone(supervisor.active_state_service)

        second_refresh_gate.set()
        await asyncio.wait_for(supervisor.wait_until_ready(), 0.1)
        self.assertIs(attempts[1].caps, supervisor.capabilities)
        self.assertIs(state_services.created[1], supervisor.active_state_service)

        await supervisor.close()
        await run_task
        self.assertIsNone(supervisor.capabilities)
        self.assertIsNone(supervisor.active_state_service)

    async def test_refresh_fault_trips_safety_before_degraded_then_uses_fresh_instances(self):
        sleep = DeterministicSleep()
        sleep.block = True
        attempts = [
            Attempt(capabilities("Rig-A"), refresh_error=RigProtocolError("bad state")),
            Attempt(capabilities("Rig-B")),
        ]
        shared_log = None

        def event_sink(event):
            shared_log.append(("lifecycle", event.lifecycle))

        supervisor, _, safety, transports, cap_services, state_services, log = make_supervisor(
            attempts,
            sleep=sleep,
            event_sink=event_sink,
        )
        shared_log = log
        run_task = asyncio.create_task(supervisor.run())
        await sleep.wait_until_blocked()

        self.assertEqual(Lifecycle.DEGRADED, supervisor.lifecycle)
        self.assertFalse(supervisor.ready)
        self.assertTrue(transports.created[0].closed)
        self.assertEqual([0.25], sleep.calls)
        safety_index = log.index(("safety.transport_fault", 1))
        degraded_index = next(
            i for i, item in enumerate(log) if item == ("lifecycle", Lifecycle.DEGRADED)
        )
        combined = [item[0:2] for item in log if item[0] == "safety.transport_fault"]
        self.assertEqual([("safety.transport_fault", 1)], combined)
        self.assertLess(safety_index, degraded_index)
        self.assertLess(degraded_index, log.index(("transport.close", transports.created[0])))

        sleep.release_next()
        await asyncio.wait_for(supervisor.wait_until_ready(), 0.1)

        self.assertIs(transports.created[1], supervisor.active_transport)
        self.assertIs(attempts[1].caps, supervisor.capabilities)
        self.assertIs(state_services.created[1], supervisor.active_state_service)
        self.assertIsNot(cap_services.created[0], cap_services.created[1])
        self.assertIsNot(state_services.created[0], state_services.created[1])
        self.assertEqual(1, safety.transport_fault_calls)
        self.assertGreaterEqual(degraded_index, 0)
        await supervisor.close()
        await run_task

    async def test_clean_remote_close_is_a_fault_and_reconnects(self):
        attempts = [Attempt(capabilities("Rig-A")), Attempt(capabilities("Rig-B"))]
        supervisor, _, safety, transports, _, state_services, _ = make_supervisor(attempts)
        run_task = asyncio.create_task(supervisor.run())
        await supervisor.wait_until_ready()
        first_transport = transports.created[0]

        first_transport.end_cleanly()
        await eventually(lambda: len(transports.created) == 2 and supervisor.ready)

        self.assertEqual(1, safety.transport_fault_calls)
        self.assertTrue(first_transport.closed)
        self.assertIs(transports.created[1], supervisor.active_transport)
        self.assertIs(state_services.created[1], supervisor.active_state_service)
        await supervisor.close()
        await run_task

    async def test_backoff_doubles_caps_at_five_seconds_and_clamps_negative_jitter(self):
        attempts = [
            Attempt(capabilities(f"Rig-{index}"), start_error=RigTransportError("no rig"))
            for index in range(7)
        ]
        sleep = StopAfterSleeps(7)
        supervisor, _, safety, transports, _, _, _ = make_supervisor(
            attempts, sleep=sleep
        )

        with self.assertRaises(asyncio.CancelledError):
            await supervisor.run()

        self.assertEqual([0.25, 0.5, 1.0, 2.0, 4.0, 5.0, 5.0], sleep.calls)
        self.assertEqual(7, safety.transport_fault_calls)
        self.assertTrue(all(transport.closed for transport in transports.created))

        negative_sleep = StopAfterSleeps(1)
        negative, *_ = make_supervisor(
            [Attempt(capabilities("Rig-N"), start_error=RigTransportError("no rig"))],
            sleep=negative_sleep,
            jitter=lambda _delay: -99.0,
        )
        with self.assertRaises(asyncio.CancelledError):
            await negative.run()
        self.assertEqual([0.0], negative_sleep.calls)

    async def test_reaching_ready_resets_next_fault_delay_to_quarter_second(self):
        sleep = StopAfterSleeps(2)
        attempts = [
            Attempt(capabilities("Rig-A"), start_error=RigTransportError("first")),
            Attempt(capabilities("Rig-B")),
        ]
        supervisor, _, _, transports, _, _, _ = make_supervisor(attempts, sleep=sleep)
        run_task = asyncio.create_task(supervisor.run())
        await eventually(lambda: len(transports.created) == 2 and supervisor.ready)

        transports.created[1].fail(RigTransportError("after ready"))
        with self.assertRaises(asyncio.CancelledError):
            await run_task

        self.assertEqual([0.25, 0.25], sleep.calls)

    async def test_close_during_backoff_cancels_sleep_without_reconnect_or_fault_translation(self):
        sleep = DeterministicSleep()
        sleep.block = True
        supervisor, _, safety, transports, _, _, _ = make_supervisor(
            [Attempt(capabilities("Rig-A"), start_error=RigTransportError("no rig"))],
            sleep=sleep,
        )
        run_task = asyncio.create_task(supervisor.run())
        await sleep.wait_until_blocked()
        fault_count = safety.transport_fault_calls

        await asyncio.wait_for(supervisor.close(), 0.1)

        await asyncio.wait_for(run_task, 0.1)
        self.assertEqual(fault_count, safety.transport_fault_calls)
        self.assertEqual(1, safety.shutdown_calls)
        self.assertEqual(1, len(transports.created))
        self.assertEqual(Lifecycle.OFFLINE, supervisor.lifecycle)


if __name__ == "__main__":
    unittest.main()
