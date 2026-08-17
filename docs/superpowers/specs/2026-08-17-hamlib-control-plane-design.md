# Remote Radio Hamlib Control Plane Design

**Date:** 2026-08-17  
**Status:** Awaiting user review  
**Scope:** First implementation slice of the Remote Radio system

## 1. Goal

Build a production-oriented Hamlib control plane for Remote Radio. Yaesu FT-710 is the first supported physical rig, while the public server model remains capability-driven so other `rigctld` radios work without UI or protocol forks.

This slice owns radio discovery, state, commands, safety, recovery, and client-facing capability metadata. Audio, FT8 DSP, iOS media handling, and external tuner hardware remain later slices, but their interfaces consume the state and safety contracts defined here.

## 2. Product Behavior

The server starts in either mock mode or real-rig mode. A client sees only controls the connected rig can actually support. Front-panel changes are reflected back to every connected client. Commands return confirmed state or a specific failure; the UI never presents an unsupported feature as successful.

The first usable path is:

1. Start a mock `rigctld`-compatible endpoint or connect to `127.0.0.1:4532`.
2. Negotiate protocol/version information.
3. Discover capabilities without transmitting or changing rig state.
4. Publish an initial state snapshot and normalized capability document.
5. Accept validated frequency, mode, VFO, level, function, split, and PTT requests.
6. Maintain state through polling, read-back confirmation, and reconnect resynchronization.
7. Force PTT off whenever a safety invariant fails.

## 3. Architecture

The implementation is a Python 3.11 `asyncio` package with focused units:

### `RigctldTransport`

- Owns one TCP connection and the Extended Response Protocol parser.
- Serializes requests because responses are ordered on a stream.
- Uses a request priority queue: emergency PTT-off, user writes, explicit reads, background polling.
- Applies bounded command timeouts and maximum response sizes.
- Parses command echo, `key: value` records, multi-record responses, and terminal `RPRT` status.
- Treats unsolicited or malformed records as protocol faults and reconnects cleanly.

### `RigSupervisor`

- Owns transport lifecycle and reconnection.
- Uses exponential retry delays from 250 ms to 5 seconds with jitter.
- Performs a complete capability and state resynchronization after reconnect.
- Publishes lifecycle states: `offline`, `connecting`, `discovering`, `ready`, `degraded`, and `locked_out`.
- Never blindly retries non-idempotent mutations. PTT-off is the only mutation automatically retried because it is an idempotent safety action.

### `CapabilityService`

- Reads `hamlib_version`, `dump_caps`, supported modes, readable/writable levels, functions, parameters, VFOs, and VFO operations.
- Uses read-only `?` queries where supported, including mode, level, function, parameter, and VFO-operation token discovery.
- Normalizes Hamlib output into a stable application model instead of exposing raw strings to clients.
- Captures RX/TX frequency ranges, filters/passbands, targetable VFO features, split support, PTT support, and meter availability.
- Persists a cache keyed by Hamlib version, model ID, manufacturer, model name, and backend version. The cache accelerates startup but never replaces a live read-only probe.
- Exposes a `raw_command` capability only to authenticated administrator sessions.

### `RigStateService`

- Maintains the authoritative last confirmed rig state.
- Polls frequency, mode, passband, VFO, split state, PTT, supported meters, levels, and functions at configurable rates.
- Uses 5 Hz for tuning-critical RX state, 2 Hz for ordinary meters, and up to 10 Hz for SWR/ALC/power while transmitting.
- Coalesces unchanged values and publishes WebSocket deltas plus periodic full snapshots.
- Treats front-panel state as authoritative when a read differs from the cache.
- Suspends low-priority polling during transport recovery or command pressure.

### `RigCommandService`

- Validates every request against discovered capabilities, frequency ranges, allowed tokens, and configured safety limits.
- Debounces rapid tuning input and sends only the latest requested frequency after an 80 ms window.
- Waits for `RPRT 0`, then reads back critical values such as frequency, mode, VFO, split, and PTT.
- Returns typed outcomes: `confirmed`, `unsupported`, `invalid`, `busy`, `offline`, `timeout`, `rejected`, or `hardware_error`.
- Provides a separate administrative raw-command path backed by Hamlib `send_raw` or `send_cmd` semantics.

### `PttSafetySupervisor`

- Is the only component permitted to request PTT-on.
- Requires an authenticated single-client transmit lease, a ready rig, a supported transmit mode, and a healthy heartbeat.
- Forces PTT-off on client disconnect, heartbeat loss after 10 seconds, hard transmit duration of 180 seconds, configured SWR threshold breach, server shutdown, or rig transport fault.
- Polls SWR, ALC, and forward power at up to 10 Hz while transmitting when supported.
- Locks out retransmission for at least 3 seconds after an SWR trip and requires the meter to return below the reset threshold.
- Records every PTT transition and trip reason in an append-only audit log.

### `RigExtension`

- Adds model-specific behavior only when Hamlib does not expose the required capability.
- The FT-710 extension may use raw commands for tuner status or other verified gaps.
- Extensions cannot bypass validation, PTT safety, transport serialization, or audit logging.
- A model extension declares the exact manufacturer/model match and the feature it supplements.

