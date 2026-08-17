import asyncio
import unittest

from remote_radio_server.rig.errors import RigReportError
from remote_radio_server.rig.models import Lifecycle, RigState
from remote_radio_server.rig.safety import PttSafetyError, PttSafetySupervisor
from tests.rig.helpers import FakeClock, RecordingPtt


TX_RANGES = ((14_000_000, 14_350_000),)


class FailingPtt:
    def __init__(self, fail_on):
        self.fail_on = fail_on
        self.calls = []

    async def set_ptt(self, enabled):
        self.calls.append(enabled)
        if enabled is self.fail_on:
            raise RuntimeError("simulated radio failure")


class GatedOffPtt:
    def __init__(self):
        self.calls = []
        self.off_started = asyncio.Event()
        self.release_off = asyncio.Event()

    async def set_ptt(self, enabled):
        self.calls.append(enabled)
        if not enabled:
            self.off_started.set()
            await self.release_off.wait()


class GatedOnPtt:
    def __init__(self):
        self.calls = []
        self.on_started = asyncio.Event()
        self.release_on = asyncio.Event()

    async def set_ptt(self, enabled):
        self.calls.append(enabled)
        if enabled:
            self.on_started.set()
            await self.release_on.wait()


class NegativeOnPtt:
    def __init__(self):
        self.calls = []

    async def set_ptt(self, enabled):
        self.calls.append(enabled)
        if enabled:
            raise RigReportError(-1)


def ready_state(**changes):
    values = {
        "lifecycle": Lifecycle.READY,
        "frequency_hz": 14_074_000,
        "split_state_known": True,
    }
    values.update(changes)
    return RigState(**values)


def make_safety(radio, clock, *, state=None, tx_ranges=TX_RANGES, **options):
    current_state = state or ready_state()
    return PttSafetySupervisor(
        radio.set_ptt,
        state_snapshot=lambda: current_state,
        tx_ranges_hz=tx_ranges,
        clock=clock,
        lease_id_factory=lambda: "lease-secret",
        **options,
    )


