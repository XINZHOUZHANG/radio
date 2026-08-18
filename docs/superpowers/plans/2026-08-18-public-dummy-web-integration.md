# Public Dummy Web Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy a real browser-to-Debian acceptance path whose HTTP, WebSocket, and official Hamlib Dummy listeners all bind to `0.0.0.0`, while every application PTT path remains disabled.

**Architecture:** Add an explicit public-Dummy orchestration mode that owns an official Hamlib model-1 `rigctld`, the authenticated WebSocket control plane, and a fixed-asset HTTP server. Promote the approved dashboard into a dependency-free web application that authenticates with a temporary token, polls revisioned snapshots, and sends confirmed frequency/mode commands.

**Tech Stack:** Python 3.11+ standard library and `unittest`; Hamlib `rigctld`; dependency-free ES modules; Node built-in test runner; Debian 13 acceptance under `/opt/testradio`.

**Spec:** `docs/superpowers/specs/2026-08-18-public-dummy-web-integration-design.md`

## Global Constraints

- Preserve the existing default that regular WebSocket and `rigctld` listeners bind only to exact IPv4 loopback `127.0.0.1`.
- Public test mode binds HTTP `8080`, WebSocket `8765`, and official Hamlib Dummy `4532` to `0.0.0.0`.
- Permit public `rigctld` only for owned Hamlib model `1` with no device, no baud, and no hardware-TX acknowledgement flags.
- Never supply `--enable-hardware-tx` or `--acknowledge-transmit-risk` in public-Dummy mode.
- Keep the temporary WebSocket token in process memory and browser `sessionStorage`; do not place it in HTML, URLs, repository files, or child-process arguments.
- Runtime frontend assets have no third-party dependencies and need no build step.
- Keep audio, FT8, tuner, rotor, and PTT controls visibly disabled because their real backends are outside this slice.
- Do not touch a serial device, physical radio, antenna, tuner, or RF path.
- On Debian, create or modify files only inside `/opt/testradio`; do not delete anything outside that directory.
- C1, C3, and I3 remain blockers for real-hardware transmission and are not waived by this plan.
- The current `D:\CodeX\remote radio` directory is not a Git checkout. Before implementation, use `superpowers:using-git-worktrees` against a real clone of `https://github.com/XINZHOUZHANG/radio`; preserve the design and plan files when moving into that checkout.

## File Structure

### Create

- `server/remote_radio_server/static_http.py` — bounded fixed-asset HTTP listener.
- `server/remote_radio_server/public_dummy.py` — public-Dummy lifecycle owner and startup metadata.
- `server/tests/test_static_http.py` — HTTP policy, assets, traversal, and lifecycle tests.
- `server/tests/test_public_dummy.py` — orchestrator and CLI validation tests.
- `server/tests/integration/test_public_dummy_web.py` — official Dummy end-to-end acceptance test.
- `web/index.html` — promoted dashboard and token dialog.
- `web/styles.css` — approved rounded dashboard styling plus connection/error states.
- `web/radio-client.js` — authenticated WebSocket client and command correlation.
- `web/dashboard.js` — snapshot rendering and DOM action wiring.
- `web/package.json` — ES-module marker and dependency-free test script.
- `web/tests/radio-client.test.mjs` — client state-machine tests.
- `web/tests/dashboard.test.mjs` — pure formatting and command-mapping tests.

### Modify

- `server/remote_radio_server/gateway.py:125-175` — add authenticated capability request.
- `server/remote_radio_server/server.py:146-206` — add explicit non-loopback listener policy.
- `server/remote_radio_server/rig/launcher.py:9-49` — allow only the explicit public model-1 Dummy argument vector.
- `server/remote_radio_server/__main__.py:16-134` — add public-Dummy CLI mode and run path.
- `server/tests/test_gateway.py:1-140` — capability request coverage.
- `server/tests/test_websocket.py:109-155` — listener-policy and regular CLI regression coverage.
- `server/tests/rig/test_launcher.py:68-120` — public-Dummy launcher validation.
- `server/tests/integration/test_cli.py:7-70` — public-mode CLI validation and startup-event serialization.
- `docs/HAMLIB.md` — exact public-Dummy startup and browser instructions.
- `docs/SAFETY.md` — plaintext/public-port warning and Dummy-only boundary.

---

### Task 1: Add the authenticated capability request

**Files:**
- Modify: `server/remote_radio_server/gateway.py:125-175`
- Modify: `server/tests/test_gateway.py:1-140`

**Interfaces:**
- Consumes: `RigMessageGateway.initial_event() -> dict[str, object]`.
- Produces: `await gateway.handle(principal, {"type": "rig.capabilities"}) -> rig.capabilities event`.

- [ ] **Step 1: Write the failing gateway tests**

Add `serialize_capabilities` to the existing test import and add this method to `GatewayValidationTests`:

```python
async def test_rig_capabilities_rejects_extras_and_serializes_ready_session(self):
    supervisor = _ToggleSupervisor()
    gateway = RigMessageGateway(supervisor, self.store, _Safety())

    event = await gateway.handle(self.user, {"type": "rig.capabilities"})

    self.assertEqual(serialize_capabilities(supervisor.capabilities), event)
    with self.assertRaises(GatewayError) as caught:
        await gateway.handle(
            self.user,
            {"type": "rig.capabilities", "extra": "rejected"},
        )
    self.assertEqual("invalid_message", caught.exception.code)
```

Also assert that the existing not-ready gateway returns code `not_ready` for an exact capability request.

- [ ] **Step 2: Run the focused test and verify the red state**

Run from `server/`:

```powershell
python -m unittest tests.test_gateway.GatewayValidationTests.test_rig_capabilities_rejects_extras_and_serializes_ready_session -v
```

Expected: FAIL because `rig.capabilities` is reported as `unsupported_message`.

- [ ] **Step 3: Add the minimal gateway branch**

Insert before `rig.snapshot` handling:

```python
if message_type == "rig.capabilities":
    _exact_fields(normalized, {"type"})
    return await self.initial_event()
```

Do not add a request ID or loosen strict field validation.

- [ ] **Step 4: Run focused and gateway suites**

```powershell
python -m unittest tests.test_gateway -v
```

Expected: all gateway tests PASS.

- [ ] **Step 5: Commit the capability request**

```powershell
git add server/remote_radio_server/gateway.py server/tests/test_gateway.py
git commit -m "feat: expose rig capabilities over websocket"
```

### Task 2: Gate non-loopback WebSocket binding behind explicit policy

**Files:**
- Modify: `server/remote_radio_server/server.py:146-206`
- Modify: `server/tests/test_websocket.py:109-155`

**Interfaces:**
- Consumes: existing `RemoteRadioServer.serve(host, port)` behavior.
- Produces: `RemoteRadioServer.serve(host, port, allow_non_loopback=False)`; only `0.0.0.0` is accepted when the flag is exact `True`.

- [ ] **Step 1: Write failing listener-policy tests**

Add an isolated async test class:

```python
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
```

- [ ] **Step 2: Run the focused tests and verify the red state**

```powershell
python -m unittest tests.test_websocket.RemoteRadioServerListenerPolicyTests -v
```

Expected: ERROR because `serve()` does not accept `allow_non_loopback`.

- [ ] **Step 3: Implement the explicit listener policy**

Change the signature and validation:

```python
async def serve(
    self,
    *,
    host: str = "127.0.0.1",
    port: int = 8765,
    allow_non_loopback: bool = False,
) -> None:
    if type(allow_non_loopback) is not bool:
        raise TypeError("allow_non_loopback must be a boolean")
    if host not in {"127.0.0.1", "0.0.0.0"}:
        raise ValueError("WebSocket host is unsupported")
    if host == "0.0.0.0" and not allow_non_loopback:
        raise ValueError("public WebSocket binding requires explicit policy")
```

Keep existing port, lifecycle-lock, listener-publication, and close behavior unchanged.

- [ ] **Step 4: Run WebSocket and CLI validation tests**

```powershell
python -m unittest tests.test_websocket -v
```

Expected: all tests PASS, including the existing rejection of ordinary CLI `--host 0.0.0.0`.

- [ ] **Step 5: Commit the listener policy**

```powershell
git add server/remote_radio_server/server.py server/tests/test_websocket.py
git commit -m "feat: gate public websocket binding"
```

### Task 3: Add the exact official public-Dummy `rigctld` launch contract

**Files:**
- Modify: `server/remote_radio_server/rig/launcher.py:9-49`
- Modify: `server/tests/rig/test_launcher.py:68-120`

**Interfaces:**
- Consumes: `RigctldConfig` and `build_rigctld_args(config)`.
- Produces: `RigctldConfig(model_id=1, device=None, host="0.0.0.0", public_dummy_test=True)` and exact argument vector `rigctld -m 1 -T 0.0.0.0 -t PORT`.

- [ ] **Step 1: Write failing argument-vector and rejection tests**

```python
def test_builds_public_official_dummy_without_device_or_hardware_tx(self):
    config = RigctldConfig(
        model_id=1,
        device=None,
        host="0.0.0.0",
        port=4532,
        public_dummy_test=True,
    )

    self.assertEqual(
        ["rigctld", "-m", "1", "-T", "0.0.0.0", "-t", "4532"],
        build_rigctld_args(config),
    )

def test_public_dummy_contract_rejects_every_hardware_shape(self):
    invalid = (
        RigctldConfig(1049, None, host="0.0.0.0", public_dummy_test=True),
        RigctldConfig(1, "COM7", host="0.0.0.0", public_dummy_test=True),
        RigctldConfig(1, None, baud=38400, host="0.0.0.0", public_dummy_test=True),
        RigctldConfig(1, None, host="127.0.0.1", public_dummy_test=True),
        RigctldConfig(
            1,
            None,
            host="0.0.0.0",
            hardware_tx_enabled=True,
            public_dummy_test=True,
        ),
    )
    for config in invalid:
        with self.subTest(config=config), self.assertRaises(ValueError):
            build_rigctld_args(config)
```

