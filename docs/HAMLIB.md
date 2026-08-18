# Hamlib control plane

The server package provides a JSON control plane around a loopback `rigctld`
connection. It discovers the backend's capabilities, maintains a revisioned rig
snapshot, validates writes, confirms them by read-back, reconnects after control
transport faults, and applies PTT safety policy.

It does **not** yet provide audio transport, FT8 orchestration, an iOS user
interface, or an external-tuner product workflow.

## No-hardware mock

Run the complete stack against the bundled in-process endpoint:

```powershell
cd server
python -m remote_radio_server --mock --once
```

The command prints exactly two newline-delimited JSON objects: one
`rig.capabilities` event and one `rig.snapshot` event. It opens no serial device,
starts no subprocess, and performs no hardware I/O.

Omit `--once` for interactive newline-delimited JSON. The process prints the two
initial events, then reads one UTF-8 JSON object per standard-input line and
prints one result or safe error per line. Malformed JSON does not stop the
session. End-of-file shuts the runtime down.

## Public official-Dummy browser acceptance

The dedicated acceptance mode owns an official Hamlib model-1 Dummy, the
authenticated WebSocket control plane, and the rounded dashboard. On the Debian
test host, run it only from the approved checkout:

```text
cd /opt/testradio/server
python3 -m remote_radio_server --public-dummy-test
```

Startup writes one JSON object to the foreground terminal. Its shape is:

```json
{"type":"public-dummy.started","url":"http://0.0.0.0:8080","websocket_url":"ws://0.0.0.0:8765/radio","device_id":"web-test","token":"<temporary-token>","identity":{"model_id":1,"model":"Dummy"}}
```

`0.0.0.0` is a listener address, not a browser destination. Open
`http://<debian-address>:8080` from the chosen test network, paste the temporary
token into the page, and connect. The browser keeps it only in memory and the
current tab's `sessionStorage`; it is not embedded in HTML, a query string, a
repository file, or a child-process argument.

This mode opens exactly these plaintext listeners:

- `0.0.0.0:8080` — fixed dashboard HTTP assets;
- `0.0.0.0:8765` — token-authenticated WebSocket control; and
- `0.0.0.0:4532` — unauthenticated official Hamlib Dummy `rigctld`.

The page enables only confirmed frequency and mode controls after capabilities
and a READY snapshot arrive. Audio, FT8, external tuner, rotor, and PTT controls
remain visibly disabled. A crafted WebSocket PTT-on request is rejected because
the stack never enables hardware TX. Stop with Ctrl+C in the same foreground
terminal; the stack closes the HTTP and WebSocket listeners and terminates only
the `rigctld` child it created.

`--public-dummy-test` is mutually exclusive with mock, ordinary serve/once,
model/device/baud, caller-supplied tokens, and both hardware-TX flags. Never
reuse this public topology for a physical-radio model or serial device.

## Existing loopback rigctld

Only the exact IPv4 loopback address is accepted:

```powershell
python -m remote_radio_server --rigctld-host 127.0.0.1 --rigctld-port 4532 --once
```

The port must be from 1 through 65535. No non-loopback bind or connection is
available through this CLI.

## Launching a local rigctld

The server can own a local `rigctld` process. Supply the Hamlib model ID, an
explicit device, optional baud rate, and the loopback port:

```powershell
python -m remote_radio_server --launch-rigctld `
  --model-id 1049 --device COM4 --baud 38400 --rigctld-port 4532 --once
```

The launcher uses an argument vector without a shell. Confirm the correct model
ID, serial device, baud rate, and that no other program owns the port or radio
before starting it. The runtime terminates only the process it created.

## JSON messages

Every object rejects unknown fields. `rig.command` requires a non-empty
`request_id` of at most 128 UTF-8 bytes.

- `{"type":"rig.capabilities"}` returns the current authenticated session's
  normalized capabilities.
- `{"type":"rig.snapshot"}` returns the current revisioned snapshot.
- `rig.command` supports `set_frequency` (`frequency_hz`), `set_mode` (`mode`,
  optional `passband_hz`), `set_level` (`level`, `value`), `set_func` (`func`,
  `enabled`), `set_split` (`enabled`, `tx_vfo`, and optional frequency/mode/
  passband), and administrator-only `send_raw` (`raw_request`). Raw CAT is not
  a general escape hatch: only exact, positively allowlisted read-only queries
  for the discovered model are accepted (currently FT-710 `; ID` and the mock
  equivalent).
- `{"type":"ptt.lease"}` acquires one device lease.
- `ptt.heartbeat` carries only `lease_id`.
- `ptt.set` carries only `lease_id` and a strict Boolean `enabled`.

Results preserve the command service's typed status: `confirmed`, `rejected`,
`invalid`, `unsupported`, `hardware_error`, or `unknown_result`. Error objects
contain stable safe codes/messages and never echo raw CAT payloads or lease
tokens.

## WebSocket bearer tokens

`--device-token DEVICE=TOKEN` remains available for local development, but the
token is plaintext in the process argument vector and may also be retained in
shell history or process-monitoring logs. For deployed use, load each token from
an operating-system secret manager or a protected environment injection and
pass the resulting mapping programmatically to `RemoteRadioServer`; do not put
production bearer tokens in command-line arguments. The server copies the
mapping internally and exposes no public plaintext-token accessor.

## Official Hamlib Dummy checks

`tests.integration.test_hamlib_dummy` is an optional read-only integration test.
It runs only when `rigctld` is on `PATH`, or when `REMOTE_RADIO_RIGCTLD` names an
existing executable. The test launches Dummy model 1 on an ephemeral loopback
port, reaches READY, reads a snapshot, and terminates the exact child process.
It never requests PTT.

```powershell
cd server
python -m unittest tests.integration.test_hamlib_dummy -v
```

`tests.integration.test_public_dummy_web` is the complete browser-stack check.
When official `rigctld` is available, it starts all three public listeners on
distinct ephemeral ports, rejects a bad WebSocket token, confirms frequency and
mode round trips, proves WebSocket PTT-on is disabled, reads the public Dummy
port directly, fetches the dashboard, and verifies owned shutdown. If official
`rigctld` is unavailable it reports one explicit skip.

```powershell
cd server
python -m unittest tests.integration.test_public_dummy_web -v
```

See [SAFETY.md](SAFETY.md) before considering hardware transmission.
