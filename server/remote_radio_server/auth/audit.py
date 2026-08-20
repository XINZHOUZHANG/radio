import json
import math
import re
from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Any, Mapping


_FORBIDDEN_KEYS = {
    "cookie",
    "csrf",
    "pairing_code",
    "password",
    "secret",
    "setup_code",
    "token",
    "user_code",
}
_FORBIDDEN_SUFFIXES = ("_password", "_secret", "_token", "_cookie")
_MAX_METADATA_BYTES = 4096


def _normalized_key(key: str) -> str:
    with_word_boundaries = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", key)
    return re.sub(r"[^a-zA-Z0-9]+", "_", with_word_boundaries).strip("_").lower()


def _validate_key(key: str) -> None:
    normalized = _normalized_key(key)
    if normalized in _FORBIDDEN_KEYS or normalized.endswith(_FORBIDDEN_SUFFIXES):
        raise ValueError(f"audit metadata key is forbidden: {key}")


def _freeze_scalar(value: Any) -> Any:
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("audit metadata numbers must be finite")
        return value
    raise ValueError("audit metadata values must be JSON scalars, scalar lists, or mappings")


def _freeze_value(value: Any) -> Any:
    if isinstance(value, Mapping):
        return _freeze_mapping(value)
    if isinstance(value, list):
        return tuple(_freeze_scalar(item) for item in value)
    return _freeze_scalar(value)


def _freeze_mapping(metadata: Mapping[str, Any]) -> Mapping[str, Any]:
    if not isinstance(metadata, Mapping):
        raise ValueError("audit metadata must be a mapping")
    frozen: dict[str, Any] = {}
    for key, value in metadata.items():
        if not isinstance(key, str):
            raise ValueError("audit metadata keys must be strings")
        _validate_key(key)
        frozen[key] = _freeze_value(value)
    return MappingProxyType(frozen)


def _json_value(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {key: _json_value(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [_json_value(item) for item in value]
    return value


def serialize_metadata(metadata: Mapping[str, Any]) -> str:
    encoded = json.dumps(
        _json_value(metadata),
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )
    if len(encoded.encode("utf-8")) > _MAX_METADATA_BYTES:
        raise ValueError("audit metadata exceeds 4 KiB")
    return encoded


@dataclass(frozen=True, slots=True)
class AuditEvent:
    action: str
    result: str
    actor_user_id: str | None = None
    actor_device_id: str | None = None
    actor_session_id: str | None = None
    target_id: str | None = None
    source_address: str | None = None
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        frozen = _freeze_mapping(self.metadata)
        serialize_metadata(frozen)
        object.__setattr__(self, "metadata", frozen)


@dataclass(frozen=True, slots=True)
class StoredAuditEvent:
    event_id: int
    occurred_at: int
    action: str
    result: str
    actor_user_id: str | None = None
    actor_device_id: str | None = None
    actor_session_id: str | None = None
    target_id: str | None = None
    source_address: str | None = None
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        frozen = _freeze_mapping(self.metadata)
        serialize_metadata(frozen)
        object.__setattr__(self, "metadata", frozen)


@dataclass(frozen=True, slots=True)
class AuditPage:
    events: tuple[StoredAuditEvent, ...]
    next_after_id: int | None