Extend the existing non-loopback test to prove `0.0.0.0` remains rejected when `public_dummy_test` is false.

- [ ] **Step 2: Run launcher tests and verify the red state**

```powershell
python -m unittest tests.rig.test_launcher.RigctldArgumentTests -v
```

Expected: ERROR because `device=None` and `public_dummy_test` are unsupported.

- [ ] **Step 3: Implement the strict Dummy configuration**

Change the dataclass fields:

```python
@dataclass(frozen=True, slots=True)
class RigctldConfig:
    model_id: int
    device: str | None
    baud: int | None = None
    host: str = "127.0.0.1"
    port: int = 4532
    hardware_tx_enabled: bool = False
    public_dummy_test: bool = False
```

In `build_rigctld_args`, validate `public_dummy_test` as an exact Boolean. For true public-Dummy mode require model `1`, `device is None`, `baud is None`, host `0.0.0.0`, and hardware TX false. For normal mode retain the current exact loopback and non-empty device rules. Build arguments without `-r` only for public-Dummy mode:

```python
args = ["rigctld", "-m", str(config.model_id)]
if config.device is not None:
    args.extend(("-r", config.device))
if config.baud is not None:
    args.extend(("-s", str(config.baud)))
args.extend(("-T", config.host, "-t", str(config.port)))
```

- [ ] **Step 4: Run all launcher tests**

```powershell
python -m unittest tests.rig.test_launcher -v
```

Expected: all tests PASS and existing FT-710 argument vectors remain unchanged.

- [ ] **Step 5: Commit the Dummy launch contract**

```powershell
git add server/remote_radio_server/rig/launcher.py server/tests/rig/test_launcher.py
git commit -m "feat: add public hamlib dummy launch contract"
```

### Task 4: Build the bounded fixed-asset HTTP server

**Files:**
- Create: `server/remote_radio_server/static_http.py`
- Create: `server/tests/test_static_http.py`

**Interfaces:**
- Consumes: a repository `web_root: pathlib.Path` containing exactly the approved assets.
- Produces: `StaticWebServer(web_root, allow_non_loopback=False)`, `await serve(host, port)`, integer `.port`, and idempotent `await close()`.

- [ ] **Step 1: Write failing fixed-asset and policy tests**

Create a temporary asset directory and a raw HTTP helper:

```python
async def request(port, path, method="GET"):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(
        f"{method} {path} HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n".encode("ascii")
    )
    await writer.drain()
    response = await asyncio.wait_for(reader.read(), 2.0)
    writer.close()
    await writer.wait_closed()
    return response
```

Add tests that assert:

```python
self.assertTrue((await request(server.port, "/")).startswith(b"HTTP/1.1 200"))
self.assertIn(b"Content-Type: text/html; charset=utf-8", await request(server.port, "/"))
self.assertTrue((await request(server.port, "/missing")).startswith(b"HTTP/1.1 404"))
self.assertTrue((await request(server.port, "/../secret")).startswith(b"HTTP/1.1 404"))
self.assertTrue((await request(server.port, "/%2e%2e/secret")).startswith(b"HTTP/1.1 404"))
self.assertTrue((await request(server.port, "/", "POST")).startswith(b"HTTP/1.1 405"))
```

Also assert `0.0.0.0` fails by default, succeeds with `allow_non_loopback=True`, and arbitrary hosts remain rejected.

- [ ] **Step 2: Run the new module and verify import failure**

```powershell
python -m unittest tests.test_static_http -v
```

Expected: ERROR with `ModuleNotFoundError: remote_radio_server.static_http`.

- [ ] **Step 3: Implement a fixed allowlist server**

Use a fixed mapping rather than filesystem-derived directory listings:

```python
_ASSETS = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
    "/radio-client.js": ("radio-client.js", "text/javascript; charset=utf-8"),
    "/dashboard.js": ("dashboard.js", "text/javascript; charset=utf-8"),
}

class StaticWebServer:
    def __init__(self, web_root: Path, *, allow_non_loopback: bool = False) -> None:
        if type(allow_non_loopback) is not bool:
            raise TypeError("allow_non_loopback must be a boolean")
        self._web_root = web_root.resolve(strict=True)
        self._allow_non_loopback = allow_non_loopback
        self._server = None
        self._port = None

    @property
    def port(self) -> int:
        if self._port is None:
            raise RuntimeError("HTTP server is not listening")
        return self._port
```

