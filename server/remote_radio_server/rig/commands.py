"""Validated rig mutations with authoritative read-back confirmation."""

import asyncio
from dataclasses import dataclass
from math import isfinite

from .errors import RigProtocolError, RigReportError, RigTransportError
from .models import CommandPriority, CommandResult


@dataclass(slots=True)
class _FrequencyBatch:
    frequency_hz: int
    requests: list[tuple[int, asyncio.Future]]
    task: asyncio.Task | None = None


class RigCommandService:
    def __init__(self, transport, capabilities, *, store, sleep=None, audit_sink=None):
        self._transport = transport
        self._caps = capabilities
        self._store = store
        self._sleep = sleep or asyncio.sleep
        self._audit_sink = audit_sink or (lambda _event, _metadata: None)
        self._frequency_batch: _FrequencyBatch | None = None
        self._frequency_tasks: set[asyncio.Task] = set()
        self._closed = False

    async def set_frequency(
        self, frequency_hz: int, *, transmitting: bool = False
    ) -> CommandResult:
        if isinstance(frequency_hz, bool) or not isinstance(frequency_hz, int):
            return CommandResult.rejected("invalid", "frequency must be an integer")
        if not isinstance(transmitting, bool):
            return CommandResult.rejected("invalid", "transmitting must be boolean")
        ranges = self._caps.tx_ranges_hz if transmitting else self._caps.rx_ranges_hz
        if ranges and not any(lower <= frequency_hz <= upper for lower, upper in ranges):
            return CommandResult.rejected(
                "invalid", "frequency is outside the applicable range"
            )
        if self._closed:
            return CommandResult("unknown_result", "command service is closed")
        future = asyncio.get_running_loop().create_future()
        batch = self._frequency_batch
        if batch is None:
            batch = _FrequencyBatch(frequency_hz, [(frequency_hz, future)])
            self._frequency_batch = batch
            batch.task = asyncio.create_task(self._flush_frequency(batch))
            self._frequency_tasks.add(batch.task)
            batch.task.add_done_callback(self._frequency_tasks.discard)
        else:
            batch.frequency_hz = frequency_hz
            batch.requests.append((frequency_hz, future))
        return await asyncio.shield(future)

    async def _flush_frequency(self, batch) -> None:
        try:
            await self._sleep(0.08)
            if self._frequency_batch is batch:
                self._frequency_batch = None
            result = await self._execute_frequency(batch.frequency_hz)
        except asyncio.CancelledError:
            result = CommandResult("unknown_result", "frequency request cancelled")
            self._resolve_frequency_batch(batch, result)
            raise
        except Exception as error:
            for _, future in batch.requests:
                if not future.done():
                    future.set_exception(error)
        else:
            self._resolve_frequency_batch(batch, result)
        finally:
            if self._frequency_batch is batch:
                self._frequency_batch = None

    def _resolve_frequency_batch(
        self, batch: _FrequencyBatch, latest_result: CommandResult
    ) -> None:
        for _, future in batch.requests[:-1]:
            if not future.done():
                future.set_result(
                    CommandResult(
                        "superseded",
                        "frequency request superseded",
                        self._store.snapshot().revision,
                    )
                )
        latest_future = batch.requests[-1][1]
        if not latest_future.done():
            latest_future.set_result(latest_result)

    async def close(self) -> None:
        self._closed = True
        tasks = tuple(self._frequency_tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _execute_frequency(self, frequency_hz: int) -> CommandResult:
        try:
            await self._transport.request(
                f"\\set_freq {frequency_hz}", CommandPriority.USER_WRITE
            )
        except RigReportError as error:
            return _write_failure(error)
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        try:
            response = await self._transport.request(
                "\\get_freq", CommandPriority.USER_READ
            )
            confirmed_frequency = _integer_field(response, "Frequency")
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        self._store.apply({"frequency_hz": confirmed_frequency})
        state = self._store.snapshot()
        if confirmed_frequency != frequency_hz:
            return CommandResult(
                "rejected", "frequency read-back did not match request", state.revision
            )
        return CommandResult("confirmed", "frequency confirmed", state.revision)

    async def set_mode(self, mode: str, passband_hz: int = 0) -> CommandResult:
        normalized = _token(mode, "mode")
        if normalized is None:
            return CommandResult.rejected("invalid", "mode must be a token")
        passband_error = _passband_error(passband_hz)
        if passband_error is not None:
            return passband_error
        if normalized not in self._caps.modes:
            return CommandResult.rejected(
                "unsupported", f"mode {normalized} is unavailable"
            )
        try:
            await self._transport.request(
                f"\\set_mode {normalized} {passband_hz}", CommandPriority.USER_WRITE
            )
        except RigReportError as error:
            return _write_failure(error)
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        try:
            response = await self._transport.request(
                "\\get_mode", CommandPriority.USER_READ
            )
            confirmed_mode = _text_field(response, "Mode")
            confirmed_passband = _integer_field(response, "Passband")
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        self._store.apply(
            {"mode": confirmed_mode, "passband_hz": confirmed_passband}
        )
        state = self._store.snapshot()
        mode_matches = confirmed_mode == normalized
        passband_matches = passband_hz == 0 or confirmed_passband == passband_hz
        if not (mode_matches and passband_matches):
            return CommandResult(
                "rejected", "mode read-back did not match request", state.revision
            )
        return CommandResult("confirmed", "mode confirmed", state.revision)

    async def set_level(self, level: str, value: int | float) -> CommandResult:
        normalized = _token(level, "level")
        if normalized is None:
            return CommandResult.rejected("invalid", "level must be a token")
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not isfinite(value)
        ):
            return CommandResult.rejected("invalid", "level value must be finite numeric")
        if (
            normalized not in self._caps.writable_levels
            or normalized not in self._caps.readable_levels
        ):
            return CommandResult.rejected(
                "unsupported", f"level {normalized} is not readable and writable"
            )
        try:
            await self._transport.request(
                f"\\set_level {normalized} {value}", CommandPriority.USER_WRITE
            )
        except RigReportError as error:
            return _write_failure(error)
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        try:
            response = await self._transport.request(
                f"\\get_level {normalized}", CommandPriority.USER_READ
            )
            confirmed_value = _numeric_value(response, normalized)
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        state = self._store.snapshot()
        if confirmed_value != float(value):
            return CommandResult(
                "rejected", "level read-back did not match request", state.revision
            )
        return CommandResult("confirmed", "level confirmed", state.revision)

    async def set_func(self, func: str, enabled: bool) -> CommandResult:
        normalized = _token(func, "function")
        if normalized is None:
            return CommandResult.rejected("invalid", "function must be a token")
        if not isinstance(enabled, bool):
            return CommandResult.rejected("invalid", "enabled must be boolean")
        if (
            normalized not in self._caps.writable_functions
            or normalized not in self._caps.readable_functions
        ):
            return CommandResult.rejected(
                "unsupported", f"function {normalized} is not readable and writable"
            )
        try:
            await self._transport.request(
                f"\\set_func {normalized} {int(enabled)}", CommandPriority.USER_WRITE
            )
        except RigReportError as error:
            return _write_failure(error)
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        try:
            response = await self._transport.request(
                f"\\get_func {normalized}", CommandPriority.USER_READ
            )
            confirmed_enabled = _boolean_value(response, normalized)
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        state = self._store.snapshot()
        if confirmed_enabled is not enabled:
            return CommandResult(
                "rejected", "function read-back did not match request", state.revision
            )
        return CommandResult("confirmed", "function confirmed", state.revision)

    async def set_split(
        self,
        enabled: bool,
        tx_vfo: str,
        *,
        frequency_hz: int | None = None,
        mode: str | None = None,
        passband_hz: int = 0,
    ) -> CommandResult:
        if not isinstance(enabled, bool):
            return CommandResult.rejected("invalid", "enabled must be boolean")
        normalized_vfo = _token(tx_vfo, "VFO")
        if normalized_vfo is None:
            return CommandResult.rejected("invalid", "TX VFO must be a token")
        normalized_mode = None if mode is None else _token(mode, "mode")
        if mode is not None and normalized_mode is None:
            return CommandResult.rejected("invalid", "mode must be a token")
        passband_error = _passband_error(passband_hz)
        if passband_error is not None:
            return passband_error
        if frequency_hz is not None and (
            isinstance(frequency_hz, bool) or not isinstance(frequency_hz, int)
        ):
            return CommandResult.rejected("invalid", "frequency must be an integer")
        if normalized_vfo not in self._caps.vfos:
            return CommandResult.rejected(
                "unsupported", f"VFO {normalized_vfo} is unavailable"
            )
        if normalized_mode is not None and normalized_mode not in self._caps.modes:
            return CommandResult.rejected(
                "unsupported", f"mode {normalized_mode} is unavailable"
            )
        if frequency_hz is not None and self._caps.tx_ranges_hz and not any(
            lower <= frequency_hz <= upper
            for lower, upper in self._caps.tx_ranges_hz
        ):
            return CommandResult.rejected(
                "invalid", "frequency is outside the TX range"
            )
        if not (
            getattr(self._caps, "supports_split_read", False)
            and getattr(self._caps, "supports_split_write", False)
        ):
            return CommandResult.rejected(
                "unsupported", "split control is not positively supported"
            )
        try:
            await self._transport.request(
                f"\\set_split_vfo {int(enabled)} {normalized_vfo}",
                CommandPriority.USER_WRITE,
            )
        except RigReportError as error:
            return _write_failure(error)
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        try:
            split_response = await self._transport.request(
                "\\get_split_vfo", CommandPriority.USER_READ
            )
            confirmed_enabled = _boolean_field(split_response, "Split")
            confirmed_vfo = _text_field(split_response, "TX VFO")
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        self._store.apply(
            {
                "split_state_known": True,
                "split_enabled": confirmed_enabled,
                "split_vfo": confirmed_vfo,
            }
        )
        if (confirmed_enabled, confirmed_vfo) != (enabled, normalized_vfo):
            return CommandResult(
                "rejected",
                "split VFO read-back did not match request",
                self._store.snapshot().revision,
            )

        if frequency_hz is not None:
            try:
                await self._transport.request(
                    f"\\set_split_freq {frequency_hz}", CommandPriority.USER_WRITE
                )
                frequency_response = await self._transport.request(
                    "\\get_split_freq", CommandPriority.USER_READ
                )
                confirmed_frequency = _integer_field(
                    frequency_response, "TX Frequency"
                )
            except _UNCERTAIN_ERRORS as error:
                return _unknown_failure(error)
            self._store.apply({"split_frequency_hz": confirmed_frequency})
            if confirmed_frequency != frequency_hz:
                return CommandResult(
                    "rejected",
                    "split frequency read-back did not match request",
                    self._store.snapshot().revision,
                )

        if normalized_mode is not None:
            try:
                await self._transport.request(
                    f"\\set_split_mode {normalized_mode} {passband_hz}",
                    CommandPriority.USER_WRITE,
                )
                mode_response = await self._transport.request(
                    "\\get_split_mode", CommandPriority.USER_READ
                )
                confirmed_mode = _text_field(mode_response, "TX Mode")
                confirmed_passband = _integer_field(mode_response, "TX Passband")
            except _UNCERTAIN_ERRORS as error:
                return _unknown_failure(error)
            self._store.apply(
                {
                    "split_mode": confirmed_mode,
                    "split_passband_hz": confirmed_passband,
                }
            )
            mode_matches = confirmed_mode == normalized_mode
            passband_matches = (
                passband_hz == 0 or confirmed_passband == passband_hz
            )
            if not (mode_matches and passband_matches):
                return CommandResult(
                    "rejected",
                    "split mode read-back did not match request",
                    self._store.snapshot().revision,
                )

        return CommandResult(
            "confirmed", "split confirmed", self._store.snapshot().revision
        )

    async def send_raw_admin(
        self, raw_request: str, *, is_admin: bool
    ) -> CommandResult:
        if is_admin is not True:
            return CommandResult.rejected(
                "unsupported", "administrator permission is required"
            )
        if not isinstance(raw_request, str):
            return CommandResult.rejected("invalid", "raw request must be text")
        try:
            encoded = raw_request.encode("ascii")
        except UnicodeEncodeError:
            return CommandResult.rejected("invalid", "raw request must be ASCII")
        if len(encoded) > 4096:
            return CommandResult.rejected("invalid", "raw request exceeds 4096 bytes")
        if "\r" in raw_request or "\n" in raw_request:
            return CommandResult.rejected("invalid", "raw request must be one line")
        if raw_request.count(" ") != 1:
            return CommandResult.rejected(
                "invalid", "raw request must contain a terminator and payload"
            )
        terminator, payload = raw_request.split(" ")
        if (
            not terminator
            or not payload
            or any(character.isspace() for character in terminator + payload)
        ):
            return CommandResult.rejected(
                "invalid", "raw request must contain two non-whitespace tokens"
            )
        normalized_terminator = _raw_terminator(terminator)
        if normalized_terminator is None:
            return CommandResult.rejected("invalid", "raw terminator is unavailable")
        identity = self._caps.identity
        allowed = _RAW_READ_ONLY_QUERIES.get(
            (identity.manufacturer.casefold(), identity.model.casefold()),
            frozenset(),
        )
        if (normalized_terminator, payload) not in allowed:
            return CommandResult.rejected(
                "unsupported", "raw request is not an allowlisted read-only query"
            )
        self._audit_sink(
            "rig.raw_admin",
            {
                "terminator": normalized_terminator,
                "payload_bytes": len(payload),
            },
        )
        try:
            await self._transport.request(
                f"\\send_raw {normalized_terminator} {payload}",
                CommandPriority.USER_READ,
            )
        except RigReportError as error:
            return _write_failure(error)
        except _UNCERTAIN_ERRORS as error:
            return _unknown_failure(error)
        return CommandResult(
            "confirmed", "raw command confirmed", self._store.snapshot().revision
        )


