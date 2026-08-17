import unittest

from remote_radio_server.rig.capabilities import CapabilityService, parse_dump_caps
from remote_radio_server.rig.models import CommandPriority, RigResponse
from remote_radio_server.rig.errors import RigReportError

from tests.rig.helpers import ScriptedTransport, fixture_response, ok, response


class CapabilityServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_discovers_read_and_write_tokens_without_fabricated_swr(self):
        transport = ScriptedTransport({
            "\\hamlib_version": response("hamlib_version", Version="4.6.5"),
            "\\dump_caps": fixture_response("dummy_caps.txt"),
            "\\get_mode ?": response("get_mode", Mode="AM FM USB LSB"),
            "\\get_level ?": response("get_level", Level="STRENGTH AF"),
            "\\set_level ?": response("set_level", Level="AF RFPOWER"),
            "\\get_func ?": response("get_func", Func="NB NR"),
            "\\set_func ?": response("set_func", Func="NB NR"),
        })
        caps = await CapabilityService(transport).discover()
        self.assertIn("STRENGTH", caps.readable_levels)
        self.assertNotIn("SWR", caps.readable_levels)
        self.assertIn("RFPOWER", caps.writable_levels)

    async def test_uses_raw_hamlib_help_and_version_payloads_without_treating_current_mode_as_a_list(self):
        transport = ScriptedTransport({
            "\\hamlib_version": RigResponse(
                "hamlib_version", (), 0, ("rigctl(d), Hamlib 4.7.1 build\nCopyright text",)
            ),
            "\\dump_caps": fixture_response("dummy_caps.txt"),
            "\\get_mode ?": RigResponse("get_mode", (), 0, ("USB\n2400",)),
            "\\get_level ?": RigResponse("get_level", (), 0, ("PREAMP AF SWR ",)),
            "\\set_level ?": RigResponse("set_level", (), 0, ("PREAMP AF RFPOWER ",)),
            "\\get_func ?": RigResponse("get_func", (), 0, ("NB NR ",)),
            "\\set_func ?": RigResponse("set_func", (), 0, ("NB NR ",)),
        })

        caps = await CapabilityService(transport).discover()

        self.assertEqual("rigctl(d), Hamlib 4.7.1 build", caps.identity.hamlib_version)
        self.assertEqual(frozenset({"AM", "CW", "USB", "LSB", "RTTY", "FM", "WFM", "CWR", "RTTYR"}), caps.modes)
        self.assertEqual(frozenset({"PREAMP", "AF", "SWR"}), caps.readable_levels)
        self.assertEqual(frozenset({"PREAMP", "AF", "RFPOWER"}), caps.writable_levels)

    async def test_unions_only_the_observed_current_mode_with_dump_mode_list(self):
        transport = ScriptedTransport({
            "\\hamlib_version": response("hamlib_version", Version="4.7.1"),
            "\\dump_caps": RigResponse(
                "dump_caps", (("Caps dump for model", "1\nMode list: AM"),), 0
            ),
            "\\get_mode ?": response("get_mode", Mode="DIGU", Passband="2400"),
            "\\get_level ?": response("get_level", Level="AF"),
            "\\set_level ?": response("set_level", Level="AF"),
            "\\get_func ?": response("get_func", Func="NB"),
            "\\set_func ?": response("set_func", Func="NB"),
        })

        caps = await CapabilityService(transport).discover()

        self.assertEqual(frozenset({"AM", "DIGU"}), caps.modes)
        self.assertNotIn("2400", caps.modes)

    async def test_uses_exact_read_only_discovery_order_and_merges_dump_only_controls(self):
        transport = ScriptedTransport({
            "\\hamlib_version": response("hamlib_version", Version="4.6.5"),
            "\\dump_caps": fixture_response("dummy_caps.txt"),
            "\\get_mode ?": response("get_mode", Mode="AM FM"),
            "\\get_level ?": response("get_level", Level="STRENGTH"),
            "\\set_level ?": response("set_level", Level="AF"),
            "\\get_func ?": response("get_func", Func="NB"),
            "\\set_func ?": response("set_func", Func="NB"),
        })

        caps = await CapabilityService(transport).discover()

        self.assertEqual(frozenset({"ANN", "APO", "BACKLIGHT", "BEEP"}), caps.readable_parameters)
        self.assertEqual(frozenset({"ANN", "APO", "BACKLIGHT", "BEEP"}), caps.writable_parameters)
        self.assertIn("TOGGLE", caps.vfo_operations)
        self.assertEqual(
            [
                "\\hamlib_version", "\\dump_caps", "\\get_mode ?", "\\get_level ?",
                "\\set_level ?", "\\get_func ?", "\\set_func ?",
            ],
            [command for command, _, _ in transport.requests],
        )
        self.assertTrue(all(
            args == (CommandPriority.DISCOVERY, 2.0) and not kwargs
            for _, args, kwargs in transport.requests
        ))
        self.assertTrue(all(" ?" in command or command in {"\\hamlib_version", "\\dump_caps"}
                            for command, _, _ in transport.requests))

    async def test_omits_only_an_explicitly_unsupported_optional_token_query(self):
        transport = ScriptedTransport({
            "\\hamlib_version": response("hamlib_version", Version="4.6.5"),
            "\\dump_caps": fixture_response("dummy_caps.txt"),
            "\\get_mode ?": response("get_mode", Mode="AM"),
            "\\get_level ?": response("get_level", Level="STRENGTH"),
            "\\set_level ?": response("set_level", Level="AF"),
            "\\get_func ?": RigReportError(-4),
            "\\set_func ?": response("set_func", Func="NB"),
        })

        caps = await CapabilityService(transport).discover()

        self.assertEqual(frozenset(), caps.readable_functions)
        self.assertEqual(frozenset({"NB"}), caps.writable_functions)

    async def test_propagates_a_non_unsupported_optional_query_error(self):
        transport = ScriptedTransport({
            "\\hamlib_version": response("hamlib_version", Version="4.6.5"),
            "\\dump_caps": fixture_response("dummy_caps.txt"),
            "\\get_mode ?": RigReportError(-12),
        })

        with self.assertRaisesRegex(RigReportError, "Hamlib report -12"):
            await CapabilityService(transport).discover()


