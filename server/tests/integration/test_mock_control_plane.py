import asyncio
import unittest

from remote_radio_server.gateway import Principal
from remote_radio_server.mock_rigctld import MockRigctld
from remote_radio_server.rig.errors import RigReportError
from remote_radio_server.rig.models import Lifecycle
from remote_radio_server.runtime import ControlPlaneRuntime
from tests.integration.helpers import running_mock_control_plane, wait_for_condition


USER = Principal(device_id="test-device")


class RejectingPttOffMockRigctld(MockRigctld):
    def __init__(self):
        super().__init__()
        self.reject_ptt_off = False

    def _dispatch(self, command):
        if command == "\\set_ptt 0" and self.reject_ptt_off:
            return b"set_ptt:|RPRT -1|\n"
        return super()._dispatch(command)


class GatedCloseMockRigctld(MockRigctld):
    def __init__(self):
        super().__init__()
        self.close_started = asyncio.Event()
        self.release_close = asyncio.Event()

    async def close(self):
        self.close_started.set()
        await self.release_close.wait()
        await super().close()


class LifecycleRecordingMockRigctld(MockRigctld):
    def __init__(self):
        super().__init__()
        self.lifecycle_provider = None
        self.off_lifecycles = []

    def _dispatch(self, command):
        if command == "\\set_ptt 0" and self.lifecycle_provider is not None:
            self.off_lifecycles.append(self.lifecycle_provider())
        return super()._dispatch(command)


