import os
import sqlite3
import stat
import tempfile
import unittest
from dataclasses import FrozenInstanceError
from pathlib import Path
from unittest import mock

from remote_radio_server.auth.audit import AuditEvent
from remote_radio_server.auth.models import Role
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

        await repository.create_user(
            user_id="user-1",
            username="duplicate.audit",
            password_phc="$argon2id$test",
            role=Role.OPERATOR,
            can_transmit=False,
            must_change_password=False,
            audit=AuditEvent("user.create", "success"),
        )
        with self.assertRaises(sqlite3.IntegrityError):
            await repository.create_user(
                user_id="user-2",
                username="duplicate.audit",
                password_phc="$argon2id$test",
                role=Role.OPERATOR,
                can_transmit=False,
                must_change_password=False,
                audit=AuditEvent("user.create", "success"),
            )

        self.assertIsNone(await repository.get_user("user-2"))
        self.assertEqual(1, len((await repository.list_audit(None, 20)).events))

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
