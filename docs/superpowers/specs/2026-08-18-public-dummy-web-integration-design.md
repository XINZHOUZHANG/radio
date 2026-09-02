# Remote Radio Public Dummy Web Integration Design

**Date:** 2026-08-18
**Status:** Approved for implementation
**Scope:** Browser-to-Debian acceptance path using the official Hamlib Dummy

## 1. Goal

Turn the approved dashboard prototype into a real, testable web client for the
existing Hamlib control plane. The acceptance stack runs on Debian from
`/opt/testradio`, exposes every test port on `0.0.0.0`, and uses the official
Hamlib Dummy backend so no radio, serial device, antenna, or RF path is touched.

The browser must display confirmed backend state rather than fabricated values.
Frequency and mode changes must travel through the WebSocket control plane,
reach the official Dummy `rigctld`, and appear in a subsequent read-back
snapshot.

## 2. Non-goals

This slice does not implement audio transport, FT8 orchestration, external
tuner control, rotor control, iOS packaging, TLS, or real-hardware PTT. Those
dashboard areas remain visible for product context but are disabled and marked
as unavailable.

This slice does not make public binding the default. Existing loopback-only
commands and tests retain their current behavior.

## 3. Approved Test Topology

One explicit public-Dummy test mode owns the three listeners:

| Port | Bind address | Purpose |
|---|---|---|
| `8080` | `0.0.0.0` | Static dashboard HTTP server |
| `8765` | `0.0.0.0` | Authenticated Remote Radio WebSocket service |
| `4532` | `0.0.0.0` | Unauthenticated official Hamlib Dummy `rigctld` |

The Python control plane connects to the Dummy through `127.0.0.1:4532` even
though Dummy also listens on every interface. The browser loads
`http://<debian-host>:8080` and derives its WebSocket URL as
`ws://<debian-host>:8765`.

Port `4532` is deliberately exposed at the user's request. `rigctld` provides
no application authentication, so this topology is permitted only when the
owned Hamlib model is model `1` (Dummy). It must never be reused for a physical
radio.

## 4. Public-Dummy Mode

Add a single explicit CLI mode, named `--public-dummy-test`, that:

1. Rejects `--mock`, real model/device options, hardware-TX flags, and custom
   non-Dummy launch settings.
2. Locates and launches the installed `rigctld` as model `1`, bound to
   `0.0.0.0:4532`.
3. Connects the Python runtime to `127.0.0.1:4532` and verifies that discovered
   identity is the official Dummy before starting browser-facing listeners.
4. Starts the WebSocket listener on `0.0.0.0:8765`.
5. Starts a fixed-directory static HTTP server on `0.0.0.0:8080` without a
   directory listing.
6. Generates a cryptographically random, process-lifetime device token in
   memory and prints the device ID, token, and test URL once at startup.
7. Owns and cleanly terminates only the child processes and listeners it
   started.

The default CLI continues to reject non-loopback WebSocket hosts. The lower
level listener API gains an explicit policy input so tests can prove that a
non-loopback bind is impossible outside public-Dummy mode.

The public-Dummy mode is plaintext HTTP and WebSocket by design. The token is
not embedded in HTML, a query string, a repository file, or a process argument.
It is entered by the tester and retained only in browser `sessionStorage`.

## 5. Web Application

Promote the approved rounded dashboard from the brainstorming workspace into a
versioned `web/` application in the repository. Use dependency-free HTML, CSS,
and JavaScript so Debian requires no frontend build tool.

Split responsibilities into small files:

- `web/index.html`: semantic dashboard structure and connection dialog.
- `web/styles.css`: existing visual direction plus connected, pending, error,
  and disabled states.
- `web/radio-client.js`: WebSocket lifecycle, authentication, request IDs,
  polling, response correlation, and reconnection.
- `web/dashboard.js`: DOM rendering and mapping user actions to typed client
  methods.

The page initially shows disconnected state and requests the temporary token.
After authentication it requests capabilities and a state snapshot, then polls
`rig.snapshot` every 500 ms. The polling approach is intentional for this slice:
the current runtime has no WebSocket state-publish subscription, while the
existing snapshot request already provides authoritative revisioned state.

## 6. Protocol Additions and Command Mapping

Add an authenticated request for current capabilities:

```json
{"type":"rig.capabilities"}
```

It returns the same normalized `rig.capabilities` document already produced by
the gateway's initial-event path. Existing message validation remains strict;
unknown fields are rejected.

The dashboard maps controls as follows:

