"""Authenticated loopback WebSocket adapter for the rig message gateway."""

from __future__ import annotations

import asyncio
import hmac
import json
import struct
from collections import deque
from collections.abc import Mapping
from math import isfinite

from .gateway import GatewayError, Principal, serialize_json_event
from .websocket import (
    WebSocketFrame,
    WebSocketFrameReader,
    WebSocketHandshakeError,
    WebSocketProtocolError,
    encode_frame,
    encode_text_frame,
    perform_server_handshake,
)


_MAX_PAYLOAD_BYTES = 1_048_576
_AUTH_TIMEOUT_S = 5.0
_JSON_OFFLOAD_CHARS = 64 * 1024


class _PeerClosed(Exception):
    pass


class _Connection:
    def __init__(self, reader, writer, *, write_timeout_s: float) -> None:
        self.reader = reader
        self.writer = writer
        self.frame_reader = WebSocketFrameReader(max_payload_bytes=_MAX_PAYLOAD_BYTES)
        self.pending_frames: deque[WebSocketFrame] = deque()
        self.write_timeout_s = write_timeout_s
        self.write_lock = asyncio.Lock()
        self.publish_capacity = asyncio.Semaphore(2)
        self.close_sent = False
        self.principal: Principal | None = None

    async def send_json(self, event: Mapping[str, object]) -> None:
        try:
            await asyncio.wait_for(
                self.publish_capacity.acquire(), self.write_timeout_s
            )
        except TimeoutError:
            self.abort()
            raise
        try:
            await asyncio.sleep(0)
            wire = await asyncio.to_thread(_encode_json_event, event)
            await self.send_wire(wire)
        finally:
            self.publish_capacity.release()

    async def send_control(self, opcode: int, payload: bytes = b"") -> None:
        await self.send_wire(encode_frame(opcode, payload))

    async def send_close(
        self, code: int | None = None, *, payload: bytes | None = None
    ) -> None:
        if self.close_sent:
            return
        self.close_sent = True
        if payload is None:
            payload = b"" if code is None else struct.pack("!H", code)
        try:
            await self.send_control(0x8, payload)
        except (OSError, TimeoutError, ConnectionError):
            self.abort()

    async def send_wire(self, wire: bytes) -> None:
        try:
            await asyncio.wait_for(self.write_lock.acquire(), self.write_timeout_s)
        except TimeoutError:
            self.abort()
            raise
        try:
            if self.writer.is_closing():
                raise ConnectionError("WebSocket transport is closing")
            self.writer.write(wire)
            try:
                await asyncio.wait_for(self.writer.drain(), self.write_timeout_s)
            except TimeoutError:
                self.abort()
                raise
        finally:
            self.write_lock.release()

    def abort(self) -> None:
        transport = self.writer.transport
        if transport is not None:
            transport.abort()


class _DeviceAuthorizer:
    def __init__(self, device_tokens: Mapping[str, str]) -> None:
        if not isinstance(device_tokens, Mapping):
            raise TypeError("device_tokens must be a mapping")
        copied: dict[str, str] = {}
        if not device_tokens:
            raise ValueError("device_tokens must not be empty")
        for device_id, token in device_tokens.items():
            if not isinstance(device_id, str) or not device_id.strip():
                raise ValueError("device IDs must be non-empty text")
            if not isinstance(token, str) or not token.strip():
                raise ValueError("device tokens must be non-empty text")
            copied[device_id] = token
        self._device_tokens = copied

    def authenticate(self, message: object) -> Principal:
        if not isinstance(message, dict) or set(message) != {
            "type",
            "device_id",
            "token",
        }:
            raise GatewayError("authentication_failed", "authentication failed")
        device_id = message.get("device_id")
        token = message.get("token")
        if (
            message.get("type") != "auth"
            or not isinstance(device_id, str)
            or not device_id.strip()
        ):
            raise GatewayError("authentication_failed", "authentication failed")
        if not isinstance(token, str):
            raise GatewayError("authentication_failed", "authentication failed")
        expected = self._device_tokens.get(device_id)
        candidate_bytes = token.encode("utf-8", "surrogatepass")
        expected_bytes = (
            expected.encode("utf-8", "surrogatepass")
            if expected is not None
            else b"\0" * len(candidate_bytes)
        )
        matched = hmac.compare_digest(candidate_bytes, expected_bytes)
        if expected is None or not matched:
            raise GatewayError("authentication_failed", "authentication failed")
        return Principal(device_id=device_id, is_admin=False)