class DumpCapsTests(unittest.TestCase):
    def test_discovers_split_read_and_write_only_from_positive_capability_evidence(self):
        """Ignoring split capability records must leave both operations unmodelled."""
        draft = parse_dump_caps(
            (
                ("Mfg name", "Test"),
                ("Model name", "Split Rig"),
                ("Can get split VFO", "Y"),
                ("Can get split freq", "Y"),
                ("Can get split mode", "Y"),
                ("Can set split VFO", "Y"),
                ("Can set split freq", "Y"),
                ("Can set split mode", "Y"),
            )
        )

        self.assertTrue(getattr(draft, "supports_split_read", False))
        self.assertTrue(getattr(draft, "supports_split_write", False))

    def test_normalizes_actual_multiline_ft710_dump_caps_records(self):
        draft = parse_dump_caps(fixture_response("ft710_caps.txt").fields)

        self.assertEqual("Yaesu", draft.identity.manufacturer)
        self.assertEqual("FT-710", draft.identity.model)
        self.assertEqual(1049, draft.identity.model_id)
        self.assertEqual("20241118.7", draft.identity.backend_version)
        self.assertEqual(frozenset({"VFOA", "VFOB", "MEM"}), draft.vfos)
        self.assertEqual(((30000, 60000000),), draft.rx_ranges_hz)
        self.assertEqual(
            ((1810000, 2000000), (3500000, 3800000), (50000000, 54000000)),
            draft.tx_ranges_hz,
        )
        self.assertEqual(
            (("AM", 9000), ("CW", 600), ("CWR", 600), ("FM", 16000),
             ("FM-D", 16000), ("LSB", 2400), ("PKTLSB", 600), ("PKTUSB", 600),
             ("RTTY", 600), ("RTTYR", 600), ("USB", 2400)),
            draft.passbands_hz,
        )
        self.assertEqual(frozenset({"FREQ"}), draft.targetable_features)
        self.assertEqual(frozenset({"BANDSELECT"}), draft.readable_parameters)
        self.assertEqual(frozenset({"BANDSELECT"}), draft.writable_parameters)
        self.assertIn("TOGGLE", draft.vfo_operations)
        self.assertTrue(draft.supports_ptt_read)
        self.assertTrue(draft.supports_ptt_write)

    def test_ignores_unknown_and_unusable_records_while_collecting_repeated_evidence(self):
        draft = parse_dump_caps((
            ("Mfg name", "Test Maker"),
            ("Model name", "Test Rig"),
            ("Model ID", "not-an-id"),
            ("VFO list", "VFOA"),
            ("VFO list", "VFOB"),
            ("RX range", "not-a-range"),
            ("RX range", "100.0 200.0"),
            ("TX range", "100 20"),
            ("Filters", "USB invalid AM 6000"),
            ("Targetable features", "VFO"),
            ("Targetable features", "MODE"),
            ("Get parameters", "ONE"),
            ("Get parameters", "TWO"),
            ("Set parameters", "THREE"),
            ("VFO operations", "TOGGLE"),
            ("VFO operations", "A=B"),
            ("Get PTT", "maybe"),
            ("Set PTT", "1"),
            ("Future caps", "ignored"),
        ))

        self.assertEqual(None, draft.identity.model_id)
        self.assertEqual(frozenset({"VFOA", "VFOB"}), draft.vfos)
        self.assertEqual(((100, 200),), draft.rx_ranges_hz)
        self.assertEqual((), draft.tx_ranges_hz)
        self.assertEqual((("AM", 6000),), draft.passbands_hz)
        self.assertEqual(frozenset({"VFO", "MODE"}), draft.targetable_features)
        self.assertEqual(frozenset({"ONE", "TWO"}), draft.readable_parameters)
        self.assertEqual(frozenset({"THREE"}), draft.writable_parameters)
        self.assertEqual(frozenset({"TOGGLE", "A=B"}), draft.vfo_operations)
        self.assertFalse(draft.supports_ptt_read)
        self.assertTrue(draft.supports_ptt_write)

    def test_normalization_is_stable_when_dump_record_order_changes(self):
        records = (
            ("Mfg name", "Example"),
            ("Model name", "Model"),
            ("VFO list", "VFOA"),
            ("VFO list", "VFOB"),
            ("RX range", "100 200"),
            ("Filters", "USB 2400"),
            ("Targetable features", "VFO"),
        )

        self.assertEqual(parse_dump_caps(records), parse_dump_caps(tuple(reversed(records))))

    def test_omits_nonfinite_overflowed_fractional_and_reversed_range_bounds(self):
        draft = parse_dump_caps((
            ("RX range", "inf 200"),
            ("RX range", "1e309 200"),
            ("RX range", "10.5 20"),
            ("RX range", "10 20.5"),
            ("RX range", "200 100"),
            ("RX range", "100 200"),
        ))

        self.assertEqual(((100, 200),), draft.rx_ranges_hz)

    def test_omits_malformed_filter_continuations_from_a_multiline_dump(self):
        draft = parse_dump_caps((
            ("Caps dump for model", "1\nFilters:\n\tbroken: USB\nCan get PTT: N"),
        ))

        self.assertEqual((), draft.passbands_hz)


class ScriptedTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_ordered_script_remains_available_for_sequence_based_tests(self):
        transport = ScriptedTransport((response("first", Value="1"), response("second", Value="2")))

        self.assertEqual("1", (await transport.request("\\first")).get("Value"))
        self.assertEqual("2", (await transport.request("\\second")).get("Value"))

    async def test_ordered_script_rejects_a_command_that_does_not_match_its_next_response(self):
        transport = ScriptedTransport((response("first", Value="1"),))

        with self.assertRaisesRegex(AssertionError, "expected first, got second"):
            await transport.request("\\second")

    async def test_ordered_script_requires_an_expected_command_for_exception_results(self):
        transport = ScriptedTransport((RigReportError(-4),))

        with self.assertRaisesRegex(AssertionError, "must label exception results"):
            await transport.request("\\first")

    async def test_ordered_script_matches_auto_derived_responses_by_verb_but_not_wrong_verbs(self):
        supported = ScriptedTransport((ok("set_freq"),))
        rejected = ScriptedTransport((ok("set_freq"),))

        await supported.request("\\set_freq 14074000")
        with self.assertRaisesRegex(AssertionError, "expected set_freq, got set_mode"):
            await rejected.request("\\set_mode USB")

    async def test_explicit_ordered_expectation_preserves_the_help_marker(self):
        transport = ScriptedTransport((("\\set_level ?", ok("set_level")),))

        with self.assertRaisesRegex(AssertionError, "expected set_level ?, got set_level"):
            await transport.request("\\set_level")

    async def test_keyed_script_rejects_unexpected_and_exhausted_commands(self):
        transport = ScriptedTransport({"\\known": response("known")})

        with self.assertRaisesRegex(AssertionError, "unexpected scripted command"):
            await transport.request("\\unknown")
        await transport.request("\\known")
        with self.assertRaisesRegex(AssertionError, "scripted command exhausted"):
            await transport.request("\\known")


if __name__ == "__main__":
    unittest.main()