class PttSafetyTests(unittest.IsolatedAsyncioTestCase):
    async def test_cancelled_ptt_on_dekeys_before_cancellation_propagates(self):
        """Removing cancellation-safe settling must leave only an attempted key."""
        clock = FakeClock()
        radio = GatedOnPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        request = asyncio.create_task(safety.request_ptt(lease, True))
        await radio.on_started.wait()

        request.cancel()
        await asyncio.sleep(0)
        self.assertFalse(
            request.done(), "PTT-on cancellation escaped before hardware converged"
        )

        radio.release_on.set()
        with self.assertRaises(asyncio.CancelledError):
            await request
        self.assertEqual([True, False], radio.calls)
        self.assertFalse(safety.ptt_on)
        self.assertFalse(getattr(safety, "dekey_required", True))

    async def test_cancelled_ptt_off_finishes_before_cancellation_propagates(self):
        """Removing cancellation shielding must cancel the physical off call."""
        clock = FakeClock()
        radio = GatedOffPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        request = asyncio.create_task(safety.request_ptt(lease, False))
        await radio.off_started.wait()

        request.cancel()
        await asyncio.sleep(0)
        self.assertFalse(
            request.done(), "PTT-off cancellation escaped before hardware converged"
        )

        radio.release_off.set()
        with self.assertRaises(asyncio.CancelledError):
            await request
        self.assertEqual([True, False], radio.calls)
        self.assertFalse(safety.ptt_on)
        self.assertFalse(getattr(safety, "dekey_required", True))

    async def test_negative_ptt_on_report_forces_off_before_returning_error(self):
        """Removing uncertain-on cleanup must omit the deterministic off attempt."""
        clock = FakeClock()
        radio = NegativeOnPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")

        with self.assertRaises(RigReportError):
            await safety.request_ptt(lease, True)

        self.assertEqual([True, False], radio.calls)
        self.assertFalse(safety.ptt_on)
        self.assertFalse(getattr(safety, "dekey_required", True))

    async def test_ptt_admission_fails_closed_when_split_state_is_unknown(self):
        """Treating the default split-disabled value as authoritative must key RF."""
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(
            radio,
            clock,
            state=ready_state(split_state_known=False, split_enabled=False),
        )
        lease = safety.acquire_lease("device-1")

        with self.assertRaises(PttSafetyError) as caught:
            await safety.request_ptt(lease, True)

        self.assertEqual("tx_split_unknown", caught.exception.reason)
        self.assertEqual([], radio.calls)

    async def test_tx_watchdog_trips_when_effective_frequency_becomes_unsafe(self):
        """Removing continuous TX-range revalidation must leave PTT keyed."""
        clock = FakeClock()
        radio = RecordingPtt()
        states = [ready_state()]
        safety = PttSafetySupervisor(
            radio.set_ptt,
            state_snapshot=lambda: states[-1],
            tx_ranges_hz=TX_RANGES,
            clock=clock,
            lease_id_factory=lambda: "lease-secret",
        )
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        states.append(ready_state(frequency_hz=50_000_000))

        trip = await safety.evaluate(swr=None)

        self.assertIsNotNone(trip)
        self.assertEqual("tx_out_of_range", trip.reason)
        self.assertEqual([True, False], radio.calls)
        self.assertFalse(safety.ptt_on)

    async def test_swr_trip_remains_latched_until_a_fresh_low_measurement(self):
        """Using only elapsed lockout must permit re-key without a safe reading."""
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        await safety.evaluate(swr=3.0)
        clock.advance(3.1)
        replacement = safety.acquire_lease("device-2")

        with self.assertRaises(PttSafetyError) as caught:
            await safety.request_ptt(replacement, True)
        self.assertEqual("swr_latched", caught.exception.reason)

        await safety.evaluate(swr=1.5)
        await safety.request_ptt(replacement, True)
        self.assertEqual([True, False, True], radio.calls)

    # Production break caught: reconnecting sessions can retain stale TX ranges.
    async def test_tx_range_provider_is_resolved_for_each_ptt_on(self):
        clock = FakeClock()
        radio = RecordingPtt()
        ranges = [((14_000_000, 14_350_000),)]
        safety = make_safety(radio, clock, tx_ranges=lambda: ranges[-1])
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        await safety.request_ptt(lease, False)
        ranges.append(((7_000_000, 7_300_000),))

        with self.assertRaises(PttSafetyError) as caught:
            await safety.request_ptt(lease, True)

        self.assertEqual("tx_out_of_range", caught.exception.reason)
        self.assertEqual([True, False], radio.calls)

    # Production break caught: absent, throwing, or malformed discovery data can
    # otherwise bypass the admission boundary and key hardware.
    async def test_tx_range_provider_failures_fail_closed(self):
        providers = (
            lambda: None,
            lambda: ((14_000_000, True),),
            lambda: ((14_350_000, 14_000_000),),
            lambda: (_ for _ in ()).throw(RuntimeError("secret backend detail")),
        )
        for provider in providers:
            with self.subTest(provider=provider):
                clock = FakeClock()
                radio = RecordingPtt()
                safety = make_safety(radio, clock, tx_ranges=provider)
                lease = safety.acquire_lease("device-1")
                with self.assertRaises(PttSafetyError) as caught:
                    await safety.request_ptt(lease, True)
                self.assertEqual("tx_ranges_unavailable", caught.exception.reason)
                self.assertNotIn("secret", str(caught.exception))
                self.assertEqual([], radio.calls)

    # Production break caught: evaluate treating age 10.0 as stale trips a fresh link.
    async def test_evaluate_heartbeat_is_fresh_at_exact_deadline(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        clock.advance(10.0)

        trip = await safety.evaluate(swr=None)

        self.assertIsNone(trip)
        self.assertTrue(safety.ptt_on)
        self.assertEqual([True], radio.calls)

    # Production break caught: checking the hard limit before heartbeat reports
    # the wrong cause when both expire together.
    async def test_evaluate_prioritizes_heartbeat_over_hard_limit(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        clock.advance(180.0)

        trip = await safety.evaluate(swr=None)

        self.assertEqual("heartbeat_timeout", trip.reason)
        self.assertEqual([True, False], radio.calls)

    # Production break caught: making the heartbeat deadline exclusive rejects a still-fresh lease.
    async def test_heartbeat_refresh_is_fresh_through_exact_deadline(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        clock.advance(5.0)
        safety.heartbeat(lease)
        clock.advance(10.0)

        await safety.request_ptt(lease, True)

        self.assertTrue(safety.ptt_on)
        self.assertEqual([True], radio.calls)

    # Production break caught: exclusive endpoints or an RX fallback mishandles
    # legal/missing split TX.
    async def test_tx_ranges_are_inclusive_and_missing_split_tx_is_unknown(self):
        accepted_states = (
            ready_state(frequency_hz=14_000_000),
            ready_state(
                frequency_hz=50_000_000,
                split_enabled=True,
                split_frequency_hz=14_350_000,
            ),
        )
        for state in accepted_states:
            with self.subTest(state=state):
                clock = FakeClock()
                radio = RecordingPtt()
                safety = make_safety(radio, clock, state=state)
                lease = safety.acquire_lease("device-1")
                await safety.request_ptt(lease, True)
                self.assertTrue(safety.ptt_on)
                self.assertEqual([True], radio.calls)

        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(
            radio,
            clock,
            state=ready_state(split_enabled=True, split_frequency_hz=None),
        )
        lease = safety.acquire_lease("device-1")
        with self.assertRaises(PttSafetyError) as caught:
            await safety.request_ptt(lease, True)
        self.assertEqual("tx_frequency_unknown", caught.exception.reason)
        self.assertFalse(safety.ptt_on)

    # Production break caught: fabricated/unordered SWR handling trips early or
    # reports the wrong watchdog.
    async def test_evaluate_ignores_unavailable_low_swr_and_prioritizes_breach(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        self.assertIsNone(await safety.evaluate(swr=None))
        self.assertIsNone(await safety.evaluate(swr=2.999))
        clock.advance(180.0)
        trip = await safety.evaluate(swr=3.0)

        self.assertEqual("swr_breach", trip.reason)
        self.assertEqual([True, False], radio.calls)

    # Production break caught: releasing the transition lock during trip-off lets
    # a queued on overtake it.
    async def test_queued_ptt_on_cannot_overtake_in_progress_trip_off(self):
        clock = FakeClock()
        radio = GatedOffPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        trip_task = asyncio.create_task(safety.transport_fault())
        await radio.off_started.wait()
        self.assertFalse(safety.ptt_on)
        self.assertIsNone(safety.lease_owner)
        next_lease = safety.acquire_lease("device-2")
        on_task = asyncio.create_task(safety.request_ptt(next_lease, True))
        await asyncio.sleep(0)

        self.assertFalse(on_task.done())
        self.assertEqual([True, False], radio.calls)
        radio.release_off.set()
        await trip_task
        with self.assertRaises(PttSafetyError) as caught:
            await on_task
        self.assertEqual("locked_out", caught.exception.reason)
        self.assertEqual([True, False], radio.calls)
        self.assertFalse(safety.ptt_on)

    # Production break caught: a failed hardware-on call can falsely mark RF
    # active or start its timer.
    async def test_hardware_on_failure_does_not_mark_transmitting(self):
        clock = FakeClock()
        radio = FailingPtt(fail_on=True)
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")

        with self.assertRaisesRegex(RuntimeError, "simulated radio failure"):
            await safety.request_ptt(lease, True)

        self.assertFalse(safety.ptt_on)
        self.assertEqual("device-1", safety.lease_owner)
        self.assertIsNone(safety.last_trip)
        clock.advance(180.0)
        safety.heartbeat(lease)
        self.assertIsNone(await safety.evaluate(swr=None))

    # Production break caught: a failed emergency-off can skip state, lockout,
    # lease, or audit updates.
    async def test_transport_fault_persists_dekey_required_without_stopping_recovery(self):
        clock = FakeClock()
        radio = FailingPtt(fail_on=False)
        audit_events = []
        safety = make_safety(
            radio,
            clock,
            audit_sink=lambda *args: audit_events.append(args),
        )
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        outcome = (await asyncio.gather(safety.transport_fault(), return_exceptions=True))[0]

        self.assertNotIsInstance(outcome, BaseException)
        self.assertFalse(safety.ptt_on)
        self.assertTrue(getattr(safety, "dekey_required", False))
        self.assertIsNone(safety.lease_owner)
        self.assertEqual("transport_fault", safety.last_trip.reason)
        self.assertEqual(
            [("ptt.trip", {"reason": "transport_fault"})], audit_events
        )
        self.assertNotIn(lease, repr(audit_events))
        new_lease = safety.acquire_lease("device-2")
        with self.assertRaises(PttSafetyError) as caught:
            await safety.request_ptt(new_lease, True)
        self.assertEqual("locked_out", caught.exception.reason)

    async def test_shutdown_retries_a_persisted_dekey_requirement(self):
        clock = FakeClock()
        radio = FailingPtt(fail_on=False)
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        await safety.transport_fault()
        self.assertTrue(safety.dekey_required)

        radio.fail_on = None
        await safety.shutdown()

        self.assertEqual([True, False, False], radio.calls)
        self.assertFalse(safety.dekey_required)

    # Production break caught: emergency manual-off can be blocked by auth or
    # revoke a usable lease.
    async def test_manual_off_is_unconditionally_idempotent_and_keeps_lease(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        await safety.request_ptt("wrong-token", False)
        await safety.request_ptt(None, False)

        self.assertFalse(safety.ptt_on)
        self.assertEqual("device-1", safety.lease_owner)
        self.assertIsNone(safety.last_trip)
        self.assertEqual([True, False], radio.calls)
        self.assertEqual(lease, safety.acquire_lease("device-1"))
        await safety.request_ptt(lease, True)
        self.assertTrue(safety.ptt_on)
        self.assertEqual([True, False, True], radio.calls)

    # Production break caught: treating None as the absent lease can admit unauthenticated PTT-on.
    async def test_ptt_on_and_heartbeat_require_current_exact_lease(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)

        with self.assertRaises(PttSafetyError) as no_lease:
            await safety.request_ptt(None, True)
        lease = safety.acquire_lease("device-1")
        with self.assertRaises(PttSafetyError) as wrong_request:
            await safety.request_ptt("wrong-token", True)
        with self.assertRaises(PttSafetyError) as wrong_heartbeat:
            safety.heartbeat("wrong-token")

        self.assertEqual("invalid_lease", no_lease.exception.reason)
        self.assertEqual("invalid_lease", wrong_request.exception.reason)
        self.assertEqual("invalid_lease", wrong_heartbeat.exception.reason)
        self.assertEqual("device-1", safety.lease_owner)
        self.assertEqual([], radio.calls)
        self.assertNotIn(lease, str(no_lease.exception))
        self.assertNotIn(lease, str(wrong_request.exception))
        self.assertNotIn(lease, str(wrong_heartbeat.exception))

    # Production break caught: repeated PTT-on calls can reset the hard limit and
    # duplicate hardware keying.
    async def test_repeated_ptt_on_is_idempotent_and_keeps_original_start(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        clock.advance(100.0)
        safety.heartbeat(lease)

        await safety.request_ptt(lease, True)
        clock.advance(80.0)
        safety.heartbeat(lease)
        trip = await safety.evaluate(swr=None)

        self.assertEqual("hard_limit", trip.reason)
        self.assertEqual([True, False], radio.calls)

    # Production break caught: an off-state fault can preserve authority and bypass the 3s lockout.
    async def test_off_state_faults_invalidate_lease_and_lock_out_until_deadline(self):
        for method_name in ("transport_fault", "shutdown"):
            with self.subTest(method=method_name):
                clock = FakeClock()
                radio = RecordingPtt()
                safety = make_safety(radio, clock)
                safety.acquire_lease("device-1")

                await getattr(safety, method_name)()

                self.assertIsNone(safety.lease_owner)
                self.assertIsNone(safety.last_trip)
                if method_name == "transport_fault":
                    self.assertTrue(safety.dekey_required)
                    await safety.reconcile_dekey()
                    self.assertEqual([False], radio.calls)
                else:
                    self.assertEqual([], radio.calls)
                new_lease = safety.acquire_lease("device-2")
                with self.assertRaises(PttSafetyError) as caught:
                    await safety.request_ptt(new_lease, True)
                self.assertEqual("locked_out", caught.exception.reason)
                clock.advance(3.0)
                await safety.request_ptt(new_lease, True)
                self.assertTrue(safety.ptt_on)
                expected = [False, True] if method_name == "transport_fault" else [True]
                self.assertEqual(expected, radio.calls)

    # Production break caught: process shutdown can abandon an active transmitter.
    async def test_shutdown_forces_ptt_off(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        await safety.shutdown()

        self.assertEqual("shutdown", safety.last_trip.reason)
        self.assertFalse(safety.ptt_on)
        self.assertIsNone(safety.lease_owner)
        self.assertEqual([True, False], radio.calls)

    # Production break caught: losing transport while keyed can leave safety ownership active.
    async def test_transport_fault_forces_ptt_off(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        await safety.transport_fault()

        self.assertEqual("transport_fault", safety.last_trip.reason)
        self.assertFalse(safety.ptt_on)
        self.assertIsNone(safety.lease_owner)
        self.assertEqual([True, False], radio.calls)

    # Production break caught: off-state disconnect handling can release the
    # wrong lease or retain the owner.
    async def test_disconnect_while_off_releases_only_owner_without_trip(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        safety.acquire_lease("device-1")

        await safety.client_disconnected("device-2")
        self.assertEqual("device-1", safety.lease_owner)
        await safety.client_disconnected("device-1")

        self.assertIsNone(safety.lease_owner)
        self.assertIsNone(safety.last_trip)
        self.assertEqual([], radio.calls)

    # Production break caught: a bystander disconnect can de-key the current owner.
    async def test_non_owner_disconnect_does_not_interrupt_active_transmission(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        await safety.client_disconnected("device-2")

        self.assertTrue(safety.ptt_on)
        self.assertEqual("device-1", safety.lease_owner)
        self.assertIsNone(safety.last_trip)
        self.assertEqual([True], radio.calls)
        safety.heartbeat(lease)

    # Production break caught: an owner disconnect can leave the transmitter keyed.
    async def test_owner_disconnect_forces_ptt_off(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        await safety.client_disconnected("device-1")

        self.assertEqual("client_disconnected", safety.last_trip.reason)
        self.assertFalse(safety.ptt_on)
        self.assertIsNone(safety.lease_owner)
        self.assertEqual([True, False], radio.calls)

    # Production break caught: resetting/omitting continuous-TX timing permits overlong RF.
    async def test_hard_limit_at_180_seconds_forces_ptt_off(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        clock.advance(180.0)
        safety.heartbeat(lease)

        trip = await safety.evaluate(swr=None)

        self.assertEqual("hard_limit", trip.reason)
        self.assertFalse(safety.ptt_on)
        self.assertIsNone(safety.lease_owner)
        self.assertEqual([True, False], radio.calls)

    # Production break caught: ignoring the SWR threshold can damage the transmitter.
    async def test_swr_at_threshold_forces_ptt_off(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        trip = await safety.evaluate(swr=3.0)

        self.assertEqual("swr_breach", trip.reason)
        self.assertEqual("swr_breach", safety.last_trip.reason)
        self.assertFalse(safety.ptt_on)
        self.assertIsNone(safety.lease_owner)
        self.assertEqual([True, False], radio.calls)

    # Production break caught: a stale lease can begin a fresh RF transmission.
    async def test_ptt_on_rejects_stale_heartbeat(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        clock.advance(10.1)

        with self.assertRaises(PttSafetyError) as caught:
            await safety.request_ptt(lease, True)

        self.assertEqual("heartbeat_timeout", caught.exception.reason)
        self.assertFalse(safety.ptt_on)
        self.assertEqual([], radio.calls)

    # Production break caught: validating RX/base frequency during split can key
    # an illegal TX frequency.
    async def test_split_uses_split_frequency_for_tx_admission(self):
        clock = FakeClock()
        radio = RecordingPtt()
        state = ready_state(
            split_enabled=True,
            split_frequency_hz=50_000_000,
        )
        safety = make_safety(radio, clock, state=state)
        lease = safety.acquire_lease("device-1")

        with self.assertRaises(PttSafetyError) as caught:
            await safety.request_ptt(lease, True)

        self.assertEqual("tx_out_of_range", caught.exception.reason)
        self.assertFalse(safety.ptt_on)
        self.assertEqual([], radio.calls)

    # Production break caught: unknown or undiscovered TX coverage keys RF open-loop.
    async def test_ptt_on_fails_closed_for_unknown_or_out_of_range_frequency(self):
        cases = (
            ("missing frequency", ready_state(frequency_hz=None), TX_RANGES,
             "tx_frequency_unknown"),
            ("no discovered ranges", ready_state(), (), "tx_out_of_range"),
            ("outside range", ready_state(frequency_hz=50_000_000), TX_RANGES,
             "tx_out_of_range"),
        )
        for label, state, tx_ranges, reason in cases:
            with self.subTest(label=label):
                clock = FakeClock()
                radio = RecordingPtt()
                safety = make_safety(
                    radio, clock, state=state, tx_ranges=tx_ranges
                )
                lease = safety.acquire_lease("device-1")

                with self.assertRaises(PttSafetyError) as caught:
                    await safety.request_ptt(lease, True)

                self.assertEqual(reason, caught.exception.reason)
                self.assertFalse(safety.ptt_on)
                self.assertEqual([], radio.calls)

    # Production break caught: keying outside READY transmits during startup or failure.
    async def test_ptt_on_rejects_every_non_ready_lifecycle(self):
        for lifecycle in Lifecycle:
            if lifecycle is Lifecycle.READY:
                continue
            with self.subTest(lifecycle=lifecycle):
                clock = FakeClock()
                radio = RecordingPtt()
                safety = make_safety(
                    radio, clock, state=ready_state(lifecycle=lifecycle)
                )
                lease = safety.acquire_lease("device-1")

                with self.assertRaises(PttSafetyError) as caught:
                    await safety.request_ptt(lease, True)

                self.assertEqual("not_ready", caught.exception.reason)
                self.assertFalse(safety.ptt_on)
                self.assertEqual([], radio.calls)

    # Production break caught: accepting a blank/non-text owner creates an unaccountable lease.
    async def test_invalid_device_is_typed_and_does_not_create_a_lease(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)

        for device_id in ("", "   ", 7, None):
            with self.subTest(device_id=device_id):
                with self.assertRaises(PttSafetyError) as caught:
                    safety.acquire_lease(device_id)
                self.assertEqual("invalid_device", caught.exception.reason)
                self.assertIsNone(safety.lease_owner)

    # Production break caught: replacing an existing owner lets two clients key RF.
    async def test_lease_is_idempotent_for_owner_and_busy_for_another_device(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)

        first = safety.acquire_lease("device-1")
        same = safety.acquire_lease("device-1")
        with self.assertRaises(PttSafetyError) as caught:
            safety.acquire_lease("device-2")

        self.assertEqual(first, same)
        self.assertEqual("lease_busy", caught.exception.reason)
        self.assertEqual("device-1", safety.lease_owner)

    # Production break caught: omitting the stale-heartbeat watchdog leaves RF keyed.
    async def test_heartbeat_timeout_forces_ptt_off(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = make_safety(radio, clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)

        clock.advance(10.1)
        trip = await safety.evaluate(swr=None)

        self.assertEqual([True, False], radio.calls)
        self.assertEqual("heartbeat_timeout", trip.reason)
        self.assertEqual(10.1, trip.at_monotonic)
        self.assertEqual("heartbeat_timeout", safety.last_trip.reason)
        self.assertFalse(safety.ptt_on)
        self.assertIsNone(safety.lease_owner)
