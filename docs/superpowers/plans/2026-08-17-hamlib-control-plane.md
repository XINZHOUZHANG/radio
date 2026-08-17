# Hamlib Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a runnable Hamlib-backed radio control slice with dynamic capabilities, confirmed state, guarded commands, PTT watchdogs, a mock rig, and a JSON message gateway.

**Architecture:** A Python 3.11 `asyncio` package talks to a single loopback `rigctld` connection with Hamlib's Extended Response Protocol. Focused services own transport, capability discovery, state polling, validated mutations, PTT safety, lifecycle recovery, and client message translation. An in-process fake `rigctld` provides deterministic end-to-end tests without radio hardware.

**Tech Stack:** Python 3.11+, standard library `asyncio`, `dataclasses`, `enum`, `json`, and `unittest`; external Hamlib tools are optional for dummy-rig integration.

## Global Constraints

- Target Python 3.11 or newer.
- Bind or connect to `rigctld` on loopback by default; never expose it publicly.
- Use Extended Response Protocol with a `|` response separator.
- Serialize all commands on one TCP connection.
- Never infer unsupported capabilities or fabricate meter values.
- Route every PTT-on request through `PttSafetySupervisor`.
- Mock mode must run without Hamlib, hardware, root, or network access.
- Hardware transmission requires an explicit opt-in flag.
- The workspace is not currently a Git repository; documented commit steps must not be run until the user initializes Git or explicitly authorizes commits.

---

## File Structure

- `server/pyproject.toml` — package metadata and test discovery settings.
- `server/remote_radio_server/rig/models.py` — immutable domain models and enums.
- `server/remote_radio_server/rig/errors.py` — typed protocol, transport, capability, and command errors.
- `server/remote_radio_server/rig/protocol.py` — incremental Extended Response Protocol parser.
- `server/remote_radio_server/rig/transport.py` — prioritized serialized TCP request worker.
- `server/remote_radio_server/rig/capabilities.py` — Hamlib discovery and normalization.
- `server/remote_radio_server/rig/state.py` — revisioned state store and polling service.
- `server/remote_radio_server/rig/commands.py` — validated writes and read-back confirmation.
- `server/remote_radio_server/rig/safety.py` — transmit lease and watchdog enforcement.
- `server/remote_radio_server/rig/supervisor.py` — lifecycle, reconnect, and resynchronization.
- `server/remote_radio_server/rig/launcher.py` — safe `rigctld` process arguments and optional subprocess lifecycle.
- `server/remote_radio_server/rig/extensions/base.py` — model-extension contract.
- `server/remote_radio_server/rig/extensions/ft710.py` — FT-710 capability supplement seam.
- `server/remote_radio_server/gateway.py` — JSON command and event mapping.
- `server/remote_radio_server/websocket.py` — bounded RFC 6455 text-frame transport.
- `server/remote_radio_server/server.py` — authenticated loopback WebSocket adapter.
- `server/remote_radio_server/mock_rigctld.py` — runnable no-hardware rig endpoint.
- `server/remote_radio_server/__main__.py` — mock or real control-plane entry point.
- `server/tests/rig/` — focused unit tests.
- `server/tests/rig/helpers.py` — shared scripted transports, clocks, identities, and response builders used by focused tests.
- `server/tests/fake_rigctld.py` — fault-injectable test server.
- `server/tests/integration/` — end-to-end and optional Hamlib dummy tests.
- `server/tests/integration/helpers.py` — running mock application and WebSocket client fixtures.
- `docs/HAMLIB.md` — operator and developer guide.
- `docs/SAFETY.md` — PTT invariants and hardware checklist.

### Task 1: Package Foundation and Domain Models

**Files:**
- Create: `server/pyproject.toml`
- Create: `server/remote_radio_server/__init__.py`
- Create: `server/remote_radio_server/rig/__init__.py`
- Create: `server/remote_radio_server/rig/models.py`
- Create: `server/remote_radio_server/rig/errors.py`
- Create: `server/tests/rig/helpers.py`
- Test: `server/tests/rig/test_models.py`

**Interfaces:**
- Consumes: Python standard library only.
- Produces: `Lifecycle`, `CommandPriority`, `RigResponse`, `RigIdentity`, `RigCapabilities`, `RigState`, `StateDelta`, and `CommandResult`.

- [ ] **Step 1: Write the failing domain-model test**

