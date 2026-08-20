from dataclasses import dataclass, field
from enum import StrEnum


class Role(StrEnum):
    ADMIN = "admin"
    OPERATOR = "operator"


@dataclass(frozen=True, slots=True)
class UserRecord:
    user_id: str
    username: str
    password_phc: str
    role: Role
    can_transmit: bool
    enabled: bool
    must_change_password: bool
    auth_revision: int
    created_at: int
    updated_at: int
    last_login_at: int | None = None
    deleted_at: int | None = None


@dataclass(frozen=True, slots=True)
class BrowserSessionRecord:
    session_id: str
    user_id: str
    secret_digest: bytes
    created_at: int
    last_seen_at: int
    idle_expires_at: int
    absolute_expires_at: int
    revoked_at: int | None = None


@dataclass(frozen=True, slots=True)
class DeviceRecord:
    device_id: str
    user_id: str
    name: str
    platform: str
    created_at: int
    last_seen_at: int | None = None
    revoked_at: int | None = None


@dataclass(frozen=True, slots=True)
class DeviceGrant:
    device_id: str
    access_token: str = field(repr=False)
    access_expires_at: int
    refresh_token: str = field(repr=False)
    refresh_expires_at: int
    role: Role
    can_transmit: bool


@dataclass(frozen=True, slots=True)
class AuthenticatedIdentity:
    user_id: str
    device_id: str | None
    browser_session_id: str | None
    role: Role
    can_transmit: bool
    auth_kind: str
    auth_revision: int
    expires_at: int


@dataclass(frozen=True, slots=True)
class Principal:
    user_id: str
    client_id: str
    device_id: str | None
    browser_session_id: str | None
    role: Role
    can_transmit: bool
    auth_kind: str
    auth_revision: int
    expires_at: int