- Band and memory buttons send `rig.command/set_frequency` with integer hertz.
- The mode selector is populated from discovered modes and sends
  `rig.command/set_mode`.
- Frequency, mode, lifecycle, revision, PTT read-back, and supported meters are
  rendered from `rig.snapshot`.
- A control remains pending until its `rig.command_result` arrives and a later
  snapshot confirms the value.
- Rejected, invalid, unsupported, hardware-error, and unknown results are shown
  without optimistic UI state.

Audio, FT8, tuner, and rotor controls are disabled with a visible "not connected
to backend" label. The PTT button is permanently disabled and no frontend code
may send `ptt.lease`, `ptt.heartbeat`, or `ptt.set`.

The backend starts without `--enable-hardware-tx` and without
`--acknowledge-transmit-risk`. A manually crafted WebSocket PTT-on sequence must
therefore fail with `hardware_tx_disabled`. Direct clients of public Dummy port
`4532` can only mutate the software Dummy and cannot reach RF hardware.

## 7. Connection and Error Behavior

The browser connection state machine is:

`disconnected -> connecting -> authenticating -> ready -> reconnecting`.

- Authentication failure clears the in-memory token, closes the socket, and
  reopens the token dialog.
- Network loss disables all supported write controls and retries after 0.5, 1,
  2, then at most 5 seconds.
- Each request has a unique bounded request ID and a three-second client
  timeout. Late responses do not update a different request.
- Snapshot revisions never move backward. A stale snapshot is ignored.
- A command error appears beside the affected control and in the connection
  activity area.
- HTTP or WebSocket startup failure shuts down the owned stack rather than
  leaving a partial public service running.
- If Dummy discovery fails or reports any model other than model `1`, ports
  `8080` and `8765` are never opened.

## 8. Testing Strategy

Implementation follows test-driven development.

### Python tests

- CLI validation proves public-Dummy mode rejects hardware TX, physical model
  and device arguments, and incompatible modes.
- Listener policy tests prove `0.0.0.0` is accepted only through the explicit
  public-Dummy policy.
- Gateway tests cover `rig.capabilities` request validation and response.
- Static-server tests cover `/`, CSS, JavaScript, traversal rejection, missing
  files, and disabled directory listing.
- Lifecycle tests prove a failed child/listener startup cleans up only owned
  resources.
- Integration tests use an official Dummy when `rigctld` is available and
  verify frequency and mode command/read-back through WebSocket.
- PTT-on through WebSocket is rejected while hardware TX remains disabled.

### JavaScript tests

Use Node's built-in test runner without third-party packages to cover URL
derivation, auth messages, request correlation, revision ordering, reconnect
backoff, command mapping, and the prohibition on PTT message construction.

### Debian acceptance

From `/opt/testradio` only:

1. Run the complete Python and JavaScript test suites.
2. Start public-Dummy mode.
3. Confirm `ss` reports `0.0.0.0:8080`, `0.0.0.0:8765`, and
   `0.0.0.0:4532`.
4. Confirm HTTP returns the dashboard assets.
5. Confirm an incorrect WebSocket token is rejected.
6. Confirm a valid browser session reads capabilities and snapshot state.
7. Change frequency and mode in the page and confirm the official Dummy returns
   the same values through a later snapshot.
8. Confirm the page emits no PTT messages and a crafted PTT-on request is
   rejected.
9. Stop the test stack and confirm its three listeners and owned child process
   are gone.

No acceptance step uses a serial device, physical radio, real PTT, or files
outside `/opt/testradio`.

## 9. Deployment Boundary

All repository checkout, logs, token-display output, PID metadata, and temporary
test artifacts remain under `/opt/testradio`. The test launcher does not install
a system service or write to `/etc`, `/var`, another `/opt` directory, or a home
directory.

Remote setup may inspect system commands and listener state, but it must not
delete or modify any file outside `/opt/testradio`. Existing temporary SSH key
authorization outside that directory is left untouched.

## 10. Acceptance Result

This slice is complete when a browser reached through an address chosen by the
user can load port `8080`, authenticate to port `8765`, and make confirmed
frequency and mode changes against the official Dummy on port `4532`, with all
three listeners bound to `0.0.0.0`. The webpage and authenticated WebSocket
application paths keep PTT disabled. A client that bypasses the application and
talks directly to public port `4532` may change only the official Dummy's
simulated PTT state; no physical hardware or RF path exists in this mode.

Passing this acceptance does not certify the control plane for real-hardware
transmission. The unresolved C1, C3, and I3 final-review findings continue to
block that use.