Implement `serve()` with `asyncio.start_server`, accept only hosts `127.0.0.1` and `0.0.0.0`, cap request headers at 8 KiB with a two-second timeout, accept only `GET` and `HEAD`, use `urllib.parse.urlsplit` for the path, look up `_ASSETS`, read one resolved allowlisted file with `asyncio.to_thread`, and always close the connection. Return `400`, `404`, `405`, or `431` with zero-length bodies as applicable.

Every `200` response must include `Content-Length`, `Content-Type`, `Connection: close`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and this CSP:

```text
default-src 'self'; connect-src ws: wss:; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'
```

- [ ] **Step 4: Run the HTTP tests**

```powershell
python -m unittest tests.test_static_http -v
```

Expected: all HTTP tests PASS with no directory listing or path traversal.

- [ ] **Step 5: Commit the HTTP server**

```powershell
git add server/remote_radio_server/static_http.py server/tests/test_static_http.py
git commit -m "feat: serve fixed dashboard assets"
```

### Task 5: Own the public-Dummy stack lifecycle

**Files:**
- Create: `server/remote_radio_server/public_dummy.py`
- Create: `server/tests/test_public_dummy.py`

**Interfaces:**
- Consumes: `RigctldLauncher`, `ControlPlaneRuntime`, `RemoteRadioServer`, `StaticWebServer`.
- Produces: `PublicDummyConfig`, `PublicDummyStartup`, and cancellation-safe `PublicDummyStack.start()/close()`.

- [ ] **Step 1: Write failing lifecycle-order and cleanup tests**

Define fakes with an event log and inject factories into the stack. The success test must prove this exact order:

```python
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
```

The identity-mismatch test returns model ID `1049` and asserts that neither browser-facing listener starts. The partial-start test makes HTTP startup fail and asserts reverse cleanup:

```python
self.assertEqual(
    ["websocket.close", "runtime.close"],
    cleanup_events,
)
```

Also cancel `close()` while a fake child cleanup is blocked and assert cleanup settles before cancellation propagates, matching existing runtime/launcher ownership rules.

- [ ] **Step 2: Run the new tests and verify import failure**

```powershell
python -m unittest tests.test_public_dummy.PublicDummyStackTests -v
```

Expected: ERROR with `ModuleNotFoundError: remote_radio_server.public_dummy`.

- [ ] **Step 3: Implement configuration, startup metadata, and stack ownership**

Create immutable configuration and startup records:

```python
@dataclass(frozen=True, slots=True)
class PublicDummyConfig:
    web_root: Path
    http_port: int = 8080
    websocket_port: int = 8765
    rigctld_port: int = 4532

@dataclass(frozen=True, slots=True)
class PublicDummyStartup:
    url: str
    websocket_url: str
    http_port: int
    websocket_port: int
    rigctld_port: int
    device_id: str
    token: str
    identity: Mapping[str, object]
```

The default runtime factory must construct:

```python
rig_config = RigctldConfig(
    model_id=1,
    device=None,
    host="0.0.0.0",
    port=config.rigctld_port,
    hardware_tx_enabled=False,
    public_dummy_test=True,
)
runtime = ControlPlaneRuntime(
    host="127.0.0.1",
    port=config.rigctld_port,
    launcher=RigctldLauncher(rig_config),
    hardware_tx_enabled=False,
)
```

`start()` must start the runtime, call `gateway.initial_event()`, require identity model ID exactly `1`, generate `secrets.token_urlsafe(32)`, create `RemoteRadioServer` with `{ "web-test": token }`, start WebSocket and HTTP on `0.0.0.0` with explicit policies, and return startup metadata. On every exception, call `close()` before re-raising.

Populate `PublicDummyStartup.http_port` and `.websocket_port` from the listeners after they start, populate `.rigctld_port` from the validated configuration, and construct both URLs from those actual ports. This keeps startup metadata correct when tests use ephemeral listener ports.

`close()` must shield a reverse-order cleanup task, close HTTP, WebSocket, then runtime, preserve resources whose cleanup failed for a retry, and never enumerate or signal unrelated processes.

- [ ] **Step 4: Run lifecycle tests**

```powershell
python -m unittest tests.test_public_dummy.PublicDummyStackTests -v
```

Expected: all stack ownership and cleanup tests PASS.

- [ ] **Step 5: Commit the public stack owner**

```powershell
git add server/remote_radio_server/public_dummy.py server/tests/test_public_dummy.py
git commit -m "feat: own public dummy test stack"
```

### Task 6: Wire the explicit public-Dummy CLI mode

**Files:**
- Modify: `server/remote_radio_server/__main__.py:16-134`
- Modify: `server/tests/test_public_dummy.py`
- Modify: `server/tests/integration/test_cli.py:7-70`
- Modify: `server/tests/test_websocket.py:134-155`

