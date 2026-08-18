import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from remote_radio_server.public_dummy import (
    PublicDummyConfig,
    PublicDummyStack,
)


def capabilities_event(model_id=1):
    return {
        "type": "rig.capabilities",
        "identity": {
            "manufacturer": "Hamlib",
            "model": "Dummy",
            "model_id": model_id,
            "backend_version": "20260101.0",
            "hamlib_version": "4.6.5",
        },
        "vfos": ["VFOA"],
        "modes": ["USB"],
        "readable_levels": [],
        "writable_levels": [],
        "readable_functions": [],
        "writable_functions": [],
        "readable_parameters": [],
        "writable_parameters": [],
        "vfo_operations": [],
        "targetable_features": [],
        "passbands_hz": [],
        "rx_ranges_hz": [[100_000, 60_000_000]],
        "tx_ranges_hz": [],
        "supports_ptt_read": True,
        "supports_ptt_write": True,
        "supports_split_read": True,
        "supports_split_write": True,
    }


class FakeGateway:
    def __init__(self, events, model_id=1):
        self.events = events
        self.event = capabilities_event(model_id)

    async def initial_event(self):
        self.events.append("gateway.capabilities")
        return self.event


class FakeRuntime:
    def __init__(self, events, cleanup_events, *, model_id=1):
        self.events = events
        self.cleanup_events = cleanup_events
        self.gateway = FakeGateway(events, model_id)

    async def start(self):
        self.events.append("runtime.start")

    async def close(self):
        self.cleanup_events.append("runtime.close")


class FakeWebSocketServer:
    def __init__(self, events, cleanup_events, *, port=8765):
        self.events = events
        self.cleanup_events = cleanup_events
        self.port = port
        self.allow_non_loopback = None

    async def serve(self, *, host, port, allow_non_loopback=False):
        self.events.append(f"websocket.serve:{host}")
        self.port = port
        self.allow_non_loopback = allow_non_loopback

    async def close(self):
        self.cleanup_events.append("websocket.close")


class FakeHttpServer:
    def __init__(
        self,
        events,
        cleanup_events,
        *,
        port=8080,
        serve_error=None,
        close_error=None,
        close_started=None,
        close_allowed=None,
    ):
        self.events = events
        self.cleanup_events = cleanup_events
        self.port = port
        self.serve_error = serve_error
        self.close_error = close_error
        self.close_started = close_started
        self.close_allowed = close_allowed

    async def serve(self, *, host, port):
        self.events.append(f"http.serve:{host}")
        if self.serve_error is not None:
            raise self.serve_error
        self.port = port

    async def close(self):
        self.cleanup_events.append("http.close")
        if self.close_started is not None:
            self.close_started.set()
        if self.close_allowed is not None:
            await self.close_allowed.wait()
            self.cleanup_events.append("http.closed")
        if self.close_error is not None:
            error, self.close_error = self.close_error, None
            raise error


class PublicDummyStackTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.web_root = Path(self.temp_directory.name)

    def tearDown(self):
        self.temp_directory.cleanup()

    def make_stack(
        self,
        runtime,
        websocket,
        http,
        *,
        events,
        captured,
    ):
        def websocket_factory(gateway, device_tokens):
            captured["gateway"] = gateway
            captured["device_tokens"] = dict(device_tokens)
            return websocket

        def http_factory(web_root, *, allow_non_loopback=False):
            captured["web_root"] = web_root
            captured["http_policy"] = allow_non_loopback
            return http

        return PublicDummyStack(
            PublicDummyConfig(web_root=self.web_root),
            runtime_factory=lambda _config: runtime,
            websocket_factory=websocket_factory,
            http_factory=http_factory,
            token_factory=lambda: "fixed-token",
        )

    async def test_default_runtime_uses_only_the_strict_public_dummy_contract(self):
        events = []
        cleanup_events = []
        captured = {}
        runtime = FakeRuntime(events, cleanup_events)
        websocket = FakeWebSocketServer(events, cleanup_events)
        http = FakeHttpServer(events, cleanup_events)
        launcher_marker = object()

        def launcher_factory(config):
            captured["rig_config"] = config
            return launcher_marker

        def runtime_factory(**kwargs):
            captured["runtime_kwargs"] = kwargs
            return runtime

        with (
            patch(
                "remote_radio_server.public_dummy.RigctldLauncher",
                side_effect=launcher_factory,
            ),
            patch(
                "remote_radio_server.public_dummy.ControlPlaneRuntime",
                side_effect=runtime_factory,
            ),
        ):
            stack = PublicDummyStack(
                PublicDummyConfig(web_root=self.web_root),
                websocket_factory=lambda _gateway, _tokens: websocket,
                http_factory=lambda _root, **_policy: http,
                token_factory=lambda: "fixed-token",
            )
            await stack.start()
            await stack.close()

        rig_config = captured["rig_config"]
        self.assertEqual(1, rig_config.model_id)
        self.assertIsNone(rig_config.device)
        self.assertIsNone(rig_config.baud)
        self.assertEqual("0.0.0.0", rig_config.host)
        self.assertEqual(4532, rig_config.port)
        self.assertFalse(rig_config.hardware_tx_enabled)
        self.assertTrue(rig_config.public_dummy_test)
        self.assertEqual(
            {
                "host": "127.0.0.1",
                "port": 4532,
                "launcher": launcher_marker,
                "hardware_tx_enabled": False,
            },
            captured["runtime_kwargs"],
        )

    async def test_starts_in_safe_order_and_returns_actual_listener_metadata(self):
        events = []
        cleanup_events = []
        captured = {}
        runtime = FakeRuntime(events, cleanup_events)
        websocket = FakeWebSocketServer(events, cleanup_events)
        http = FakeHttpServer(events, cleanup_events)
        stack = self.make_stack(
            runtime,
            websocket,
            http,
            events=events,
            captured=captured,
        )

        startup = await stack.start()
        repeated = await stack.start()

        self.assertIs(startup, repeated)
        self.assertEqual(
            [
                "runtime.start",
                "gateway.capabilities",
                "websocket.serve:0.0.0.0",
                "http.serve:0.0.0.0",
            ],
            events,
        )
        self.assertEqual(1, startup.identity["model_id"])
        self.assertEqual("web-test", startup.device_id)
        self.assertEqual("fixed-token", startup.token)
        self.assertEqual(8080, startup.http_port)
        self.assertEqual(8765, startup.websocket_port)
        self.assertEqual(4532, startup.rigctld_port)
        self.assertEqual("http://0.0.0.0:8080", startup.url)
        self.assertEqual("ws://0.0.0.0:8765/radio", startup.websocket_url)
        self.assertIs(runtime.gateway, captured["gateway"])
        self.assertEqual({"web-test": "fixed-token"}, captured["device_tokens"])
        self.assertTrue(websocket.allow_non_loopback)
        self.assertTrue(captured["http_policy"])
        self.assertEqual(self.web_root, captured["web_root"])

        await stack.close()
        self.assertEqual(
            ["http.close", "websocket.close", "runtime.close"], cleanup_events
        )

    async def test_rejects_non_exact_dummy_identity_before_public_listeners(self):
        for model_id in (1049, True, "1"):
            with self.subTest(model_id=model_id):
                events = []
                cleanup_events = []
                captured = {}
                runtime = FakeRuntime(events, cleanup_events, model_id=model_id)
                stack = self.make_stack(
                    runtime,
                    FakeWebSocketServer(events, cleanup_events),
                    FakeHttpServer(events, cleanup_events),
                    events=events,
                    captured=captured,
                )

                with self.assertRaisesRegex(ValueError, "model 1"):
                    await stack.start()

                self.assertEqual(
                    ["runtime.start", "gateway.capabilities"], events
                )
                self.assertEqual(["runtime.close"], cleanup_events)
                self.assertNotIn("device_tokens", captured)

    async def test_http_start_failure_closes_started_resources_in_reverse_order(self):
        events = []
        cleanup_events = []
        captured = {}
        runtime = FakeRuntime(events, cleanup_events)
        websocket = FakeWebSocketServer(events, cleanup_events)
        http = FakeHttpServer(
            events,
            cleanup_events,
            serve_error=OSError("HTTP bind failed"),
        )
        stack = self.make_stack(
            runtime,
            websocket,
            http,
            events=events,
            captured=captured,
        )

        with self.assertRaisesRegex(OSError, "HTTP bind failed"):
            await stack.start()

        self.assertEqual(
            [
                "runtime.start",
                "gateway.capabilities",
                "websocket.serve:0.0.0.0",
                "http.serve:0.0.0.0",
            ],
            events,
        )
        self.assertEqual(
            ["websocket.close", "runtime.close"], cleanup_events
        )

    async def test_close_finishes_owned_cleanup_before_propagating_cancellation(self):
        events = []
        cleanup_events = []
        captured = {}
        close_started = asyncio.Event()
        close_allowed = asyncio.Event()
        stack = self.make_stack(
            FakeRuntime(events, cleanup_events),
            FakeWebSocketServer(events, cleanup_events),
            FakeHttpServer(
                events,
                cleanup_events,
                close_started=close_started,
                close_allowed=close_allowed,
            ),
            events=events,
            captured=captured,
        )
        await stack.start()
        close_task = asyncio.create_task(stack.close())
        await close_started.wait()

        close_task.cancel()
        close_allowed.set()

        with self.assertRaises(asyncio.CancelledError):
            await close_task
        self.assertEqual(
            ["http.close", "http.closed", "websocket.close", "runtime.close"],
            cleanup_events,
        )
        await stack.close()
        self.assertEqual(4, len(cleanup_events))

    async def test_failed_resource_cleanup_is_retained_for_a_later_retry(self):
        events = []
        cleanup_events = []
        captured = {}
        http = FakeHttpServer(
            events,
            cleanup_events,
            close_error=OSError("close failed"),
        )
        stack = self.make_stack(
            FakeRuntime(events, cleanup_events),
            FakeWebSocketServer(events, cleanup_events),
            http,
            events=events,
            captured=captured,
        )
        await stack.start()

        with self.assertRaisesRegex(OSError, "close failed"):
            await stack.close()
        self.assertEqual(
            ["http.close", "websocket.close", "runtime.close"], cleanup_events
        )

        await stack.close()
        self.assertEqual(
            ["http.close", "websocket.close", "runtime.close", "http.close"],
            cleanup_events,
        )


if __name__ == "__main__":
    unittest.main()
