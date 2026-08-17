"""Read-only discovery of controls reported by rigctld."""

from dataclasses import dataclass
from math import isfinite

from .errors import RigReportError
from .models import CommandPriority, RigCapabilities, RigIdentity


@dataclass(frozen=True, slots=True)
class CapabilityDraft:
    identity: RigIdentity
    modes: frozenset[str] = frozenset()
    vfos: frozenset[str] = frozenset()
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


def parse_dump_caps(fields) -> CapabilityDraft:
    manufacturer: set[str] = set()
    model: set[str] = set()
    model_ids: set[int] = set()
    backend_versions: set[str] = set()
    modes: set[str] = set()
    vfos: set[str] = set()
    readable_parameters: set[str] = set()
    writable_parameters: set[str] = set()
    vfo_operations: set[str] = set()
    targetable_features: set[str] = set()
    passbands: set[tuple[str, int]] = set()
    rx_ranges: set[tuple[int, int]] = set()
    tx_ranges: set[tuple[int, int]] = set()
    ptt_read = False
    ptt_write = False
    split_read: set[str] = set()
    split_write: set[str] = set()

    for field, raw_value in _dump_records(fields):
        key = field.strip().casefold()
        value = raw_value.strip()
        if key in {"mfg name", "manufacturer", "manufacturer name"} and value:
            manufacturer.add(value)
        elif key in {"model name", "model"} and value:
            model.add(value)
        elif key in {"model id", "model number", "caps dump for model"}:
            parsed = _integer(value)
            if parsed is not None:
                model_ids.add(parsed)
        elif key == "backend version" and value:
            backend_versions.add(value)
        elif key == "mode list":
            modes.update(value.split())
        elif key in {"vfo list", "vfos"}:
            vfos.update(value.split())
        elif key in {"get parameters", "get parms", "readable parameters"}:
            readable_parameters.update(_capability_tokens(value))
        elif key in {"set parameters", "set parms", "writable parameters"}:
            writable_parameters.update(_capability_tokens(value))
        elif key in {"vfo operations", "vfo ops"}:
            vfo_operations.update(value.split())
        elif key in {"targetable features", "targetable"}:
            targetable_features.update(value.split())
        elif key in {"filters", "passbands"}:
            passbands.update(_passbands(value))
        elif key == "filter":
            passbands.update(_hamlib_filter(value))
        elif key in {"rx range", "rx ranges"}:
            parsed = _range(value)
            if parsed is not None:
                rx_ranges.add(parsed)
        elif key in {"tx range", "tx ranges"}:
            parsed = _range(value)
            if parsed is not None:
                tx_ranges.add(parsed)
        elif key in {"get ptt", "ptt get", "can get ptt"}:
            ptt_read = ptt_read or _supported(value)
        elif key in {"set ptt", "ptt set", "can set ptt"}:
            ptt_write = ptt_write or _supported(value)
        elif key in {
            "get split vfo",
            "get split freq",
            "get split mode",
            "can get split vfo",
            "can get split freq",
            "can get split mode",
        } and _supported(value):
            split_read.add(key.replace("can ", "").replace("frequency", "freq"))
        elif key in {
            "set split vfo",
            "set split freq",
            "set split mode",
            "can set split vfo",
            "can set split freq",
            "can set split mode",
        } and _supported(value):
            split_write.add(key.replace("can ", "").replace("frequency", "freq"))

    return CapabilityDraft(
        identity=RigIdentity(
             min(manufacturer, default=""),
             min(model, default=""),
             min(model_ids, default=None),
             min(backend_versions, default=None),
             None,
        ),
        modes=frozenset(modes),
        vfos=frozenset(vfos),
        readable_parameters=frozenset(readable_parameters),
        writable_parameters=frozenset(writable_parameters),
        vfo_operations=frozenset(vfo_operations),
        targetable_features=frozenset(targetable_features),
        passbands_hz=tuple(sorted(passbands)),
        rx_ranges_hz=tuple(sorted(rx_ranges)),
        tx_ranges_hz=tuple(sorted(tx_ranges)),
        supports_ptt_read=ptt_read,
        supports_ptt_write=ptt_write,
        supports_split_read={
            "get split vfo", "get split freq", "get split mode"
        }.issubset(split_read),
        supports_split_write={
            "set split vfo", "set split freq", "set split mode"
        }.issubset(split_write),
    )