**Interfaces:**
- Consumes: `PublicDummyConfig` and `PublicDummyStack`.
- Produces: `python -m remote_radio_server --public-dummy-test` and one strict JSON startup event.

- [ ] **Step 1: Write failing parser and startup-event tests**

Add parser tests that accept only the dedicated mode:

```python
def test_public_dummy_mode_has_fixed_public_ports_and_no_hardware_tx(self):
    args = _validated_args(["--public-dummy-test"])
    self.assertTrue(args.public_dummy_test)
    self.assertEqual(8080, args.http_port)
    self.assertEqual(8765, args.port)
    self.assertEqual(4532, args.rigctld_port)
    self.assertFalse(args.enable_hardware_tx)
    self.assertFalse(args.acknowledge_transmit_risk)
```

Reject each incompatible shape with `SystemExit` and empty stdout:

```python
invalid = (
    ["--public-dummy-test", "--mock"],
    ["--public-dummy-test", "--launch-rigctld", "--model-id", "1", "--device", "dummy"],
    ["--public-dummy-test", "--serve"],
    ["--public-dummy-test", "--once"],
    ["--public-dummy-test", "--device-token", "phone=secret"],
    ["--public-dummy-test", "--enable-hardware-tx", "--acknowledge-transmit-risk"],
    ["--public-dummy-test", "--host", "0.0.0.0"],
)
```

Add a pure serialization test for the printed event:

```python
self.assertEqual(
    {
        "type": "public-dummy.started",
        "url": "http://0.0.0.0:8080",
        "websocket_url": "ws://0.0.0.0:8765/radio",
        "device_id": "web-test",
        "token": "secret",
        "identity": {"model_id": 1, "model": "Dummy"},
    },
    public_dummy_startup_event(startup),
)
```

- [ ] **Step 2: Run CLI-focused tests and verify the red state**

```powershell
python -m unittest tests.test_public_dummy tests.test_websocket.RemoteRadioServerValidationTests tests.integration.test_cli -v
```

Expected: FAIL because the parser and run path do not know `--public-dummy-test`.

- [ ] **Step 3: Add parser validation and run path**

Add `--public-dummy-test` to the existing mutually exclusive source group and add `--http-port` defaulting to `8080`. In `_validated_args`, branch for public mode before regular launch validation and enforce exact default `--host 127.0.0.1`, no `--serve`, no `--once`, no device tokens, no model/device/baud, and no TX flags. Continue using the existing port range checks.

Add a run branch before `_runtime(args)`:

```python
if args.public_dummy_test:
    web_root = Path(__file__).resolve().parents[2] / "web"
    stack = PublicDummyStack(
        PublicDummyConfig(
            web_root=web_root,
            http_port=args.http_port,
            websocket_port=args.port,
            rigctld_port=args.rigctld_port,
        )
    )
    try:
        startup = await stack.start()
        _write_event(public_dummy_startup_event(startup))
        await asyncio.Event().wait()
    finally:
        await stack.close()
    return 0
```

The startup event may contain the temporary token because it is written once to the operator's stdout. Do not pass it to a child process, URL, environment variable, or file.

- [ ] **Step 4: Run CLI and legacy suites**

```powershell
python -m unittest tests.test_public_dummy tests.test_websocket tests.integration.test_cli -v
```

Expected: all tests PASS; `--mock --once` still prints exactly capabilities and snapshot.

- [ ] **Step 5: Commit CLI wiring**

```powershell
git add server/remote_radio_server/__main__.py server/tests/test_public_dummy.py server/tests/test_websocket.py server/tests/integration/test_cli.py
git commit -m "feat: add public dummy cli mode"
```

### Task 7: Implement the dependency-free WebSocket client

**Files:**
- Create: `web/package.json`
- Create: `web/radio-client.js`
- Create: `web/tests/radio-client.test.mjs`

**Interfaces:**
- Produces: `deriveWebSocketUrl`, `reconnectDelayMs`, and `RadioClient` methods `connect`, `disconnect`, `requestCapabilities`, `requestSnapshot`, `setFrequency`, and `setMode`.
- Emits: callbacks `onConnectionState(state)`, `onCapabilities(event)`, `onSnapshot(event)`, and `onCommandResult(event)`.

- [ ] **Step 1: Create the ES-module marker and failing client tests**

Create `web/package.json`:

```json
{
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test tests/radio-client.test.mjs tests/dashboard.test.mjs"
  }
}
```

The first test file must cover URL derivation and retry bounds:

```javascript
import test from "node:test";
import assert from "node:assert/strict";
import { deriveWebSocketUrl, reconnectDelayMs, RadioClient } from "../radio-client.js";

test("derives ws and wss URLs from the page host", () => {
  assert.equal(
    deriveWebSocketUrl({ protocol: "http:", hostname: "10.0.0.8" }),
    "ws://10.0.0.8:8765/radio",
  );
  assert.equal(
    deriveWebSocketUrl({ protocol: "https:", hostname: "radio.example" }),
    "wss://radio.example:8765/radio",
  );
});

test("reconnect delay is bounded at five seconds", () => {
  assert.deepEqual([0, 1, 2, 3, 4, 8].map(reconnectDelayMs), [500, 1000, 2000, 4000, 5000, 5000]);
});
```

Use a `FakeWebSocket` with `sent`, `open()`, `message(document)`, and `close()` methods. Assert the first sent document is exact auth, `auth.ok` triggers exact capability and snapshot requests, snapshot polling is 500 ms, command request IDs correlate results, stale revisions are ignored, auth failure clears credentials, and `typeof client.setPtt === "undefined"`.

- [ ] **Step 2: Run Node tests and verify the red state**

Run from repository root:

```powershell
node --test web/tests/radio-client.test.mjs
```

Expected: FAIL with module-not-found for `web/radio-client.js`.

- [ ] **Step 3: Implement the client state machine**

Start with pure helpers:

```javascript
export function deriveWebSocketUrl(locationLike, port = 8765) {
  const protocol = locationLike.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${locationLike.hostname}:${port}/radio`;
}

export function reconnectDelayMs(attempt) {
  return Math.min(500 * (2 ** attempt), 5000);
}
```

Give `RadioClient` injected `socketFactory`, `setTimeoutFn`, `clearTimeoutFn`, `setIntervalFn`, `clearIntervalFn`, and `idFactory` dependencies so tests never wait on wall-clock time. On socket open send only:

```javascript
{ type: "auth", device_id: this.deviceId, token: this.token }
```

After `auth.ok`, set state `ready`, send `{type:"rig.capabilities"}` and `{type:"rig.snapshot"}`, then schedule one snapshot request every 500 ms. `setFrequency()` and `setMode()` must validate input before sending these exact messages:

```javascript
{
  type: "rig.command",
  request_id: requestId,
  command: "set_frequency",
  frequency_hz: frequencyHz,
}
```

```javascript
{
  type: "rig.command",
  request_id: requestId,
  command: "set_mode",
  mode,
  passband_hz: passbandHz,
}
```

Track the highest snapshot revision; ignore lower revisions. Resolve pending commands only on matching `request_id`; expire them after three seconds. On close, stop polling, disable ready state, and schedule bounded reconnect unless the user explicitly disconnected. Never define or dynamically construct a PTT method or PTT message type.

- [ ] **Step 4: Run all client tests**

```powershell
node --test web/tests/radio-client.test.mjs
```

Expected: all client tests PASS with no network access.

- [ ] **Step 5: Commit the WebSocket client**

```powershell
git add web/package.json web/radio-client.js web/tests/radio-client.test.mjs
git commit -m "feat: add browser radio websocket client"
```

### Task 8: Promote and wire the approved dashboard

**Files:**
- Create: `web/index.html`
- Create: `web/styles.css`
- Create: `web/dashboard.js`
- Create: `web/tests/dashboard.test.mjs`
- Modify: `server/tests/test_static_http.py`
- Source reference: `D:/CodeX/remote radio/.superpowers/brainstorm/remote-radio-ui/content/widget-dashboard-v3-live.html`

**Interfaces:**
- Consumes: `RadioClient` callbacks and methods from Task 7.
- Produces: `formatFrequency(hz)`, `snapshotView(snapshot)`, `memoryCommand(element)`, and browser DOM wiring.

- [ ] **Step 1: Write failing pure dashboard and served-asset tests**

Create tests for formatting and mapping:

```javascript
import test from "node:test";
import assert from "node:assert/strict";
import { formatFrequency, snapshotView, memoryCommand } from "../dashboard.js";

test("formats confirmed hertz as grouped MHz", () => {
  assert.equal(formatFrequency(14074000), "14.074.000");
  assert.equal(formatFrequency(7074000), "7.074.000");
});

test("maps snapshot without inventing unavailable values", () => {
  assert.deepEqual(
    snapshotView({ revision: 9, lifecycle: "ready", frequency_hz: 14074000, mode: "USB", meters: {} }),
    { revision: 9, lifecycle: "ready", frequencyText: "14.074.000", modeText: "USB", swrText: "—" },
  );
});