class MockControlPlaneTests(unittest.IsolatedAsyncioTestCase):
    async def test_close_cancellation_is_propagated_after_endpoint_cleanup(self):
        endpoint = GatedCloseMockRigctld()
        app = ControlPlaneRuntime.with_mock(endpoint)
        await app.start()
        port = endpoint.port

        close_task = asyncio.create_task(app.close())
        await endpoint.close_started.wait()
        close_task.cancel()
        endpoint.release_close.set()

        with self.assertRaises(asyncio.CancelledError):
            await close_task
        with self.assertRaises(OSError):
            await asyncio.open_connection("127.0.0.1", port)
        await app.close()

    async def test_close_releases_all_resources_before_reporting_ptt_off_failure(self):
        endpoint = RejectingPttOffMockRigctld()
        app = ControlPlaneRuntime.with_mock(endpoint)
        await app.start()
        endpoint.reject_ptt_off = True
        lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
        await app.gateway.handle(
            USER,
            {"type": "ptt.set", "lease_id": lease["lease_id"], "enabled": True},
        )
        port = endpoint.port

        try:
            with self.assertRaises(RigReportError):
                await app.close()

            self.assertTrue(app.poll_task is None or app.poll_task.done())
            self.assertTrue(app.run_task is None or app.run_task.done())
            with self.assertRaises(OSError):
                await asyncio.open_connection("127.0.0.1", port)
        finally:
            endpoint.reject_ptt_off = False
            await app.close()

    async def test_all_gateway_command_routes_return_typed_results(self):
        admin = Principal("admin-device", is_admin=True)
        async with running_mock_control_plane() as app:
            commands = (
                {
                    "type": "rig.command",
                    "request_id": "mode",
                    "command": "set_mode",
                    "mode": "USB",
                    "passband_hz": 2400,
                },
                {
                    "type": "rig.command",
                    "request_id": "level",
                    "command": "set_level",
                    "level": "AF",
                    "value": 0.5,
                },
                {
                    "type": "rig.command",
                    "request_id": "func",
                    "command": "set_func",
                    "func": "NB",
                    "enabled": True,
                },
                {
                    "type": "rig.command",
                    "request_id": "split",
                    "command": "set_split",
                    "enabled": True,
                    "tx_vfo": "VFOB",
                    "frequency_hz": 14_074_000,
                    "mode": "USB",
                    "passband_hz": 2400,
                },
                {
                    "type": "rig.command",
                    "request_id": "raw",
                    "command": "send_raw",
                    "raw_request": "; ID",
                },
            )
            for message in commands:
                with self.subTest(command=message["command"]):
                    result = await app.gateway.handle(admin, message)
                    self.assertEqual("rig.command_result", result["type"])
                    self.assertEqual(message["request_id"], result["request_id"])
                    self.assertEqual(message["command"], result["command"])
                    self.assertEqual("confirmed", result["status"])
                    self.assertEqual(
                        {"type", "request_id", "command", "status", "message", "revision"},
                        set(result),
                    )

            snapshot = await app.gateway.handle(admin, {"type": "rig.snapshot"})
            self.assertTrue(snapshot["split_enabled"])
            self.assertEqual(14_074_000, snapshot["split_frequency_hz"])
            self.assertEqual("USB", snapshot["split_mode"])

    async def test_ptt_heartbeat_and_exact_schema(self):
        async with running_mock_control_plane() as app:
            lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
            heartbeat = await app.gateway.handle(
                USER,
                {"type": "ptt.heartbeat", "lease_id": lease["lease_id"]},
            )
            self.assertEqual(
                {"type": "ptt.heartbeat", "status": "ok"}, heartbeat
            )
            with self.assertRaisesRegex(Exception, "fields"):
                await app.gateway.handle(
                    USER, {"type": "ptt.lease", "unexpected": True}
                )

    async def test_hard_limit_dekeys_during_persistent_telemetry_failure(self):
        """Coupling evaluate() behind poll_once() must leave the mock keyed."""
        async with running_mock_control_plane() as app:
            app.safety._hard_limit_s = 0.05
            app.safety._heartbeat_timeout_s = 60.0
            session = app.session_binding.ready_session()

            async def failed_poll(_transmitting):
                raise RigReportError(-12)

            session.state_service.poll_once = failed_poll
            lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
            await app.gateway.handle(
                USER,
                {"type": "ptt.set", "lease_id": lease["lease_id"], "enabled": True},
            )

            await wait_for_condition(
                lambda: not app.mock_rig.ptt,
                "hard-limit watchdog independent of failed telemetry",
                timeout_s=0.5,
            )
            self.assertEqual("hard_limit", app.safety.last_trip.reason)

    async def test_set_split_is_rejected_before_any_write_while_keyed(self):
        """Routing keyed split changes directly to commands must mutate the mock."""
        async with running_mock_control_plane() as app:
            lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
            await app.gateway.handle(
                USER,
                {"type": "ptt.set", "lease_id": lease["lease_id"], "enabled": True},
            )
            before = len(app.mock_rig.commands)

            result = await app.gateway.handle(
                USER,
                {
                    "type": "rig.command",
                    "request_id": "keyed-split",
                    "command": "set_split",
                    "enabled": True,
                    "tx_vfo": "VFOB",
                    "frequency_hz": 14_100_000,
                },
            )

            self.assertEqual("invalid", result["status"])
            self.assertFalse(app.mock_rig.split_enabled)
            self.assertFalse(
                [
                    command
                    for command in app.mock_rig.commands[before:]
                    if command.startswith("\\set_split")
                ]
            )

    async def test_discover_control_and_disconnect_trip(self):
        async with running_mock_control_plane() as app:
            caps = await app.gateway.initial_event()
            self.assertEqual("rig.capabilities", caps["type"])
            result = await app.gateway.handle(
                USER,
                {
                    "type": "rig.command",
                    "request_id": "r1",
                    "command": "set_frequency",
                    "frequency_hz": 14_074_000,
                },
            )
            self.assertEqual("confirmed", result["status"])
            lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
            await app.gateway.handle(
                USER,
                {
                    "type": "ptt.set",
                    "lease_id": lease["lease_id"],
                    "enabled": True,
                },
            )
            self.assertTrue(app.mock_rig.ptt)
            await app.gateway.client_disconnected(USER.device_id)
            self.assertFalse(app.safety.ptt_on)
            self.assertFalse(app.mock_rig.ptt)
            self.assertEqual(
                ["\\set_ptt 1", "\\set_ptt 0"],
                [command for command in app.mock_rig.commands if command.startswith("\\set_ptt")],
            )

    async def test_real_mode_policy_rejects_ptt_before_mock_transport_write(self):
        from remote_radio_server.gateway import GatewayError
        from remote_radio_server.mock_rigctld import MockRigctld

        async with MockRigctld() as endpoint:
            app = ControlPlaneRuntime(
                port=endpoint.port,
                hardware_tx_enabled=False,
            )
            await app.start()
            try:
                lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
                with self.assertRaises(GatewayError) as caught:
                    await app.gateway.handle(
                        USER,
                        {
                            "type": "ptt.set",
                            "lease_id": lease["lease_id"],
                            "enabled": True,
                        },
                    )
                self.assertEqual("hardware_tx_disabled", caught.exception.code)
                self.assertNotIn("\\set_ptt 1", endpoint.commands)
                self.assertFalse(app.safety.ptt_on)
            finally:
                await app.close()

    def test_simulation_override_is_rejected_without_owned_mock(self):
        with self.assertRaisesRegex(ValueError, "requires an owned MockRigctld"):
            ControlPlaneRuntime(simulated_tx=True)
        with self.assertRaisesRegex(TypeError, "mock_rig must be a MockRigctld"):
            ControlPlaneRuntime(mock_rig=object())

    async def test_polling_trips_high_swr_and_reconnect_uses_new_session(self):
        async with running_mock_control_plane() as app:
            first_transport = app.supervisor.active_transport
            lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
            await app.gateway.handle(
                USER,
                {
                    "type": "ptt.set",
                    "lease_id": lease["lease_id"],
                    "enabled": True,
                },
            )
            app.mock_rig.levels["SWR"] = 3.1
            await wait_for_condition(
                lambda: not app.safety.ptt_on, "SWR watchdog to de-key simulated PTT"
            )
            self.assertFalse(app.safety.ptt_on)
            self.assertEqual("swr_breach", app.safety.last_trip.reason)

            app.mock_rig.levels["SWR"] = 1.1
            await app.mock_rig.disconnect_clients()
            await wait_for_condition(
                lambda: (
                    app.supervisor.ready
                    and app.supervisor.active_transport is not first_transport
                    and not app.mock_rig.ptt
                ),
                "READY replacement session after SWR trip",
            )
            self.assertTrue(app.supervisor.ready)
            self.assertIsNot(first_transport, app.supervisor.active_transport)
            result = await app.gateway.handle(
                USER,
                {
                    "type": "rig.command",
                    "request_id": "after-reconnect",
                    "command": "set_mode",
                    "mode": "USB",
                    "passband_hz": 2400,
                },
            )
            self.assertEqual("confirmed", result["status"])

    async def test_transport_disconnect_while_ptt_on_trips_and_reconnects(self):
        async with running_mock_control_plane() as app:
            first_transport = app.supervisor.active_transport
            lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
            await app.gateway.handle(
                USER,
                {
                    "type": "ptt.set",
                    "lease_id": lease["lease_id"],
                    "enabled": True,
                },
            )

            await app.mock_rig.disconnect_clients()
            await wait_for_condition(
                lambda: (
                    app.supervisor.ready
                    and app.supervisor.active_transport is not first_transport
                    and not app.mock_rig.ptt
                ),
                "transport trip, replacement READY session, and fail-safe PTT off",
            )

            self.assertFalse(app.safety.ptt_on)
            self.assertEqual("transport_fault", app.safety.last_trip.reason)
            self.assertTrue(app.supervisor.ready)
            self.assertIsNot(first_transport, app.supervisor.active_transport)
            self.assertFalse(app.mock_rig.ptt)

    async def test_reconnect_dekeys_and_confirms_before_publishing_ready(self):
        """Post-READY reconciliation must record READY for the replacement off."""
        endpoint = LifecycleRecordingMockRigctld()
        app = ControlPlaneRuntime.with_mock(endpoint)
        await app.start()
        endpoint.lifecycle_provider = lambda: app.supervisor.lifecycle
        first_transport = app.supervisor.active_transport
        try:
            lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
            await app.gateway.handle(
                USER,
                {"type": "ptt.set", "lease_id": lease["lease_id"], "enabled": True},
            )
            endpoint.off_lifecycles.clear()

            await endpoint.disconnect_clients()
            await wait_for_condition(
                lambda: (
                    app.supervisor.ready
                    and app.supervisor.active_transport is not first_transport
                    and not endpoint.ptt
                    and bool(endpoint.off_lifecycles)
                ),
                "replacement session de-key before READY",
            )

            self.assertEqual(Lifecycle.DISCOVERING, endpoint.off_lifecycles[0])
        finally:
            await app.close()

    async def test_close_is_idempotent_and_releases_owned_resources(self):
        app = ControlPlaneRuntime.with_mock()
        await app.start()
        port = app.mock_rig.port

        await app.close()
        await app.close()

        self.assertTrue(app.poll_task is None or app.poll_task.done())
        self.assertTrue(app.run_task is None or app.run_task.done())
        with self.assertRaises(OSError):
            await asyncio.open_connection("127.0.0.1", port)


if __name__ == "__main__":
    unittest.main()
