import asyncio
import base64
import contextlib
import io
import struct
import unittest
from unittest.mock import patch

from remote_radio_server.__main__ import _validated_args
from remote_radio_server.server import RemoteRadioServer, _Connection
from remote_radio_server.websocket import (
    WebSocketProtocolError,
    WebSocketFrameReader,
    encode_text_frame,
)


def masked_client_frame(payload, *, opcode=0x1, fin=True, length_form=None):
    first = (0x80 if fin else 0) | opcode
    length = len(payload)
    if length_form == 126 or (length_form is None and length > 125 and length <= 0xFFFF):
        header = bytes((first, 0x80 | 126)) + struct.pack("!H", length)
    elif length_form == 127 or (length_form is None and length > 0xFFFF):
        header = bytes((first, 0x80 | 127)) + struct.pack("!Q", length)
    else:
        header = bytes((first, 0x80 | length))
    key = b"\x11\x22\x33\x44"
    masked = bytearray(length)
    for phase, mask_byte in enumerate(key):
        xor_table = bytes(value ^ mask_byte for value in range(256))
        masked[phase::4] = payload[phase::4].translate(xor_table)
    return header + key + bytes(masked)


class WebSocketFrameTests(unittest.TestCase):
    def test_decodes_fragmented_masked_text_frame(self):
        reader = WebSocketFrameReader(max_payload_bytes=1_048_576)
        wire = masked_client_frame(b'{"type":"rig.snapshot"}')

        self.assertEqual((), reader.feed(wire[:5]))
        frames = reader.feed(wire[5:])

        self.assertEqual('{"type":"rig.snapshot"}', frames[0].text)

    def test_returns_multiple_frames_from_one_tcp_chunk(self):
        reader = WebSocketFrameReader(max_payload_bytes=1_048_576)
        wire = masked_client_frame(b"one") + masked_client_frame(b"two")

        frames = reader.feed(wire)

        self.assertEqual(["one", "two"], [frame.text for frame in frames])

    def test_encodes_unmasked_text_at_all_length_boundaries(self):
        cases = (
            ("a" * 125, b"\x81\x7d"),
            ("a" * 126, b"\x81\x7e\x00\x7e"),
            ("a" * 65_536, b"\x81\x7f\x00\x00\x00\x00\x00\x01\x00\x00"),
        )
        for text, prefix in cases:
            with self.subTest(length=len(text)):
                wire = encode_text_frame(text)
                self.assertTrue(wire.startswith(prefix))
                self.assertEqual(text.encode(), wire[len(prefix) :])

    def test_rejects_protocol_and_size_violations_with_bound_close_codes(self):
        cases = (
            (b"\x81\x01x", 1002, "unmasked"),
            (bytes((0xC1, 0x80)) + b"\0\0\0\0", 1002, "RSV"),
            (masked_client_frame(b"x", opcode=0x0), 1002, "continuation"),
            (masked_client_frame(b"x", fin=False), 1002, "final"),
            (masked_client_frame(b"x", opcode=0x3), 1002, "opcode"),
            (masked_client_frame(b"x", length_form=126), 1002, "canonical"),
            (masked_client_frame(b"x" * 126, length_form=127), 1002, "canonical"),
            (bytes((0x81, 0xFF)) + struct.pack("!Q", 1 << 63), 1002, "length"),
            (bytes((0x81, 0xFF)) + struct.pack("!Q", 1_048_577), 1009, "large"),
            (masked_client_frame(b"x" * 126, opcode=0x9), 1002, "control"),
            (masked_client_frame(b"x", opcode=0x9, fin=False), 1002, "final"),
        )
        for wire, close_code, label in cases:
            with self.subTest(label=label):
                reader = WebSocketFrameReader(max_payload_bytes=1_048_576)
                with self.assertRaises(WebSocketProtocolError) as caught:
                    reader.feed(wire)
                self.assertEqual(close_code, caught.exception.close_code)

    def test_rejects_invalid_text_and_close_payloads(self):
        cases = (
            (masked_client_frame(b"\xff"), 1007),
            (masked_client_frame(b"x", opcode=0x8), 1002),
            (masked_client_frame(struct.pack("!H", 1000) + b"\xff", opcode=0x8), 1007),
            (masked_client_frame(struct.pack("!H", 1005), opcode=0x8), 1002),
        )
        for wire, close_code in cases:
            with self.subTest(close_code=close_code, wire=base64.b64encode(wire)):
                reader = WebSocketFrameReader(max_payload_bytes=1_048_576)
                with self.assertRaises(WebSocketProtocolError) as caught:
                    reader.feed(wire)
                self.assertEqual(close_code, caught.exception.close_code)

    def test_binary_frame_is_reserved_for_application_policy(self):
        frame = WebSocketFrameReader(max_payload_bytes=16).feed(
            masked_client_frame(b"binary", opcode=0x2)
        )[0]
        self.assertEqual(0x2, frame.opcode)
        self.assertIsNone(frame.text)
        self.assertEqual(b"binary", frame.payload)


