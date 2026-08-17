import asyncio
import contextlib
import io
import json
import socket
import struct
import threading
import time
import unittest
from unittest.mock import patch

from remote_radio_server.__main__ import _run, _validated_args
from remote_radio_server.mock_rigctld import MockRigctld
from remote_radio_server.runtime import ControlPlaneRuntime
from remote_radio_server.server import RemoteRadioServer
from tests.integration import helpers as websocket_helpers
from tests.integration.helpers import (
    open_websocket_client,
    running_websocket_control_plane,
    wait_for_condition,
)


class RejectingDisconnectPttOffMockRigctld(MockRigctld):
    def __init__(self):
        super().__init__()
        self.reject_ptt_off = False

    def _dispatch(self, command):
        if command == "\\set_ptt 0" and self.reject_ptt_off:
            return b"set_ptt:|RPRT -1|\n"
        return super()._dispatch(command)


class BlockingDisconnectGateway:
    def __init__(self):
        self.disconnect_calls = 0
        self.disconnect_started = asyncio.Event()
        self.release_disconnect = asyncio.Event()
        self.disconnect_completed = False

    async def client_disconnected(self, _device_id):
        self.disconnect_calls += 1
        self.disconnect_started.set()
        await self.release_disconnect.wait()
        self.disconnect_completed = True


def masked_text_wire(payload: bytes) -> bytes:
    length = len(payload)
    if length <= 125:
        header = bytes((0x81, 0x80 | length))
    elif length <= 0xFFFF:
        header = bytes((0x81, 0x80 | 126)) + struct.pack("!H", length)
    else:
        header = bytes((0x81, 0x80 | 127)) + struct.pack("!Q", length)
    key = b"\x01\x02\x03\x04"
    masked = bytearray(length)
    for phase, mask_byte in enumerate(key):
        xor_table = bytes(value ^ mask_byte for value in range(256))
        masked[phase::4] = payload[phase::4].translate(xor_table)
    return header + key + bytes(masked)


