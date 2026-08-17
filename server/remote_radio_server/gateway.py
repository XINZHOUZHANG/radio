"""Strict JSON message boundary for the rig control plane."""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum
from math import isfinite

from .rig.commands import RigCommandService
from .rig.models import CommandResult, Lifecycle, RigCapabilities, RigState, StateDelta
from .rig.safety import PttSafetyError
from .rig.supervisor import LifecycleEvent, RigNotReadyError


@dataclass(frozen=True, slots=True)
class Principal:
    device_id: str
    is_admin: bool = False

    def __post_init__(self) -> None:
        if not isinstance(self.device_id, str) or not self.device_id.strip():
            raise ValueError("device_id must be non-empty text")
        if type(self.is_admin) is not bool:
            raise TypeError("is_admin must be a boolean")


class GatewayError(Exception):
    def __init__(
        self, code: str, message: str, request_id: str | None = None
    ) -> None:
        self.code = code
        self.safe_message = message
        self.request_id = request_id
        super().__init__(message)

    def to_event(self) -> dict[str, object]:
        event: dict[str, object] = {
            "type": "error",
            "code": self.code,
            "message": self.safe_message,
        }
        if self.request_id is not None:
            event["request_id"] = self.request_id
        return event


@dataclass(frozen=True, slots=True)
class _CurrentSession:
    transport: object
    capabilities: RigCapabilities
    state_service: object


class _CurrentSessionBinding:
    def __init__(self, supervisor=None) -> None:
        self._supervisor = supervisor
        self._invalidators = []

    def attach(self, supervisor) -> None:
        if self._supervisor is not None and self._supervisor is not supervisor:
            raise RuntimeError("session binding is already attached")
        self._supervisor = supervisor

    def add_invalidator(self, invalidator) -> None:
        self._invalidators.append(invalidator)

    async def lifecycle_changed(self, event: LifecycleEvent) -> None:
        if event.lifecycle is not Lifecycle.READY:
            for invalidator in tuple(self._invalidators):
                result = invalidator()
                if hasattr(result, "__await__"):
                    await result

    def ready_session(self) -> _CurrentSession:
        supervisor = self._supervisor
        if supervisor is None:
            raise RigNotReadyError("rig session binding is unattached")
        supervisor.require_ready()
        transport = supervisor.active_transport
        capabilities = supervisor.capabilities
        state_service = supervisor.active_state_service
        if transport is None or capabilities is None or state_service is None:
            raise RigNotReadyError("rig is not ready")
        session = _CurrentSession(transport, capabilities, state_service)
        if not self.is_current(session):
            raise RigNotReadyError("rig session changed")
        return session

    def is_current(self, session: _CurrentSession) -> bool:
        supervisor = self._supervisor
        return bool(
            supervisor is not None
            and supervisor.ready
            and supervisor.active_transport is session.transport
            and supervisor.capabilities is session.capabilities
            and supervisor.active_state_service is session.state_service
        )

    def active_transport(self):
        supervisor = self._supervisor
        return None if supervisor is None else supervisor.active_transport