class RemoteRadioServerValidationTests(unittest.TestCase):
    def test_requires_safe_copied_device_tokens(self):
        tokens = {"phone": "secret"}
        server = RemoteRadioServer(object(), tokens)
        tokens["phone"] = "changed"
        principal = server._authorizer.authenticate(
            {"type": "auth", "device_id": "phone", "token": "secret"}
        )
        self.assertEqual("phone", principal.device_id)
        with self.assertRaises(AttributeError):
            _ = server.device_tokens

        for invalid in ({}, {"": "secret"}, {"phone": ""}, {1: "secret"}):
            with self.subTest(invalid=invalid):
                with self.assertRaises((TypeError, ValueError)):
                    RemoteRadioServer(object(), invalid)

    def test_write_timeout_requires_finite_positive_seconds(self):
        for invalid in (float("nan"), float("inf")):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    RemoteRadioServer(
                        object(), {"phone": "secret"}, write_timeout_s=invalid
                    )

    def test_cli_serve_validation_is_strict(self):
        args = _validated_args(
            ["--mock", "--serve", "--device-token", "phone=secret", "--port", "8765"]
        )
        self.assertTrue(args.serve)
        self.assertEqual({"phone": "secret"}, args.device_tokens)

        invalid_argv = (
            ["--mock", "--serve"],
            ["--mock", "--serve", "--once", "--device-token", "phone=secret"],
            ["--mock", "--serve", "--host", "0.0.0.0", "--device-token", "phone=secret"],
            ["--mock", "--serve", "--port", "0", "--device-token", "phone=secret"],
            ["--mock", "--serve", "--device-token", "invalid"],
            ["--mock", "--serve", "--device-token", "phone="],
            ["--mock", "--serve", "--device-token", "phone=a", "--device-token", "phone=b"],
        )
        for argv in invalid_argv:
            with self.subTest(argv=argv):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        _validated_args(argv)


class RemoteRadioServerListenerPolicyTests(unittest.IsolatedAsyncioTestCase):
    async def test_public_ipv4_bind_requires_explicit_exact_boolean_policy(self):
        for policy in (False, 1, "yes"):
            server = RemoteRadioServer(object(), {"phone": "secret"})
            with self.subTest(policy=policy), self.assertRaises((TypeError, ValueError)):
                await server.serve(
                    host="0.0.0.0",
                    port=0,
                    allow_non_loopback=policy,
                )

        server = RemoteRadioServer(object(), {"phone": "secret"})
        try:
            await server.serve(
                host="0.0.0.0",
                port=0,
                allow_non_loopback=True,
            )
            self.assertGreater(server.port, 0)
        finally:
            await server.close()

    async def test_public_policy_does_not_admit_arbitrary_hosts(self):
        for host in ("::", "localhost", "127.0.0.2"):
            server = RemoteRadioServer(object(), {"phone": "secret"})
            with self.subTest(host=host), self.assertRaises(ValueError):
                await server.serve(
                    host=host,
                    port=0,
                    allow_non_loopback=True,
                )


class RemoteRadioServerConcurrencyTests(unittest.IsolatedAsyncioTestCase):
    async def test_large_buffered_frame_yields_to_ready_safety_work(self):
        """Removing the receive checkpoint must starve already-ready safety work."""

        payload = (
            b'{"type":"rig.snapshot","padding":"'
            + b"x" * 128_000
            + b'"}'
        )
        wire = await asyncio.to_thread(masked_client_frame, payload)
        await asyncio.sleep(0)

        class ImmediateReader:
            async def read(self, _limit):
                return wire

        connection = _Connection(
            ImmediateReader(), None, write_timeout_s=1.0
        )
        server = RemoteRadioServer(object(), {"phone": "secret"})
        safety_ran = asyncio.Event()
        await asyncio.sleep(0)
        asyncio.get_running_loop().call_soon(safety_ran.set)

        text = await server._receive_text(connection)

        self.assertEqual(len(payload), len(text.encode("utf-8")))
        self.assertTrue(
            safety_ran.is_set(),
            "buffered frame processing returned before ready safety work ran",
        )

    async def test_serve_close_race_cannot_publish_a_listener_after_close(self):
        """Using separate lifecycle checks must leak the delayed listener."""

        class FakeSocket:
            def getsockname(self):
                return ("127.0.0.1", 43123)

        class FakeServer:
            def __init__(self):
                self.sockets = (FakeSocket(),)
                self.closed = False

            def close(self):
                self.closed = True

            async def wait_closed(self):
                return None

        entered = asyncio.Event()
        release = asyncio.Event()
        listener = FakeServer()

        async def delayed_start_server(*_args, **_kwargs):
            entered.set()
            await release.wait()
            return listener

        server = RemoteRadioServer(object(), {"phone": "secret"})
        with patch(
            "remote_radio_server.server.asyncio.start_server",
            side_effect=delayed_start_server,
        ):
            serving = asyncio.create_task(server.serve(port=0))
            await entered.wait()
            closing = asyncio.create_task(server.close())
            await asyncio.sleep(0)
            release.set()
            await asyncio.gather(serving, closing)

        self.assertTrue(listener.closed)
        with self.assertRaises(RuntimeError):
            _ = server.port

    async def test_pending_publish_capacity_is_acquired_before_serialization(self):
        """Serializing before capacity acquisition must process every event eagerly."""

        class FakeTransport:
            def __init__(self):
                self.aborted = False

            def abort(self):
                self.aborted = True

        class BlockingWriter:
            def __init__(self):
                self.transport = FakeTransport()
                self.drain_started = asyncio.Event()
                self.release = asyncio.Event()

            def is_closing(self):
                return False

            def write(self, _wire):
                return None

            async def drain(self):
                self.drain_started.set()
                await self.release.wait()

        writer = BlockingWriter()
        connection = _Connection(None, writer, write_timeout_s=1.0)
        serialized = []

        def serialize(event):
            serialized.append(event["sequence"])
            return "{}"

        with patch("remote_radio_server.server.serialize_json_event", side_effect=serialize):
            sends = [
                asyncio.create_task(connection.send_json({"sequence": sequence}))
                for sequence in range(8)
            ]
            try:
                await writer.drain_started.wait()
                for _ in range(3):
                    await asyncio.sleep(0)
                self.assertLessEqual(
                    len(serialized),
                    2,
                    "more than bounded capacity was serialized for a slow publisher",
                )
            finally:
                writer.release.set()
                await asyncio.gather(*sends, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
