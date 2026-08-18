"""Bounded fixed-asset HTTP service for the remote-radio dashboard."""

from __future__ import annotations

import asyncio
from pathlib import Path
from urllib.parse import urlsplit


_ASSETS = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
    "/radio-client.js": ("radio-client.js", "text/javascript; charset=utf-8"),
    "/dashboard.js": ("dashboard.js", "text/javascript; charset=utf-8"),
}
_HEADER_LIMIT_BYTES = 8 * 1024
_REQUEST_TIMEOUT_S = 2.0
_CONTENT_SECURITY_POLICY = (
    "default-src 'self'; connect-src ws: wss:; img-src 'self' data:; "
    "style-src 'self'; script-src 'self'; base-uri 'none'; "
    "frame-ancestors 'none'"
)
_STATUS_TEXT = {
    200: "OK",
    400: "Bad Request",
    404: "Not Found",
    405: "Method Not Allowed",
    431: "Request Header Fields Too Large",
}


class _RequestError(Exception):
    def __init__(self, status: int) -> None:
        self.status = status
        super().__init__(_STATUS_TEXT[status])


class StaticWebServer:
    def __init__(self, web_root: Path, *, allow_non_loopback: bool = False) -> None:
        if not isinstance(web_root, Path):
            raise TypeError("web_root must be a Path")
        if type(allow_non_loopback) is not bool:
            raise TypeError("allow_non_loopback must be a boolean")
        resolved_root = web_root.resolve(strict=True)
        if not resolved_root.is_dir():
            raise ValueError("web_root must be a directory")
        self._web_root = resolved_root
        self._allow_non_loopback = allow_non_loopback
        self._server: asyncio.Server | None = None
        self._writers: set[asyncio.StreamWriter] = set()
        self._client_tasks: set[asyncio.Task[None]] = set()
        self._lifecycle_lock = asyncio.Lock()
        self._closed = False
        self._close_complete = False
        self._port: int | None = None
        self._client_sequence = 0

    @property
    def port(self) -> int:
        if self._port is None:
            raise RuntimeError("HTTP server is not listening")
        return self._port

    async def serve(self, *, host: str = "127.0.0.1", port: int = 8080) -> None:
        if host not in {"127.0.0.1", "0.0.0.0"}:
            raise ValueError("HTTP host is unsupported")
        if host == "0.0.0.0" and not self._allow_non_loopback:
            raise ValueError("public HTTP binding requires explicit policy")
        if type(port) is not int:
            raise TypeError("HTTP port must be an integer")
        if not 0 <= port <= 65535:
            raise ValueError("HTTP port must be in the range 0..65535")
        async with self._lifecycle_lock:
            if self._closed:
                raise RuntimeError("HTTP server is closed")
            if self._server is not None:
                return
            server = await asyncio.start_server(
                self._accept_client,
                host,
                port,
                limit=_HEADER_LIMIT_BYTES + 4,
            )
            sockets = server.sockets or ()
            if not sockets:
                server.close()
                await server.wait_closed()
                raise RuntimeError("HTTP listener has no socket")
            self._server = server
            self._port = sockets[0].getsockname()[1]

    async def close(self) -> None:
        async with self._lifecycle_lock:
            if self._close_complete:
                return
            self._closed = True
            cleanup = asyncio.create_task(
                self._close_owned_resources(), name="static-http-cleanup"
            )
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
        writers = tuple(self._writers)
        for writer in writers:
            writer.close()
        tasks = tuple(self._client_tasks)
        for task in tasks:
            if not task.done():
                task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if server is not None:
            await server.wait_closed()
        self._port = None

    def _accept_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        if self._closed:
            writer.close()
            return
        self._writers.add(writer)
        self._client_sequence += 1
        task = asyncio.create_task(
            self._handle_client(reader, writer),
            name=f"static-http-client-{self._client_sequence}",
        )
        self._client_tasks.add(task)
        task.add_done_callback(self._client_tasks.discard)

    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            try:
                method, target = await self._read_request(reader)
                if method not in {"GET", "HEAD"}:
                    await self._write_response(writer, 405, method=method)
                    return
                asset = await self._asset_for_target(target)
                if asset is None:
                    await self._write_response(writer, 404, method=method)
                    return
                body, content_type = asset
                await self._write_response(
                    writer,
                    200,
                    body=body,
                    content_type=content_type,
                    method=method,
                )
            except _RequestError as error:
                await self._write_response(writer, error.status)
        except (OSError, ConnectionError, TimeoutError):
            pass
        finally:
            self._writers.discard(writer)
            writer.close()
            try:
                await writer.wait_closed()
            except (OSError, ConnectionError):
                pass

    async def _read_request(
        self, reader: asyncio.StreamReader
    ) -> tuple[str, str]:
        try:
            header_block = await asyncio.wait_for(
                reader.readuntil(b"\r\n\r\n"), _REQUEST_TIMEOUT_S
            )
        except asyncio.LimitOverrunError as error:
            raise _RequestError(431) from error
        except (asyncio.IncompleteReadError, TimeoutError) as error:
            raise _RequestError(400) from error
        if len(header_block) > _HEADER_LIMIT_BYTES:
            raise _RequestError(431)
        lines = header_block[:-4].decode("iso-8859-1").split("\r\n")
        request_parts = lines[0].split(" ")
        if len(request_parts) != 3:
            raise _RequestError(400)
        method, target, version = request_parts
        if not method or not target or version not in {"HTTP/1.0", "HTTP/1.1"}:
            raise _RequestError(400)
        if any(not line or ":" not in line for line in lines[1:]):
            raise _RequestError(400)
        return method, target

    async def _asset_for_target(self, target: str) -> tuple[bytes, str] | None:
        try:
            parsed = urlsplit(target)
        except ValueError:
            return None
        if parsed.scheme or parsed.netloc or not parsed.path.startswith("/"):
            return None
        asset = _ASSETS.get(parsed.path)
        if asset is None:
            return None
        filename, content_type = asset
        try:
            path = (self._web_root / filename).resolve(strict=True)
            if path.parent != self._web_root or not path.is_file():
                return None
            body = await asyncio.to_thread(path.read_bytes)
        except OSError:
            return None
        return body, content_type

    async def _write_response(
        self,
        writer: asyncio.StreamWriter,
        status: int,
        *,
        body: bytes = b"",
        content_type: str | None = None,
        method: str = "GET",
    ) -> None:
        headers = [
            f"HTTP/1.1 {status} {_STATUS_TEXT[status]}",
            f"Content-Length: {len(body)}",
            "Connection: close",
        ]
        if status == 200:
            assert content_type is not None
            headers.extend(
                (
                    f"Content-Type: {content_type}",
                    "Cache-Control: no-store",
                    "X-Content-Type-Options: nosniff",
                    "Referrer-Policy: no-referrer",
                    f"Content-Security-Policy: {_CONTENT_SECURITY_POLICY}",
                )
            )
        elif status == 405:
            headers.append("Allow: GET, HEAD")
        wire = ("\r\n".join(headers) + "\r\n\r\n").encode("ascii")
        if method != "HEAD":
            wire += body
        writer.write(wire)
        await asyncio.wait_for(writer.drain(), _REQUEST_TIMEOUT_S)


__all__ = ["StaticWebServer"]
