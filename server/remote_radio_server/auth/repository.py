import asyncio
import json
import os
import secrets
import sqlite3
from collections.abc import Callable
from pathlib import Path
from typing import TypeVar

from .audit import AuditEvent, AuditPage, StoredAuditEvent, serialize_metadata
from .models import Role, UserRecord


T = TypeVar("T")
SCHEMA_VERSION = 1
DATABASE_NAME = "remote-radio.sqlite3"
CSRF_KEY_NAME = "csrf.key"


class AuthRepository:
    def __init__(
        self,
        connection: sqlite3.Connection,
        database_path: Path,
        csrf_key: bytes,
        clock: Callable[[], int],
    ) -> None:
        self._connection = connection
        self._database_path = database_path
        self._csrf_key = csrf_key
        self._clock = clock
        self._lock = asyncio.Lock()
        self._closed = False

    @property
    def csrf_key(self) -> bytes:
        return self._csrf_key

    @classmethod
    async def open(
        cls, data_dir: Path, *, clock: Callable[[], int]
    ) -> "AuthRepository":
        resolved_dir = data_dir.resolve()
        resolved_dir.mkdir(mode=0o700, exist_ok=True)
        os.chmod(resolved_dir, 0o700)
        database_path = resolved_dir / DATABASE_NAME
        csrf_key_path = resolved_dir / CSRF_KEY_NAME

        csrf_key = await asyncio.to_thread(_load_or_create_csrf_key, csrf_key_path)
        connection = await asyncio.to_thread(_open_connection, database_path)
        try:
            await asyncio.to_thread(_migrate, connection)
            await asyncio.to_thread(_tighten_file_modes, database_path)
        except BaseException:
            await asyncio.to_thread(connection.close)
            raise
        return cls(connection, database_path, csrf_key, clock)

    async def close(self) -> None:
        async with self._lock:
            if self._closed:
                return
            await asyncio.to_thread(self._connection.close)
            self._closed = True

    async def _run(self, operation: Callable[[sqlite3.Connection], T]) -> T:
        async with self._lock:
            if self._closed:
                raise RuntimeError("repository is closed")
            result = await asyncio.to_thread(operation, self._connection)
            await asyncio.to_thread(_tighten_file_modes, self._database_path)
            return result

    async def create_user(
        self,
        *,
        user_id: str,
        username: str,
        password_phc: str,
        role: Role,
        can_transmit: bool,
        must_change_password: bool,
        audit: AuditEvent,
    ) -> UserRecord:
        now = self._clock()

        def create(connection: sqlite3.Connection) -> UserRecord:
            try:
                connection.execute("BEGIN IMMEDIATE")
                connection.execute(
                    """
                    INSERT INTO users(
                        id, username, password_phc, role, can_transmit, enabled,
                        must_change_password, auth_revision, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, 1, ?, 1, ?, ?)
                    """,
                    (
                        user_id,
                        username,
                        password_phc,
                        role.value,
                        int(can_transmit),
                        int(must_change_password),
                        now,
                        now,
                    ),
                )
                _append_audit(connection, now, audit)
                connection.commit()
            except BaseException:
                connection.rollback()
                raise
            row = connection.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
            return _user_from_row(row)

        return await self._run(create)

    async def find_user_by_username(self, username: str) -> UserRecord | None:
        return await self._run(
            lambda connection: _optional_user(
                connection.execute(
                    "SELECT * FROM users WHERE username = ?", (username,)
                ).fetchone()
            )
        )

    async def get_user(self, user_id: str) -> UserRecord | None:
        return await self._run(
            lambda connection: _optional_user(
                connection.execute(
                    "SELECT * FROM users WHERE id = ?", (user_id,)
                ).fetchone()
            )
        )

    async def list_users(self) -> tuple[UserRecord, ...]:
        return await self._run(
            lambda connection: tuple(
                _user_from_row(row)
                for row in connection.execute("SELECT * FROM users ORDER BY username")
            )
        )

    async def append_audit(self, event: AuditEvent) -> StoredAuditEvent:
        now = self._clock()

        def append(connection: sqlite3.Connection) -> StoredAuditEvent:
            try:
                connection.execute("BEGIN IMMEDIATE")
                event_id = _append_audit(connection, now, event)
                connection.commit()
            except BaseException:
                connection.rollback()
                raise
            row = connection.execute(
                "SELECT * FROM audit_events WHERE id = ?", (event_id,)
            ).fetchone()
            return _audit_from_row(row)

        return await self._run(append)

    async def list_audit(self, after_id: int | None, limit: int) -> AuditPage:
        if not 1 <= limit <= 100:
            raise ValueError("audit limit must be between 1 and 100")

        def list_page(connection: sqlite3.Connection) -> AuditPage:
            if after_id is None:
                rows = connection.execute(
                    "SELECT * FROM audit_events ORDER BY id DESC LIMIT ?", (limit,)
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM audit_events WHERE id < ? ORDER BY id DESC LIMIT ?",
                    (after_id, limit),
                ).fetchall()
            events = tuple(_audit_from_row(row) for row in rows)
            return AuditPage(events, events[-1].event_id if events else None)

        return await self._run(list_page)