test("maps a memory element to confirmed backend commands", () => {
  assert.deepEqual(
    memoryCommand({ dataset: { frequencyHz: "7074000", mode: "USB" } }),
    { frequencyHz: 7074000, mode: "USB" },
  );
});
```

Extend Python HTTP tests to assert `/`, `/styles.css`, `/radio-client.js`, and `/dashboard.js` return `200`, while the HTML contains a disabled PTT button, a token form, a mode selector, and no inline `<script>` block.

- [ ] **Step 2: Run JavaScript and HTTP tests and verify the red state**

```powershell
node --test web/tests/dashboard.test.mjs
Set-Location server
python -m unittest tests.test_static_http -v
```

Expected: dashboard module/assets are missing and tests FAIL.

- [ ] **Step 3: Promote the approved visual source and add real states**

Use the approved prototype as the exact visual source, split its `<style>` content into `styles.css`, remove brainstorming-only adoption controls and inline preview functions, and retain rounded buttons/cards. The document head must load only external assets:

```html
<link rel="stylesheet" href="/styles.css">
<script type="module" src="/dashboard.js"></script>
```

Add stable elements:

```html
<form id="connection-form" class="rr-connection-dialog">
  <label for="device-token">临时连接令牌</label>
  <input id="device-token" name="token" type="password" autocomplete="off" required>
  <button type="submit" class="rr-pill-button rr-primary">连接后台</button>
</form>
<span id="connection-state" role="status">未连接</span>
<select id="mode-select" disabled aria-label="工作模式"></select>
<button id="rr-ptt-v3" type="button" class="rr-ptt-button" disabled aria-disabled="true">PTT 已禁用</button>
```

All frequency/memory buttons use integer `data-frequency-hz` and a supported Hamlib `data-mode`. Add `disabled` and a visible `未接入后台` badge to audio, FT8, tuner, and rotor actions.

Implement and export the three pure functions from the tests. In browser-only initialization, read the token from `sessionStorage` key `remote-radio-test-token`, create `RadioClient`, populate modes from capabilities, render only snapshots accepted by the client, and keep write controls disabled unless connection state is `ready`. On command result, show the exact status/message; do not update frequency or mode until a later snapshot confirms it. On authentication failure, remove the session token and reopen the form.

- [ ] **Step 4: Run frontend and static server tests**

From repository root:

```powershell
node --test web/tests/radio-client.test.mjs web/tests/dashboard.test.mjs
Set-Location server
python -m unittest tests.test_static_http -v
```

Expected: all frontend and HTTP asset tests PASS.

- [ ] **Step 5: Commit the wired dashboard**

```powershell
git add web/index.html web/styles.css web/dashboard.js web/tests/dashboard.test.mjs server/tests/test_static_http.py
git commit -m "feat: connect dashboard to confirmed rig state"
```

### Task 9: Add official Dummy end-to-end coverage and operator docs

**Files:**
- Create: `server/tests/integration/test_public_dummy_web.py`
- Modify: `docs/HAMLIB.md`
- Modify: `docs/SAFETY.md`

**Interfaces:**
- Consumes: complete `PublicDummyStack`, existing `WebSocketTestClient`, and official `rigctld` executable discovery.
- Produces: one optional official-Hamlib end-to-end test and exact operator instructions.

- [ ] **Step 1: Write the optional official Dummy integration test**

Reuse `_rigctld_executable()` and the raw WebSocket helper. Allocate three distinct ephemeral ports, start `PublicDummyStack` with `web_root` from repository root, retain the returned startup metadata, then verify:

```python
startup = await stack.start()
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

await client.send_json(
    {
        "type": "rig.command",
        "request_id": "freq-1",
        "command": "set_frequency",
        "frequency_hz": 7_074_000,
    }
)
self.assertEqual("confirmed", (await client.receive_json())["status"])
await client.send_json({"type": "rig.snapshot"})
self.assertEqual(7_074_000, (await client.receive_json())["frequency_hz"])
```

Repeat for a mode present in the returned capability list. Acquire a PTT lease, send PTT-on, and assert an error event with code `hardware_tx_disabled` and no enabled `ptt.state`. Open a raw TCP client to the Dummy port and verify an Extended Response Protocol read succeeds. Fetch `/` from the HTTP port and assert the dashboard marker is present. Close the stack and assert all three ports reject new connections.

- [ ] **Step 2: Run the optional integration test and verify the red state**

```powershell
python -m unittest tests.integration.test_public_dummy_web -v
```

Expected when `rigctld` is available: FAIL until every previous component is connected. Expected when unavailable: one explicit SKIP, not a false pass.

- [ ] **Step 3: Finish the integration path and document exact operation**

Make only the minimal corrections revealed by the test. Update `docs/HAMLIB.md` with:

```text
cd /opt/testradio/server
python3 -m remote_radio_server --public-dummy-test
```

Document the JSON startup event, `http://<debian-address>:8080`, token entry, exact three port bindings, and Ctrl+C shutdown. Update `docs/SAFETY.md` to state that ports `8080`, `8765`, and unauthenticated `4532` are plaintext/public in this mode, that the mode hard-requires official Dummy model `1`, that WebSocket PTT-on is rejected, and that direct `4532` clients can mutate only simulated Dummy state.

