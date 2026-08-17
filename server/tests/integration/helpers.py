import asyncio
import base64
import hashlib
import json
import os
import struct
from contextlib import asynccontextmanager

from remote_radio_server.runtime import ControlPlaneRuntime
from remote_radio_server.server import RemoteRadioServer


@asynccontextmanager
async def running_mock_control_plane():
    runtime = ControlPlaneRuntime.with_mock()
    await runtime.start()
    try:
        yield runtime
    finally:
        await runtime.close()


class WebSocketTestClient:
    def __init__(self, reader, writer, *, runtime=None, websocket_server=None):
        self.reader = reader
        self.writer = writer
        self.runtime = runtime
        self.websocket_server = websocket_server

    async def send_json(self, document):
        await self.send_frame(0x1, json.dumps(document, separators=(",", ":")).encode())

    async def send_frame(self, opcode, payload=b"", *, fin=True, masked=True):
        first = (0x80 if fin else 0) | opcode
        length = len(payload)
        mask_bit = 0x80 if masked else 0
        if length <= 125:
            header = bytes((first, mask_bit | length))
        elif length <= 0xFFFF:
            header = bytes((first, mask_bit | 126)) + struct.pack("!H", length)
        else:
            header = bytes((first, mask_bit | 127)) + struct.pack("!Q", length)
        if masked:
            key = b"\x01\x02\x03\x04"
            payload = bytes(value ^ key[index % 4] for index, value in enumerate(payload))
            header += key
        self.writer.write(header + payload)
        await self.writer.drain()

    async def receive_frame(self, *, timeout_s=2.0):
        async def read_frame():
            head = await self.reader.readexactly(2)
            fin = bool(head[0] & 0x80)
            opcode = head[0] & 0x0F
            masked = bool(head[1] & 0x80)
            length = head[1] & 0x7F
            if length == 126:
                length = struct.unpack("!H", await self.reader.readexactly(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", await self.reader.readexactly(8))[0]
            mask = await self.reader.readexactly(4) if masked else b""
            payload = await self.reader.readexactly(length)
            if masked:
                payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
            return fin, opcode, payload, masked

        return await asyncio.wait_for(read_frame(), timeout_s)

    async def receive_json(self, *, timeout_s=2.0):
        fin, opcode, payload, masked = await self.receive_frame(timeout_s=timeout_s)
        if not fin or opcode != 0x1 or masked:
            raise AssertionError(
                f"expected final unmasked text frame, got fin={fin}, opcode={opcode}, masked={masked}"
            )
        return json.loads(payload.decode("utf-8", "strict"))

    async def receive_close_code(self, *, timeout_s=2.0):
        _fin, opcode, payload, masked = await self.receive_frame(timeout_s=timeout_s)
        if opcode != 0x8 or masked:
            raise AssertionError(f"expected unmasked close frame, got opcode={opcode}")
        return None if not payload else struct.unpack("!H", payload[:2])[0]

    async def close(self):
        if not self.writer.is_closing():
            try:
                await self.send_frame(0x8, struct.pack("!H", 1000))
                await self.receive_frame()
            except (OSError, asyncio.IncompleteReadError, TimeoutError):
                pass
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except OSError:
            pass

    def abort(self):
        self.writer.transport.abort()


async def open_websocket_client(port, *, request_headers=()):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    headers = [
        "GET /radio HTTP/1.1",
        f"Host: 127.0.0.1:{port}",
        "Upgrade: websocket",
        "Connection: keep-alive, Upgrade",
        f"Sec-WebSocket-Key: {key}",
        "Sec-WebSocket-Version: 13",
        *request_headers,
        "",
        "",
    ]
    writer.write("\r\n".join(headers).encode("ascii"))
    await writer.drain()
    response = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 2.0)
    expected_accept = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
    )
    if not response.startswith(b"HTTP/1.1 101 Switching Protocols\r\n"):
        writer.close()
        await writer.wait_closed()
        raise AssertionError(response.decode("ascii", "replace"))
    if b"Sec-WebSocket-Accept: " + expected_accept not in response:
        raise AssertionError("server returned an invalid Sec-WebSocket-Accept")
    return WebSocketTestClient(reader, writer)


@asynccontextmanager
async def running_websocket_control_plane(token="secret"):
    runtime = ControlPlaneRuntime.with_mock()
    websocket_server = RemoteRadioServer(runtime.gateway, {"phone": token})
    client = None
    await runtime.start()
    try:
        await websocket_server.serve(host="127.0.0.1", port=0)
        client = await open_websocket_client(websocket_server.port)
        client.runtime = runtime
        client.websocket_server = websocket_server
        yield client
    finally:
        try:
            if client is not None:
                await client.close()
        finally:
            try:
                await websocket_server.close()
            finally:
                await runtime.close()


async def wait_for_condition(condition, description, *, timeout_s=5.0):
    deadline = asyncio.get_running_loop().time() + timeout_s
    while True:
        result = condition()
        if result:
            return result
        if asyncio.get_running_loop().time() >= deadline:
            raise AssertionError(f"timed out waiting for {description}")
        await asyncio.sleep(0.01)