```python
from dataclasses import FrozenInstanceError
import unittest

from remote_radio_server.rig.models import Lifecycle, RigState


class RigStateTests(unittest.TestCase):
    def test_state_is_immutable_and_starts_offline(self):
        state = RigState()
        self.assertEqual(Lifecycle.OFFLINE, state.lifecycle)
        self.assertEqual(0, state.revision)
        with self.assertRaises(FrozenInstanceError):
            state.revision = 1
```

- [ ] **Step 2: Run the test and confirm the import fails**

Run: `cd server && python -m unittest tests.rig.test_models -v`  
Expected: `ModuleNotFoundError` for `remote_radio_server.rig.models`.

- [ ] **Step 3: Implement package metadata, errors, enums, and frozen dataclasses**

```python
from enum import IntEnum, StrEnum


class CommandPriority(IntEnum):
    EMERGENCY = 0
    USER_WRITE = 10
    USER_READ = 20
    DISCOVERY = 30
    POLLING = 40


class Lifecycle(StrEnum):
    OFFLINE = "offline"
    CONNECTING = "connecting"
    DISCOVERING = "discovering"
    READY = "ready"
    DEGRADED = "degraded"
    LOCKED_OUT = "locked_out"


@dataclass(frozen=True, slots=True)
class RigResponse:
    command: str
    fields: tuple[tuple[str, str], ...]
    report: int

    def get(self, key: str, default: str | None = None) -> str | None:
        return dict(self.fields).get(key, default)


@dataclass(frozen=True, slots=True)
class RigIdentity:
    manufacturer: str
    model: str
    model_id: int | None
    backend_version: str | None
    hamlib_version: str | None


@dataclass(frozen=True, slots=True)
class RigCapabilities:
    identity: RigIdentity
    vfos: frozenset[str] = frozenset()
    modes: frozenset[str] = frozenset()
    readable_levels: frozenset[str] = frozenset()
    writable_levels: frozenset[str] = frozenset()
    readable_functions: frozenset[str] = frozenset()
    writable_functions: frozenset[str] = frozenset()
    readable_parameters: frozenset[str] = frozenset()
    writable_parameters: frozenset[str] = frozenset()
    vfo_operations: frozenset[str] = frozenset()
    targetable_features: frozenset[str] = frozenset()
    passbands_hz: tuple[tuple[str, int], ...] = ()
    rx_ranges_hz: tuple[tuple[int, int], ...] = ()
    tx_ranges_hz: tuple[tuple[int, int], ...] = ()
    supports_ptt_read: bool = False
    supports_ptt_write: bool = False


@dataclass(frozen=True, slots=True)
class RigState:
    lifecycle: Lifecycle = Lifecycle.OFFLINE
    revision: int = 0
    frequency_hz: int | None = None
    mode: str | None = None
    passband_hz: int | None = None
    vfo: str | None = None
    split_enabled: bool = False
    split_frequency_hz: int | None = None
    split_mode: str | None = None
    ptt: bool = False
    meters: tuple[tuple[str, float], ...] = ()


@dataclass(frozen=True, slots=True)
class StateDelta:
    revision: int
    changes: tuple[tuple[str, object], ...]


@dataclass(frozen=True, slots=True)
class CommandResult:
    status: str
    message: str
    revision: int | None = None
    hamlib_code: int | None = None

    @classmethod
    def rejected(cls, status: str, message: str) -> "CommandResult":
        return cls(status=status, message=message)


class RigError(Exception):
    """Base radio-control error."""


class RigProtocolError(RigError):
    """Malformed or oversized rigctld response."""


class RigTransportError(RigError):
    """TCP connection or request-timeout failure."""
```

`server/tests/rig/helpers.py` defines `response(command, **fields)`, `ok(command)`, `value(command, **fields)`, `fixture_response(name)`, `ScriptedTransport`, `FakeClock`, `RecordingPtt`, and `identity(manufacturer, model)` with the exact model types above. Later tasks extend this helper file only when their own test requires a new constructor.

- [ ] **Step 4: Run all Task 1 tests**

Run: `cd server && python -m unittest tests.rig.test_models -v`  
Expected: all tests pass.

- [ ] **Step 5: Record the intended commit**

Commit message after Git is authorized: `feat: add radio control domain models`

### Task 2: Extended Response Protocol Parser