def _integer_field(response, field: str) -> int:
    raw = response.get(field)
    if raw is None or not raw.strip():
        raise RigProtocolError(f"{response.command} response is missing {field}")
    try:
        value = float(raw)
    except ValueError as error:
        raise RigProtocolError(
            f"{response.command} response has malformed {field}"
        ) from error
    if not isfinite(value) or not value.is_integer():
        raise RigProtocolError(f"{response.command} response has malformed {field}")
    return int(value)


def _text_field(response, field: str) -> str:
    raw = response.get(field)
    if raw is None or not raw.strip():
        raise RigProtocolError(f"{response.command} response is missing {field}")
    normalized = _token(raw, field)
    if normalized is None:
        raise RigProtocolError(f"{response.command} response has malformed {field}")
    return normalized


def _boolean_field(response, field: str) -> bool:
    raw = response.get(field)
    if raw is None or raw.strip() not in {"0", "1"}:
        raise RigProtocolError(f"{response.command} response has malformed {field}")
    return raw.strip() == "1"


def _numeric_value(response, fallback_field: str) -> float:
    raw = response.values[0] if response.values else response.get(fallback_field)
    if raw is None or not raw.strip():
        raise RigProtocolError(f"{response.command} response is missing value")
    try:
        value = float(raw)
    except ValueError as error:
        raise RigProtocolError(
            f"{response.command} response has malformed value"
        ) from error
    if not isfinite(value):
        raise RigProtocolError(f"{response.command} response has malformed value")
    return value


