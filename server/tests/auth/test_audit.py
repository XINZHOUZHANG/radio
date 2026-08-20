import math
import tempfile
import unittest
from pathlib import Path

from remote_radio_server.auth.audit import AuditEvent
from remote_radio_server.auth.repository import AuthRepository


class AuditEventTests(unittest.TestCase):
    def test_audit_event_rejects_secret_shaped_metadata(self):
        for key in ("password", "token", "cookie", "csrf", "setup_code", "pairing_code"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                AuditEvent("login", "failure", metadata={key: "must-not-log"})

    def test_audit_event_rejects_nested_and_normalized_secret_keys(self):
        for key in (
            "APIToken",
            "CSRFToken",
            "HTTPPassword",
            "user_code",
            "refresh_token",
            "refresh-token",
            "refreshToken",
            "session_cookie",
            "current_password",
            "client_secret",
        ):
            with self.subTest(key=key), self.assertRaises(ValueError):
                AuditEvent(
                    "login",
                    "failure",
                    metadata={"context": {key: "must-not-log"}},
                )

    def test_audit_event_accepts_only_supported_json_shapes(self):
        event = AuditEvent(
            "login",
            "failure",
            metadata={
                "error_code": "authentication_failed",
                "reason": None,
                "count": 2,
                "retryable": False,
                "ratios": [1, 0.5],
                "context": {"method": "password"},
            },
        )
        self.assertEqual("authentication_failed", event.metadata["error_code"])

        invalid_values = (
            object(),
            [["nested-list"]],
            [{"mapping": "inside-list"}],
            math.nan,
            math.inf,
        )
        for value in invalid_values:
            with self.subTest(value=value), self.assertRaises(ValueError):
                AuditEvent("login", "failure", metadata={"reason": value})
        with self.assertRaises(ValueError):
            AuditEvent("login", "failure", metadata={1: "non-string-key"})

    def test_audit_event_caps_serialized_metadata_at_four_kibibytes(self):
        AuditEvent("login", "failure", metadata={"reason": "x" * 4083})
        with self.assertRaises(ValueError):
            AuditEvent("login", "failure", metadata={"reason": "x" * 4084})


class AuditRepositoryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    async def test_append_serializes_deterministically_and_list_uses_cursor(self):
        repository = await AuthRepository.open(Path(self.temp.name), clock=lambda: 200)
        self.addAsyncCleanup(repository.close)
        for index in range(1, 6):
            await repository.append_audit(
                AuditEvent(
                    "login",
                    "failure",
                    target_id=str(index),
                    metadata={"b": "two", "a": index},
                )
            )

        encoded = await repository._run(
            lambda connection: connection.execute(
                "SELECT metadata_json FROM audit_events WHERE id = 1"
            ).fetchone()[0]
        )
        self.assertEqual('{"a":1,"b":"two"}', encoded)

        first = await repository.list_audit(None, 2)
        second = await repository.list_audit(first.next_after_id, 2)
        final = await repository.list_audit(second.next_after_id, 2)
        empty = await repository.list_audit(final.next_after_id, 2)
        self.assertEqual([5, 4], [event.event_id for event in first.events])
        self.assertEqual(4, first.next_after_id)
        self.assertEqual([3, 2], [event.event_id for event in second.events])
        self.assertEqual(2, second.next_after_id)
        self.assertEqual([1], [event.event_id for event in final.events])
        self.assertEqual(1, final.next_after_id)
        self.assertEqual((), empty.events)
        self.assertIsNone(empty.next_after_id)

    async def test_list_audit_rejects_out_of_range_limits(self):
        repository = await AuthRepository.open(Path(self.temp.name), clock=lambda: 200)
        self.addAsyncCleanup(repository.close)
        for limit in (0, 101):
            with self.subTest(limit=limit), self.assertRaises(ValueError):
                await repository.list_audit(None, limit)


if __name__ == "__main__":
    unittest.main()