class RigMessageGateway:
    def __init__(
        self,
        supervisor,
        state_store,
        safety,
        *,
        session_binding=None,
        command_service_factory=None,
    ):
        self._supervisor = supervisor
        self._state_store = state_store
        self._safety = safety
        self._session_binding = session_binding or _CurrentSessionBinding(supervisor)
        self._command_service_factory = command_service_factory or RigCommandService
        self._cached_transport = None
        self._cached_command_service = None
        self._session_binding.add_invalidator(self._discard_command_service)

    async def handle(
        self, principal: Principal, message: Mapping[str, object]
    ) -> dict[str, object]:
        if not isinstance(principal, Principal):
            raise GatewayError("invalid_principal", "principal is invalid")
        normalized = _mapping(message)
        message_type = _required_text(normalized, "type")
        request_id = _possible_request_id(normalized)
        try:
            if message_type == "rig.snapshot":
                _exact_fields(normalized, {"type"})
                return serialize_snapshot(self._state_store.snapshot())
            if message_type == "rig.command":
                return await self._handle_rig_command(principal, normalized)
            if message_type == "ptt.lease":
                _exact_fields(normalized, {"type"})
                lease_id = self._safety.acquire_lease(principal.device_id)
                return {"type": "ptt.lease", "lease_id": lease_id}
            if message_type == "ptt.heartbeat":
                _exact_fields(normalized, {"type", "lease_id"})
                self._safety.heartbeat(_required_text(normalized, "lease_id"))
                return {"type": "ptt.heartbeat", "status": "ok"}
            if message_type == "ptt.set":
                _exact_fields(normalized, {"type", "lease_id", "enabled"})
                lease_id = _required_text(normalized, "lease_id")
                enabled = _required_bool(normalized, "enabled")
                await self._safety.request_ptt(lease_id, enabled)
                return {"type": "ptt.state", "enabled": self._safety.ptt_on}
            raise GatewayError(
                "unsupported_message", "message type is unsupported", request_id
            )
        except GatewayError as error:
            if (
                message_type == "rig.command"
                and error.request_id is None
                and request_id is not None
            ):
                error.request_id = request_id
            raise
        except PttSafetyError as error:
            raise GatewayError(error.reason, str(error), request_id) from None
        except RigNotReadyError as error:
            await self._discard_command_service()
            raise GatewayError("not_ready", str(error), request_id) from None

    async def initial_event(self) -> dict[str, object]:
        try:
            session = self._session_binding.ready_session()
        except RigNotReadyError as error:
            raise GatewayError("not_ready", str(error)) from None
        return serialize_capabilities(session.capabilities)

    async def client_disconnected(self, device_id: str) -> None:
        await self._safety.client_disconnected(device_id)

    async def _handle_rig_command(self, principal, message) -> dict[str, object]:
        request_id = _request_id(message)
        command = _required_text(message, "command")
        fields = {
            "set_frequency": ({"type", "request_id", "command", "frequency_hz"}, ()),
            "set_mode": ({"type", "request_id", "command", "mode"}, {"passband_hz"}),
            "set_level": ({"type", "request_id", "command", "level", "value"}, ()),
            "set_func": ({"type", "request_id", "command", "func", "enabled"}, ()),
            "set_split": (
                {"type", "request_id", "command", "enabled", "tx_vfo"},
                {"frequency_hz", "mode", "passband_hz"},
            ),
            "send_raw": ({"type", "request_id", "command", "raw_request"}, ()),
        }
        if command not in fields:
            raise GatewayError("unsupported_command", "command is unsupported", request_id)
        required, optional = fields[command]
        _exact_fields(message, set(required), set(optional), request_id=request_id)
        values = self._validated_command_values(command, message, request_id)
        service = await self._current_command_service(request_id)
        if command == "set_frequency":
            result = await service.set_frequency(
                values["frequency_hz"], transmitting=self._safety.ptt_on
            )
        elif command == "set_mode":
            result = await service.set_mode(values["mode"], values.get("passband_hz", 0))
        elif command == "set_level":
            result = await service.set_level(values["level"], values["value"])
        elif command == "set_func":
            result = await service.set_func(values["func"], values["enabled"])
        elif command == "set_split":
            if self._safety.ptt_on:
                result = CommandResult.rejected(
                    "invalid", "split cannot be changed while transmitting"
                )
            else:
                result = await service.set_split(
                    values["enabled"],
                    values["tx_vfo"],
                    frequency_hz=values.get("frequency_hz"),
                    mode=values.get("mode"),
                    passband_hz=values.get("passband_hz", 0),
                )
        else:
            result = await service.send_raw_admin(
                values["raw_request"], is_admin=principal.is_admin
            )
        return _command_result(request_id, command, result)

    def _validated_command_values(self, command, message, request_id):
        try:
            if command == "set_frequency":
                return {"frequency_hz": _required_int(message, "frequency_hz")}
            if command == "set_mode":
                values = {"mode": _required_text(message, "mode")}
                if "passband_hz" in message:
                    values["passband_hz"] = _required_int(message, "passband_hz")
                return values
            if command == "set_level":
                return {
                    "level": _required_text(message, "level"),
                    "value": _required_number(message, "value"),
                }
            if command == "set_func":
                return {
                    "func": _required_text(message, "func"),
                    "enabled": _required_bool(message, "enabled"),
                }
            if command == "set_split":
                values = {
                    "enabled": _required_bool(message, "enabled"),
                    "tx_vfo": _required_text(message, "tx_vfo"),
                }
                if "frequency_hz" in message:
                    values["frequency_hz"] = _required_int(message, "frequency_hz")
                if "mode" in message:
                    values["mode"] = _required_text(message, "mode")
                if "passband_hz" in message:
                    values["passband_hz"] = _required_int(message, "passband_hz")
                return values
            return {"raw_request": _required_text(message, "raw_request")}
        except GatewayError as error:
            if error.request_id is None:
                error.request_id = request_id
            raise

    async def _current_command_service(self, request_id):
        try:
            session = self._session_binding.ready_session()
        except RigNotReadyError as error:
            await self._discard_command_service()
            raise GatewayError("not_ready", str(error), request_id) from None
        if session.transport is not self._cached_transport:
            await self._discard_command_service()
            self._cached_transport = session.transport
            self._cached_command_service = self._command_service_factory(
                session.transport, session.capabilities, store=self._state_store
            )
        return self._cached_command_service

    async def _discard_command_service(self):
        service = self._cached_command_service
        self._cached_transport = None
        self._cached_command_service = None
        close = getattr(service, "close", None)
        if close is not None:
            result = close()
            if hasattr(result, "__await__"):
                await result


