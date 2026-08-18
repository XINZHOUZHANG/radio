import asyncio
import tempfile
import unittest
from pathlib import Path

from remote_radio_server.static_http import StaticWebServer


async def raw_request(port: int, wire: bytes) -> bytes:
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(wire)
    await writer.drain()
    response = await asyncio.wait_for(reader.read(), 2.0)
    writer.close()
    await writer.wait_closed()
    return response


async def request(port: int, path: str, method: str = "GET") -> bytes:
    return await raw_request(
        port,
        (
            f"{method} {path} HTTP/1.1\r\n"
            "Host: test\r\n"
            "Connection: close\r\n"
            "\r\n"
        ).encode("ascii"),
    )


def split_response(response: bytes) -> tuple[bytes, bytes]:
    return tuple(response.split(b"\r\n\r\n", 1))


class StaticWebServerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.web_root = Path(self.temp_directory.name)
        self.assets = {
            "index.html": b"<!doctype html><title>Remote Radio</title>",
            "styles.css": b"body { color: white; }",
            "radio-client.js": b"export class RadioClient {}",
            "dashboard.js": b"export const dashboard = true;",
        }
        for name, body in self.assets.items():
            (self.web_root / name).write_bytes(body)
        (self.web_root / "not-public.txt").write_text("secret", encoding="utf-8")

    def tearDown(self):
        self.temp_directory.cleanup()

    async def test_serves_only_fixed_assets_with_security_headers(self):
        server = StaticWebServer(self.web_root)
        try:
            await server.serve(host="127.0.0.1", port=0)

            response = await request(server.port, "/?cache-bust=1")
            headers, body = split_response(response)
            self.assertTrue(headers.startswith(b"HTTP/1.1 200 OK\r\n"))
            self.assertEqual(self.assets["index.html"], body)
            self.assertIn(b"Content-Type: text/html; charset=utf-8", headers)
            self.assertIn(b"Cache-Control: no-store", headers)
            self.assertIn(b"X-Content-Type-Options: nosniff", headers)
            self.assertIn(b"Referrer-Policy: no-referrer", headers)
            self.assertIn(
                b"Content-Security-Policy: default-src 'self'; connect-src ws: wss:;",
                headers,
            )

            for path in (
                "/missing",
                "/not-public.txt",
                "/../secret",
                "/%2e%2e/secret",
            ):
                with self.subTest(path=path):
                    self.assertTrue(
                        (await request(server.port, path)).startswith(
                            b"HTTP/1.1 404 Not Found"
                        )
                    )
        finally:
            await server.close()

    async def test_head_methods_and_malformed_requests_are_bounded(self):
        server = StaticWebServer(self.web_root)
        try:
            await server.serve(port=0)

            head_response = await request(server.port, "/index.html", "HEAD")
            head_headers, head_body = split_response(head_response)
            self.assertTrue(head_headers.startswith(b"HTTP/1.1 200 OK\r\n"))
            self.assertIn(
                f"Content-Length: {len(self.assets['index.html'])}".encode("ascii"),
                head_headers,
            )
            self.assertEqual(b"", head_body)

            self.assertTrue(
                (await request(server.port, "/", "POST")).startswith(
                    b"HTTP/1.1 405 Method Not Allowed"
                )
            )
            self.assertTrue(
                (await raw_request(server.port, b"BROKEN\r\n\r\n")).startswith(
                    b"HTTP/1.1 400 Bad Request"
                )
            )

            oversized = (
                b"GET / HTTP/1.1\r\nHost: test\r\nX-Fill: "
                + b"x" * (8 * 1024)
                + b"\r\n\r\n"
            )
            self.assertTrue(
                (await raw_request(server.port, oversized)).startswith(
                    b"HTTP/1.1 431 Request Header Fields Too Large"
                )
            )
        finally:
            await server.close()

    async def test_public_ipv4_bind_requires_explicit_exact_boolean_policy(self):
        for policy in (1, "yes"):
            with self.subTest(policy=policy), self.assertRaises(TypeError):
                StaticWebServer(self.web_root, allow_non_loopback=policy)

        server = StaticWebServer(self.web_root)
        with self.assertRaises(ValueError):
            await server.serve(host="0.0.0.0", port=0)
        await server.close()

        server = StaticWebServer(self.web_root, allow_non_loopback=True)
        try:
            await server.serve(host="0.0.0.0", port=0)
            self.assertGreater(server.port, 0)
            self.assertTrue(
                (await request(server.port, "/")).startswith(b"HTTP/1.1 200 OK")
            )
        finally:
            await server.close()

    async def test_public_policy_does_not_admit_arbitrary_hosts(self):
        for host in ("::", "localhost", "127.0.0.2"):
            server = StaticWebServer(self.web_root, allow_non_loopback=True)
            with self.subTest(host=host), self.assertRaises(ValueError):
                await server.serve(host=host, port=0)
            await server.close()

    async def test_port_and_close_lifecycle_are_strict_and_idempotent(self):
        server = StaticWebServer(self.web_root)
        with self.assertRaises(RuntimeError):
            _ = server.port

        for invalid_port in (True, -1, 65536):
            with self.subTest(port=invalid_port), self.assertRaises(
                (TypeError, ValueError)
            ):
                await server.serve(port=invalid_port)

        await server.serve(port=0)
        listening_port = server.port
        await asyncio.gather(server.close(), server.close())

        with self.assertRaises(RuntimeError):
            _ = server.port
        with self.assertRaises((ConnectionRefusedError, OSError)):
            await asyncio.open_connection("127.0.0.1", listening_port)
        with self.assertRaises(RuntimeError):
            await server.serve(port=0)


if __name__ == "__main__":
    unittest.main()
