"""Revisioned rig state and single-tick adaptive polling."""

from dataclasses import replace
from math import isfinite
from time import monotonic
from typing import Mapping

from .errors import RigProtocolError
from .models import CommandPriority, RigCapabilities, RigState, StateDelta


class RigStateStore:
    """Own the current immutable state and monotonically increasing revision."""

    def __init__(self, initial: RigState | None = None) -> None:
        self._state = initial or RigState()

    def snapshot(self) -> RigState:
        return self._state

    def apply(self, values: Mapping[str, object]) -> StateDelta | None:
        if "revision" in values:
            raise ValueError("revision is owned by RigStateStore")
        unknown = set(values).difference(RigState.__dataclass_fields__)
        if unknown:
            raise ValueError(f"unknown rig state keys: {', '.join(sorted(unknown))}")
        changes = {
            key: value for key, value in values.items()
            if getattr(self._state, key) != value
        }
        if not changes:
            return None
        revision = self._state.revision + 1
        self._state = replace(self._state, revision=revision, **changes)
        return StateDelta(revision=revision, changes=tuple(sorted(changes.items())))


class RigStateService:
    _ORDINARY_METERS = (
        "STRENGTH", "RAWSTR", "COMP_METER", "VD_METER", "ID_METER", "TEMP_METER",
    )
    _TX_METERS = ("SWR", "ALC", "RFPOWER_METER", "RFPOWER_METER_WATTS")

    def __init__(
        self,
        transport,
        capabilities: RigCapabilities,
        *,
        store: RigStateStore | None = None,
        clock=None,
    ) -> None:
        self._transport = transport
        self._capabilities = capabilities
        self._store = store or RigStateStore()
        self._clock = clock or monotonic
        self._last_core_poll: float | None = None
        self._last_ordinary_meter_poll: float | None = None
        self._last_tx_meter_poll: float | None = None

    async def full_refresh(self, transmitting: bool = False) -> StateDelta | None:
        self._last_core_poll = None
        self._last_ordinary_meter_poll = None
        self._last_tx_meter_poll = None
        return await self.poll_once(transmitting)

    async def poll_once(self, transmitting: bool) -> StateDelta | None:
        now = self._clock()
        starting_revision = self._store.snapshot().revision
        values = {}
        core_due = (
            self._last_core_poll is None
            or now + 1e-12 >= self._last_core_poll + 0.2
        )
        ordinary_meters_due = (
            self._last_ordinary_meter_poll is None
            or now + 1e-12 >= self._last_ordinary_meter_poll + 0.5
        )
        tx_meters_due = transmitting and (
            self._last_tx_meter_poll is None
            or now + 1e-12 >= self._last_tx_meter_poll + 0.1
        )
        if core_due:
            values.update(await self._read_core())
        if ordinary_meters_due:
            meters, attempted = await self._read_meters(self._ORDINARY_METERS)
            if attempted:
                self._merge_meters(values, meters, attempted)
        if tx_meters_due:
            meters, attempted = await self._read_meters(self._TX_METERS)
            if attempted:
                self._merge_meters(values, meters, attempted)
        delta = (
            self._store.apply(values)
            if self._store.snapshot().revision == starting_revision
            else None
        )
        if core_due:
            self._last_core_poll = now
        if ordinary_meters_due:
            self._last_ordinary_meter_poll = now
        if tx_meters_due:
            self._last_tx_meter_poll = now
        return delta

    def _merge_meters(
        self,
        values: dict[str, object],
        updates: dict[str, float],
        attempted,
    ) -> None:
        meters = dict(self._store.snapshot().meters)
        meters.update(dict(values.get("meters", ())))
        for token in attempted:
            meters.pop(token, None)
        meters.update(updates)
        values["meters"] = tuple(sorted(meters.items()))

    async def _read_core(self) -> dict[str, object]:
        frequency = await self._transport.request("\\get_freq", CommandPriority.POLLING)
        mode = await self._transport.request("\\get_mode", CommandPriority.POLLING)
        vfo = await self._transport.request("\\get_vfo", CommandPriority.POLLING)
        values = {
            "frequency_hz": _integer(frequency, "Frequency"),
            "mode": _text(mode, "Mode"),
            "passband_hz": _integer(mode, "Passband"),
            "vfo": _text(vfo, "VFO"),
        }
        if getattr(self._capabilities, "supports_split_read", False):
            split = await self._transport.request(
                "\\get_split_vfo", CommandPriority.POLLING
            )
            split_frequency = await self._transport.request(
                "\\get_split_freq", CommandPriority.POLLING
            )
            split_mode = await self._transport.request(
                "\\get_split_mode", CommandPriority.POLLING
            )
            split_value = _text(split, "Split")
            if split_value not in {"0", "1"}:
                raise RigProtocolError("get_split_vfo response has malformed Split")
            split_enabled = split_value == "1"
            if split_enabled:
                split_vfo = _text(split, "TX VFO")
                split_frequency_hz = _integer(
                    split_frequency, "TX Frequency"
                )
                split_mode_name = _text(split_mode, "TX Mode")
                split_passband_hz = _integer(split_mode, "TX Passband")
            else:
                split_vfo = None
                split_frequency_hz = None
                split_mode_name = None
                split_passband_hz = None
            values.update(
                {
                    "split_state_known": True,
                    "split_enabled": split_enabled,
                    "split_vfo": split_vfo,
                    "split_frequency_hz": split_frequency_hz,
                    "split_mode": split_mode_name,
                    "split_passband_hz": split_passband_hz,
                }
            )
        if self._capabilities.supports_ptt_read:
            ptt = await self._transport.request("\\get_ptt", CommandPriority.POLLING)
            ptt_value = _text(ptt, "PTT")
            if ptt_value not in {"0", "1"}:
                raise RigProtocolError("get_ptt response has malformed PTT")
            values["ptt"] = ptt_value == "1"
        return values

    async def _read_meters(self, candidates) -> tuple[dict[str, float], set[str]]:
        meters = {}
        attempted = set()
        for token in candidates:
            if token not in self._capabilities.readable_levels:
                continue
            attempted.add(token)
            try:
                response = await self._transport.request(
                    f"\\get_level {token}", CommandPriority.POLLING
                )
            except Exception:
                self._invalidate_meter(token)
                raise
            raw = response.values[0] if response.values else response.get(token)
            if raw is None:
                continue
            try:
                value = float(raw)
            except ValueError:
                continue
            if isfinite(value):
                meters[token] = value
        return meters, attempted

    def _invalidate_meter(self, token: str) -> None:
        meters = dict(self._store.snapshot().meters)
        if token not in meters:
            return
        meters.pop(token)
        self._store.apply({"meters": tuple(sorted(meters.items()))})


def _text(response, field: str) -> str:
    value = response.get(field)
    if value is None or not value.strip():
        raise RigProtocolError(f"{response.command} response is missing {field}")
    return value.strip()


def _integer(response, field: str) -> int:
    try:
        value = float(_text(response, field))
    except ValueError as error:
        raise RigProtocolError(f"{response.command} response has malformed {field}") from error
    if not isfinite(value) or not value.is_integer():
        raise RigProtocolError(f"{response.command} response has malformed {field}")
    return int(value)