- [ ] **Step 4: Run complete local verification**

From `server/`:

```powershell
python -m unittest discover -s tests -v
```

From repository root:

```powershell
node --test web/tests/radio-client.test.mjs web/tests/dashboard.test.mjs
```

Expected: every non-optional test PASS; official Hamlib tests either PASS when `rigctld` exists or report their documented SKIP.

- [ ] **Step 5: Commit integration and documentation**

```powershell
git add server/tests/integration/test_public_dummy_web.py docs/HAMLIB.md docs/SAFETY.md
git commit -m "test: verify public dummy web stack"
```

### Task 10: Publish, deploy, and leave the acceptance service running

**Files:**
- Verify and publish all files listed above.
- Remote working directory: `/opt/testradio` only.

**Interfaces:**
- Consumes: committed feature branch and `--public-dummy-test` CLI.
- Produces: reachable browser URL, one-time token, three verified public listeners, and a foreground-owned test session.

- [ ] **Step 1: Run fresh pre-publish verification and inspect scope**

```powershell
Set-Location server
python -m unittest discover -s tests -v
Set-Location ..
node --test web/tests/radio-client.test.mjs web/tests/dashboard.test.mjs
git status --short
git diff --check
git log --oneline -10
```

Expected: tests PASS, `git diff --check` is empty, and only approved project files are changed.

- [ ] **Step 2: Publish through the approved GitHub workflow**

Use the `github:yeet` skill. Push the reviewed feature branch to `https://github.com/XINZHOUZHANG/radio`, open a draft PR, and merge or fast-forward `main` only with the user's approval. Record the resulting commit SHA before touching Debian.

- [ ] **Step 3: Re-establish bounded SSH access if no valid key exists**

Generate a new temporary Ed25519 key locally, display only its public key, and ask the user to add it to `connor` with an expiry and restrictions. Do not use Computer Use to control Termius. Verify the server fingerprint remains:

```text
SHA256:KzJfgnDt538GkZj7RkEWSCXRUVJiRMIkUiRTynEQQic
```

Use direct SSH to `connor@ah.992218.xyz:3022`. Do not remove any authorization line outside `/opt/testradio`; delete only the local temporary private key when remote work finishes.

- [ ] **Step 4: Inspect the remote checkout before changing it**

Run read-only commands first:

```bash
cd /opt/testradio
pwd
git status --short --branch
git remote -v
git rev-parse HEAD
command -v python3
command -v rigctld
command -v node
ss -ltnp
```

Expected: path is exactly `/opt/testradio`; existing worktree state is known; required ports are not occupied by unrelated processes. If local changes exist or a required port belongs to another process, stop and report rather than resetting, deleting, or killing it.

- [ ] **Step 5: Fast-forward the remote checkout inside `/opt/testradio`**

After confirming a clean checkout:

```bash
cd /opt/testradio
git fetch origin main
git merge --ff-only origin/main
git rev-parse HEAD
```

Expected: SHA matches the reviewed GitHub commit. Do not use `git reset`, recursive deletion, or any command that changes files outside `/opt/testradio`.

- [ ] **Step 6: Run Debian tests**

```bash
cd /opt/testradio/server
python3 -m unittest discover -s tests -v
cd /opt/testradio
node --test web/tests/radio-client.test.mjs web/tests/dashboard.test.mjs
```

Expected: every test PASS, including official Hamlib Dummy integration. If `node` is absent, stop and report the missing test runtime; do not install system packages or write outside `/opt/testradio` without new approval.

- [ ] **Step 7: Start the stack in one long-lived foreground SSH session**

```bash
cd /opt/testradio/server
python3 -m remote_radio_server --public-dummy-test
```

Capture the single `public-dummy.started` JSON event and keep that SSH process attached. Give the user the URL formed from their chosen Debian-reachable address on port `8080`, device ID `web-test`, and the temporary token. Do not persist the token to a file.

- [ ] **Step 8: Verify all listeners and the real browser round trip**

In a second read-only SSH connection:

```bash
ss -ltnp '( sport = :8080 or sport = :8765 or sport = :4532 )'
curl --fail --silent --show-error http://127.0.0.1:8080/ >/dev/null
```

Expected: `0.0.0.0:8080`, `0.0.0.0:8765`, and `0.0.0.0:4532` are owned by this test stack. In the browser, authenticate, select `7.074.000 MHz`, change to an advertised mode, and confirm both values persist after at least two snapshot polls. Confirm unsupported panels and PTT stay disabled.

- [ ] **Step 9: Preserve the service for user acceptance, then shut down safely on request**

Leave the foreground process running while the user tests. When the user explicitly finishes, send Ctrl+C to that exact SSH session, wait for owned cleanup, then rerun the scoped `ss` command. Expected: all three listeners are gone and no unrelated process or file was touched.