**Files:**
- Create: `server/remote_radio_server/rig/protocol.py`
- Test: `server/tests/rig/test_protocol.py`

**Interfaces:**
- Consumes: `RigResponse` and `RigProtocolError`.
- Produces: `ExtendedResponseParser.feed(data: bytes) -> tuple[RigResponse, ...]` and `encode_command(command: str) -> bytes`.

- [ ] **Step 1: Write parser tests for fragmentation, multiple responses, and faults**

```python
class ExtendedResponseParserTests(unittest.TestCase):
    def test_fragmented_mode_response(self):
        parser = ExtendedResponseParser()
        self.assertEqual((), parser.feed(b"get_mode:|Mode: US"))
        responses = parser.feed(b"B|Passband: 2400|RPRT 0|")
        self.assertEqual("get_mode", responses[0].command)
        self.assertEqual((("Mode", "USB"), ("Passband", "2400")), responses[0].fields)
        self.assertEqual(0, responses[0].report)

    def test_rejects_response_without_header(self):
        parser = ExtendedResponseParser(max_buffer_bytes=64)
        with self.assertRaises(RigProtocolError):
            parser.feed(b"Mode: USB|RPRT 0|")
```

- [ ] **Step 2: Run tests and confirm parser symbols are missing**

Run: `cd server && python -m unittest tests.rig.test_protocol -v`  
Expected: import failure.

- [ ] **Step 3: Implement bounded incremental parsing**

```python
def encode_command(command: str) -> bytes:
    if "\n" in command or "\r" in command:
        raise ValueError("rigctld commands must be one line")
    return f"|{command}\n".encode("ascii")


class ExtendedResponseParser:
    def __init__(self, max_buffer_bytes: int = 262_144):
        self._buffer = ""
        self._records: list[str] = []
        self._max_buffer_bytes = max_buffer_bytes

    def feed(self, data: bytes) -> tuple[RigResponse, ...]:
        self._buffer += data.decode("utf-8", errors="strict")
        if len(self._buffer.encode()) > self._max_buffer_bytes:
            raise RigProtocolError("response exceeds configured limit")
        completed: list[RigResponse] = []
        while "|" in self._buffer:
            record, self._buffer = self._buffer.split("|", 1)
            if record:
                self._records.append(record)
            if record.startswith("RPRT "):
                completed.append(self._finish_response())
        return tuple(completed)
```

- [ ] **Step 4: Run parser tests**

Run: `cd server && python -m unittest tests.rig.test_protocol -v`  
Expected: fragmentation, batching, negative `RPRT`, overflow, and malformed-header tests pass.

- [ ] **Step 5: Record the intended commit**

Commit message after Git is authorized: `feat: parse hamlib extended responses`

### Task 3: Fake Rig and Serialized TCP Transport

**Files:**
- Create: `server/tests/fake_rigctld.py`
- Create: `server/remote_radio_server/rig/transport.py`
- Test: `server/tests/rig/test_transport.py`

**Interfaces:**
- Consumes: `encode_command`, `ExtendedResponseParser`, `CommandPriority`, and `RigResponse`.
- Produces: `RigctldTransport.start()`, `close()`, and `request(command, priority, timeout_s)`.

- [ ] **Step 1: Write an async transport test with fragmented server output**

```python
class RigctldTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_serializes_requests_and_parses_fragmented_response(self):
        async with FakeRigctld({"\\get_freq": [b"get_freq:|Frequency: ", b"14074000|RPRT 0|"]}) as fake:
            transport = RigctldTransport(fake.host, fake.port)
            await transport.start()
            response = await transport.request("\\get_freq")
            self.assertEqual("14074000", response.get("Frequency"))
            self.assertEqual(["|\\get_freq\n"], fake.received)
            await transport.close()
```

- [ ] **Step 2: Run the focused transport test and confirm failure**

Run: `cd server && python -m unittest tests.rig.test_transport -v`  
Expected: missing fake server and transport symbols.

- [ ] **Step 3: Implement the fake endpoint and priority worker**

```python
async def request(
    self,
    command: str,
    priority: CommandPriority = CommandPriority.USER_READ,
    timeout_s: float = 1.5,
) -> RigResponse:
    loop = asyncio.get_running_loop()
    future: asyncio.Future[RigResponse] = loop.create_future()
    await self._queue.put((int(priority), next(self._sequence), command, timeout_s, future))
    return await future
```