## 4. Capability Model

The client-facing capability document contains:

- Rig identity and Hamlib/backend versions.
- Supported VFOs, modes, mode passbands, RX ranges, and TX ranges.
- Readable and writable levels with value type, unit, and known bounds.
- Readable and writable functions and parameters.
- Supported VFO operations and split controls.
- PTT read/write support and configured PTT mechanism.
- Available meters such as strength, SWR, ALC, RF power, and raw meter values.
- Targetable VFO behavior when the backend exposes it.
- Optional model-extension features.
- Poll-rate hints and UI presentation hints derived from semantics, never from a hard-coded screen layout.

Unknown fields are omitted rather than populated with fabricated defaults.

## 5. Data Flow

For a normal write:

1. WebSocket authentication identifies the device and permissions.
2. `RigCommandService` validates the request against capability and safety state.
3. The request enters the serialized transport queue.
4. `RigctldTransport` sends one extended-protocol command and parses through terminal `RPRT`.
5. Critical writes are read back.
6. `RigStateService` updates confirmed state and broadcasts one delta with a monotonic revision.
7. The requesting client receives the same revision and command outcome.

For emergency PTT-off, the safety request preempts queued work. If an active request is stuck, the supervisor closes the socket, reconnects, sends PTT-off first, and enters `degraded` until state is resynchronized.

## 6. Error Handling

- Hamlib `RPRT` values are mapped to typed domain errors while retaining the numeric code for diagnostics.
- Unsupported and unavailable operations are feature-level failures and do not disconnect the rig.
- Timeouts, connection loss, response overflow, and malformed protocol records are transport failures and trigger reconnect.
- Mutating commands that lose their response are reported as `unknown_result`; the server resynchronizes instead of assuming success or replaying them.
- Clients receive the last confirmed state, its age, connection lifecycle state, and a human-readable recovery action.
- Repeated transport failures trip a circuit breaker that slows retries but continues safety attempts.

## 7. Mock and Test Strategy

### Unit tests

- Extended response parsing with fragmented TCP reads, multiple records, separators, large `dump_caps` responses, malformed fields, and all terminal status cases.
- Capability normalization from multiple backend fixtures.
- Command validation for ranges, modes, writable/read-only features, and targetable VFO behavior.
- State coalescing, revisions, polling priorities, and stale-state detection.
- PTT heartbeat, disconnect, duration, SWR, shutdown, and reconnect races.

### Integration tests

- An in-process fake `rigctld` that implements the real extended response shape and supports fault injection.
- Hamlib dummy model integration through `rigctld -m 1` when Hamlib is installed.
- Full mock flow from discovery through WebSocket command, confirmed state delta, PTT-on, and forced PTT-off.

### Hardware acceptance

- Hardware tests are disabled by default and require an explicit device path plus an acknowledgement flag.
- Initial FT-710 validation uses a dummy load and starts with read-only discovery.
- PTT tests begin with minimum RF power and verify heartbeat loss, network disconnect, duration timeout, and SWR trip independently.

## 8. Public Protocol

The first WebSocket messages are:

- `rig.capabilities` — full normalized capability document.
- `rig.snapshot` — full confirmed state plus revision and age.
- `rig.delta` — changed values with the next revision.
- `rig.command` — validated client command with request ID.
- `rig.command_result` — typed outcome, Hamlib code when present, and confirmed revision.
- `rig.lifecycle` — connection and recovery state.
- `ptt.lease`, `ptt.heartbeat`, `ptt.state`, and `ptt.trip` — explicit transmit safety messages.

Binary WebSocket frames remain reserved for later audio transport.

## 9. Delivery Order

1. Protocol parser and fake `rigctld`.
2. Capability normalization and mock fixtures.
3. State polling and revisioned events.
4. Validated command service and read-back confirmation.
5. PTT lease and watchdog safety.
6. Real `rigctld` launcher/configuration and Hamlib dummy integration.
7. FT-710 extension seam and read-only hardware checklist.
8. Web UI binding to dynamic capabilities.

Audio, FT8, external tuner hardware, and the iOS client follow after this control plane passes its mock and dummy-rig acceptance tests.

## 10. Acceptance Criteria

- The complete flow runs without radio hardware through the fake endpoint.
- The same client code connects to an installed Hamlib dummy `rigctld`.
- Unsupported controls are absent from capability output and rejected server-side if sent manually.
- Front-panel-equivalent state changes made by the fake endpoint appear as revisioned deltas.
- Disconnect and heartbeat loss force PTT-off immediately when the transport is responsive.
- A stuck request cannot leave queued PTT-off waiting indefinitely.
- Reconnect produces a fresh capability/state snapshot before user writes are accepted.
- No hardware test can transmit without explicit opt-in.

## 11. Official References

- Hamlib latest `rigctld` manual: https://hamlib.sourceforge.net/snapshots/man1/rigctld.1.html
- Hamlib `rigctl` source manual: https://github.com/Hamlib/Hamlib/blob/master/doc/man1/rigctl.1
- Hamlib release notes: https://github.com/Hamlib/Hamlib/wiki/Download