def _boolean_value(response, fallback_field: str) -> bool:
    raw = response.values[0] if response.values else response.get(fallback_field)
    if raw is None or raw.strip() not in {"0", "1"}:
        raise RigProtocolError(f"{response.command} response has malformed value")
    return raw.strip() == "1"


def _token(value, label: str) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().upper()
    if not normalized or any(character.isspace() for character in normalized):
        return None
    return normalized


def _passband_error(passband_hz) -> CommandResult | None:
    if (
        isinstance(passband_hz, bool)
        or not isinstance(passband_hz, int)
        or passband_hz < 0
    ):
        return CommandResult.rejected(
            "invalid", "passband must be a non-negative integer"
        )
    return None


def _raw_terminator(value: str) -> str | None:
    normalized = value.upper()
    if normalized in {"CR", "LF", ";", "ICOM", "-1"}:
        return normalized
    if not value.isdigit():
        return None
    numeric = int(value)
    return str(numeric) if 0 <= numeric <= 100 else None


def _write_failure(error: RigReportError) -> CommandResult:
    status = "unsupported" if error.is_unsupported else "hardware_error"
    return CommandResult(status, str(error), hamlib_code=error.code)


_UNCERTAIN_ERRORS = (RigProtocolError, RigTransportError, RigReportError, TimeoutError)


_RAW_READ_ONLY_QUERIES = {
    ("yaesu", "ft-710"): frozenset({(";", "ID")}),
    ("mock", "in-process rig"): frozenset({(";", "ID")}),
}


def _unknown_failure(error: Exception) -> CommandResult:
    code = error.code if isinstance(error, RigReportError) else None
    return CommandResult("unknown_result", str(error), hamlib_code=code)
