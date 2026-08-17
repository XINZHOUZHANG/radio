import asyncio
import inspect
import math
import unittest

from remote_radio_server.gateway import (
    GatewayError,
    Principal,
    RigMessageGateway,
    serialize_json_event,
    serialize_lifecycle_event,
    serialize_snapshot,
    serialize_state_delta,
)
from remote_radio_server.rig.models import Lifecycle, RigState, StateDelta
from remote_radio_server.rig.models import CommandResult, RigCapabilities, RigIdentity
from remote_radio_server.rig.state import RigStateStore
from remote_radio_server.rig.supervisor import LifecycleEvent


class _NotReadySupervisor:
    capabilities = None
    active_transport = None

    def require_ready(self):
        from remote_radio_server.rig.supervisor import RigNotReadyError

        raise RigNotReadyError("rig is not ready")


class _Safety:
    ptt_on = False

    async def client_disconnected(self, _device_id):
        pass


class _ToggleSupervisor:
    def __init__(self):
        self.ready = True
        self.active_transport = object()
        self.active_state_service = object()
        self.capabilities = RigCapabilities(
            identity=RigIdentity("Test", "Rig", 1, "1", "1"),
            rx_ranges_hz=((100_000, 60_000_000),),
        )

    def require_ready(self):
        if not self.ready:
            from remote_radio_server.rig.supervisor import RigNotReadyError

            raise RigNotReadyError("rig is not ready")


class _MarkerCommandService:
    def __init__(self, marker):
        self.marker = marker

    async def set_frequency(self, _frequency_hz, *, transmitting=False):
        return CommandResult("confirmed", self.marker, revision=1)


class _GatedCloseCommandService(_MarkerCommandService):
    def __init__(self, marker):
        super().__init__(marker)
        self.close_started = asyncio.Event()
        self.close_allowed = asyncio.Event()
        self.close_calls = 0

    async def close(self):
        self.close_calls += 1
        self.close_started.set()
        await self.close_allowed.wait()


class GatewayValidationTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.store = RigStateStore()
        self.gateway = RigMessageGateway(_NotReadySupervisor(), self.store, _Safety())
        self.user = Principal("device-1")

    async def test_rejects_unknown_fields_before_not_ready_resolution(self):
        with self.assertRaises(GatewayError) as caught:
            await self.gateway.handle(
                self.user,
                {
                    "type": "rig.command",
                    "request_id": "r1",
                    "command": "set_frequency",
                    "frequency_hz": 14_074_000,
                    "transmitting": True,
                },
            )

        self.assertEqual("invalid_message", caught.exception.code)
        self.assertEqual("r1", caught.exception.request_id)

    async def test_rejects_boolean_as_numeric_command_value(self):
        with self.assertRaises(GatewayError) as caught:
            await self.gateway.handle(
                self.user,
                {
                    "type": "rig.command",
                    "request_id": "r2",
                    "command": "set_level",
                    "level": "AF",
                    "value": True,
                },
            )

        self.assertEqual("invalid_message", caught.exception.code)

    async def test_rig_snapshot_rejects_extras_and_serializes_current_state(self):
        self.store.apply(
            {
                "lifecycle": Lifecycle.READY,
                "frequency_hz": 14_074_000,
                "mode": "USB",
                "meters": (("SWR", 1.2),),
            }
        )
        event = await self.gateway.handle(self.user, {"type": "rig.snapshot"})
        self.assertEqual(serialize_snapshot(self.store.snapshot()), event)
        with self.assertRaises(GatewayError):
            await self.gateway.handle(
                self.user, {"type": "rig.snapshot", "extra": "rejected"}
            )

    def test_principal_and_request_id_validation_are_strict(self):
        with self.assertRaises(ValueError):
            Principal("")
        with self.assertRaises(TypeError):
            Principal("device", is_admin=1)

    async def test_request_id_enforces_utf8_byte_limit(self):
        accepted = "é" * 64
        with self.assertRaises(GatewayError) as not_ready:
            await self.gateway.handle(
                self.user,
                {
                    "type": "rig.command",
                    "request_id": accepted,
                    "command": "set_frequency",
                    "frequency_hz": 14_074_000,
                },
            )
        self.assertEqual("not_ready", not_ready.exception.code)

        with self.assertRaises(GatewayError) as too_long:
            await self.gateway.handle(
                self.user,
                {
                    "type": "rig.command",
                    "request_id": accepted + "a",
                    "command": "set_frequency",
                    "frequency_hz": 14_074_000,
                },
            )
        self.assertEqual("invalid_message", too_long.exception.code)

    async def test_whitespace_only_possible_request_id_is_not_echoed(self):
        with self.assertRaises(GatewayError) as caught:
            await self.gateway.handle(
                self.user, {"type": "unsupported", "request_id": "   "}
            )

        self.assertNotIn("request_id", caught.exception.to_event())

    async def test_every_command_schema_error_echoes_valid_request_id(self):
        messages = (
            {"type": "rig.command", "request_id": "r1"},
            {"type": "rig.command", "request_id": "r2", "command": 123},
        )
        for message in messages:
            with self.subTest(message=message):
                with self.assertRaises(GatewayError) as caught:
                    await self.gateway.handle(self.user, message)
                self.assertEqual("invalid_message", caught.exception.code)
                self.assertEqual(message["request_id"], caught.exception.request_id)
                self.assertEqual(
                    message["request_id"], caught.exception.to_event()["request_id"]
                )

    async def test_error_event_is_safe_and_preserves_request_id(self):
        error = GatewayError("invalid_message", "request is invalid", "r1")
        self.assertEqual(
            {
                "type": "error",
                "code": "invalid_message",
                "message": "request is invalid",
                "request_id": "r1",
            },
            error.to_event(),
        )

    async def test_ready_loss_invalidates_cached_service_even_for_same_transport(self):
        from remote_radio_server.gateway import _CurrentSessionBinding

        supervisor = _ToggleSupervisor()
        binding = _CurrentSessionBinding(supervisor)
        created = []

        def command_service_factory(_transport, _capabilities, *, store):
            service = _MarkerCommandService(f"service-{len(created) + 1}")
            created.append(service)
            return service

        gateway = RigMessageGateway(
            supervisor,
            RigStateStore(),
            _Safety(),
            session_binding=binding,
            command_service_factory=command_service_factory,
        )
        message = {
            "type": "rig.command",
            "request_id": "r1",
            "command": "set_frequency",
            "frequency_hz": 14_074_000,
        }
        first = await gateway.handle(self.user, message)

        supervisor.ready = False
        changed = binding.lifecycle_changed(LifecycleEvent(Lifecycle.DEGRADED, 2))
        if inspect.isawaitable(changed):
            await changed
        supervisor.ready = True
        changed = binding.lifecycle_changed(LifecycleEvent(Lifecycle.READY, 3))
        if inspect.isawaitable(changed):
            await changed
        second = await gateway.handle(self.user, {**message, "request_id": "r2"})

        self.assertEqual("service-1", first["message"])
        self.assertEqual("service-2", second["message"])

    async def test_session_invalidation_awaits_command_service_cleanup(self):
        from remote_radio_server.gateway import _CurrentSessionBinding

        supervisor = _ToggleSupervisor()
        binding = _CurrentSessionBinding(supervisor)
        created = []

        def command_service_factory(_transport, _capabilities, *, store):
            service = _GatedCloseCommandService(f"service-{len(created) + 1}")
            created.append(service)
            return service

        gateway = RigMessageGateway(
            supervisor,
            RigStateStore(),
            _Safety(),
            session_binding=binding,
            command_service_factory=command_service_factory,
        )
        await gateway.handle(
            self.user,
            {
                "type": "rig.command",
                "request_id": "r1",
                "command": "set_frequency",
                "frequency_hz": 14_074_000,
            },
        )

        changed = binding.lifecycle_changed(LifecycleEvent(Lifecycle.DEGRADED, 2))
        self.assertTrue(inspect.isawaitable(changed))
        invalidation = asyncio.create_task(changed)
        await created[0].close_started.wait()
        self.assertFalse(invalidation.done())

        created[0].close_allowed.set()
        await invalidation
        self.assertEqual(1, created[0].close_calls)

    def test_pure_event_serializers_are_deterministic_and_json_strict(self):
        snapshot = RigState(
            lifecycle=Lifecycle.READY,
            revision=7,
            meters=(("SWR", 1.25), ("ALC", 0.1)),
        )
        self.assertEqual(
            {
                "type": "rig.lifecycle",
                "lifecycle": "ready",
                "revision": 7,
            },
            serialize_lifecycle_event(LifecycleEvent(Lifecycle.READY, 7)),
        )
        self.assertEqual(
            {
                "type": "rig.state_delta",
                "revision": 8,
                "changes": {"frequency_hz": 14_074_000, "lifecycle": "ready"},
            },
            serialize_state_delta(
                StateDelta(
                    8,
                    (("lifecycle", Lifecycle.READY), ("frequency_hz", 14_074_000)),
                )
            ),
        )
        self.assertEqual(
            '{"frequency_hz":null,"lifecycle":"ready","meters":{"ALC":0.1,"SWR":1.25},'
            '"mode":null,"passband_hz":null,"ptt":false,"revision":7,'
            '"split_enabled":false,"split_frequency_hz":null,"split_mode":null,'
            '"split_passband_hz":null,"split_state_known":false,"split_vfo":null,'
            '"type":"rig.snapshot","vfo":null}',
            serialize_json_event(serialize_snapshot(snapshot)),
        )
        with self.assertRaises(ValueError):
            serialize_json_event({"value": math.nan})


if __name__ == "__main__":
    unittest.main()