def serialize_capabilities(capabilities: RigCapabilities) -> dict[str, object]:
    identity = capabilities.identity
    return {
        "type": "rig.capabilities",
        "identity": {
            "manufacturer": identity.manufacturer,
            "model": identity.model,
            "model_id": identity.model_id,
            "backend_version": identity.backend_version,
            "hamlib_version": identity.hamlib_version,
        },
        "vfos": sorted(capabilities.vfos),
        "modes": sorted(capabilities.modes),
        "readable_levels": sorted(capabilities.readable_levels),
        "writable_levels": sorted(capabilities.writable_levels),
        "readable_functions": sorted(capabilities.readable_functions),
        "writable_functions": sorted(capabilities.writable_functions),
        "readable_parameters": sorted(capabilities.readable_parameters),
        "writable_parameters": sorted(capabilities.writable_parameters),
        "vfo_operations": sorted(capabilities.vfo_operations),
        "targetable_features": sorted(capabilities.targetable_features),
        "passbands_hz": [list(item) for item in sorted(capabilities.passbands_hz)],
        "rx_ranges_hz": [list(bounds) for bounds in sorted(capabilities.rx_ranges_hz)],
        "tx_ranges_hz": [list(bounds) for bounds in sorted(capabilities.tx_ranges_hz)],
        "supports_ptt_read": capabilities.supports_ptt_read,
        "supports_ptt_write": capabilities.supports_ptt_write,
        "supports_split_read": capabilities.supports_split_read,
        "supports_split_write": capabilities.supports_split_write,
    }


def serialize_snapshot(state: RigState) -> dict[str, object]:
    return {
        "type": "rig.snapshot",
        "lifecycle": state.lifecycle.value,
        "revision": state.revision,
        "frequency_hz": state.frequency_hz,
        "mode": state.mode,
        "passband_hz": state.passband_hz,
        "vfo": state.vfo,
        "split_state_known": state.split_state_known,
        "split_enabled": state.split_enabled,
        "split_vfo": state.split_vfo,
        "split_frequency_hz": state.split_frequency_hz,
        "split_mode": state.split_mode,
        "split_passband_hz": state.split_passband_hz,
        "ptt": state.ptt,
        "meters": dict(sorted(state.meters)),
    }


def serialize_lifecycle_event(event: LifecycleEvent) -> dict[str, object]:
    return {
        "type": "rig.lifecycle",
        "lifecycle": event.lifecycle.value,
        "revision": event.revision,
    }


def serialize_state_delta(delta: StateDelta) -> dict[str, object]:
    return {
        "type": "rig.state_delta",
        "revision": delta.revision,
        "changes": {key: _json_value(value) for key, value in delta.changes},
    }


def serialize_json_event(event: Mapping[str, object]) -> str:
    return json.dumps(event, separators=(",", ":"), sort_keys=True, allow_nan=False)


def _json_value(value):
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, tuple):
        return [_json_value(item) for item in value]
    return value


def _command_result(request_id: str, command: str, result: CommandResult):
    event = {
        "type": "rig.command_result",
        "request_id": request_id,
        "command": command,
        "status": result.status,
        "message": result.message,
    }
    if result.revision is not None:
        event["revision"] = result.revision
    if result.hamlib_code is not None:
        event["hamlib_code"] = result.hamlib_code
    return event


def _mapping(message):
    if not isinstance(message, Mapping) or any(not isinstance(key, str) for key in message):
        raise GatewayError("invalid_message", "message must be an object with text keys")
    return message


def _exact_fields(message, required, optional=frozenset(), *, request_id=None):
    actual = set(message)
    if not required.issubset(actual) or not actual.issubset(required | set(optional)):
        raise GatewayError("invalid_message", "message fields are invalid", request_id)


def _required_text(message, field):
    value = message.get(field)
    if not isinstance(value, str) or not value.strip():
        raise GatewayError("invalid_message", f"{field} must be non-empty text")
    return value


def _request_id(message):
    value = _required_text(message, "request_id")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeEncodeError:
        size = 129
    if size > 128:
        raise GatewayError("invalid_message", "request_id exceeds 128 UTF-8 bytes")
    return value


def _possible_request_id(message):
    value = message.get("request_id")
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        return value if len(value.encode("utf-8")) <= 128 else None
    except UnicodeEncodeError:
        return None


def _required_bool(message, field):
    value = message.get(field)
    if type(value) is not bool:
        raise GatewayError("invalid_message", f"{field} must be a boolean")
    return value


def _required_int(message, field):
    value = message.get(field)
    if type(value) is not int:
        raise GatewayError("invalid_message", f"{field} must be an integer")
    return value


def _required_number(message, field):
    value = message.get(field)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not isfinite(value):
        raise GatewayError("invalid_message", f"{field} must be finite numeric")
    return value


__all__ = [
    "GatewayError",
    "Principal",
    "RigMessageGateway",
    "serialize_capabilities",
    "serialize_json_event",
    "serialize_lifecycle_event",
    "serialize_snapshot",
    "serialize_state_delta",
]