def _load_or_create_csrf_key(path: Path) -> bytes:
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0),
            0o600,
        )
    except FileExistsError:
        pass
    else:
        try:
            key = secrets.token_bytes(32)
            remaining = memoryview(key)
            while remaining:
                written = os.write(descriptor, remaining)
                if written == 0:
                    raise OSError("unable to write csrf.key")
                remaining = remaining[written:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    os.chmod(path, 0o600)
    key = path.read_bytes()
    if len(key) != 32:
        raise RuntimeError("csrf.key must contain exactly 32 bytes")
    return key


def _open_connection(path: Path) -> sqlite3.Connection:
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    os.close(descriptor)
    os.chmod(path, 0o600)
    connection = sqlite3.connect(path, check_same_thread=False)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA busy_timeout=5000")
    return connection


def _migrate(connection: sqlite3.Connection) -> None:
    schema_meta_exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_meta'"
    ).fetchone()
    if schema_meta_exists is None:
        migration_path = Path(__file__).with_name("migrations") / "001_initial.sql"
        connection.executescript(migration_path.read_text(encoding="utf-8"))
        return

    row = connection.execute("SELECT version FROM schema_meta").fetchone()
    if row is None:
        raise RuntimeError("schema_meta contains no version")
    version = int(row[0])
    if version > SCHEMA_VERSION:
        raise RuntimeError(
            f"database has newer schema version {version}; supported version is {SCHEMA_VERSION}"
        )
    if version != SCHEMA_VERSION:
        raise RuntimeError(f"unsupported schema version {version}")


def _tighten_file_modes(database_path: Path) -> None:
    for path in (
        database_path,
        Path(f"{database_path}-wal"),
        Path(f"{database_path}-shm"),
    ):
        if path.exists():
            os.chmod(path, 0o600)


def _user_from_row(row: sqlite3.Row) -> UserRecord:
    return UserRecord(
        user_id=row["id"],
        username=row["username"],
        password_phc=row["password_phc"],
        role=Role(row["role"]),
        can_transmit=bool(row["can_transmit"]),
        enabled=bool(row["enabled"]),
        must_change_password=bool(row["must_change_password"]),
        auth_revision=row["auth_revision"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
        last_login_at=row["last_login_at"],
        deleted_at=row["deleted_at"],
    )


def _optional_user(row: sqlite3.Row | None) -> UserRecord | None:
    return None if row is None else _user_from_row(row)


def _append_audit(connection: sqlite3.Connection, occurred_at: int, event: AuditEvent) -> int:
    cursor = connection.execute(
        """
        INSERT INTO audit_events(
            occurred_at, action, result, actor_user_id, actor_device_id,
            actor_session_id, target_id, source_address, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            occurred_at,
            event.action,
            event.result,
            event.actor_user_id,
            event.actor_device_id,
            event.actor_session_id,
            event.target_id,
            event.source_address,
            serialize_metadata(event.metadata),
        ),
    )
    return int(cursor.lastrowid)


def _audit_from_row(row: sqlite3.Row) -> StoredAuditEvent:
    return StoredAuditEvent(
        event_id=row["id"],
        occurred_at=row["occurred_at"],
        action=row["action"],
        result=row["result"],
        actor_user_id=row["actor_user_id"],
        actor_device_id=row["actor_device_id"],
        actor_session_id=row["actor_session_id"],
        target_id=row["target_id"],
        source_address=row["source_address"],
        metadata=json.loads(row["metadata_json"]),
    )
