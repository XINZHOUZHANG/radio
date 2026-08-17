import json
import subprocess
import sys
import unittest


class CliTests(unittest.TestCase):
    def run_cli(self, *arguments, input_text=None):
        return subprocess.run(
            [sys.executable, "-m", "remote_radio_server", *arguments],
            input=input_text,
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def run_cli_bytes(self, *arguments, input_bytes):
        return subprocess.run(
            [sys.executable, "-m", "remote_radio_server", *arguments],
            input=input_bytes,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def test_mock_once_prints_exactly_capabilities_and_snapshot(self):
        result = self.run_cli("--mock", "--once")

        self.assertEqual(0, result.returncode, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(2, len(lines))
        events = [json.loads(line) for line in lines]
        self.assertEqual(["rig.capabilities", "rig.snapshot"], [event["type"] for event in events])
        self.assertEqual("", result.stderr)

    def test_interactive_ndjson_continues_after_malformed_input(self):
        result = self.run_cli(
            "--mock",
            input_text='not-json\n{"type":"rig.snapshot"}\n',
        )

        self.assertEqual(0, result.returncode, result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(
            ["rig.capabilities", "rig.snapshot", "error", "rig.snapshot"],
            [event["type"] for event in events],
        )
        self.assertEqual("invalid_json", events[2]["code"])

    def test_interactive_ndjson_decodes_strict_utf8_and_continues_after_error(self):
        result = self.run_cli_bytes(
            "--mock",
            input_bytes=b'\xff\n{"type":"rig.snapshot"}\n',
        )

        self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", "replace"))
        events = [json.loads(line) for line in result.stdout.decode("utf-8").splitlines()]
        self.assertEqual(
            ["rig.capabilities", "rig.snapshot", "error", "rig.snapshot"],
            [event["type"] for event in events],
        )
        self.assertEqual("invalid_utf8", events[2]["code"])

    def test_hardware_tx_requires_both_acknowledgement_flags(self):
        for lone_flag in ("--enable-hardware-tx", "--acknowledge-transmit-risk"):
            with self.subTest(flag=lone_flag):
                result = self.run_cli("--mock", lone_flag, "--once")
                self.assertNotEqual(0, result.returncode)
                self.assertEqual("", result.stdout)
                self.assertIn("must be supplied together", result.stderr)


if __name__ == "__main__":
    unittest.main()