The worker writes exactly one encoded command, reads until one complete response arrives, raises `RigReportError` for a non-zero report, and fails every queued future with `RigTransportClosed` during shutdown.

- [ ] **Step 4: Run transport tests including priority and timeout cases**

Run: `cd server && python -m unittest tests.rig.test_transport -v`  
Expected: all tests pass and emergency priority is processed before queued polling work.

- [ ] **Step 5: Record the intended commit**

Commit message after Git is authorized: `feat: add serialized rigctld transport`

### Task 4: Dynamic Capability Discovery

**Files:**
- Create: `server/remote_radio_server/rig/capabilities.py`
- Test: `server/tests/rig/test_capabilities.py`
- Create: `server/tests/fixtures/ft710_caps.txt`
- Create: `server/tests/fixtures/dummy_caps.txt`

**Interfaces:**
- Consumes: an object with `request(command, priority, timeout_s)` and `RigCapabilities`.
- Produces: `CapabilityService.discover() -> RigCapabilities` and `parse_dump_caps(fields) -> CapabilityDraft`.

- [ ] **Step 1: Write tests proving controls come from discovery data**

```python
class CapabilityServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_discovers_read_and_write_tokens_without_fabricated_swr(self):
        transport = ScriptedTransport({
            "\\hamlib_version": response("hamlib_version", Version="4.6.5"),
            "\\dump_caps": fixture_response("dummy_caps.txt"),
            "\\get_mode ?": response("get_mode", Mode="AM FM USB LSB"),
            "\\get_level ?": response("get_level", Level="STRENGTH AF"),
            "\\set_level ?": response("set_level", Level="AF RFPOWER"),
            "\\get_func ?": response("get_func", Func="NB NR"),
            "\\set_func ?": response("set_func", Func="NB NR"),
        })
        caps = await CapabilityService(transport).discover()
        self.assertIn("STRENGTH", caps.readable_levels)
        self.assertNotIn("SWR", caps.readable_levels)
        self.assertIn("RFPOWER", caps.writable_levels)
```

- [ ] **Step 2: Run capability tests and confirm failure**

Run: `cd server && python -m unittest tests.rig.test_capabilities -v`  
Expected: missing service.

- [ ] **Step 3: Implement tolerant discovery and normalization**

```python
async def _tokens(self, command: str, field: str) -> frozenset[str]:
    try:
        response = await self._transport.request(command, CommandPriority.DISCOVERY, 2.0)
    except RigReportError as error:
        if error.is_unsupported:
            return frozenset()
        raise
    return frozenset(response.get(field, "").split())
```

`discover()` requests version and caps first, then token queries. It omits unknown ranges and bounds, records backend identity, and never sends a mutating command.

- [ ] **Step 4: Run capability tests and fixture coverage**

Run: `cd server && python -m unittest tests.rig.test_capabilities -v`  
Expected: FT-710 and dummy fixtures normalize deterministically.

- [ ] **Step 5: Record the intended commit**

Commit message after Git is authorized: `feat: discover hamlib rig capabilities`

### Task 5: Revisioned State and Adaptive Polling

**Files:**
- Create: `server/remote_radio_server/rig/state.py`
- Modify: `server/tests/rig/helpers.py`
- Test: `server/tests/rig/test_state.py`

**Interfaces:**
- Consumes: `RigCapabilities`, `RigState`, and transport requests.
- Produces: `RigStateStore.apply(values) -> StateDelta | None`, `snapshot()`, and `RigStateService.poll_once(transmitting)`.
- Test helper: `make_state_service(readable_levels: set[str]) -> StateServiceHarness`, whose `transport.commands` records requested Hamlib commands.

- [ ] **Step 1: Write tests for coalescing, revisions, and TX meter selection**

```python
class RigStateStoreTests(unittest.TestCase):
    def test_unchanged_values_do_not_advance_revision(self):
        store = RigStateStore(RigState())
        first = store.apply({"frequency_hz": 14_074_000})
        self.assertEqual(1, first.revision)
        self.assertIsNone(store.apply({"frequency_hz": 14_074_000}))

class RigPollingTests(unittest.IsolatedAsyncioTestCase):
    async def test_tx_poll_reads_swr_only_when_supported(self):
        service = make_state_service(readable_levels={"SWR", "ALC"})
        await service.poll_once(transmitting=True)
        self.assertIn("\\get_level SWR", service.transport.commands)
```

