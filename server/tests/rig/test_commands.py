import asyncio
import unittest

from remote_radio_server.rig.errors import RigProtocolError, RigReportError, RigTransportError
from remote_radio_server.rig.models import CommandPriority, RigResponse
from tests.rig.helpers import DeferredResponse, make_command_service
from tests.rig.helpers import ok, value


class RigCommandServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_rejects_frequency_outside_tx_range_before_transport(self):
        service = make_command_service(tx_ranges=((14_000_000, 14_350_000),))

        result = await service.set_frequency(50_000_000, transmitting=True)

        self.assertEqual("invalid", result.status)
        self.assertEqual([], service.transport.commands)

    async def test_frequency_write_is_read_back_with_user_priorities(self):
        service = make_command_service(
            script=[ok("set_freq"), value("get_freq", Frequency="14074000")]
        )

        result = await service.set_frequency(14_074_000, transmitting=False)

        self.assertEqual("confirmed", result.status)
        self.assertEqual(1, result.revision)
        self.assertEqual(
            (
                ("\\set_freq 14074000", (CommandPriority.USER_WRITE,), {}),
                ("\\get_freq", (CommandPriority.USER_READ,), {}),
            ),
            tuple(service.transport.requests),
        )
        self.assertEqual(14_074_000, service.store.snapshot().frequency_hz)

    async def test_rejects_invalid_or_undiscovered_arguments_before_transport(self):
        service = make_command_service(tx_ranges=((14_000_000, 14_350_000),))
        cases = (
            ("boolean frequency", lambda: service.set_frequency(True), "invalid"),
            (
                "non-boolean transmitting flag",
                lambda: service.set_frequency(14_074_000, transmitting="yes"),
                "invalid",
            ),
            ("undiscovered mode", lambda: service.set_mode("CW"), "unsupported"),
            ("boolean passband", lambda: service.set_mode("USB", True), "invalid"),
            (
                "undiscovered level",
                lambda: service.set_level("SWR", 0.5),
                "unsupported",
            ),
            ("boolean level value", lambda: service.set_level("AF", True), "invalid"),
            (
                "undiscovered function",
                lambda: service.set_func("NR", True),
                "unsupported",
            ),
            ("non-boolean function value", lambda: service.set_func("NB", 1), "invalid"),
            (
                "undiscovered split VFO",
                lambda: service.set_split(True, "VFOZ"),
                "unsupported",
            ),
            (
                "split frequency outside TX range",
                lambda: service.set_split(True, "VFOB", frequency_hz=50_000_000),
                "invalid",
            ),
        )

        for label, invoke, expected_status in cases:
            with self.subTest(label=label):
                result = await invoke()
                self.assertEqual(expected_status, result.status)
        self.assertEqual([], service.transport.commands)

    async def test_frequency_mismatch_rejects_but_stores_authoritative_read_back(self):
        service = make_command_service(
            script=[ok("set_freq"), value("get_freq", Frequency="14075000")]
        )

        result = await service.set_frequency(14_074_000)

        self.assertEqual("rejected", result.status)
        self.assertEqual(1, result.revision)
        self.assertEqual(14_075_000, service.store.snapshot().frequency_hz)

    async def test_mode_write_normalizes_and_confirms_mode_and_passband(self):
        service = make_command_service(
            script=[
                ok("set_mode"),
                value("get_mode", Mode="USB", Passband="2400"),
            ]
        )

        result = await service.set_mode("usb", 2400)

        self.assertEqual("confirmed", result.status)
        self.assertEqual(1, result.revision)
        self.assertEqual(
            (
                ("\\set_mode USB 2400", (CommandPriority.USER_WRITE,), {}),
                ("\\get_mode", (CommandPriority.USER_READ,), {}),
            ),
            tuple(service.transport.requests),
        )
        state = service.store.snapshot()
        self.assertEqual("USB", state.mode)
        self.assertEqual(2400, state.passband_hz)

    async def test_mode_mismatch_rejects_after_storing_actual_mode_and_passband(self):
        service = make_command_service(
            script=[
                ok("set_mode"),
                value("get_mode", Mode="LSB", Passband="2100"),
            ]
        )

        result = await service.set_mode("USB", 2400)

        self.assertEqual("rejected", result.status)
        state = service.store.snapshot()
        self.assertEqual("LSB", state.mode)
        self.assertEqual(2100, state.passband_hz)

    async def test_level_confirmation_prefers_real_unlabelled_value(self):
        read_back = RigResponse(
            "get_level", (("AF", "0.99"),), 0, ("0.25",)
        )
        service = make_command_service(script=[ok("set_level"), read_back])

        result = await service.set_level("af", 0.25)

        self.assertEqual("confirmed", result.status)
        self.assertEqual(0, result.revision)
        self.assertEqual(
            (
                ("\\set_level AF 0.25", (CommandPriority.USER_WRITE,), {}),
                ("\\get_level AF", (CommandPriority.USER_READ,), {}),
            ),
            tuple(service.transport.requests),
        )

    async def test_level_mismatch_is_rejected_without_advancing_state(self):
        service = make_command_service(
            script=[
                ok("set_level"),
                RigResponse("get_level", (), 0, ("0.5",)),
            ]
        )

        result = await service.set_level("AF", 0.25)

        self.assertEqual("rejected", result.status)
        self.assertEqual(0, result.revision)

    async def test_function_confirmation_prefers_real_unlabelled_value(self):
        read_back = RigResponse("get_func", (("NB", "0"),), 0, ("1",))
        service = make_command_service(script=[ok("set_func"), read_back])

        result = await service.set_func("nb", True)

        self.assertEqual("confirmed", result.status)
        self.assertEqual(0, result.revision)
        self.assertEqual(
            (
                ("\\set_func NB 1", (CommandPriority.USER_WRITE,), {}),
                ("\\get_func NB", (CommandPriority.USER_READ,), {}),
            ),
            tuple(service.transport.requests),
        )

    async def test_function_mismatch_is_rejected(self):
        service = make_command_service(
            script=[ok("set_func"), RigResponse("get_func", (), 0, ("0",))]
        )

        result = await service.set_func("NB", True)

        self.assertEqual("rejected", result.status)
        self.assertEqual(0, result.revision)

    async def test_split_writes_each_requested_part_and_confirms_state(self):
        service = make_command_service(
            tx_ranges=((14_000_000, 14_350_000),),
            script=[
                ok("set_split_vfo"),
                value("get_split_vfo", Split="1", **{"TX VFO": "VFOB"}),
                ok("set_split_freq"),
                value("get_split_freq", **{"TX Frequency": "14076000"}),
                ok("set_split_mode"),
                value(
                    "get_split_mode",
                    **{"TX Mode": "USB", "TX Passband": "2400"},
                ),
            ],
        )

        result = await service.set_split(
            True,
            "vfob",
            frequency_hz=14_076_000,
            mode="usb",
            passband_hz=2400,
        )

        self.assertEqual("confirmed", result.status)
        self.assertEqual(3, result.revision)
        self.assertEqual(
            (
                ("\\set_split_vfo 1 VFOB", (CommandPriority.USER_WRITE,), {}),
                ("\\get_split_vfo", (CommandPriority.USER_READ,), {}),
                ("\\set_split_freq 14076000", (CommandPriority.USER_WRITE,), {}),
                ("\\get_split_freq", (CommandPriority.USER_READ,), {}),
                ("\\set_split_mode USB 2400", (CommandPriority.USER_WRITE,), {}),
                ("\\get_split_mode", (CommandPriority.USER_READ,), {}),
            ),
            tuple(service.transport.requests),
        )
        state = service.store.snapshot()
        self.assertTrue(state.split_enabled)
        self.assertEqual(14_076_000, state.split_frequency_hz)
        self.assertEqual("USB", state.split_mode)

    async def test_split_mismatch_rejects_and_stops_later_writes(self):
        service = make_command_service(
            tx_ranges=((14_000_000, 14_350_000),),
            script=[
                ok("set_split_vfo"),
                value("get_split_vfo", Split="0", **{"TX VFO": "VFOA"}),
            ],
        )

        result = await service.set_split(
            True, "VFOB", frequency_hz=14_076_000, mode="USB"
        )

        self.assertEqual("rejected", result.status)
        self.assertFalse(service.store.snapshot().split_enabled)
        self.assertEqual(
            ("\\set_split_vfo 1 VFOB", "\\get_split_vfo"),
            tuple(service.transport.commands),
        )

    async def test_split_optional_mismatches_store_actual_confirmed_values(self):
        frequency_service = make_command_service(
            tx_ranges=((14_000_000, 14_350_000),),
            script=[
                ok("set_split_vfo"),
                value("get_split_vfo", Split="1", **{"TX VFO": "VFOB"}),
                ok("set_split_freq"),
                value("get_split_freq", **{"TX Frequency": "14077000"}),
            ],
        )
        frequency_result = await frequency_service.set_split(
            True, "VFOB", frequency_hz=14_076_000
        )
        self.assertEqual("rejected", frequency_result.status)
        self.assertEqual(
            14_077_000, frequency_service.store.snapshot().split_frequency_hz
        )

        mode_service = make_command_service(
            script=[
                ok("set_split_vfo"),
                value("get_split_vfo", Split="1", **{"TX VFO": "VFOB"}),
                ok("set_split_mode"),
                value(
                    "get_split_mode",
                    **{"TX Mode": "LSB", "TX Passband": "2100"},
                ),
            ]
        )
        mode_result = await mode_service.set_split(
            True, "VFOB", mode="USB", passband_hz=2400
        )
        self.assertEqual("rejected", mode_result.status)
        self.assertEqual("LSB", mode_service.store.snapshot().split_mode)

    async def test_first_write_report_errors_are_typed_and_preserve_code(self):
        cases = ((-4, "unsupported"), (-1, "hardware_error"))

        for code, expected_status in cases:
            with self.subTest(code=code):
                service = make_command_service(
                    script=[("\\set_mode USB 0", RigReportError(code))]
                )
                result = await service.set_mode("USB")
                self.assertEqual(expected_status, result.status)
                self.assertEqual(code, result.hamlib_code)
                self.assertEqual(("\\set_mode USB 0",), tuple(service.transport.commands))

    async def test_each_typed_mutation_maps_a_first_write_failure(self):
        cases = (
            ("frequency", "\\set_freq 14074000", lambda service: service.set_frequency(14_074_000)),
            ("level", "\\set_level AF 0.25", lambda service: service.set_level("AF", 0.25)),
            ("function", "\\set_func NB 1", lambda service: service.set_func("NB", True)),
            ("split", "\\set_split_vfo 1 VFOB", lambda service: service.set_split(True, "VFOB")),
        )

        for label, command, invoke in cases:
            with self.subTest(label=label):
                service = make_command_service(
                    script=[(command, RigReportError(-1))]
                )
                result = await invoke(service)
                self.assertEqual("hardware_error", result.status)
                self.assertEqual(-1, result.hamlib_code)
                self.assertEqual((command,), tuple(service.transport.commands))

    async def test_uncertain_write_or_confirmation_failures_return_unknown_result(self):
        cases = (
            (
                "transport failure during first write",
                [("\\set_mode USB 0", RigTransportError("disconnected"))],
                None,
            ),
            (
                "failed confirmation report",
                [ok("set_mode"), ("\\get_mode", RigReportError(-1))],
                -1,
            ),
            (
                "malformed confirmation",
                [ok("set_mode"), value("get_mode", Mode="USB", Passband="bad")],
                None,
            ),
        )

        for label, script, expected_code in cases:
            with self.subTest(label=label):
                service = make_command_service(script=script)
                result = await service.set_mode("USB")
                self.assertEqual("unknown_result", result.status)
                self.assertEqual(expected_code, result.hamlib_code)
                self.assertEqual(0, service.store.snapshot().revision)

    async def test_malformed_mode_token_is_unknown_without_state_update(self):
        service = make_command_service(
            script=[
                ok("set_mode"),
                value("get_mode", Mode="USB BAD", Passband="2400"),
            ]
        )

        result = await service.set_mode("USB", 2400)

        self.assertEqual("unknown_result", result.status)
        state = service.store.snapshot()
        self.assertEqual(0, state.revision)
        self.assertIsNone(state.mode)
        self.assertIsNone(state.passband_hz)

    async def test_malformed_split_vfo_token_is_unknown_without_state_update(self):
        service = make_command_service(
            script=[
                ok("set_split_vfo"),
                value("get_split_vfo", Split="1", **{"TX VFO": "VFO B"}),
            ]
        )

        result = await service.set_split(True, "VFOB")

        self.assertEqual("unknown_result", result.status)
        state = service.store.snapshot()
        self.assertEqual(0, state.revision)
        self.assertFalse(state.split_enabled)

    async def test_malformed_split_mode_token_does_not_advance_confirmed_revision(self):
        service = make_command_service(
            script=[
                ok("set_split_vfo"),
                value("get_split_vfo", Split="1", **{"TX VFO": "VFOB"}),
                ok("set_split_mode"),
                value(
                    "get_split_mode",
                    **{"TX Mode": "USB BAD", "TX Passband": "2400"},
                ),
            ]
        )

        result = await service.set_split(
            True, "VFOB", mode="USB", passband_hz=2400
        )

        self.assertEqual("unknown_result", result.status)
        state = service.store.snapshot()
        self.assertEqual(1, state.revision)
        self.assertTrue(state.split_enabled)
        self.assertIsNone(state.split_mode)

    async def test_valid_textual_confirmations_are_normalized_consistently(self):
        mode_service = make_command_service(
            script=[
                ok("set_mode"),
                value("get_mode", Mode="usb", Passband="2400"),
            ]
        )
        mode_result = await mode_service.set_mode("USB", 2400)
        self.assertEqual("confirmed", mode_result.status)
        self.assertEqual("USB", mode_service.store.snapshot().mode)

        split_service = make_command_service(
            script=[
                ok("set_split_vfo"),
                value("get_split_vfo", Split="1", **{"TX VFO": "vfob"}),
                ok("set_split_mode"),
                value(
                    "get_split_mode",
                    **{"TX Mode": "usb", "TX Passband": "2400"},
                ),
            ]
        )
        split_result = await split_service.set_split(
            True, "VFOB", mode="USB", passband_hz=2400
        )
        self.assertEqual("confirmed", split_result.status)
        self.assertEqual("USB", split_service.store.snapshot().split_mode)

    async def test_cancellation_is_not_swallowed(self):
        service = make_command_service(
            script=[("\\set_mode USB 0", asyncio.CancelledError())]
        )

        with self.assertRaises(asyncio.CancelledError):
            await service.set_mode("USB")

    async def test_each_mutation_maps_confirmation_failure_to_unknown_result(self):
        cases = (
            (
                [ok("set_freq"), ("\\get_freq", RigProtocolError("bad"))],
                lambda service: service.set_frequency(14_074_000),
            ),
            (
                [ok("set_level"), ("\\get_level AF", RigProtocolError("bad"))],
                lambda service: service.set_level("AF", 0.25),
            ),
            (
                [ok("set_func"), ("\\get_func NB", RigProtocolError("bad"))],
                lambda service: service.set_func("NB", True),
            ),
            (
                [
                    ok("set_split_vfo"),
                    ("\\get_split_vfo", RigProtocolError("bad")),
                ],
                lambda service: service.set_split(True, "VFOB"),
            ),
        )

        for script, invoke in cases:
            service = make_command_service(script=script)
            result = await invoke(service)
            self.assertEqual("unknown_result", result.status)
            self.assertEqual(0, service.store.snapshot().revision)

    async def test_later_split_write_failure_is_unknown_and_keeps_confirmed_state(self):
        service = make_command_service(
            tx_ranges=((14_000_000, 14_350_000),),
            script=[
                ok("set_split_vfo"),
                value("get_split_vfo", Split="1", **{"TX VFO": "VFOB"}),
                ("\\set_split_freq 14076000", RigReportError(-4)),
            ],
        )

        result = await service.set_split(
            True, "VFOB", frequency_hz=14_076_000, mode="USB"
        )

        self.assertEqual("unknown_result", result.status)
        self.assertEqual(-4, result.hamlib_code)
        self.assertEqual(1, service.store.snapshot().revision)
        self.assertTrue(service.store.snapshot().split_enabled)
        self.assertIsNone(service.store.snapshot().split_frequency_hz)
        self.assertEqual(
            (
                "\\set_split_vfo 1 VFOB",
                "\\get_split_vfo",
                "\\set_split_freq 14076000",
            ),
            tuple(service.transport.commands),
        )

    async def test_frequency_requests_coalesce_for_80_ms_and_cancellation_isolated(self):
        service = make_command_service(
            script=[ok("set_freq"), value("get_freq", Frequency="14076000")]
        )
        service.sleep.block = True
        cancelled = asyncio.create_task(service.set_frequency(14_074_000))
        survivor = asyncio.create_task(service.set_frequency(14_075_000))
        latest = asyncio.create_task(service.set_frequency(14_076_000))

        await service.sleep.wait_until_blocked()
        cancelled.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await cancelled
        self.assertEqual([], service.transport.commands)
        service.sleep.release_next()
        survivor_result, latest_result = await asyncio.gather(survivor, latest)

        self.assertEqual("superseded", survivor_result.status)
        self.assertEqual("confirmed", latest_result.status)
        self.assertEqual([0.08], service.sleep.calls)
        self.assertEqual(
            ("\\set_freq 14076000", "\\get_freq"),
            tuple(service.transport.commands),
        )

    async def test_close_cancels_and_waits_for_the_owned_frequency_debounce_task(self):
        """Dropping service close ownership must leave a delayed write alive."""
        service = make_command_service(
            script=[ok("set_freq"), value("get_freq", Frequency="14074000")]
        )
        service.sleep.block = True
        pending = asyncio.create_task(service.set_frequency(14_074_000))
        await service.sleep.wait_until_blocked()
        try:
            self.assertTrue(
                hasattr(service, "close"),
                "RigCommandService must own a close operation for its debounce task",
            )
            await service.close()
            result = await pending
            self.assertEqual("unknown_result", result.status)
            self.assertEqual([], service.transport.commands)
        finally:
            if not pending.done():
                service.sleep.release_next()
                await asyncio.gather(pending, return_exceptions=True)

    async def test_frequency_request_after_detach_starts_a_later_batch(self):
        first_write = DeferredResponse(ok("set_freq"))
        service = make_command_service(
            script=[
                ("\\set_freq 14074000", first_write),
                value("get_freq", Frequency="14074000"),
                ok("set_freq"),
                value("get_freq", Frequency="14075000"),
            ]
        )
        service.sleep.block = True
        first = asyncio.create_task(service.set_frequency(14_074_000))
        await service.sleep.wait_until_blocked()
        service.sleep.release_next()
        await first_write.started.wait()

        second = asyncio.create_task(service.set_frequency(14_075_000))
        for _ in range(3):
            await asyncio.sleep(0)
        self.assertEqual([0.08, 0.08], service.sleep.calls)

        first_write.released.set()
        first_result = await first
        service.sleep.release_next()
        second_result = await second
        self.assertEqual("confirmed", first_result.status)
        self.assertEqual("confirmed", second_result.status)
        self.assertEqual(
            (
                "\\set_freq 14074000",
                "\\get_freq",
                "\\set_freq 14075000",
                "\\get_freq",
            ),
            tuple(service.transport.commands),
        )

    async def test_raw_admin_audits_redacted_metadata_before_confirmed_write(self):
        service = make_command_service(
            script=[ok("send_raw")], rig_identity=("Yaesu", "FT-710")
        )

        result = await service.send_raw_admin("; ID", is_admin=True)

        self.assertEqual("confirmed", result.status)
        self.assertEqual(0, result.revision)
        self.assertEqual(
            (("rig.raw_admin", {"terminator": ";", "payload_bytes": 2}),),
            tuple(service.audit_events),
        )
        self.assertNotIn("ID", repr(service.audit_events))
        self.assertEqual([0], service.audit_transport_counts)
        self.assertEqual(
            (("\\send_raw ; ID", (CommandPriority.USER_READ,), {}),),
            tuple(service.transport.requests),
        )

    async def test_raw_admin_rejects_mutating_cat_outside_positive_allowlist(self):
        """Restoring grammar-only raw access must transmit this CAT TX command."""
        service = make_command_service(
            script=[ok("send_raw")], rig_identity=("Yaesu", "FT-710")
        )

        result = await service.send_raw_admin("; TX1", is_admin=True)

        self.assertEqual("unsupported", result.status)
        self.assertEqual([], service.audit_events)
        self.assertEqual([], service.transport.commands)

    async def test_raw_admin_rejects_unauthorized_or_invalid_grammar_before_audit(self):
        cases = (
            ("unauthorized before parsing", "\n", False, "unsupported"),
            ("missing payload", "CR", True, "invalid"),
            ("leading whitespace", " CR FE", True, "invalid"),
            ("trailing whitespace", "CR FE ", True, "invalid"),
            ("payload whitespace", "CR FE FE", True, "invalid"),
            ("newline", "CR FE\n", True, "invalid"),
            ("non-ASCII", "CR café", True, "invalid"),
            ("over 4096 bytes", "CR " + "A" * 4094, True, "invalid"),
            ("bad named terminator", "BAD FE", True, "invalid"),
            ("numeric terminator below range", "-2 FE", True, "invalid"),
            ("numeric terminator above range", "101 FE", True, "invalid"),
        )

        for label, raw_request, is_admin, expected_status in cases:
            with self.subTest(label=label):
                service = make_command_service()
                result = await service.send_raw_admin(
                    raw_request, is_admin=is_admin
                )
                self.assertEqual(expected_status, result.status)
                self.assertEqual([], service.audit_events)
                self.assertEqual([], service.transport.commands)

    async def test_raw_admin_rejects_unlisted_model_terminator_payload_pairs(self):
        for raw_request in ("LF AA", "ICOM AA", "-1 AA", "0 AA", "100 AA"):
            with self.subTest(raw_request=raw_request):
                service = make_command_service(
                    script=[ok("send_raw")], rig_identity=("Yaesu", "FT-710")
                )
                result = await service.send_raw_admin(raw_request, is_admin=True)
                self.assertEqual("unsupported", result.status)
                self.assertEqual([], service.transport.commands)

    async def test_raw_admin_maps_report_and_transport_failures_after_audit(self):
        cases = (
            (RigReportError(-4), "unsupported", -4),
            (RigReportError(-1), "hardware_error", -1),
            (RigTransportError("lost"), "unknown_result", None),
        )

        for error, expected_status, expected_code in cases:
            with self.subTest(status=expected_status):
                service = make_command_service(
                    script=[("\\send_raw ; ID", error)],
                    rig_identity=("Yaesu", "FT-710"),
                )
                result = await service.send_raw_admin("; ID", is_admin=True)
                self.assertEqual(expected_status, result.status)
                self.assertEqual(expected_code, result.hamlib_code)
                self.assertEqual(1, len(service.audit_events))
                self.assertEqual(("\\send_raw ; ID",), tuple(service.transport.commands))

    async def test_zero_passband_confirms_backend_selected_mode_width(self):
        mode_service = make_command_service(
            script=[
                ok("set_mode"),
                value("get_mode", Mode="USB", Passband="2400"),
            ]
        )
        mode_result = await mode_service.set_mode("USB")
        self.assertEqual("confirmed", mode_result.status)
        self.assertEqual(2400, mode_service.store.snapshot().passband_hz)

        split_service = make_command_service(
            script=[
                ok("set_split_vfo"),
                value("get_split_vfo", Split="1", **{"TX VFO": "VFOB"}),
                ok("set_split_mode"),
                value(
                    "get_split_mode",
                    **{"TX Mode": "USB", "TX Passband": "2400"},
                ),
            ]
        )
        split_result = await split_service.set_split(True, "VFOB", mode="USB")
        self.assertEqual("confirmed", split_result.status)
