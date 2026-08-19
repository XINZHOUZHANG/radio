import asyncio
import unittest
from pathlib import Path
from unittest.mock import patch

from remote_radio_server.public_dummy import PublicDummyConfig, PublicDummyStack
from tests.integration.helpers import open_websocket_client
from tests.integration.test_hamlib_dummy import (
    _ephemeral_port,
    _rigctld_executable,
)


def three_distinct_ports():
    ports = set()
    while len(ports) < 3:
        ports.add(_ephemeral_port())
    return tuple(ports)


async def fetch_dashboard(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        writer.write(
            b"GET / HTTP/1.1\r\n"
            b"Host: test\r\n"
            b"Connection: close\r\n\r\n"
        )
        await writer.drain()
        return await asyncio.wait_for(reader.read(), 2.0)
    finally:
        writer.close()
        await writer.wait_closed()


async def read_extended_frequency(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        writer.write(b"|\\get_freq\n")
        await writer.drain()
        response = bytearray()
        while b"RPRT 0" not in response:
            chunk = await asyncio.wait_for(reader.read(4096), 2.0)
            if not chunk:
                break
            response.extend(chunk)
        return bytes(response)
    finally:
        writer.close()
        await writer.wait_closed()


@unittest.skipUnless(
    _rigctld_executable(),
    "official rigctld is not explicitly available on PATH or REMOTE_RADIO_RIGCTLD",
)
class PublicDummyWebIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_official_dummy_round_trip_and_owned_shutdown(self):
        executable = _rigctld_executable()
        http_port, websocket_port, rigctld_port = three_distinct_ports()
        web_root = Path(__file__).resolve().parents[3] / "web"
        stack = PublicDummyStack(
            PublicDummyConfig(
                web_root=web_root,
                http_port=http_port,
                websocket_port=websocket_port,
                rigctld_port=rigctld_port,
            )
        )
        client = None
        startup = None
        original_create_subprocess_exec = asyncio.create_subprocess_exec

        async def launch_configured_executable(program, *arguments, **kwargs):
            self.assertEqual("rigctld", program)
            return await original_create_subprocess_exec(
                executable, *arguments, **kwargs
            )

        try:
            with patch(
                "remote_radio_server.rig.launcher.asyncio.create_subprocess_exec",
                new=launch_configured_executable,
            ):
                startup = await stack.start()

            bad_client = await open_websocket_client(startup.websocket_port)
            try:
                await bad_client.send_json(
                    {
                        "type": "auth",
                        "device_id": startup.device_id,
                        "token": "incorrect-token",
                    }
                )
                self.assertEqual(1008, await bad_client.receive_close_code())
            finally:
                await bad_client.close()

            client = await open_websocket_client(startup.websocket_port)
            await client.send_json(
                {
                    "type": "auth",
                    "device_id": startup.device_id,
                    "token": startup.token,
                }
            )
            self.assertEqual("auth.ok", (await client.receive_json())["type"])

            await client.send_json({"type": "rig.capabilities"})
            capabilities = await client.receive_json()
            self.assertEqual(1, capabilities["identity"]["model_id"])
            self.assertTrue(capabilities["modes"])

            await client.send_json(
                {
                    "type": "rig.command",
                    "request_id": "freq-1",
                    "command": "set_frequency",
                    "frequency_hz": 7_074_000,
                }
            )
            frequency_result = await client.receive_json()
            self.assertEqual("confirmed", frequency_result["status"])
            await client.send_json({"type": "rig.snapshot"})
            self.assertEqual(7_074_000, (await client.receive_json())["frequency_hz"])

            mode = capabilities["modes"][0]
            await client.send_json(
                {
                    "type": "rig.command",
                    "request_id": "mode-1",
                    "command": "set_mode",
                    "mode": mode,
                }
            )
            mode_result = await client.receive_json()
            self.assertEqual("confirmed", mode_result["status"])
            await client.send_json({"type": "rig.snapshot"})
            self.assertEqual(mode, (await client.receive_json())["mode"])

            await client.send_json({"type": "ptt.lease"})
            lease = await client.receive_json()
            ptt_request = {
                "type": "ptt.set",
                "lease_id": lease["lease_id"],
                "enabled": True,
            }
            ptt_deadline = asyncio.get_running_loop().time() + 5.0
            while True:
                await client.send_json(ptt_request)
                ptt_result = await client.receive_json()
                self.assertEqual("error", ptt_result["type"])
                if ptt_result["code"] != "locked_out":
                    break
                if asyncio.get_running_loop().time() >= ptt_deadline:
                    self.fail(
                        "timed out waiting for the startup PTT lockout to clear"
                    )
                await asyncio.sleep(0.05)
            self.assertEqual("hardware_tx_disabled", ptt_result["code"])
            await client.send_json({"type": "rig.snapshot"})
            self.assertFalse((await client.receive_json())["ptt"])

            rig_response = await read_extended_frequency(startup.rigctld_port)
            self.assertIn(b"get_freq:", rig_response)
            self.assertIn(b"7074000", rig_response)
            self.assertIn(b"RPRT 0", rig_response)

            dashboard = await fetch_dashboard(startup.http_port)
            self.assertTrue(dashboard.startswith(b"HTTP/1.1 200 OK"))
            self.assertIn(b'data-dashboard="remote-radio-v3"', dashboard)
        finally:
            if client is not None:
                await client.close()
            await stack.close()

        for port in (
            startup.http_port,
            startup.websocket_port,
            startup.rigctld_port,
        ):
            with self.subTest(port=port), self.assertRaises(OSError):
                await asyncio.open_connection("127.0.0.1", port)


if __name__ == "__main__":
    unittest.main()