- [ ] **Step 2: Run state tests and confirm missing implementation**

Run: `cd server && python -m unittest tests.rig.test_state -v`  
Expected: import failure.

- [ ] **Step 3: Implement atomic state application and poll plans**

```python
def apply(self, values: Mapping[str, object]) -> StateDelta | None:
    changes = {key: value for key, value in values.items() if getattr(self._state, key) != value}
    if not changes:
        return None
    revision = self._state.revision + 1
    self._state = replace(self._state, revision=revision, **changes)
    return StateDelta(revision=revision, changes=tuple(sorted(changes.items())))
```

The poller uses frequency/mode/VFO/PTT reads for core state, adds only discovered meters, applies 5 Hz/2 Hz/10 Hz intervals, and yields to queued user writes.

- [ ] **Step 4: Run state and polling tests**

Run: `cd server && python -m unittest tests.rig.test_state -v`  
Expected: all tests pass.

- [ ] **Step 5: Record the intended commit**

Commit message after Git is authorized: `feat: add revisioned rig state polling`

### Task 6: Validated Commands and Read-Back Confirmation

**Files:**
- Create: `server/remote_radio_server/rig/commands.py`
- Modify: `server/tests/rig/helpers.py`
- Test: `server/tests/rig/test_commands.py`

**Interfaces:**
- Consumes: transport, `RigCapabilities`, and `RigStateStore`.
- Produces: `set_frequency`, `set_mode`, `set_level`, `set_func`, `set_split`, and `send_raw_admin` returning `CommandResult`.
- Test helper: `make_command_service(*, tx_ranges=(), script=()) -> CommandServiceHarness`, whose transport records requests and consumes scripted responses in order.

- [ ] **Step 1: Write tests for rejection and confirmed writes**

```python
class RigCommandServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_rejects_frequency_outside_tx_range_before_transport(self):
        service = make_command_service(tx_ranges=((14_000_000, 14_350_000),))
        result = await service.set_frequency(50_000_000, transmitting=True)
        self.assertEqual("invalid", result.status)
        self.assertEqual([], service.transport.commands)

    async def test_frequency_write_is_read_back(self):
        service = make_command_service(script=[ok("set_freq"), value("get_freq", Frequency="14074000")])
        result = await service.set_frequency(14_074_000, transmitting=False)
        self.assertEqual("confirmed", result.status)
        self.assertEqual(("\\set_freq 14074000", "\\get_freq"), tuple(service.transport.commands))
```

- [ ] **Step 2: Run command tests and confirm failure**

Run: `cd server && python -m unittest tests.rig.test_commands -v`  
Expected: missing command service.

- [ ] **Step 3: Implement validation, typed outcomes, and an 80 ms frequency coalescer**

```python
async def set_mode(self, mode: str, passband_hz: int = 0) -> CommandResult:
    normalized = mode.upper()
    if normalized not in self._caps.modes:
        return CommandResult.rejected("unsupported", f"mode {normalized} is unavailable")
    await self._transport.request(f"\\set_mode {normalized} {passband_hz}", CommandPriority.USER_WRITE)
    confirmed = await self._transport.request("\\get_mode", CommandPriority.USER_READ)
    return self._confirm_mode(confirmed)
```

Raw commands require `is_admin=True`, reject newline characters, cap input at 4 KiB, and are written to the audit sink.

- [ ] **Step 4: Run command tests including debounce and unknown-result cases**

Run: `cd server && python -m unittest tests.rig.test_commands -v`  
Expected: all tests pass.

- [ ] **Step 5: Record the intended commit**

Commit message after Git is authorized: `feat: validate and confirm rig commands`

### Task 7: PTT Lease and Four Watchdogs

**Files:**
- Create: `server/remote_radio_server/rig/safety.py`
- Test: `server/tests/rig/test_safety.py`

**Interfaces:**
- Consumes: an emergency `set_ptt(enabled: bool)` callable, state snapshots, monotonic clock, and audit sink.
- Produces: `acquire_lease`, `heartbeat`, `request_ptt`, `client_disconnected`, `transport_fault`, and `evaluate`.

```python
@dataclass(frozen=True, slots=True)
class PttTrip:
    reason: str
    at_monotonic: float
```

