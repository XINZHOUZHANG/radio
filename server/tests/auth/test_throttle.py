import tempfile
import unittest
from pathlib import Path

from remote_radio_server.auth.audit import AuditEvent
from remote_radio_server.auth.models import Role
from remote_radio_server.auth.repository import AuthRepository
from remote_radio_server.auth.throttle import LoginThrottle


class FakeClock:
    def __init__(self, now: int = 1_000):
        self.now = now

    def __call__(self) -> int:
        return self.now

    def advance(self, seconds: int) -> None:
        self.now += seconds


class LoginThrottleTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.clock = FakeClock()
        self.repository = await AuthRepository.open(
            Path(self.temp.name), clock=self.clock
        )
        self.addAsyncCleanup(self.repository.close)
        self.throttle = LoginThrottle(self.repository)

    async def test_fifth_failure_blocks_for_30_seconds_then_backoff_caps_at_15_minutes(self):
        for _ in range(4):
            decision = await self.throttle.failure("operator.one", "203.0.113.9")
            self.assertEqual(0, decision.retry_after_s)
        await self.throttle.failure("operator.one", "203.0.113.9")
        self.assertEqual(
            30,
            (await self.throttle.check("operator.one", "203.0.113.9")).retry_after_s,
        )

        elapsed_delays = (30, 60, 120, 240, 480, 900)
        expected_delays = (60, 120, 240, 480, 900, 900)
        for elapsed, delay in zip(elapsed_delays, expected_delays, strict=True):
            self.clock.advance(elapsed)
            decision = await self.throttle.failure("operator.one", "203.0.113.9")
            self.assertEqual(delay, decision.retry_after_s)

    async def test_source_blocks_on_thirtieth_failure_inside_ten_minutes(self):
        for number in range(29):
            decision = await self.throttle.failure(
                f"operator{number:02d}", "203.0.113.9"
            )
            self.assertEqual(0, decision.retry_after_s)

        decision = await self.throttle.failure("operator29", "203.0.113.9")

        self.assertEqual(900, decision.retry_after_s)
        self.assertEqual(
            900,
            (await self.throttle.check("someone.else", "203.0.113.9")).retry_after_s,
        )

    async def test_source_budget_starts_a_new_window_after_ten_minutes(self):
        for number in range(29):
            await self.throttle.failure(f"operator{number:02d}", "203.0.113.9")
        self.clock.advance(600)

        decision = await self.throttle.failure("operator29", "203.0.113.9")

        self.assertEqual(0, decision.retry_after_s)

    async def test_success_clears_only_the_account_scope(self):
        for _ in range(5):
            await self.throttle.failure("operator.one", "203.0.113.9")
        await self.throttle.success("operator.one", "203.0.113.9")
        self.assertEqual(
            0,
            (await self.throttle.check("operator.one", "203.0.113.9")).retry_after_s,
        )
        self.assertEqual(
            0,
            (await self.throttle.failure("operator.one", "203.0.113.9")).retry_after_s,
        )

        for number in range(23):
            await self.throttle.failure(f"another{number:02d}", "203.0.113.9")
        await self.throttle.success("another00", "203.0.113.9")
        decision = await self.throttle.failure("last.operator", "203.0.113.9")
        self.assertEqual(900, decision.retry_after_s)

    async def test_normalized_known_and_unknown_names_use_the_same_opaque_scope_scheme(self):
        await self.throttle.failure("  Operator.One ", "203.0.113.9")

        unknown_scope_keys = await self.repository._run(
            lambda connection: tuple(
                row["scope_key"]
                for row in connection.execute(
                    "SELECT scope_key FROM login_throttles ORDER BY scope_key"
                )
            )
        )
        await self.repository.create_user(
            user_id="user-1",
            username="operator.one",
            password_phc="$argon2id$test",
            role=Role.OPERATOR,
            can_transmit=False,
            must_change_password=False,
            audit=AuditEvent("user.create", "success"),
        )
        await self.throttle.failure("operator.one", "203.0.113.9")
        known_scope_keys = await self.repository._run(
            lambda connection: tuple(
                row["scope_key"]
                for row in connection.execute(
                    "SELECT scope_key FROM login_throttles ORDER BY scope_key"
                )
            )
        )

        self.assertEqual(
            (
                "498169cb7ff097ddbc7fdad177f08d66d9b1cf98e156969a6e0a5aff19dedd87",
                "7befbeefb816468971298a90af04a208daef1242f369ac7080ccdf3c42c44c2a",
            ),
            unknown_scope_keys,
        )
        self.assertEqual(unknown_scope_keys, known_scope_keys)

    async def test_block_survives_repository_reopen(self):
        for _ in range(5):
            await self.throttle.failure("operator.one", "203.0.113.9")
        await self.repository.close()

        self.repository = await AuthRepository.open(
            Path(self.temp.name), clock=self.clock
        )
        self.addAsyncCleanup(self.repository.close)
        self.throttle = LoginThrottle(self.repository)

        self.assertEqual(
            30,
            (await self.throttle.check("operator.one", "203.0.113.9")).retry_after_s,
        )


if __name__ == "__main__":
    unittest.main()