class WebSocketControlPlaneTests(unittest.IsolatedAsyncioTestCase):
    async def test_server_close_waits_for_exactly_one_authenticated_disconnect_cleanup(self):
        """Cancelling the client task must not abandon its safety cleanup."""
        gateway = BlockingDisconnectGateway()
        server = RemoteRadioServer(gateway, {"phone": "secret"})
        await server.serve(port=0)
        client = await open_websocket_client(server.port)
        closing = None
        try:
            await client.send_json(
                {"type": "auth", "device_id": "phone", "token": "secret"}
            )
            await client.receive_json()
            client.abort()
            await gateway.disconnect_started.wait()

            closing = asyncio.create_task(server.close())
            await asyncio.sleep(0)
            self.assertFalse(
                closing.done(),
                "server close returned before authenticated disconnect cleanup completed",
            )

            gateway.release_disconnect.set()
            await closing
            self.assertTrue(gateway.disconnect_completed)
            self.assertEqual(1, gateway.disconnect_calls)
        finally:
            gateway.release_disconnect.set()
            if closing is not None:
                await asyncio.gather(closing, return_exceptions=True)
            await server.close()

    async def test_helper_partial_client_setup_failure_reclaims_all_owned_resources(self):
        captured = {}
        real_open = websocket_helpers.open_websocket_client

        async def open_real_client_then_fail(port, *, request_headers=()):
            client = await real_open(port, request_headers=request_headers)
            captured["client"] = client
            captured["port"] = port
            client_tasks = [
                task
                for task in asyncio.all_tasks()
                if task.get_name().startswith("websocket-client-")
            ]
            self.assertEqual(1, len(client_tasks))
            frame = client_tasks[0].get_coro().cr_frame
            self.assertIsNotNone(frame)
            captured["server"] = frame.f_locals["self"]
            raise RuntimeError("injected failure after real WebSocket upgrade")

        try:
            with patch.object(
                websocket_helpers,
                "open_websocket_client",
                open_real_client_then_fail,
            ):
                with self.assertRaisesRegex(RuntimeError, "injected failure"):
                    async with running_websocket_control_plane():
                        self.fail("partial setup must not yield")

            try:
                probe_reader, probe_writer = await asyncio.open_connection(
                    "127.0.0.1", captured["port"]
                )
            except OSError:
                listener_closed = True
            else:
                listener_closed = False
                probe_writer.close()
                await probe_writer.wait_closed()

            try:
                client_eof = (
                    await asyncio.wait_for(captured["client"].reader.read(1), 0.2)
                    == b""
                )
            except TimeoutError:
                client_eof = False
            live_client_tasks = tuple(
                task.get_name()
                for task in asyncio.all_tasks()
                if task.get_name().startswith("websocket-client-")
            )
            self.assertEqual(
                (True, True, (), True),
                (
                    listener_closed,
                    client_eof,
                    live_client_tasks,
                    not captured["server"]._connections,
                ),
            )
        finally:
            if "client" in captured:
                await captured["client"].close()
            if "server" in captured:
                await captured["server"].close()

    async def test_cli_serve_mode_owns_listener_and_emits_no_ndjson(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        args = _validated_args(
            [
                "--mock",
                "--serve",
                "--port",
                str(port),
                "--device-token",
                "phone=secret",
            ]
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            run_task = asyncio.create_task(_run(args))
            client = None
            try:
                async def connect_when_ready():
                    deadline = asyncio.get_running_loop().time() + 5.0
                    while True:
                        try:
                            return await open_websocket_client(port)
                        except (OSError, AssertionError):
                            if asyncio.get_running_loop().time() >= deadline:
                                raise
                            await asyncio.sleep(0.01)

                client = await connect_when_ready()
                await client.send_json(
                    {"type": "auth", "device_id": "phone", "token": "secret"}
                )
                self.assertEqual("auth.ok", (await client.receive_json())["type"])
            finally:
                if client is not None:
                    await client.close()
                run_task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await run_task
        self.assertEqual("", output.getvalue())
        with self.assertRaises(OSError):
            await asyncio.open_connection("127.0.0.1", port)

    async def test_auth_then_frequency_command(self):
        async with running_websocket_control_plane(token="secret") as client:
            await client.send_json({"type": "auth", "device_id": "phone", "token": "secret"})
            self.assertEqual(
                {"type": "auth.ok", "device_id": "phone"},
                await client.receive_json(),
            )
            await client.send_json(
                {
                    "type": "rig.command",
                    "request_id": "r1",
                    "command": "set_frequency",
                    "frequency_hz": 14_074_000,
                }
            )
            result = await client.receive_json()
            self.assertEqual("confirmed", result["status"])
            self.assertEqual("r1", result["request_id"])

    async def test_authentication_failures_close_without_gateway_access_or_token_echo(self):
        runtime = ControlPlaneRuntime.with_mock()
        server = RemoteRadioServer(runtime.gateway, {"phone": "secret"})
        await runtime.start()
        await server.serve(port=0)
        try:
            messages = (
                {"type": "rig.snapshot"},
                {"type": "auth", "device_id": "phone", "token": "wrong"},
                {"type": "auth", "device_id": "unknown", "token": "secret"},
                {"type": "auth", "device_id": "phone", "token": "secret", "extra": True},
            )
            for message in messages:
                with self.subTest(message=message):
                    client = await open_websocket_client(server.port)
                    await client.send_json(message)
                    _fin, opcode, payload, masked = await client.receive_frame()
                    self.assertEqual(0x8, opcode)
                    self.assertFalse(masked)
                    self.assertEqual(1008, struct.unpack("!H", payload[:2])[0])
                    self.assertNotIn(b"secret", payload)
                    await client.close()
            self.assertFalse(runtime.mock_rig.ptt)
        finally:
            await server.close()
            await runtime.close()

    async def test_ping_gateway_error_binary_and_close_are_protocol_safe(self):
        async with running_websocket_control_plane() as client:
            await client.send_frame(0x9, b"same-payload")
            fin, opcode, payload, masked = await client.receive_frame()
            self.assertEqual((True, 0xA, b"same-payload", False), (fin, opcode, payload, masked))

            await client.send_json({"type": "auth", "device_id": "phone", "token": "secret"})
            await client.receive_json()
            await client.send_json({"type": "unsupported", "request_id": "safe-r1"})
            error = await client.receive_json()
            self.assertEqual("error", error["type"])
            self.assertEqual("unsupported_message", error["code"])
            self.assertEqual("safe-r1", error["request_id"])

            await client.send_frame(0x2, b"reserved")
            self.assertEqual(1003, await client.receive_close_code())

    async def test_non_standard_json_constant_returns_safe_error_and_connection_continues(self):
        async with running_websocket_control_plane() as client:
            await client.send_json({"type": "auth", "device_id": "phone", "token": "secret"})
            await client.receive_json()
            await client.send_frame(0x1, b'{"type":"unsupported","value":NaN}')
            error = await client.receive_json()
            self.assertEqual("invalid_json", error["code"])

            await client.send_json({"type": "rig.snapshot"})
            self.assertEqual("rig.snapshot", (await client.receive_json())["type"])

    async def test_large_masked_frame_does_not_monopolize_the_safety_event_loop(self):
        """Per-byte Python unmasking must prevent a hard-limit de-key deadline."""
        async with running_websocket_control_plane() as client:
            await client.send_json(
                {"type": "auth", "device_id": "phone", "token": "secret"}
            )
            await client.receive_json()
            payload = (
                b'{"type":"rig.snapshot","padding":"'
                + b"x" * 950_000
                + b'"}'
            )
            wire = masked_text_wire(payload)
            await client.send_json({"type": "ptt.lease"})
            lease = await client.receive_json()
            await client.send_json(
                {"type": "ptt.set", "lease_id": lease["lease_id"], "enabled": True}
            )
            await client.receive_json()
            client.writer.write(wire[:-1])
            await client.writer.drain()
            await asyncio.sleep(0.05)
            client.runtime.safety._hard_limit_s = 0.05
            client.runtime.safety._heartbeat_timeout_s = 60.0
            client.runtime.safety._tx_started_at = client.runtime.safety._clock()
            safety_samples = []

            def sample_after_deadline():
                time.sleep(0.3)
                trip = client.runtime.safety.last_trip
                safety_samples.append(
                    {
                        "mock_ptt": client.runtime.mock_rig.ptt,
                        "safety_ptt": client.runtime.safety.ptt_on,
                        "dekey_required": client.runtime.safety.dekey_required,
                        "trip_reason": None if trip is None else trip.reason,
                        "watchdog_done": client.runtime.watchdog_task.done(),
                    }
                )

            observer = threading.Thread(target=sample_after_deadline, daemon=True)
            observer.start()
            client.writer.write(wire[-1:])
            await client.writer.drain()
            await asyncio.to_thread(observer.join, 3.0)

            self.assertEqual(
                [False],
                [sample["safety_ptt"] for sample in safety_samples],
                "large client-frame unmasking monopolized the safety event loop "
                f"past the watchdog trip: {safety_samples!r}",
            )
            self.assertEqual(
                ["hard_limit"],
                [sample["trip_reason"] for sample in safety_samples],
            )
            await wait_for_condition(
                lambda: not client.runtime.mock_rig.ptt,
                "hard-limit trip to finish physical de-key",
                timeout_s=3.0,
            )

    async def test_real_tcp_close_echoes_payload_and_then_reaches_eof(self):
        async with running_websocket_control_plane() as client:
            await client.send_json(
                {"type": "auth", "device_id": "phone", "token": "secret"}
            )
            await client.receive_json()
            payload = struct.pack("!H", 1000) + b"done"

            await client.send_frame(0x8, payload)
            fin, opcode, echoed, masked = await client.receive_frame()

            self.assertEqual((True, 0x8, payload, False), (fin, opcode, echoed, masked))
            self.assertEqual(b"", await asyncio.wait_for(client.reader.read(), 1.0))

    async def test_disconnect_while_simulated_ptt_on_forces_ptt_off(self):
        async with running_websocket_control_plane() as client:
            await client.send_json({"type": "auth", "device_id": "phone", "token": "secret"})
            await client.receive_json()
            await client.send_json({"type": "ptt.lease"})
            lease = await client.receive_json()
            await client.send_json(
                {"type": "ptt.set", "lease_id": lease["lease_id"], "enabled": True}
            )
            self.assertTrue((await client.receive_json())["enabled"])
            self.assertTrue(client.runtime.mock_rig.ptt)

            client.abort()
            await wait_for_condition(
                lambda: not client.runtime.mock_rig.ptt,
                "WebSocket disconnect to de-key simulated PTT",
            )
            self.assertFalse(client.runtime.safety.ptt_on)

    async def test_publish_targets_only_authenticated_clients(self):
        runtime = ControlPlaneRuntime.with_mock()
        server = RemoteRadioServer(runtime.gateway, {"phone": "secret"})
        await runtime.start()
        await server.serve(port=0)
        unauthenticated = await open_websocket_client(server.port)
        authenticated = await open_websocket_client(server.port)
        try:
            await authenticated.send_json(
                {"type": "auth", "device_id": "phone", "token": "secret"}
            )
            await authenticated.receive_json()
            await server.publish({"type": "rig.lifecycle", "lifecycle": "ready", "revision": 1})
            self.assertEqual("rig.lifecycle", (await authenticated.receive_json())["type"])
            with self.assertRaises(TimeoutError):
                await unauthenticated.receive_frame(timeout_s=0.05)
        finally:
            await unauthenticated.close()
            await authenticated.close()
            await server.close()
            await runtime.close()

    async def test_slow_subscriber_is_disconnected_with_bounded_output(self):
        runtime = ControlPlaneRuntime.with_mock()
        server = RemoteRadioServer(runtime.gateway, {"phone": "secret"}, write_timeout_s=0.05)
        await runtime.start()
        await server.serve(port=0)
        client = await open_websocket_client(server.port)
        try:
            await client.send_json({"type": "auth", "device_id": "phone", "token": "secret"})
            await client.receive_json()
            document = {"type": "bulk", "value": "x" * 1_000_000}
            for _ in range(32):
                await server.publish(document)
                if server.authenticated_client_count == 0:
                    break
            await wait_for_condition(
                lambda: server.authenticated_client_count == 0,
                "slow WebSocket subscriber disconnect",
                timeout_s=2.0,
            )
        finally:
            client.abort()
            await server.close()
            await runtime.close()

    async def test_server_close_releases_listener_clients_and_named_tasks(self):
        runtime = ControlPlaneRuntime.with_mock()
        server = RemoteRadioServer(runtime.gateway, {"phone": "secret"})
        await runtime.start()
        await server.serve(port=0)
        port = server.port
        client = await open_websocket_client(port)
        await client.send_json({"type": "auth", "device_id": "phone", "token": "secret"})
        await client.receive_json()

        await server.close()
        await server.close()

        with self.assertRaises(OSError):
            await asyncio.open_connection("127.0.0.1", port)
        self.assertEqual(0, server.authenticated_client_count)
        self.assertFalse(
            [task for task in asyncio.all_tasks() if task.get_name().startswith("websocket-client-")]
        )
        client.abort()
        await runtime.close()

    async def test_disconnect_failure_still_releases_websocket_client_resources(self):
        endpoint = RejectingDisconnectPttOffMockRigctld()
        runtime = ControlPlaneRuntime.with_mock(endpoint)
        server = RemoteRadioServer(runtime.gateway, {"phone": "secret"})
        await runtime.start()
        endpoint.reject_ptt_off = True
        await server.serve(port=0)
        client = await open_websocket_client(server.port)
        try:
            await client.send_json({"type": "auth", "device_id": "phone", "token": "secret"})
            await client.receive_json()
            await client.send_json({"type": "ptt.lease"})
            lease = await client.receive_json()
            await client.send_json(
                {"type": "ptt.set", "lease_id": lease["lease_id"], "enabled": True}
            )
            await client.receive_json()
            client.abort()
            await wait_for_condition(
                lambda: not server._client_tasks,
                "failed disconnect cleanup task to finish",
            )
            await server.close()
            self.assertFalse(server._connections)
        finally:
            endpoint.reject_ptt_off = False
            await server.close()
            await runtime.close()

    async def test_rejects_non_loopback_and_invalid_programmatic_ports_before_listen(self):
        runtime = ControlPlaneRuntime.with_mock()
        server = RemoteRadioServer(runtime.gateway, {"phone": "secret"})
        await runtime.start()
        try:
            for host in ("localhost", "0.0.0.0", "::1"):
                with self.subTest(host=host), self.assertRaises(ValueError):
                    await server.serve(host=host, port=0)
            for port in (-1, 65_536, True, "8765"):
                with self.subTest(port=port), self.assertRaises((TypeError, ValueError)):
                    await server.serve(port=port)
        finally:
            await server.close()
            await runtime.close()

    async def test_malformed_upgrade_requests_are_rejected_with_bounded_safe_http_error(self):
        runtime = ControlPlaneRuntime.with_mock()
        server = RemoteRadioServer(runtime.gateway, {"phone": "secret"})
        await runtime.start()
        await server.serve(port=0)
        requests = (
            b"POST / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n\r\n",
            b"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 12\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n\r\n",
            b"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: bad\r\n\r\n",
            b"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nSec-WebSocket-Key: BBBBBBBBBBBBBBBBBBBBBB==\r\n\r\n",
            b"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nBad@Name: value\r\n\r\n",
            b"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade, bad token\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n\r\n",
            b"G" + b"x" * 16_384,
        )
        try:
            for request in requests:
                with self.subTest(length=len(request)):
                    reader, writer = await asyncio.open_connection("127.0.0.1", server.port)
                    try:
                        writer.write(request)
                        await writer.drain()
                        response = await asyncio.wait_for(reader.read(1024), 2.0)
                        self.assertTrue(response.startswith(b"HTTP/1.1 400 Bad Request") or response == b"")
                        self.assertNotIn(request[:100], response)
                    finally:
                        writer.close()
                        await writer.wait_closed()
        finally:
            await server.close()
            await runtime.close()


if __name__ == "__main__":
    unittest.main()