- [ ] **Step 1: Write deterministic tests for all trip paths**

```python
class PttSafetyTests(unittest.IsolatedAsyncioTestCase):
    async def test_heartbeat_timeout_forces_ptt_off(self):
        clock = FakeClock()
        radio = RecordingPtt()
        safety = PttSafetySupervisor(radio.set_ptt, clock=clock)
        lease = safety.acquire_lease("device-1")
        await safety.request_ptt(lease, True)
        clock.advance(10.1)
        await safety.evaluate(swr=None)
        self.assertEqual([True, False], radio.calls)
        self.assertEqual("heartbeat_timeout", safety.last_trip.reason)
```

Add independent tests for disconnect, 180-second hard limit, SWR breach, transport fault, shutdown, lockout, and lease contention.

- [ ] **Step 2: Run safety tests and confirm failure**

Run: `cd server && python -m unittest tests.rig.test_safety -v`  
Expected: missing supervisor.

- [ ] **Step 3: Implement the single-owner lease and idempotent emergency off**

```python
async def _trip(self, reason: str) -> None:
    if self._ptt_on:
        await self._set_ptt(False)
    self._ptt_on = False
    self._lockout_until = self._clock() + 3.0
    self.last_trip = PttTrip(reason=reason, at_monotonic=self._clock())
    self._audit("ptt.trip", {"reason": reason})
```

`request_ptt(True)` checks lease identity, rig readiness, heartbeat age, lockout, and TX range. `request_ptt(False)` is always allowed and idempotent.

- [ ] **Step 4: Run safety tests and race cases**

Run: `cd server && python -m unittest tests.rig.test_safety -v`  
Expected: every watchdog independently forces PTT-off.

- [ ] **Step 5: Record the intended commit**

Commit message after Git is authorized: `feat: enforce ptt safety watchdogs`

### Task 8: Lifecycle Supervisor, Launcher, and FT-710 Extension Seam

**Files:**
- Create: `server/remote_radio_server/rig/supervisor.py`
- Create: `server/remote_radio_server/rig/launcher.py`
- Create: `server/remote_radio_server/rig/extensions/__init__.py`
- Create: `server/remote_radio_server/rig/extensions/base.py`
- Create: `server/remote_radio_server/rig/extensions/ft710.py`
- Test: `server/tests/rig/test_supervisor.py`
- Test: `server/tests/rig/test_launcher.py`
- Test: `server/tests/rig/test_ft710_extension.py`

**Interfaces:**
- Consumes: transport factory, capability service, state service, safety supervisor, and rig identity.
- Produces: `RigSupervisor.run()`, lifecycle events, `build_rigctld_args(config)`, and `extension_for(identity)`.

```python
@dataclass(frozen=True, slots=True)
class RigctldConfig:
    model_id: int
    device: str
    baud: int | None = None
    host: str = "127.0.0.1"
    port: int = 4532
    hardware_tx_enabled: bool = False
```

- [ ] **Step 1: Write reconnect, safe-argument, and identity-match tests**

```python
class RigctldLauncherTests(unittest.TestCase):
    def test_binds_loopback_and_preserves_explicit_device(self):
        args = build_rigctld_args(RigctldConfig(model_id=1049, device="/dev/ttyUSB0", baud=38400))
        self.assertEqual("127.0.0.1", args[args.index("-T") + 1])
        self.assertEqual("/dev/ttyUSB0", args[args.index("-r") + 1])

class ExtensionTests(unittest.TestCase):
    def test_ft710_extension_requires_exact_identity(self):
        self.assertIsInstance(extension_for(identity("Yaesu", "FT-710")), Ft710Extension)
        self.assertIsNone(extension_for(identity("Yaesu", "FTDX10")))
```

- [ ] **Step 2: Run supervisor, launcher, and extension tests**

Run: `cd server && python -m unittest tests.rig.test_supervisor tests.rig.test_launcher tests.rig.test_ft710_extension -v`  
Expected: missing modules.

- [ ] **Step 3: Implement reconnect and resynchronization**

