import asyncio
import os
import sqlite3
import stat
import tempfile
import threading
import unittest
from dataclasses import FrozenInstanceError
from pathlib import Path
from unittest import mock

from remote_radio_server.auth.audit import AuditEvent
from remote_radio_server.auth.models import DeviceGrant, Role
from remote_radio_server.auth import repository as repository_module
from remote_radio_server.auth.repository import AuthRepository


EXPECTED_TABLES = {
    "access_credentials",
    "audit_events",
    "browser_sessions",
    "devices",
    "login_throttles",
    "refresh_credentials",
    "schema_meta",
    "sqlite_sequence",
    "users",
}


class RepositoryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    async def test_open_migrates_private_database_and_round_trips_user(self):
        repository = await AuthRepository.open(Path(self.temp.name), clock=lambda: 100)
        self.addAsyncCleanup(repository.close)

        user = await repository.create_user(
            user_id="user-1",
            username="operator.one",
            password_phc="$argon2id$test",
            role=Role.OPERATOR,
            can_transmit=False,
            must_change_password=False,
            audit=AuditEvent("user.create", "success", actor_user_id="admin-1"),
        )

        self.assertEqual("operator.one", user.username)
        self.assertEqual(user, await repository.find_user_by_username("operator.one"))
        self.assertEqual(user, await repository.get_user("user-1"))
        self.assertEqual((user,), await repository.list_users())
        self.assertEqual(1, (await repository.list_audit(None, 20)).events[0].event_id)
        self.assertEqual(100, user.created_at)
        self.assertEqual(100, user.updated_at)
        self.assertTrue(user.enabled)
        self.assertEqual(1, user.auth_revision)
        with self.assertRaises(FrozenInstanceError):
            user.username = "changed"

        database_path = Path(self.temp.name) / "remote-radio.sqlite3"
        connection = sqlite3.connect(database_path)
        try:
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'"
                )
            }
            self.assertEqual(EXPECTED_TABLES, tables)
            self.assertEqual(1, connection.execute("SELECT version FROM schema_meta").fetchone()[0])
        finally:
            connection.close()

        if os.name != "nt":
            self.assertEqual(0o700, stat.S_IMODE(Path(self.temp.name).stat().st_mode))
            private_files = [
                database_path,
                Path(f"{database_path}-wal"),
                Path(f"{database_path}-shm"),
                Path(self.temp.name) / "csrf.key",
            ]
            self.assertTrue(all(path.exists() for path in private_files))
            for path in private_files:
                with self.subTest(path=path):
                    self.assertEqual(0, stat.S_IMODE(path.stat().st_mode) & 0o077)

    async def test_schema_enforces_identity_and_credential_invariants(self):
        repository = await AuthRepository.open(Path(self.temp.name), clock=lambda: 100)
        self.addAsyncCleanup(repository.close)

        columns = await repository._run(
            lambda connection: {
                table: {
                    row["name"]
                    for row in connection.execute(f"PRAGMA table_info({table})")
                }
                for table in (
                    "users",
                    "browser_sessions",
                    "devices",
                    "access_credentials",
                    "refresh_credentials",
                )
            }
        )
        self.assertTrue(
            {"password_phc", "auth_revision", "deleted_at"} <= columns["users"]
        )
        self.assertTrue(
            {"user_id", "secret_digest", "absolute_expires_at"}
            <= columns["browser_sessions"]
        )
        self.assertTrue({"user_id", "platform", "revoked_at"} <= columns["devices"])
        self.assertTrue(
            {"device_id", "secret_digest", "expires_at"}
            <= columns["access_credentials"]
        )
        self.assertTrue(
            {"device_id", "family_id", "previous_id", "used_at"}
            <= columns["refresh_credentials"]
        )

        def insert_user(connection, values):
            try:
                connection.execute(
                    """
                    INSERT INTO users(
                        id, username, password_phc, role, can_transmit, enabled,
                        must_change_password, auth_revision, created_at, updated_at
                    ) VALUES (?, ?, '$argon2id$test', ?, ?, ?, ?, ?, 100, 100)
                    """,
                    values,
                )
                connection.commit()
            except BaseException:
                connection.rollback()
                raise

        await repository._run(
            lambda connection: insert_user(
                connection, ("valid-user", "valid.user", "operator", 0, 1, 0, 1)
            )
        )

        invalid_users = (
            ("observer-user", "observer.user", "observer", 0, 1, 0, 1),
            ("transmit-user", "transmit.user", "operator", 2, 1, 0, 1),
            ("enabled-user", "enabled.user", "operator", 0, 2, 0, 1),
            ("password-user", "password.user", "operator", 0, 1, 2, 1),
            ("revision-user", "revision.user", "operator", 0, 1, 0, 0),
            ("duplicate-user", "valid.user", "operator", 0, 1, 0, 1),
        )
        for values in invalid_users:
            with self.subTest(values=values), self.assertRaises(sqlite3.IntegrityError):
                await repository._run(
                    lambda connection, values=values: insert_user(connection, values)
                )

        def insert_and_rollback_on_error(connection, sql, parameters):
            try:
                connection.execute(sql, parameters)
                connection.commit()
            except BaseException:
                connection.rollback()
                raise

        with self.assertRaises(sqlite3.IntegrityError):
            await repository._run(
                lambda connection: insert_and_rollback_on_error(
                    connection,
                    """
                    INSERT INTO browser_sessions(
                        id, user_id, secret_digest, created_at, last_seen_at,
                        idle_expires_at, absolute_expires_at
                    ) VALUES ('session-1', 'missing-user', X'01', 100, 100, 200, 300)
                    """,
                    (),
                )
            )
        with self.assertRaises(sqlite3.IntegrityError):
            await repository._run(
                lambda connection: insert_and_rollback_on_error(
                    connection,
                    """
                    INSERT INTO devices(id, user_id, name, platform, created_at)
                    VALUES ('device-1', 'valid-user', 'Phone', ?, 100)
                    """,
                    ("android",),
                )
            )

    async def test_open_persists_csrf_key_and_data(self):
        data_dir = Path(self.temp.name)
        first = await AuthRepository.open(data_dir, clock=lambda: 100)
        first_key = first.csrf_key
        self.assertEqual(32, len(first_key))
        with self.assertRaises(AttributeError):
            first.csrf_key = b"x" * 32
        await first.create_user(
            user_id="user-1",
            username="admin.one",
            password_phc="$argon2id$test",
            role=Role.ADMIN,
            can_transmit=False,
            must_change_password=True,
            audit=AuditEvent("setup.initialize", "success"),
        )
        await first.close()

        second = await AuthRepository.open(data_dir, clock=lambda: 200)
        self.addAsyncCleanup(second.close)
        self.assertEqual(first_key, second.csrf_key)
        self.assertEqual("admin.one", (await second.get_user("user-1")).username)

    async def test_open_applies_required_sqlite_pragmas(self):
        repository = await AuthRepository.open(Path(self.temp.name), clock=lambda: 100)
        self.addAsyncCleanup(repository.close)

        pragmas = await repository._run(
            lambda connection: (
                connection.execute("PRAGMA foreign_keys").fetchone()[0],
                connection.execute("PRAGMA journal_mode").fetchone()[0],
                connection.execute("PRAGMA busy_timeout").fetchone()[0],
            )
        )

        self.assertEqual((1, "wal", 5000), pragmas)

    async def test_open_rejects_unknown_newer_schema(self):
        database_path = Path(self.temp.name) / "remote-radio.sqlite3"
        connection = sqlite3.connect(database_path)
        try:
            connection.execute("CREATE TABLE schema_meta(version INTEGER NOT NULL)")
            connection.execute("INSERT INTO schema_meta(version) VALUES (2)")
            connection.commit()
        finally:
            connection.close()

        with self.assertRaisesRegex(RuntimeError, "newer schema version"):
            await AuthRepository.open(Path(self.temp.name), clock=lambda: 100)

    async def test_create_user_and_audit_are_atomic(self):
        repository = await AuthRepository.open(Path(self.temp.name), clock=lambda: 100)
        self.addAsyncCleanup(repository.close)

        await repository._run(
            lambda connection: connection.execute(
                """
                CREATE TRIGGER fail_audit_insert
                BEFORE INSERT ON audit_events
                BEGIN
                    SELECT RAISE(ABORT, 'forced audit failure');
                END
                """
            )
        )
        with self.assertRaisesRegex(sqlite3.IntegrityError, "forced audit failure"):
            await repository.create_user(
                user_id="user-1",
                username="atomic.audit",
                password_phc="$argon2id$test",
                role=Role.OPERATOR,
                can_transmit=False,
                must_change_password=False,
                audit=AuditEvent("user.create", "success"),
            )

        self.assertIsNone(await repository.get_user("user-1"))
        self.assertEqual((), (await repository.list_audit(None, 20)).events)

    async def test_cancelled_operation_retains_lock_until_worker_finishes(self):
        repository = await AuthRepository.open(Path(self.temp.name), clock=lambda: 100)
        self.addAsyncCleanup(repository.close)
        worker_started = threading.Event()
        worker_finished = threading.Event()
        release_worker = threading.Event()
        later_started = threading.Event()

        def blocked_operation(connection):
            worker_started.set()
            try:
                if not release_worker.wait(2):
                    raise TimeoutError("test worker was not released")
                return connection.execute("SELECT 1").fetchone()[0]
            finally:
                worker_finished.set()

        def later_operation(connection):
            later_started.set()
            return connection.execute("SELECT 1").fetchone()[0]

        first = asyncio.create_task(repository._run(blocked_operation))
        self.assertTrue(await asyncio.to_thread(worker_started.wait, 1))
        first.cancel()
        await asyncio.sleep(0)
        later = asyncio.create_task(repository._run(later_operation))
        entered_while_worker_active = await asyncio.to_thread(later_started.wait, 0.2)
        release_worker.set()
        self.assertTrue(await asyncio.to_thread(worker_finished.wait, 1))
        with self.assertRaises(asyncio.CancelledError):
            await first
        self.assertEqual(1, await later)
        self.assertFalse(entered_while_worker_active)

    def test_device_grant_repr_redacts_plaintext_credentials(self):
        grant = DeviceGrant(
            device_id="device-1",
            access_token="access-plaintext",
            access_expires_at=100,
            refresh_token="refresh-plaintext",
            refresh_expires_at=200,
            role=Role.OPERATOR,
            can_transmit=False,
        )

        representation = repr(grant)
        self.assertIn("device-1", representation)
        self.assertNotIn("access-plaintext", representation)
        self.assertNotIn("refresh-plaintext", representation)

    def test_csrf_creation_handles_short_os_write(self):
        key_path = Path(self.temp.name) / "csrf.key"
        real_write = os.write

        def short_first_write(descriptor, data):
            if short_first_write.first:
                short_first_write.first = False
                return real_write(descriptor, data[:8])
            return real_write(descriptor, data)

        short_first_write.first = True
        with mock.patch.object(repository_module.os, "write", side_effect=short_first_write):
            key = repository_module._load_or_create_csrf_key(key_path)

        self.assertEqual(32, len(key))
        self.assertEqual(key, key_path.read_bytes())

    def test_csrf_creation_writes_random_bytes_without_text_translation(self):
        key_path = Path(self.temp.name) / "csrf.key"
        expected_key = b"\n" * 32

        with mock.patch.object(repository_module.secrets, "token_bytes", return_value=expected_key):
            key = repository_module._load_or_create_csrf_key(key_path)

        self.assertEqual(expected_key, key)
        self.assertEqual(expected_key, key_path.read_bytes())


if __name__ == "__main__":
    unittest.main()
