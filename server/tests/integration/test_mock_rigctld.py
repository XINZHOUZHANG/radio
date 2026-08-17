import asyncio
import unittest

from remote_radio_server.mock_rigctld import MockRigctld
from remote_radio_server.rig.capabilities import CapabilityService
from remote_radio_server.rig.models import CommandPriority
from remote_radio_server.rig.protocol import ExtendedResponseParser
from remote_radio_server.rig.transport import RigctldTransport


class MockRigctldEndpointTests(unittest.IsolatedAsyncioTestCase):
    async def test_malformed_or_unsupported_command_returns_parseable_negative_report(self):
        async with MockRigctld() as mock:
            reader, writer = await asyncio.open_connection(mock.host, mock.port)
            writer.write(b"|\\bad!\n")
            await writer.drain()

            responses = ExtendedResponseParser().feed(await reader.readline())

            self.assertEqual(1, len(responses))
            self.assertLess(responses[0].report, 0)
            writer.close()

    async def test_discovery_and_state_persist_across_sequential_clients(self):
        mock = MockRigctld()
        await mock.start()
        self.addAsyncCleanup(mock.close)

        first = RigctldTransport(mock.host, mock.port)
        await first.start()
        caps = await CapabilityService(first).discover()
        self.assertEqual("Mock", caps.identity.manufacturer)
        self.assertIn(14_074_000, range(caps.tx_ranges_hz[0][0], caps.tx_ranges_hz[0][1] + 1))
        self.assertEqual(frozenset({"AF", "SWR", "ALC"}), caps.readable_levels)
        await first.request("\\set_freq 14076000", CommandPriority.USER_WRITE)
        await first.close()

        second = RigctldTransport(mock.host, mock.port)
        await second.start()
        response = await second.request("\\get_freq")
        self.assertEqual("14076000", response.get("Frequency"))
        await second.close()

        self.assertIn("\\hamlib_version", mock.commands)
        self.assertEqual("\\get_freq", mock.commands[-1])

    async def test_ptt_and_supported_controls_round_trip(self):
        async with MockRigctld() as mock:
            transport = RigctldTransport(mock.host, mock.port)
            await transport.start()
            commands = (
                "\\set_mode USB 2400",
                "\\set_level AF 0.5",
                "\\set_func NB 1",
                "\\set_split_vfo 1 VFOB",
                "\\set_split_freq 14074000",
                "\\set_split_mode USB 2400",
                "\\set_ptt 1",
            )
            for command in commands:
                await asyncio.wait_for(transport.request(command), 1.0)

            async def request(command):
                return await asyncio.wait_for(transport.request(command), 1.0)

            self.assertEqual("USB", (await request("\\get_mode")).get("Mode"))
            self.assertEqual(("0.5",), (await request("\\get_level AF")).values)
            self.assertEqual(("1",), (await request("\\get_func NB")).values)
            self.assertEqual("1", (await request("\\get_split_vfo")).get("Split"))
            self.assertEqual("1", (await request("\\get_ptt")).get("PTT"))
            self.assertTrue(mock.ptt)
            await transport.close()

    async def test_close_aborts_an_active_client_and_listener(self):
        mock = MockRigctld()
        await mock.start()
        reader, writer = await asyncio.open_connection(mock.host, mock.port)

        await mock.close()

        self.assertEqual(b"", await asyncio.wait_for(reader.read(1), 1.0))
        with self.assertRaises(OSError):
            await asyncio.open_connection(mock.host, mock.port)
        writer.close()


if __name__ == "__main__":
    unittest.main()
