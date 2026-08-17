"""Push-to-talk admission and watchdog safety boundary."""

import asyncio
import secrets
from dataclasses import dataclass
from time import monotonic

from .models import Lifecycle


@dataclass(frozen=True, slots=True)
class PttTrip:
    reason: str
    at_monotonic: float


class PttSafetyError(Exception):
    def __init__(self, reason: str, message: str) -> None:
        super().__init__(message)
        self.reason = reason


class PttSafetySupervisor:
    def __init__(
        self,
        set_ptt,
        *,
        state_snapshot,
        tx_ranges_hz,
        clock=None,
        audit_sink=None,
        lease_id_factory=None,
        heartbeat_timeout_s: float = 10.0,
        hard_limit_s: float = 180.0,
        swr_trip: float = 3.0,
        swr_reset: float = 2.0,
        lockout_s: float = 3.0,
    ) -> None:
        self._set_ptt = set_ptt
        self._state_snapshot = state_snapshot
        self._tx_ranges_hz = tx_ranges_hz
        self._clock = clock or monotonic
        self._audit_sink = audit_sink or (lambda _event, _metadata: None)
        self._lease_id_factory = lease_id_factory or (lambda: secrets.token_urlsafe(32))
        self._heartbeat_timeout_s = heartbeat_timeout_s
        self._hard_limit_s = hard_limit_s
        self._swr_trip = swr_trip
        self._swr_reset = swr_reset
        self._lockout_s = lockout_s
        self._lease_id = None
        self._lease_owner = None
        self._last_heartbeat = None
        self._ptt_on = False
        self._dekey_required = False
        self._tx_started_at = None
        self._lockout_until = 0.0
        self._last_trip = None
        self._swr_latched = False
        self._transition_lock = asyncio.Lock()

    @property
    def ptt_on(self) -> bool:
        return self._ptt_on

    @property
    def dekey_required(self) -> bool:
        return self._dekey_required

    @property
    def swr_latched(self) -> bool:
        return self._swr_latched

    @property
    def last_trip(self) -> PttTrip | None:
        return self._last_trip

    @property
    def lease_owner(self) -> str | None:
        return self._lease_owner

    def acquire_lease(self, device_id: str) -> str:
        if not isinstance(device_id, str) or not device_id.strip():
            raise PttSafetyError("invalid_device", "device ID must be non-empty text")
        if self._lease_owner == device_id:
            return self._lease_id
        if self._lease_owner is not None:
            raise PttSafetyError("lease_busy", "another device owns the PTT lease")
        self._lease_owner = device_id
        self._lease_id = self._lease_id_factory()
        self._last_heartbeat = self._clock()
        return self._lease_id

    def heartbeat(self, lease_id: str) -> None:
        if self._lease_id is None or lease_id != self._lease_id:
            raise PttSafetyError("invalid_lease", "PTT lease is invalid")
        self._last_heartbeat = self._clock()

    async def request_ptt(self, lease_id: str | None, enabled: bool) -> None:
        async with self._transition_lock:
            if enabled:
                if self._lease_id is None or lease_id != self._lease_id:
                    raise PttSafetyError("invalid_lease", "PTT lease is invalid")
                state = self._state_snapshot()
                if state.lifecycle is not Lifecycle.READY:
                    raise PttSafetyError("not_ready", "rig is not ready to transmit")
                if self._clock() - self._last_heartbeat > self._heartbeat_timeout_s:
                    raise PttSafetyError(
                        "heartbeat_timeout", "PTT lease heartbeat is stale"
                    )
                if self._clock() < self._lockout_until:
                    raise PttSafetyError("locked_out", "PTT safety lockout is active")
                if self._swr_latched:
                    raise PttSafetyError(
                        "swr_latched", "SWR safety trip requires a fresh low reading"
                    )
                self._validate_effective_tx(state)
                if self._ptt_on:
                    return
                if self._dekey_required:
                    raise PttSafetyError(
                        "dekey_required", "hardware de-key has not been confirmed"
                    )
                self._dekey_required = True
                result, cancelled = await self._settle_ptt_call(True)
                if cancelled or isinstance(result, BaseException):
                    try:
                        await self._physical_off()
                    except Exception:
                        pass
                    if cancelled:
                        raise asyncio.CancelledError
                    raise result
                self._ptt_on = True
                self._tx_started_at = self._clock()
                return
            if self._ptt_on or self._dekey_required:
                await self._physical_off()

    def _validate_effective_tx(self, state) -> None:
        if not getattr(state, "split_state_known", False):
            raise PttSafetyError(
                "tx_split_unknown", "effective split TX state is unknown"
            )
        frequency_hz = (
            state.split_frequency_hz if state.split_enabled else state.frequency_hz
        )
        if frequency_hz is None:
            raise PttSafetyError(
                "tx_frequency_unknown", "effective TX frequency is unknown"
            )
        tx_ranges_hz = self._current_tx_ranges()
        if not any(
            low_hz <= frequency_hz <= high_hz
            for low_hz, high_hz in tx_ranges_hz
        ):
            raise PttSafetyError(
                "tx_out_of_range", "effective TX frequency is out of range"
            )

    def _current_tx_ranges(self) -> tuple[tuple[int, int], ...]:
        from_provider = callable(self._tx_ranges_hz)
        try:
            ranges = (
                self._tx_ranges_hz()
                if from_provider
                else self._tx_ranges_hz
            )
            if type(ranges) is not tuple or (from_provider and not ranges):
                raise ValueError
            for item in ranges:
                if type(item) is not tuple or len(item) != 2:
                    raise ValueError
                low_hz, high_hz = item
                if type(low_hz) is not int or type(high_hz) is not int:
                    raise ValueError
                if low_hz > high_hz:
                    raise ValueError
            return ranges
        except Exception as error:
            if isinstance(error, asyncio.CancelledError):
                raise
            raise PttSafetyError(
                "tx_ranges_unavailable", "transmit ranges are unavailable"
            ) from None

    async def client_disconnected(self, device_id: str) -> None:
        async with self._transition_lock:
            if device_id == self._lease_owner and self._ptt_on:
                await self._trip("client_disconnected")
            elif device_id == self._lease_owner:
                self._invalidate_lease()

    async def transport_fault(self) -> None:
        async with self._transition_lock:
            if self._ptt_on:
                await self._trip("transport_fault", suppress_off_error=True)
            elif self._dekey_required:
                try:
                    await self._physical_off()
                except Exception:
                    pass
                self._invalidate_lease()
                self._lockout_until = self._clock() + self._lockout_s
            else:
                self._dekey_required = True
                self._invalidate_lease()
                self._lockout_until = self._clock() + self._lockout_s

    async def shutdown(self) -> None:
        async with self._transition_lock:
            if self._ptt_on:
                await self._trip("shutdown")
            elif self._dekey_required:
                self._invalidate_lease()
                self._lockout_until = self._clock() + self._lockout_s
                await self._physical_off()
            else:
                self._invalidate_lease()
                self._lockout_until = self._clock() + self._lockout_s

    async def evaluate(self, swr: float | None) -> PttTrip | None:
        async with self._transition_lock:
            if swr is not None and swr <= self._swr_reset:
                self._swr_latched = False
            if not self._ptt_on:
                return None
            if swr is not None and swr >= self._swr_trip:
                self._swr_latched = True
                return await self._trip("swr_breach")
            if self._clock() - self._last_heartbeat > self._heartbeat_timeout_s:
                return await self._trip("heartbeat_timeout")
            try:
                self._validate_effective_tx(self._state_snapshot())
            except PttSafetyError as error:
                return await self._trip(error.reason)
            if self._clock() - self._tx_started_at >= self._hard_limit_s:
                return await self._trip("hard_limit")
            return None

    async def reconcile_dekey(self) -> None:
        """Converge a newly connected session to confirmed receive state."""
        async with self._transition_lock:
            self._dekey_required = True
            await self._physical_off()

    async def _trip(self, reason: str, *, suppress_off_error: bool = False) -> PttTrip:
        now = self._clock()
        trip = PttTrip(reason, now)
        self._ptt_on = False
        self._dekey_required = True
        self._tx_started_at = None
        self._invalidate_lease()
        self._lockout_until = now + self._lockout_s
        self._last_trip = trip
        self._audit_sink("ptt.trip", {"reason": reason})
        try:
            await self._physical_off()
        except Exception:
            if not suppress_off_error:
                raise
        return trip

    async def _physical_off(self) -> None:
        self._dekey_required = True
        result, cancelled = await self._settle_ptt_call(False)
        if not isinstance(result, BaseException):
            self._ptt_on = False
            self._dekey_required = False
            self._tx_started_at = None
        if cancelled:
            raise asyncio.CancelledError
        if isinstance(result, BaseException):
            raise result

    async def _settle_ptt_call(self, enabled: bool) -> tuple[object, bool]:
        operation = asyncio.create_task(self._set_ptt(enabled))
        try:
            return await asyncio.shield(operation), False
        except asyncio.CancelledError:
            current = asyncio.current_task()
            if current is None or not current.cancelling():
                raise
            result = (await asyncio.gather(operation, return_exceptions=True))[0]
            return result, True
        except BaseException as error:
            return error, False

    def _invalidate_lease(self) -> None:
        self._lease_id = None
        self._lease_owner = None
        self._last_heartbeat = None
