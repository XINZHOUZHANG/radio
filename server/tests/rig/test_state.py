import asyncio
import unittest

from collections import deque
from types import SimpleNamespace

from remote_radio_server.rig.errors import RigProtocolError, RigReportError
from remote_radio_server.rig.models import CommandPriority, RigResponse, RigState
from remote_radio_server.rig.state import RigStateService, RigStateStore

from tests.rig.helpers import StateServiceTransport, make_state_service


class RigStateStoreTests(unittest.TestCase):
    def test_unchanged_values_do_not_advance_revision(self):
        store = RigStateStore(RigState())

        first = store.apply({"frequency_hz": 14_074_000})

        self.assertEqual(1, first.revision)
        self.assertIsNone(store.apply({"frequency_hz": 14_074_000}))

    def test_store_owns_revision_and_rejects_unknown_keys(self):
        store = RigStateStore(RigState())

        with self.assertRaisesRegex(ValueError, "revision is owned"):
            store.apply({"revision": 0})
        with self.assertRaisesRegex(ValueError, "unknown rig state keys: mystery"):
            store.apply({"mystery": "value"})

    def test_delta_and_meter_snapshot_are_deterministically_ordered(self):
        store = RigStateStore(RigState())

        delta = store.apply({
            "vfo": "VFOA",
            "frequency_hz": 14_074_000,
            "meters": (("SWR", 1.5), ("ALC", 0.0)),
        })

        self.assertEqual(
            (("frequency_hz", 14_074_000), ("meters", (("SWR", 1.5), ("ALC", 0.0))), ("vfo", "VFOA")),
            delta.changes,
        )
        self.assertEqual(RigState(revision=1, frequency_hz=14_074_000, vfo="VFOA", meters=(("SWR", 1.5), ("ALC", 0.0))), store.snapshot())


