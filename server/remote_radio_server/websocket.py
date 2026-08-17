"""Small, bounded RFC 6455 primitives for the loopback control plane."""

from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import struct
from dataclasses import dataclass


_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
_MAX_HTTP_HEAD_BYTES = 8 * 1024
_VALID_OPCODES = frozenset((0x1, 0x2, 0x8, 0x9, 0xA))
_CONTROL_OPCODES = frozenset((0x8, 0x9, 0xA))
_HEADER_TOKEN_PUNCTUATION = frozenset("!#$%&'*+-.^_`|~")
_XOR_TABLES = tuple(
    bytes(value ^ key for value in range(256)) for key in range(256)
)


class WebSocketProtocolError(Exception):
    """A peer-visible protocol failure with an RFC 6455 close status."""

    def __init__(self, close_code: int, message: str) -> None:
        self.close_code = close_code
        super().__init__(message)


class WebSocketHandshakeError(Exception):
    """A deliberately generic HTTP upgrade failure."""


@dataclass(frozen=True, slots=True)
class WebSocketFrame:
    opcode: int
    payload: bytes
    text: str | None = None
    close_code: int | None = None
    close_reason: str | None = None


class WebSocketFrameReader:
    """Incrementally decode final, masked client frames."""

    def __init__(self, *, max_payload_bytes: int) -> None:
        if type(max_payload_bytes) is not int or max_payload_bytes < 0:
            raise ValueError("max_payload_bytes must be a non-negative integer")
        self._max_payload_bytes = max_payload_bytes
        self._buffer = bytearray()

    def feed(self, data: bytes) -> tuple[WebSocketFrame, ...]:
        if not isinstance(data, bytes):
            raise TypeError("frame data must be bytes")
        self._buffer.extend(data)
        frames: list[WebSocketFrame] = []
        while True:
            frame = self._next_frame()
            if frame is None:
                return tuple(frames)
            frames.append(frame)

    def _next_frame(self) -> WebSocketFrame | None:
        if len(self._buffer) < 2:
            return None
        first, second = self._buffer[0], self._buffer[1]
        if first & 0x70:
            raise WebSocketProtocolError(1002, "RSV bits are unsupported")
        final = bool(first & 0x80)
        opcode = first & 0x0F
        if opcode not in _VALID_OPCODES:
            if opcode == 0:
                message = "continuation frames are unsupported"
            else:
                message = "frame opcode is unsupported"
            raise WebSocketProtocolError(1002, message)
        if not final:
            raise WebSocketProtocolError(1002, "frames must be final")
        if not second & 0x80:
            raise WebSocketProtocolError(1002, "client frames must be masked")

        length_marker = second & 0x7F
        offset = 2
        if length_marker == 126:
            if len(self._buffer) < offset + 2:
                return None
            payload_length = struct.unpack("!H", self._buffer[offset : offset + 2])[0]
            offset += 2
            if payload_length < 126:
                raise WebSocketProtocolError(1002, "payload length is not canonical")
        elif length_marker == 127:
            if len(self._buffer) < offset + 8:
                return None
            encoded_length = bytes(self._buffer[offset : offset + 8])
            if encoded_length[0] & 0x80:
                raise WebSocketProtocolError(1002, "payload length is invalid")
            payload_length = struct.unpack("!Q", encoded_length)[0]
            offset += 8
            if payload_length <= 0xFFFF:
                raise WebSocketProtocolError(1002, "payload length is not canonical")
        else:
            payload_length = length_marker

        if opcode in _CONTROL_OPCODES and payload_length > 125:
            raise WebSocketProtocolError(1002, "control frame payload is too large")
        if payload_length > self._max_payload_bytes:
            raise WebSocketProtocolError(1009, "frame payload is too large")
        if len(self._buffer) < offset + 4:
            return None
        mask = bytes(self._buffer[offset : offset + 4])
        offset += 4
        total = offset + payload_length
        if len(self._buffer) < total:
            return None
        masked = bytes(self._buffer[offset:total])
        payload_buffer = bytearray(payload_length)
        for phase, key in enumerate(mask):
            payload_buffer[phase::4] = masked[phase::4].translate(_XOR_TABLES[key])
        payload = bytes(payload_buffer)
        del self._buffer[:total]
        return _validated_frame(opcode, payload)


def _validated_frame(opcode: int, payload: bytes) -> WebSocketFrame:
    if opcode == 0x1:
        try:
            text = payload.decode("utf-8", "strict")
        except UnicodeDecodeError:
            raise WebSocketProtocolError(1007, "text frame is not valid UTF-8") from None
        return WebSocketFrame(opcode, payload, text=text)
    if opcode != 0x8:
        return WebSocketFrame(opcode, payload)
    if len(payload) == 1:
        raise WebSocketProtocolError(1002, "close payload is malformed")
    if not payload:
        return WebSocketFrame(opcode, payload)
    close_code = struct.unpack("!H", payload[:2])[0]
    if not _valid_close_code(close_code):
        raise WebSocketProtocolError(1002, "close status is invalid")
    try:
        reason = payload[2:].decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise WebSocketProtocolError(1007, "close reason is not valid UTF-8") from None
    return WebSocketFrame(
        opcode, payload, close_code=close_code, close_reason=reason
    )


