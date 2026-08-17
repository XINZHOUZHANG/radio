import asyncio
import unittest
from unittest.mock import patch

from remote_radio_server.rig.errors import (
    RigProtocolError,
    RigReportError,
    RigTransportClosed,
    RigTransportError,
)
from remote_radio_server.rig.models import CommandPriority
from remote_radio_server.rig.transport import RigctldTransport
from tests.fake_rigctld import FakeRigctld


class RigctldTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_cancelling_an_inflight_request_waits_for_the_exchange_to_settle(self):
        """Removing cancellation shielding must let this cancellation escape early."""
        release_response = asyncio.Event()
        async with FakeRigctld(
            {"\\set_ptt 1": [b"set_ptt:|", b"RPRT 0|\n"]},
            fragment_gate=release_response,
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            request = asyncio.create_task(
                transport.request("\\set_ptt 1", CommandPriority.EMERGENCY)
            )
            try:
                await fake.first_fragment_sent.wait()
                request.cancel()
                await asyncio.sleep(0)

                self.assertFalse(
                    request.done(),
                    "caller cancellation escaped before the serialized exchange settled",
                )

                release_response.set()
                with self.assertRaises(asyncio.CancelledError):
                    await request
            finally:
                release_response.set()
                await asyncio.gather(request, return_exceptions=True)
                await transport.close()

    async def test_mismatched_response_verb_is_a_terminal_protocol_fault(self):
        """Removing echoed-verb correlation must make this wrong response succeed."""
        async with FakeRigctld(
            {"\\get_freq": [b"get_mode:|Mode: USB|Passband: 2400|RPRT 0|\n"]}
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            try:
                with self.assertRaisesRegex(RigProtocolError, "does not match"):
                    await transport.request("\\get_freq")
                with self.assertRaises(RigProtocolError):
                    await transport.request("\\get_freq")
            finally:
                await transport.close()

    async def test_trailing_response_data_is_a_terminal_protocol_fault(self):
        """Ignoring bytes after one terminal response must make this request succeed."""
        async with FakeRigctld(
            {
                "\\get_freq": [
                    b"get_freq:|Frequency: 14074000|RPRT 0|\nget_mode:"
                ]
            }
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            try:
                with self.assertRaisesRegex(RigProtocolError, "trailing"):
                    await transport.request("\\get_freq")
                with self.assertRaises(RigProtocolError):
                    await transport.request("\\get_freq")
            finally:
                await transport.close()

    async def test_wait_closed_returns_normally_after_explicit_close(self):
        async with FakeRigctld({}) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            try:
                waiter = asyncio.create_task(transport.wait_closed())

                await transport.close()

                await asyncio.wait_for(waiter, 0.1)
            finally:
                await transport.close()

    async def test_wait_closed_preserves_terminal_error_for_requests_and_all_waiters(self):
        async with FakeRigctld(
            {"\\stalled": [b"stalled:|RPRT 0\n"]}, response_delay_s=0.03
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            try:
                first_waiter = asyncio.create_task(transport.wait_closed())
                second_waiter = asyncio.create_task(transport.wait_closed())

                with self.assertRaisesRegex(RigTransportError, "response timed out"):
                    await transport.request("\\stalled", timeout_s=0.01)
                for waiter in (first_waiter, second_waiter):
                    with self.assertRaisesRegex(RigTransportError, "response timed out"):
                        await waiter
                with self.assertRaisesRegex(RigTransportError, "response timed out"):
                    await transport.request("\\after_abort")
            finally:
                await transport.close()

    async def test_cancelling_wait_closed_does_not_cancel_worker(self):
        async with FakeRigctld({}) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            try:
                worker = transport._worker
                waiter = asyncio.create_task(transport.wait_closed())
                await asyncio.sleep(0)

                waiter.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await waiter

                self.assertIs(worker, transport._worker)
                self.assertFalse(worker.done())
            finally:
                await transport.close()

    async def test_completes_a_fragmented_real_newline_terminated_response(self):
        async with FakeRigctld(
            {"\\get_freq": [b"get_freq:|Frequency: 145000000|RPRT ", b"0\n"]}
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            response = await transport.request("\\get_freq", timeout_s=0.1)

            self.assertEqual("145000000", response.get("Frequency"))
            await transport.close()

    async def test_serializes_requests_and_parses_legacy_pipe_terminated_response(self):
        async with FakeRigctld({"\\get_freq": [b"get_freq:|Frequency: ", b"14074000|RPRT 0|"]}) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            response = await transport.request("\\get_freq")
            self.assertEqual("14074000", response.get("Frequency"))
            self.assertEqual(["|\\get_freq\n"], fake.received)
            await transport.close()

    async def test_processes_response_fragments_delivered_in_separate_turns(self):
        fragment_gate = asyncio.Event()
        async with FakeRigctld(
            {"\\get_freq": [b"get_freq:|Frequency: ", b"14074000|RPRT 0\n"]},
            fragment_gate=fragment_gate,
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            request = asyncio.create_task(transport.request("\\get_freq"))
            await fake.first_fragment_sent.wait()
            await asyncio.sleep(0)
            self.assertFalse(request.done())
            fragment_gate.set()
            response = await request
            self.assertEqual("14074000", response.get("Frequency"))
            await transport.close()

    async def test_concurrent_starts_share_one_connection_attempt(self):
        connect_started = asyncio.Event()
        release_connection = asyncio.Event()
        connection_attempts = 0
        real_open_connection = asyncio.open_connection

        async def gated_open_connection(host: str, port: int):
            nonlocal connection_attempts
            connection_attempts += 1
            connect_started.set()
            await release_connection.wait()
            return await real_open_connection(host, port)

        transport = RigctldTransport()
        with patch(
            "remote_radio_server.rig.transport.asyncio.open_connection",
            new=gated_open_connection,
        ):
            first_start = asyncio.create_task(transport.start())
            await connect_started.wait()
            second_start = asyncio.create_task(transport.start())
            try:
                await asyncio.sleep(0)
                self.assertEqual(1, connection_attempts)
            finally:
                first_start.cancel()
                second_start.cancel()
                await asyncio.gather(first_start, second_start, return_exceptions=True)
                await transport.close()

    async def test_close_waits_for_an_in_progress_start_to_finish_cleanup(self):
        connect_started = asyncio.Event()
        release_connection = asyncio.Event()
        real_open_connection = asyncio.open_connection

        async def gated_open_connection(host: str, port: int):
            connect_started.set()
            await release_connection.wait()
            return await real_open_connection(host, port)

        async with FakeRigctld({}) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            with patch(
                "remote_radio_server.rig.transport.asyncio.open_connection",
                new=gated_open_connection,
            ):
                start_task = asyncio.create_task(transport.start())
                await connect_started.wait()
                close_task = asyncio.create_task(transport.close())
                try:
                    await asyncio.sleep(0)
                    self.assertFalse(close_task.done())
                    release_connection.set()
                    await start_task
                    await close_task
                    with self.assertRaises(RigTransportClosed):
                        await transport.request("\\get_freq")
                    self.assertIsNone(transport._worker)
                    self.assertIsNone(transport._writer)
                finally:
                    release_connection.set()
                    await asyncio.gather(start_task, close_task, return_exceptions=True)
                    await self._force_transport_cleanup(transport)

    async def test_does_not_write_second_request_until_first_response_completes(self):
        async with FakeRigctld(
            {
                "\\first": [b"first:|Value: 1|RPRT 0\n"],
                "\\second": [b"second:|Value: 2|RPRT 0\n"],
            },
            response_delay_s=0.05,
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            first = asyncio.create_task(transport.request("\\first"))
            await self._wait_for_received(fake, 1)
            second = asyncio.create_task(transport.request("\\second"))
            await asyncio.sleep(0.01)
            self.assertEqual(["|\\first\n"], fake.received)
            self.assertEqual("1", (await first).get("Value"))
            self.assertEqual("2", (await second).get("Value"))
            await transport.close()

    async def test_prioritizes_emergency_request_ahead_of_queued_polling(self):
        async with FakeRigctld(
            {
                "\\slow": [b"slow:|RPRT 0\n"],
                "\\poll": [b"poll:|RPRT 0\n"],
                "\\emergency": [b"emergency:|RPRT 0\n"],
            },
            response_delay_s=0.03,
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            slow = asyncio.create_task(transport.request("\\slow"))
            await self._wait_for_received(fake, 1)
            poll = asyncio.create_task(
                transport.request("\\poll", CommandPriority.POLLING)
            )
            emergency = asyncio.create_task(
                transport.request("\\emergency", CommandPriority.EMERGENCY)
            )
            await asyncio.gather(slow, poll, emergency)
            self.assertEqual(
                ["|\\slow\n", "|\\emergency\n", "|\\poll\n"], fake.received
            )
            await transport.close()

    async def test_preserves_fifo_order_for_equal_priorities(self):
        async with FakeRigctld(
            {
                "\\slow": [b"slow:|RPRT 0\n"],
                "\\first": [b"first:|RPRT 0\n"],
                "\\second": [b"second:|RPRT 0\n"],
            },
            response_delay_s=0.03,
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            slow = asyncio.create_task(transport.request("\\slow"))
            await self._wait_for_received(fake, 1)
            first = asyncio.create_task(transport.request("\\first"))
            second = asyncio.create_task(transport.request("\\second"))
            await asyncio.gather(slow, first, second)
            self.assertEqual(
                ["|\\slow\n", "|\\first\n", "|\\second\n"], fake.received
            )
            await transport.close()

    async def test_maps_nonzero_terminal_report_to_typed_error(self):
        async with FakeRigctld({"\\get_level": [b"get_level:|RPRT -4\n"]}) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            with self.assertRaises(RigReportError) as raised:
                await transport.request("\\get_level")
            self.assertEqual(-4, raised.exception.code)
            await transport.close()

    async def test_maps_response_timeout_to_transport_error(self):
        async with FakeRigctld(
            {
                "\\stalled": [b"stalled:|RPRT 0\n"],
                "\\queued": [b"queued:|RPRT 0\n"],
            },
            response_delay_s=0.03,
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            stalled = asyncio.create_task(
                transport.request("\\stalled", timeout_s=0.01)
            )
            await self._wait_for_received(fake, 1)
            queued = asyncio.create_task(transport.request("\\queued"))
            with self.assertRaisesRegex(RigTransportError, "response timed out"):
                await stalled
            with self.assertRaises(RigTransportError):
                await queued
            self.assertEqual(["|\\stalled\n"], fake.received)
            await transport.close()

    async def test_close_fails_inflight_and_queued_requests(self):
        async with FakeRigctld(
            {"\\slow": [b"slow:|RPRT 0\n"], "\\queued": [b"queued:|RPRT 0\n"]},
            response_delay_s=5,
        ) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            inflight = asyncio.create_task(transport.request("\\slow"))
            await self._wait_for_received(fake, 1)
            queued = asyncio.create_task(transport.request("\\queued"))
            await asyncio.sleep(0)
            await transport.close()
            with self.assertRaises(RigTransportClosed):
                await inflight
            with self.assertRaises(RigTransportClosed):
                await queued

    async def _wait_for_received(self, fake: FakeRigctld, count: int) -> None:
        for _ in range(100):
            if len(fake.received) >= count:
                return
            await asyncio.sleep(0.001)
        self.fail(f"fake server did not receive {count} command(s)")

    async def _force_transport_cleanup(self, transport: RigctldTransport) -> None:
        worker = transport._worker
        if worker is not None and not worker.done():
            worker.cancel()
            await asyncio.gather(worker, return_exceptions=True)
        writer = transport._writer
        if writer is not None:
            writer.close()
            await asyncio.gather(writer.wait_closed(), return_exceptions=True)
