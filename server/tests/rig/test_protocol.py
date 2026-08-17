import unittest

from remote_radio_server.rig.errors import RigProtocolError
from remote_radio_server.rig.protocol import ExtendedResponseParser, encode_command


class ExtendedResponseParserTests(unittest.TestCase):
    def test_completes_a_newline_terminated_report_fragment(self):
        parser = ExtendedResponseParser()

        self.assertEqual((), parser.feed(b"get_freq:|Frequency: 145000000|RPRT "))
        responses = parser.feed(b"0\n")

        self.assertEqual("get_freq", responses[0].command)
        self.assertEqual("145000000", responses[0].get("Frequency"))

    def test_accepts_header_with_echoed_arguments(self):
        responses = ExtendedResponseParser().feed(b"set_freq: 14074000|RPRT 0\n")

        self.assertEqual("set_freq", responses[0].command)
        self.assertEqual((), responses[0].fields)

    def test_preserves_unlabelled_help_tokens_as_values(self):
        responses = ExtendedResponseParser().feed(
            b"get_level: ?|PREAMP AF SWR |\nRPRT 0\n"
        )

        self.assertEqual(("PREAMP AF SWR ",), responses[0].values)

    def test_preserves_multiline_unlabelled_version_payload(self):
        responses = ExtendedResponseParser().feed(
            b"hamlib_version:|rigctl(d), Hamlib 4.7.1 build\n\nCopyright text\nRPRT 0\n"
        )

        self.assertEqual(
            ("rigctl(d), Hamlib 4.7.1 build\n\nCopyright text",),
            responses[0].values,
        )

    def test_keeps_a_fragmented_raw_payload_line_that_starts_with_rprt(self):
        parser = ExtendedResponseParser()

        self.assertEqual(
            (), parser.feed(b"hamlib_version:|first line\nRPRT descriptive payload\n")
        )
        responses = parser.feed(b"last line\nRPRT 0\n")

        self.assertEqual(
            ("first line\nRPRT descriptive payload\nlast line",),
            responses[0].values,
        )

    def test_rejects_newline_terminated_malformed_report_after_pipe_boundary(self):
        parser = ExtendedResponseParser()

        with self.assertRaisesRegex(RigProtocolError, "malformed report code"):
            parser.feed(b"get_mode:|RPRT nope\n")

    def test_rejects_malformed_report_before_later_valid_response(self):
        parser = ExtendedResponseParser()

        with self.assertRaisesRegex(RigProtocolError, "malformed report code"):
            parser.feed(
                b"get_mode:|RPRT nope\nget_freq:|Frequency: 1|RPRT 0\n"
            )

    def test_returns_multiple_newline_terminated_responses(self):
        responses = ExtendedResponseParser().feed(
            b"get_freq:|Frequency: 7100000|RPRT 0\nget_vfo:|VFO: VFOA|RPRT 0\n"
        )

        self.assertEqual(("get_freq", "get_vfo"), tuple(response.command for response in responses))

    def test_fragmented_mode_response(self):
        parser = ExtendedResponseParser()
        self.assertEqual((), parser.feed(b"get_mode:|Mode: US"))
        responses = parser.feed(b"B|Passband: 2400|RPRT 0|")
        self.assertEqual("get_mode", responses[0].command)
        self.assertEqual((("Mode", "USB"), ("Passband", "2400")), responses[0].fields)
        self.assertEqual(0, responses[0].report)

    def test_rejects_response_without_header(self):
        parser = ExtendedResponseParser(max_buffer_bytes=64)
        with self.assertRaises(RigProtocolError):
            parser.feed(b"Mode: USB|RPRT 0|")

    def test_returns_multiple_responses_from_one_feed(self):
        parser = ExtendedResponseParser()

        responses = parser.feed(
            b"get_freq:|Frequency: 7100000|RPRT 0|get_vfo:|VFO: VFOA|RPRT 0|"
        )

        self.assertEqual(
            (
                ("get_freq", (("Frequency", "7100000"),), 0),
                ("get_vfo", (("VFO", "VFOA"),), 0),
            ),
            tuple((response.command, response.fields, response.report) for response in responses),
        )

    def test_keeps_negative_report_as_response_data(self):
        parser = ExtendedResponseParser()

        responses = parser.feed(b"get_level:|Level: RFPOWER|RPRT -4|")

        self.assertEqual("get_level", responses[0].command)
        self.assertEqual(-4, responses[0].report)

    def test_rejects_response_exceeding_configured_limit(self):
        parser = ExtendedResponseParser(max_buffer_bytes=8)

        with self.assertRaisesRegex(RigProtocolError, "response exceeds configured limit"):
            parser.feed(b"get_mode:")

    def test_rejects_unfinished_response_exceeding_configured_limit(self):
        parser = ExtendedResponseParser(max_buffer_bytes=16)

        parser.feed(b"get_mode:|")
        with self.assertRaisesRegex(RigProtocolError, "response exceeds configured limit"):
            parser.feed(b"Mode: USB|")

    def test_reassembles_a_fragmented_utf8_field_value(self):
        parser = ExtendedResponseParser()

        self.assertEqual((), parser.feed(b"get_info:|Label: caf\xc3"))
        responses = parser.feed(b"\xa9|RPRT 0|")

        self.assertEqual((("Label", "caf\N{LATIN SMALL LETTER E WITH ACUTE}"),), responses[0].fields)

    def test_rejects_invalid_utf8_and_recovers_for_next_response(self):
        parser = ExtendedResponseParser()

        with self.assertRaises(RigProtocolError):
            parser.feed(b"get_info:|Label: \xff")

        responses = parser.feed(b"get_mode:|Mode: USB|RPRT 0|")
        self.assertEqual("get_mode", responses[0].command)

    def test_rejects_malformed_report_record(self):
        parser = ExtendedResponseParser()

        with self.assertRaises(RigProtocolError):
            parser.feed(b"get_mode:|RPRT|")

    def test_rejects_malformed_command_header(self):
        parser = ExtendedResponseParser()

        with self.assertRaises(RigProtocolError):
            parser.feed(b"get_mode|Mode: USB|RPRT 0|")

    def test_rejects_malformed_field_record(self):
        parser = ExtendedResponseParser()

        with self.assertRaises(RigProtocolError):
            parser.feed(b"get_mode:|Mode=USB|RPRT 0|")


class EncodeCommandTests(unittest.TestCase):
    def test_prefixes_and_terminates_ascii_command(self):
        self.assertEqual(b"|get_mode\n", encode_command("get_mode"))

    def test_rejects_newline_injection(self):
        with self.assertRaisesRegex(ValueError, "rigctld commands must be one line"):
            encode_command("get_mode\nset_ptt 1")

    def test_rejects_carriage_return_injection(self):
        with self.assertRaisesRegex(ValueError, "rigctld commands must be one line"):
            encode_command("get_mode\rset_ptt 1")

    def test_rejects_non_ascii_commands(self):
        with self.assertRaises(UnicodeEncodeError):
            encode_command("get_m\N{LATIN SMALL LETTER O WITH DIAERESIS}de")


if __name__ == "__main__":
    unittest.main()