def _valid_close_code(code: int) -> bool:
    if 1000 <= code <= 1014:
        return code not in (1004, 1005, 1006)
    return 3000 <= code <= 4999


def encode_text_frame(text: str) -> bytes:
    if not isinstance(text, str):
        raise TypeError("text frame payload must be text")
    try:
        payload = text.encode("utf-8", "strict")
    except UnicodeEncodeError:
        raise ValueError("text frame payload is not valid Unicode") from None
    return encode_frame(0x1, payload)


def encode_frame(opcode: int, payload: bytes = b"") -> bytes:
    """Encode one final, unmasked server frame."""

    if opcode not in _VALID_OPCODES:
        raise ValueError("server frame opcode is unsupported")
    if not isinstance(payload, bytes):
        raise TypeError("frame payload must be bytes")
    length = len(payload)
    if opcode in _CONTROL_OPCODES and length > 125:
        raise ValueError("control frame payload is too large")
    if length <= 125:
        header = bytes((0x80 | opcode, length))
    elif length <= 0xFFFF:
        header = bytes((0x80 | opcode, 126)) + struct.pack("!H", length)
    else:
        header = bytes((0x80 | opcode, 127)) + struct.pack("!Q", length)
    return header + payload


async def perform_server_handshake(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    try:
        head = await reader.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError):
        raise WebSocketHandshakeError("WebSocket upgrade failed") from None
    if len(head) > _MAX_HTTP_HEAD_BYTES:
        raise WebSocketHandshakeError("WebSocket upgrade failed")
    key = _validate_upgrade(head)
    accept = base64.b64encode(hashlib.sha1(key + _GUID).digest())
    writer.write(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: "
        + accept
        + b"\r\n\r\n"
    )
    await writer.drain()


def _validate_upgrade(head: bytes) -> bytes:
    try:
        lines = head[:-4].decode("ascii", "strict").split("\r\n")
    except UnicodeDecodeError:
        raise WebSocketHandshakeError("WebSocket upgrade failed") from None
    if not lines or lines[0].split(" ")[:1] != ["GET"]:
        raise WebSocketHandshakeError("WebSocket upgrade failed")
    request_parts = lines[0].split(" ")
    if (
        len(request_parts) != 3
        or request_parts[0] != "GET"
        or request_parts[2] != "HTTP/1.1"
    ):
        raise WebSocketHandshakeError("WebSocket upgrade failed")
    headers: dict[str, str] = {}
    critical = {
        "upgrade",
        "connection",
        "sec-websocket-key",
        "sec-websocket-version",
    }
    seen_critical: set[str] = set()
    for line in lines[1:]:
        if not line or ":" not in line:
            raise WebSocketHandshakeError("WebSocket upgrade failed")
        raw_name, raw_value = line.split(":", 1)
        if not _is_http_token(raw_name):
            raise WebSocketHandshakeError("WebSocket upgrade failed")
        name = raw_name.lower()
        value = raw_value.strip(" \t")
        if name in critical:
            if name in seen_critical:
                raise WebSocketHandshakeError("WebSocket upgrade failed")
            seen_critical.add(name)
        headers[name] = value
    if headers.get("upgrade", "").lower() != "websocket":
        raise WebSocketHandshakeError("WebSocket upgrade failed")
    connection_tokens = set()
    for raw_token in headers.get("connection", "").split(","):
        token = raw_token.strip()
        if not _is_http_token(token):
            raise WebSocketHandshakeError("WebSocket upgrade failed")
        connection_tokens.add(token.lower())
    if "upgrade" not in connection_tokens:
        raise WebSocketHandshakeError("WebSocket upgrade failed")
    if headers.get("sec-websocket-version") != "13":
        raise WebSocketHandshakeError("WebSocket upgrade failed")
    encoded_key = headers.get("sec-websocket-key", "")
    try:
        decoded_key = base64.b64decode(encoded_key, validate=True)
    except (binascii.Error, ValueError):
        raise WebSocketHandshakeError("WebSocket upgrade failed") from None
    if len(decoded_key) != 16:
        raise WebSocketHandshakeError("WebSocket upgrade failed")
    return encoded_key.encode("ascii")


def _is_http_token(value: str) -> bool:
    return bool(value) and all(
        character.isalnum() or character in _HEADER_TOKEN_PUNCTUATION
        for character in value
    )


__all__ = [
    "WebSocketFrame",
    "WebSocketFrameReader",
    "WebSocketHandshakeError",
    "WebSocketProtocolError",
    "encode_text_frame",
    "perform_server_handshake",
]