```python
async def run(self) -> None:
    delay = 0.25
    while not self._closing:
        try:
            await self._set_lifecycle(Lifecycle.CONNECTING)
            await self._transport.start()
            await self._set_lifecycle(Lifecycle.DISCOVERING)
            self.capabilities = await self._capability_service.discover()
            await self._state_service.full_refresh()
            await self._set_lifecycle(Lifecycle.READY)
            delay = 0.25
            await self._transport.wait_closed()
        except (RigTransportError, RigProtocolError):
            await self._safety.transport_fault()
            await self._set_lifecycle(Lifecycle.DEGRADED)
            await self._sleep(self._jitter(delay))
            delay = min(delay * 2, 5.0)
```

The FT-710 extension exposes explicit raw query/tune methods but never runs during discovery and never bypasses the safety supervisor.

- [ ] **Step 4: Run fault-injection tests**

Run: `cd server && python -m unittest tests.rig.test_supervisor tests.rig.test_launcher tests.rig.test_ft710_extension -v`  
Expected: reconnect publishes a fresh snapshot before accepting writes; launcher never binds `0.0.0.0` by default.

- [ ] **Step 5: Record the intended commit**

Commit message after Git is authorized: `feat: supervise hamlib lifecycle and extensions`

### Task 9: Message Gateway, Runnable Mock, and End-to-End Acceptance

**Files:**
- Create: `server/remote_radio_server/gateway.py`
- Create: `server/remote_radio_server/mock_rigctld.py`
- Create: `server/remote_radio_server/__main__.py`
- Test: `server/tests/test_gateway.py`
- Test: `server/tests/integration/test_mock_control_plane.py`
- Test: `server/tests/integration/test_hamlib_dummy.py`
- Create: `server/tests/integration/helpers.py`
- Create: `docs/HAMLIB.md`
- Create: `docs/SAFETY.md`

**Interfaces:**
- Consumes: command service, state service, capability document, supervisor lifecycle, and PTT safety supervisor.
- Produces: `RigMessageGateway.handle(principal, message) -> dict`, event dictionaries, `python -m remote_radio_server --mock`, and optional `--rigctld-host` operation.

```python
@dataclass(frozen=True, slots=True)
class Principal:
    device_id: str
    is_admin: bool = False


USER = Principal(device_id="test-device")
```

`server/tests/integration/helpers.py` provides `running_mock_control_plane()` as an async context manager returning an object with `gateway`, `safety`, `supervisor`, and `mock_rig` attributes.

- [ ] **Step 1: Write a full mock-flow test**

```python
class MockControlPlaneTests(unittest.IsolatedAsyncioTestCase):
    async def test_discover_control_and_disconnect_trip(self):
        async with running_mock_control_plane() as app:
            caps = await app.gateway.initial_event()
            self.assertEqual("rig.capabilities", caps["type"])
            result = await app.gateway.handle(USER, {
                "type": "rig.command",
                "request_id": "r1",
                "command": "set_frequency",
                "frequency_hz": 14_074_000,
            })
            self.assertEqual("confirmed", result["status"])
            lease = await app.gateway.handle(USER, {"type": "ptt.lease"})
            await app.gateway.handle(USER, {"type": "ptt.set", "lease_id": lease["lease_id"], "enabled": True})
            await app.gateway.client_disconnected(USER.device_id)
            self.assertFalse(app.safety.ptt_on)
```

- [ ] **Step 2: Run gateway and integration tests and confirm failure**

Run: `cd server && python -m unittest tests.test_gateway tests.integration.test_mock_control_plane -v`  
Expected: missing gateway and entry point.

- [ ] **Step 3: Implement strict JSON routing and mock startup**

```python
async def handle(self, principal: Principal, message: Mapping[str, object]) -> dict[str, object]:
    message_type = require_string(message, "type")
    if message_type == "rig.command":
        return await self._handle_rig_command(principal, message)
    if message_type == "ptt.lease":
        return self._lease_event(principal)
    if message_type == "ptt.heartbeat":
        return self._heartbeat_event(principal, message)
    if message_type == "ptt.set":
        return await self._ptt_event(principal, message)
    raise GatewayError("unsupported_message", message_type)
```

`--mock` starts the bundled fake endpoint, discovers it through the real transport, prints a JSON capability event, and accepts newline-delimited JSON commands on standard input. `test_hamlib_dummy` skips unless `rigctld` is on `PATH`.

- [ ] **Step 4: Run the complete suite and smoke command**

Run: `cd server && python -m unittest discover -s tests -v`  
Expected: all unit and mock integration tests pass; Hamlib dummy test either passes or reports an explicit skip.