class RigPollingTests(unittest.IsolatedAsyncioTestCase):
    async def test_poll_discards_reads_when_a_newer_command_revision_wins(self):
        """Removing the revision check must overwrite the confirmed command value."""
        service = make_state_service(readable_levels=set())
        read_started = asyncio.Event()
        release_read = asyncio.Event()
        real_request = service.transport.request

        async def gated_request(command, *args, **kwargs):
            response = await real_request(command, *args, **kwargs)
            if command == "\\get_vfo":
                read_started.set()
                await release_read.wait()
            return response

        service.transport.request = gated_request
        poll = asyncio.create_task(service.poll_once(transmitting=False))
        await read_started.wait()
        service.store.apply({"frequency_hz": 14_100_000})
        release_read.set()

        await poll

        self.assertEqual(14_100_000, service.store.snapshot().frequency_hz)
        self.assertEqual(1, service.store.snapshot().revision)

    async def test_full_refresh_reads_authoritative_split_tx_path(self):
        """Omitting split reads must leave the TX path fabricated or unknown."""
        transport = StateServiceTransport(set())
        transport.responses.update(
            {
                "\\get_split_vfo": deque(
                    (RigResponse("get_split_vfo", (("Split", "1"), ("TX VFO", "VFOB")), 0),)
                ),
                "\\get_split_freq": deque(
                    (RigResponse("get_split_freq", (("TX Frequency", "14100000"),), 0),)
                ),
                "\\get_split_mode": deque(
                    (
                        RigResponse(
                            "get_split_mode",
                            (("TX Mode", "USB"), ("TX Passband", "2400")),
                            0,
                        ),
                    )
                ),
            }
        )
        capabilities = SimpleNamespace(
            readable_levels=frozenset(),
            supports_ptt_read=False,
            supports_split_read=True,
        )
        store = RigStateStore()
        service = RigStateService(transport, capabilities, store=store)

        await service.full_refresh()

        self.assertEqual(
            (
                "\\get_freq",
                "\\get_mode",
                "\\get_vfo",
                "\\get_split_vfo",
                "\\get_split_freq",
                "\\get_split_mode",
            ),
            tuple(transport.commands),
        )
        state = store.snapshot()
        self.assertTrue(getattr(state, "split_state_known", False))
        self.assertTrue(state.split_enabled)
        self.assertEqual("VFOB", getattr(state, "split_vfo", None))
        self.assertEqual(14_100_000, state.split_frequency_hz)
        self.assertEqual("USB", state.split_mode)

    async def test_dummy_split_placeholders_are_normalized_only_when_split_is_disabled(self):
        """Parsing disabled split placeholders as a TX path must block Dummy READY."""

        def make_service(split_value):
            transport = StateServiceTransport(set())
            transport.responses.update(
                {
                    "\\get_split_vfo": deque(
                        (
                            RigResponse(
                                "get_split_vfo",
                                (("Split", split_value), ("TX VFO", "None")),
                                0,
                            ),
                        )
                    ),
                    "\\get_split_freq": deque(
                        (
                            RigResponse(
                                "get_split_freq", (("TX Frequency", "0"),), 0
                            ),
                        )
                    ),
                    "\\get_split_mode": deque(
                        (
                            RigResponse(
                                "get_split_mode",
                                (("TX Mode", ""), ("TX Passband", "0")),
                                0,
                            ),
                        )
                    ),
                }
            )
            capabilities = SimpleNamespace(
                readable_levels=frozenset(),
                supports_ptt_read=False,
                supports_split_read=True,
            )
            store = RigStateStore()
            return RigStateService(transport, capabilities, store=store), store

        with self.subTest(split="disabled"):
            service, store = make_service("0")
            try:
                await service.full_refresh()
            except RigProtocolError as error:
                self.fail(f"disabled split placeholders were rejected: {error}")
            state = store.snapshot()
            self.assertTrue(state.split_state_known)
            self.assertFalse(state.split_enabled)
            self.assertIsNone(state.split_vfo)
            self.assertIsNone(state.split_frequency_hz)
            self.assertIsNone(state.split_mode)
            self.assertIsNone(state.split_passband_hz)

        with self.subTest(split="enabled"):
            service, store = make_service("1")
            with self.assertRaisesRegex(RigProtocolError, "missing TX Mode"):
                await service.full_refresh()
            self.assertEqual(RigState(), store.snapshot())

    async def test_full_refresh_makes_every_poll_group_immediately_due(self):
        service = make_state_service(readable_levels={"STRENGTH", "SWR"})
        await service.poll_once(transmitting=True)

        delta = await service.full_refresh(transmitting=True)

        self.assertIsNone(delta)
        self.assertEqual(2, service.transport.commands.count("\\get_freq"))
        self.assertEqual(2, service.transport.commands.count("\\get_level STRENGTH"))
        self.assertEqual(2, service.transport.commands.count("\\get_level SWR"))

    async def test_failed_full_refresh_keeps_every_group_due_for_immediate_retry(self):
        service = make_state_service(readable_levels={"STRENGTH", "SWR"})
        await service.poll_once(transmitting=True)
        service.transport.responses["\\get_level SWR"] = deque((
            RigReportError(-12),
            RigResponse("get_level", (), 0, ("1.25",)),
        ))

        with self.assertRaises(RigReportError):
            await service.full_refresh(transmitting=True)
        retry = await service.poll_once(transmitting=True)

        self.assertIsNotNone(retry)
        self.assertEqual(3, service.transport.commands.count("\\get_freq"))
        self.assertEqual(3, service.transport.commands.count("\\get_level STRENGTH"))
        self.assertEqual(3, service.transport.commands.count("\\get_level SWR"))

    async def test_core_state_is_polled_at_five_hz(self):
        service = make_state_service(readable_levels=set())

        await service.poll_once(transmitting=False)
        service.clock.advance(0.1)
        self.assertIsNone(await service.poll_once(transmitting=False))
        service.clock.advance(0.1)
        await service.poll_once(transmitting=False)

        self.assertEqual(
            ["\\get_freq", "\\get_mode", "\\get_vfo"] * 2,
            service.transport.commands,
        )

    async def test_first_tick_reads_named_core_state_and_supported_ptt_at_polling_priority(self):
        service = make_state_service(readable_levels=set(), supports_ptt_read=True)

        delta = await service.poll_once(transmitting=False)

        self.assertEqual(
            ["\\get_freq", "\\get_mode", "\\get_vfo", "\\get_ptt"],
            service.transport.commands,
        )
        self.assertEqual(1, delta.revision)
        self.assertEqual(14_074_000, service.store.snapshot().frequency_hz)
        self.assertEqual("USB", service.store.snapshot().mode)
        self.assertEqual(2_400, service.store.snapshot().passband_hz)
        self.assertEqual("VFOA", service.store.snapshot().vfo)
        self.assertTrue(service.store.snapshot().ptt)
        self.assertTrue(all(
            args == (CommandPriority.POLLING,) and not kwargs
            for _, args, kwargs in service.transport.requests
        ))

    async def test_tx_meters_poll_at_most_ten_hz(self):
        service = make_state_service(readable_levels={"SWR"})

        await service.poll_once(transmitting=True)
        service.clock.advance(0.05)
        self.assertIsNone(await service.poll_once(transmitting=True))
        service.clock.advance(0.05)
        await service.poll_once(transmitting=True)

        self.assertEqual(2, service.transport.commands.count("\\get_level SWR"))

    async def test_ordinary_discovered_meters_poll_at_two_hz(self):
        service = make_state_service(readable_levels={"STRENGTH"})

        await service.poll_once(transmitting=False)
        service.clock.advance(0.2)
        await service.poll_once(transmitting=False)
        service.clock.advance(0.3)
        await service.poll_once(transmitting=False)

        self.assertEqual(2, service.transport.commands.count("\\get_level STRENGTH"))
        self.assertEqual((("STRENGTH", 1.5),), service.store.snapshot().meters)

    async def test_tx_poll_reads_swr_only_when_supported(self):
        service = make_state_service(readable_levels={"SWR", "ALC"})

        await service.poll_once(transmitting=True)

        self.assertIn("\\get_level SWR", service.transport.commands)
        self.assertNotIn("\\get_level RFPOWER_METER", service.transport.commands)
        self.assertEqual((("ALC", 1.5), ("SWR", 1.5)), service.store.snapshot().meters)

    async def test_named_meter_fallback_preserves_real_unlabelled_values_and_skips_malformed_values(self):
        service = make_state_service(readable_levels={"STRENGTH", "SWR"})
        service.transport.responses["\\get_level STRENGTH"] = deque((
            RigResponse("get_level", (("STRENGTH", "-73"),), 0),
        ))
        service.transport.responses["\\get_level SWR"] = deque((
            RigResponse("get_level", (), 0, ("not-a-number",)),
        ))

        await service.poll_once(transmitting=True)

        self.assertEqual((("STRENGTH", -73.0),), service.store.snapshot().meters)

    async def test_malformed_swr_read_invalidates_the_previous_measurement(self):
        """Merge-only meter updates must leave the old low SWR in the snapshot."""
        service = make_state_service(readable_levels={"SWR"})
        await service.poll_once(transmitting=True)
        self.assertEqual(1.5, dict(service.store.snapshot().meters)["SWR"])
        service.clock.advance(0.1)
        service.transport.responses["\\get_level SWR"] = deque(
            (RigResponse("get_level", (), 0, ("not-a-number",)),)
        )

        await service.poll_once(transmitting=True)

        self.assertNotIn("SWR", dict(service.store.snapshot().meters))

    async def test_failed_swr_read_invalidates_the_previous_measurement(self):
        """A failed meter request must not let an old value masquerade as fresh."""
        service = make_state_service(readable_levels={"SWR"})
        await service.poll_once(transmitting=True)
        service.clock.advance(0.1)
        service.transport.responses["\\get_level SWR"] = deque((RigReportError(-12),))

        with self.assertRaises(RigReportError):
            await service.poll_once(transmitting=True)

        self.assertNotIn("SWR", dict(service.store.snapshot().meters))

    async def test_failed_request_leaves_the_whole_tick_unapplied(self):
        service = make_state_service(readable_levels={"SWR"})
        service.transport.responses["\\get_mode"] = deque((RigReportError(-12),))

        with self.assertRaises(RigReportError):
            await service.poll_once(transmitting=True)

        self.assertEqual(RigState(), service.store.snapshot())

    async def test_same_clock_retry_rereads_every_due_group_after_late_meter_failure(self):
        service = make_state_service(readable_levels={"STRENGTH", "SWR"})
        service.transport.responses["\\get_level SWR"] = deque((
            RigReportError(-12),
            RigResponse("get_level", (), 0, ("1.25",)),
        ))

        with self.assertRaises(RigReportError):
            await service.poll_once(transmitting=True)
        self.assertEqual(RigState(), service.store.snapshot())

        retry = await service.poll_once(transmitting=True)

        self.assertEqual(
            [
                "\\get_freq", "\\get_mode", "\\get_vfo", "\\get_level STRENGTH", "\\get_level SWR",
                "\\get_freq", "\\get_mode", "\\get_vfo", "\\get_level STRENGTH", "\\get_level SWR",
            ],
            service.transport.commands,
        )
        self.assertEqual(1, retry.revision)
        self.assertEqual(14_074_000, service.store.snapshot().frequency_hz)
        self.assertEqual("USB", service.store.snapshot().mode)
        self.assertEqual(2_400, service.store.snapshot().passband_hz)
        self.assertEqual("VFOA", service.store.snapshot().vfo)
        self.assertEqual(
            (("STRENGTH", 1.5), ("SWR", 1.25)),
            service.store.snapshot().meters,
        )

    async def test_malformed_required_core_values_fail_explicitly(self):
        service = make_state_service(readable_levels=set())
        service.transport.responses["\\get_freq"] = deque((
            RigResponse("get_freq", (("Frequency", "not-a-frequency"),), 0),
        ))

        with self.assertRaisesRegex(RigProtocolError, "malformed Frequency"):
            await service.poll_once(transmitting=False)

        self.assertEqual(RigState(), service.store.snapshot())



if __name__ == "__main__":
    unittest.main()