class RemoteRadioServer:
    def __init__(
        self,
        gateway,
        device_tokens: Mapping[str, str],
        *,
        write_timeout_s: float = 1.0,
    ) -> None:
        if not isinstance(write_timeout_s, (int, float)) or isinstance(
            write_timeout_s, bool
        ):
            raise TypeError("write_timeout_s must be numeric")
        if not isfinite(write_timeout_s) or write_timeout_s <= 0:
            raise ValueError("write_timeout_s must be finite and positive")
        self._gateway = gateway
        self._authorizer = _DeviceAuthorizer(device_tokens)
        self._write_timeout_s = float(write_timeout_s)
        self._server: asyncio.Server | None = None
        self._connections: set[_Connection] = set()
        self._client_tasks: set[asyncio.Task[None]] = set()
        self._closed = False
        self._close_complete = False
        self._lifecycle_lock = asyncio.Lock()
        self._client_sequence = 0
        self._port: int | None = None

    @property
    def port(self) -> int:
        if self._port is None:
            raise RuntimeError("WebSocket server is not listening")
        return self._port

    @property
    def authenticated_client_count(self) -> int:
        return sum(connection.principal is not None for connection in self._connections)

    async def serve(self, *, host: str = "127.0.0.1", port: int = 8765) -> None:
        if host != "127.0.0.1":
            raise ValueError("WebSocket host must be exactly 127.0.0.1")
        if type(port) is not int:
            raise TypeError("WebSocket port must be an integer")
        if not 0 <= port <= 65535:
            raise ValueError("WebSocket port must be in the range 0..65535")
        async with self._lifecycle_lock:
            if self._closed:
                raise RuntimeError("WebSocket server is closed")
            if self._server is not None:
                return
            server = await asyncio.start_server(
                self._accept_client,
                host,
                port,
                limit=8 * 1024 + 4,
            )
            sockets = server.sockets or ()
            if not sockets:
                server.close()
                await server.wait_closed()
                raise RuntimeError("WebSocket listener has no socket")
            self._server = server
            self._port = sockets[0].getsockname()[1]

    async def publish(self, event: Mapping[str, object]) -> None:
        if not isinstance(event, Mapping):
            raise TypeError("published event must be a mapping")
        clients = tuple(
            connection
            for connection in self._connections
            if connection.principal is not None
        )
        if not clients:
            return

        async def send(connection: _Connection) -> None:
            try:
                await connection.send_json(event)
            except asyncio.CancelledError:
                raise
            except (
                OSError,
                ConnectionError,
                TimeoutError,
                WebSocketProtocolError,
                ValueError,
            ):
                connection.abort()

        await asyncio.gather(*(send(connection) for connection in clients))

    async def close(self) -> None:
        async with self._lifecycle_lock:
            if self._close_complete:
                return
            self._closed = True
            cleanup = asyncio.create_task(self._close_owned_resources())
            try:
                await asyncio.shield(cleanup)
            except asyncio.CancelledError:
                await asyncio.gather(cleanup, return_exceptions=True)
                raise
            self._close_complete = True

    async def _close_owned_resources(self) -> None:
        server, self._server = self._server, None
        if server is not None:
            server.close()
        connections = tuple(self._connections)
        for connection in connections:
            connection.writer.close()
        tasks = tuple(self._client_tasks)
        for task in tasks:
            if not task.done():
                task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        for connection in connections:
            if not connection.writer.is_closing():
                connection.abort()
        if server is not None:
            await server.wait_closed()
        self._port = None

    def _accept_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if self._closed:
            writer.close()
            return
        connection = _Connection(reader, writer, write_timeout_s=self._write_timeout_s)
        self._connections.add(connection)
        self._client_sequence += 1
        task = asyncio.create_task(
            self._handle_client(connection),
            name=f"websocket-client-{self._client_sequence}",
        )
        self._client_tasks.add(task)
        task.add_done_callback(self._client_tasks.discard)

    async def _handle_client(self, connection: _Connection) -> None:
        try:
            try:
                await asyncio.wait_for(
                    perform_server_handshake(connection.reader, connection.writer),
                    _AUTH_TIMEOUT_S,
                )
            except WebSocketHandshakeError:
                await self._reject_http(connection)
                return
            try:
                auth_text = await asyncio.wait_for(
                    self._receive_text(connection), _AUTH_TIMEOUT_S
                )
                auth_message = await _decode_json_cooperatively(auth_text)
                principal = self._authorizer.authenticate(auth_message)
            except TimeoutError:
                await connection.send_close(1008)
                return
            except (GatewayError, ValueError):
                await connection.send_close(1008)
                return
            connection.principal = principal
            await connection.send_json(
                {"type": "auth.ok", "device_id": principal.device_id}
            )
            while True:
                try:
                    text = await self._receive_text(connection)
                except _PeerClosed:
                    return
                try:
                    message = await _decode_json_cooperatively(text)
                except ValueError:
                    await connection.send_json(
                        GatewayError("invalid_json", "message is not valid JSON").to_event()
                    )
                    continue
                try:
                    result = await self._gateway.handle(principal, message)
                except GatewayError as error:
                    result = error.to_event()
                await connection.send_json(result)
        except WebSocketProtocolError as error:
            await connection.send_close(error.close_code)
        except _PeerClosed:
            pass
        except asyncio.CancelledError:
            raise
        except (OSError, ConnectionError, asyncio.IncompleteReadError, TimeoutError):
            pass
        except Exception:
            await connection.send_close(1011)
        finally:
            cleanup_cancellation: asyncio.CancelledError | None = None
            if connection.principal is not None:
                disconnect = asyncio.create_task(
                    self._gateway.client_disconnected(
                        connection.principal.device_id
                    )
                )
                try:
                    await asyncio.shield(disconnect)
                except asyncio.CancelledError as error:
                    cleanup_cancellation = error
                    await asyncio.gather(disconnect, return_exceptions=True)
                except Exception:
                    pass
                finally:
                    connection.principal = None
            self._connections.discard(connection)
            connection.writer.close()
            try:
                await connection.writer.wait_closed()
            except asyncio.CancelledError as error:
                if cleanup_cancellation is None:
                    cleanup_cancellation = error
            except (OSError, ConnectionError):
                pass
            if cleanup_cancellation is not None:
                raise cleanup_cancellation

    async def _receive_text(self, connection: _Connection) -> str:
        while True:
            if connection.pending_frames:
                frame = connection.pending_frames.popleft()
            else:
                data = await connection.reader.read(64 * 1024)
                if not data:
                    raise _PeerClosed
                await asyncio.sleep(0)
                frames = await asyncio.to_thread(connection.frame_reader.feed, data)
                connection.pending_frames.extend(frames)
                continue
            if frame.opcode == 0x1:
                assert frame.text is not None
                return frame.text
            if frame.opcode == 0x2:
                raise WebSocketProtocolError(1003, "binary messages are unsupported")
            if frame.opcode == 0x9:
                await connection.send_control(0xA, frame.payload)
                continue
            if frame.opcode == 0xA:
                continue
            if frame.opcode == 0x8:
                await connection.send_close(payload=frame.payload)
                raise _PeerClosed
            raise WebSocketProtocolError(1002, "frame opcode is unsupported")

    async def _reject_http(self, connection: _Connection) -> None:
        try:
            await connection.send_wire(
                b"HTTP/1.1 400 Bad Request\r\n"
                b"Connection: close\r\n"
                b"Content-Length: 0\r\n\r\n"
            )
        except (OSError, ConnectionError, TimeoutError):
            pass


def _decode_json(text: str) -> object:
    def strict_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON field")
            result[key] = value
        return result

    def reject_constant(_value):
        raise ValueError("non-standard JSON constant")

    try:
        return json.loads(
            text,
            object_pairs_hook=strict_object,
            parse_constant=reject_constant,
        )
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ValueError("message is not valid JSON") from error


def _encode_json_event(event: Mapping[str, object]) -> bytes:
    text = serialize_json_event(event)
    if len(text.encode("utf-8")) > _MAX_PAYLOAD_BYTES:
        raise WebSocketProtocolError(1009, "outgoing event is too large")
    return encode_text_frame(text)


async def _decode_json_cooperatively(text: str) -> object:
    if len(text) < _JSON_OFFLOAD_CHARS:
        return _decode_json(text)
    await asyncio.sleep(0)
    return await asyncio.to_thread(_decode_json, text)


__all__ = ["RemoteRadioServer"]