Run: `cd server && python -m remote_radio_server --mock --once`  
Expected: exit code 0 and one `rig.capabilities` plus one `rig.snapshot` JSON object.

- [ ] **Step 5: Write operator documentation and record the intended commit**

Document loopback binding, model/device/baud configuration, supported control messages, the no-hardware mock command, dummy-rig testing, PTT trip conditions, and the FT-710 dummy-load checklist.

Commit message after Git is authorized: `feat: deliver runnable hamlib control plane`

### Task 10: Authenticated Loopback WebSocket Adapter

**Files:**
- Create: `server/remote_radio_server/websocket.py`
- Create: `server/remote_radio_server/server.py`
- Modify: `server/remote_radio_server/__main__.py`
- Modify: `server/tests/integration/helpers.py`
- Test: `server/tests/test_websocket.py`
- Test: `server/tests/integration/test_websocket_control_plane.py`

**Interfaces:**
- Consumes: `RigMessageGateway`, JSON dictionaries, a configured device-token map, and supervisor events.
- Produces: `WebSocketFrameReader`, `encode_text_frame`, and `RemoteRadioServer.serve(host="127.0.0.1", port=8765)`.

- [ ] **Step 1: Write frame, authentication, and end-to-end tests**

```python
class WebSocketFrameTests(unittest.IsolatedAsyncioTestCase):
    async def test_decodes_fragmented_masked_text_frame(self):
        reader = WebSocketFrameReader(max_payload_bytes=1_048_576)
        wire = masked_client_text('{"type":"rig.snapshot"}')
        self.assertEqual((), reader.feed(wire[:5]))
        frames = reader.feed(wire[5:])
        self.assertEqual('{"type":"rig.snapshot"}', frames[0].text)


class WebSocketControlPlaneTests(unittest.IsolatedAsyncioTestCase):
    async def test_auth_then_frequency_command(self):
        async with running_websocket_control_plane(token="secret") as client:
            await client.send_json({"type": "auth", "device_id": "phone", "token": "secret"})
            self.assertEqual("auth.ok", (await client.receive_json())["type"])
            await client.send_json({"type": "rig.command", "request_id": "r1", "command": "set_frequency", "frequency_hz": 14_074_000})
            self.assertEqual("confirmed", (await client.receive_json())["status"])
```

- [ ] **Step 2: Run WebSocket tests and confirm missing implementation**

Run: `cd server && python -m unittest tests.test_websocket tests.integration.test_websocket_control_plane -v`  
Expected: missing frame and server modules.

- [ ] **Step 3: Implement bounded RFC 6455 control frames and authentication**

```python
async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    await perform_server_handshake(reader, writer)
    auth_message = await receive_json(reader, max_payload_bytes=1_048_576)
    principal = self._authorizer.authenticate(auth_message)
    await send_json(writer, {"type": "auth.ok", "device_id": principal.device_id})
    try:
        async for message in iter_json_messages(reader, max_payload_bytes=1_048_576):
            result = await self._gateway.handle(principal, message)
            await send_json(writer, result)
    finally:
        await self._gateway.client_disconnected(principal.device_id)
```

Reject unmasked client frames, control payloads over 1 MiB, invalid UTF-8, unsupported opcodes, and unauthenticated commands. Respond to ping, complete the close handshake, and reserve binary frames without interpreting them.

- [ ] **Step 4: Run WebSocket and full-suite tests**

Run: `cd server && python -m unittest discover -s tests -v`  
Expected: all tests pass; an unauthorized client is closed and disconnecting an authenticated transmitting client forces PTT-off.

- [ ] **Step 5: Record the intended commit**

Commit message after Git is authorized: `feat: expose authenticated radio websocket`

## Final Verification

- [ ] Run `cd server && python -m unittest discover -s tests -v`.
- [ ] Run `cd server && python -m remote_radio_server --mock --once`.
- [ ] Run `cd server && python -m remote_radio_server --mock --serve --host 127.0.0.1` and complete one authenticated WebSocket frequency command.
- [ ] Run `cd server && python -m compileall remote_radio_server tests`.
- [ ] Search source and docs for unfinished work markers and unguarded `set_ptt` calls.
- [ ] Confirm no process listens on a non-loopback address.
- [ ] Confirm hardware integration tests remain skipped without explicit device and acknowledgement flags.