class CapabilityService:
    def __init__(self, transport) -> None:
        self._transport = transport

    async def discover(self) -> RigCapabilities:
        version = await self._transport.request(
            "\\hamlib_version", CommandPriority.DISCOVERY, 2.0
        )
        dumped = await self._transport.request(
            "\\dump_caps", CommandPriority.DISCOVERY, 2.0
        )
        draft = parse_dump_caps(dumped.fields)
        current_mode = await self._current_mode()
        identity = RigIdentity(
            draft.identity.manufacturer,
            draft.identity.model,
            draft.identity.model_id,
            draft.identity.backend_version,
            version.get("Version") or _first_raw_line(version.values),
        )
        return RigCapabilities(
            identity=identity,
            vfos=draft.vfos,
            modes=draft.modes | frozenset({current_mode} if current_mode else ()),
            readable_levels=await self._tokens("\\get_level ?", "Level"),
            writable_levels=await self._tokens("\\set_level ?", "Level"),
            readable_functions=await self._tokens("\\get_func ?", "Func"),
            writable_functions=await self._tokens("\\set_func ?", "Func"),
            readable_parameters=draft.readable_parameters,
            writable_parameters=draft.writable_parameters,
            vfo_operations=draft.vfo_operations,
            targetable_features=draft.targetable_features,
            passbands_hz=draft.passbands_hz,
            rx_ranges_hz=draft.rx_ranges_hz,
            tx_ranges_hz=draft.tx_ranges_hz,
            supports_ptt_read=draft.supports_ptt_read,
            supports_ptt_write=draft.supports_ptt_write,
            supports_split_read=draft.supports_split_read,
            supports_split_write=draft.supports_split_write,
        )

    async def _tokens(self, command: str, field: str) -> frozenset[str]:
        try:
            response = await self._transport.request(
                command, CommandPriority.DISCOVERY, 2.0
            )
        except RigReportError as error:
            if error.is_unsupported:
                return frozenset()
            raise
        return frozenset((response.get(field, "") or " ".join(response.values)).split())

    async def _current_mode(self) -> str | None:
        try:
            response = await self._transport.request(
                "\\get_mode ?", CommandPriority.DISCOVERY, 2.0
            )
        except RigReportError as error:
            if error.is_unsupported:
                return None
            raise
        mode = response.get("Mode")
        if mode:
            return mode.split()[0] if mode.split() else None
        return _first_raw_line(response.values).split()[0] if _first_raw_line(response.values) else None


def _integer(value: str) -> int | None:
    try:
        return int(value)
    except ValueError:
        return None


def _range(value: str) -> tuple[int, int] | None:
    parts = value.split()
    if len(parts) != 2:
        return None
    try:
        bounds = tuple(float(part) for part in parts)
    except (ValueError, OverflowError):
        return None
    if not all(isfinite(bound) and bound.is_integer() for bound in bounds):
        return None
    lower, upper = (int(bound) for bound in bounds)
    return (lower, upper) if lower <= upper else None


def _passbands(value: str) -> tuple[tuple[str, int], ...]:
    parts = value.split()
    result = set()
    for mode, width in zip(parts[::2], parts[1::2]):
        parsed = _integer(width)
        if parsed is not None and parsed >= 0:
            result.add((mode, parsed))
    return tuple(sorted(result))


def _supported(value: str) -> bool:
    return value.casefold() in {"1", "true", "yes", "y", "supported"}


def _dump_records(fields):
    for field, value in fields:
        if field.strip().casefold() != "caps dump for model":
            yield field, value
            continue

        range_kind: str | None = None
        filters = False
        for line in f"Caps dump for model: {value}".splitlines():
            stripped = line.strip()
            if stripped.startswith("TX ranges #") and " status" not in stripped:
                range_kind, filters = "TX range", False
                continue
            if stripped.startswith("RX ranges #") and " status" not in stripped:
                range_kind, filters = "RX range", False
                continue
            if stripped == "Filters:":
                range_kind, filters = None, True
                continue
            if range_kind is not None:
                parsed = _hamlib_range_line(stripped)
                if parsed is not None:
                    yield range_kind, parsed
                    continue
            if filters and line[:1].isspace():
                parsed = _hamlib_filter_line(stripped)
                if parsed is not None:
                    yield "Filter", parsed
                    continue
            if filters:
                filters = False
            key, separator, record_value = stripped.partition(":")
            if separator and key:
                yield key, record_value.strip()


def _hamlib_range_line(value: str) -> str | None:
    parts = value.split()
    if len(parts) != 5 or parts[1] != "Hz" or parts[2] != "-" or parts[4] != "Hz":
        return None
    return f"{parts[0]} {parts[3]}"


def _hamlib_filter_line(value: str) -> str | None:
    width, separator, modes = value.partition(":")
    if not separator or not modes.strip() or width == "ANY":
        return None
    return f"{width.strip()}|{modes.strip()}"


def _hamlib_filter(value: str) -> tuple[tuple[str, int], ...]:
    width_text, separator, modes = value.partition("|")
    if not separator:
        return ()
    width_parts = width_text.split()
    if len(width_parts) != 2:
        return ()
    magnitude, unit = width_parts
    try:
        width = float(magnitude)
    except ValueError:
        return ()
    multiplier = {"hz": 1, "khz": 1_000}.get(unit.casefold())
    if multiplier is None or not isfinite(width):
        return ()
    hertz = width * multiplier
    if not hertz.is_integer() or hertz < 0:
        return ()
    return tuple((mode, int(hertz)) for mode in modes.split())


def _capability_tokens(value: str) -> frozenset[str]:
    return frozenset(token.partition("(")[0] for token in value.split() if token)


def _first_raw_line(values: tuple[str, ...]) -> str | None:
    for value in values:
        for line in value.splitlines():
            if line.strip():
                return line.strip()
    return None
