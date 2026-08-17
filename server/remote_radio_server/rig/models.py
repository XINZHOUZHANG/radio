from dataclasses import dataclass
from enum import IntEnum, StrEnum


class CommandPriority(IntEnum):
    EMERGENCY = 0
    USER_WRITE = 10
    USER_READ = 20
    DISCOVERY = 30
    POLLING = 40


class Lifecycle(StrEnum):
    OFFLINE = "offline"
    CONNECTING = "connecting"
    DISCOVERING = "discovering"
    READY = "ready"
    DEGRADED = "degraded"
    LOCKED_OUT = "locked_out"


@dataclass(frozen=True, slots=True)
class RigResponse:
    command: str
    fields: tuple[tuple[str, str], ...]
    report: int
    values: tuple[str, ...] = ()

    def get(self, key: str, default: str | None = None) -> str | None:
        return dict(self.fields).get(key, default)


@dataclass(frozen=True, slots=True)
class RigIdentity:
    manufacturer: str
    model: str
    model_id: int | None
    backend_version: str | None
    hamlib_version: str | None


@dataclass(frozen=True, slots=True)
class RigCapabilities:
    identity: RigIdentity
    vfos: frozenset[str] = frozenset()
    modes: frozenset[str] = frozenset()
    readable_levels: frozenset[str] = frozenset()
    writable_levels: frozenset[str] = frozenset()
    readable_functions: frozenset[str] = frozenset()
    writable_functions: frozenset[str] = frozenset()
    readable_parameters: frozenset[str] = frozenset()
    writable_parameters: frozenset[str] = frozenset()
    vfo_operations: frozenset[str] = frozenset()
    targetable_features: frozenset[str] = frozenset()
    passbands_hz: tuple[tuple[str, int], ...] = ()
    rx_ranges_hz: tuple[tuple[int, int], ...] = ()
    tx_ranges_hz: tuple[tuple[int, int], ...] = ()
    supports_ptt_read: bool = False
    supports_ptt_write: bool = False
    supports_split_read: bool = False
    supports_split_write: bool = False


@dataclass(frozen=True, slots=True)
class RigState:
    lifecycle: Lifecycle = Lifecycle.OFFLINE
    revision: int = 0
    frequency_hz: int | None = None
    mode: str | None = None
    passband_hz: int | None = None
    vfo: str | None = None
    split_state_known: bool = False
    split_enabled: bool = False
    split_vfo: str | None = None
    split_frequency_hz: int | None = None
    split_mode: str | None = None
    split_passband_hz: int | None = None
    ptt: bool = False
    meters: tuple[tuple[str, float], ...] = ()


@dataclass(frozen=True, slots=True)
class StateDelta:
    revision: int
    changes: tuple[tuple[str, object], ...]


@dataclass(frozen=True, slots=True)
class CommandResult:
    status: str
    message: str
    revision: int | None = None
    hamlib_code: int | None = None

    @classmethod
    def rejected(cls, status: str, message: str) -> "CommandResult":
        return cls(status=status, message=message)
