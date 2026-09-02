"""Authentication persistence and policy primitives."""

from .audit import AuditEvent, AuditPage, StoredAuditEvent
from .errors import (
    AuthConflict,
    AuthError,
    AuthFailure,
    AuthForbidden,
    AuthGone,
    AuthRateLimited,
)
from .models import (
    AuthenticatedIdentity,
    BrowserSessionRecord,
    DeviceGrant,
    DeviceRecord,
    Principal,
    Role,
    UserRecord,
)
from .repository import AuthRepository

__all__ = [
    "AuditEvent",
    "AuditPage",
    "AuthConflict",
    "AuthError",
    "AuthFailure",
    "AuthForbidden",
    "AuthGone",
    "AuthRateLimited",
    "AuthRepository",
    "AuthenticatedIdentity",
    "BrowserSessionRecord",
    "DeviceGrant",
    "DeviceRecord",
    "Principal",
    "Role",
    "StoredAuditEvent",
    "UserRecord",
]
