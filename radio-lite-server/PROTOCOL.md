# Radio Lite protocol v1

HTTP APIs and both WebSockets share one configured listener. WebSocket clients
must offer the `radio-lite.v1` subprotocol.

## Authentication

A browser may authenticate with its `rr_session` cookie. A paired app sends the
following as its first text frame. The authentication deadline is five minutes
to allow initial connections over a very slow link.

```json
{"t":"auth.device","deviceId":"...","accessToken":"..."}
```

The server replies with `auth.ok`, the channel name, principal permissions and
the configured radio list. Binary data is rejected until authentication has
completed.

## Capability discovery

`GET /healthz` is unauthenticated and advertises optional server features:

```json
{
  "status":"ok",
  "service":"radio-lite",
  "protocolVersion":1,
  "features":{"hardwarePreflight":true,"safetyEvents":true}
}
```

Clients must treat a missing feature field as unsupported. In particular,
missing `hardwarePreflight` means the server is too old or a reverse proxy is
not forwarding `/api/v1/hardware/test`; clients should not present a generic
404 for that case.

## Safety state stream

After `auth.ok` on `/ws/control`, the server immediately sends one complete,
epoch-scoped safety snapshot envelope. It includes every configured radio,
including radios that currently have no alert:

```json
{"t":"safety.snapshot.begin","safetyEpoch":"boot-uuid"}
{"t":"safety.snapshot","safetyEpoch":"boot-uuid","radioId":"main","revision":4,"alert":{"kind":"dekey_required","startedAtMs":1787700000000,"source":"software"}}
{"t":"safety.snapshot","safetyEpoch":"boot-uuid","radioId":"backup","revision":0,"alert":null}
{"t":"safety.snapshot.end","safetyEpoch":"boot-uuid"}
```

Later changes use revisioned increments:

```json
{"t":"safety.event","safetyEpoch":"boot-uuid","radioId":"main","revision":5,"kind":"dekey_escalated","startedAtMs":1787700000000,"source":"software"}
{"t":"safety.event","safetyEpoch":"boot-uuid","radioId":"main","revision":6,"kind":"recovered","startedAtMs":1787700032000,"source":"software"}
```

Persistent alert kinds are `active`, `external_ptt`, `telemetry_uncertain`,
`dekey_required`, `dekey_escalated`, `swr_trip_latched`, and
`swr_rearm_pending`. `recovered` is an event only: it clears the corresponding
radio alert and never appears inside a snapshot. Clients replace state only
after receiving the matching `safety.snapshot.end`, ignore older revisions,
and discard state from a previous `safetyEpoch` after committing the new
complete envelope. This server stream is authoritative for remote PTT-OFF
confirmation and persistent stop-failure warnings.

## Shared radio telemetry

An authenticated control WebSocket subscribes to one radio with an optional
`commandId`:

```json
{"t":"rig.telemetry.subscribe","radioId":"main","commandId":"telemetry-1"}
```

The server first acknowledges ownership of that socket's subscription, then
sends the current cached sample (or the first completed sample) and subsequent
shared samples. Multiple sockets receive the same runtime-owned sample and do
not cause additional CAT reads.

```json
{"t":"rig.telemetry.subscribed","radioId":"main","commandId":"telemetry-1"}
{"t":"rig.telemetry","radioId":"main","sampledAtMs":1787700000000,"state":{"frequencyHz":14074000,"mode":"USB","passbandHz":3000,"ptt":false},"meters":{"strengthDbRelativeS9":-8},"availableMeters":["STRENGTH","SWR","ALC","RFPOWER_METER_WATTS"]}
```

`meters` omits values that were not sampled in the current receive/transmit
phase. `availableMeters` contains readable Hamlib meter tokens. Actual power
uses `RFPOWER_METER_WATTS` when available, otherwise `RFPOWER_METER`;
`RFPOWER` is a transmit-power setting and is never published as measured power.
Hamlib meter discovery uses one cached `get_level ?` warm-up during driver
initialization, outside steady telemetry ticks.

Unsubscribe is scoped to the sending socket and radio. It is idempotent: the
server returns the same acknowledgement when no matching subscription exists.
Closing a socket removes all of that socket's telemetry subscriptions without
affecting other clients.

```json
{"t":"rig.telemetry.unsubscribe","radioId":"main","commandId":"telemetry-2"}
{"t":"rig.telemetry.unsubscribed","radioId":"main","commandId":"telemetry-2"}
```

Authenticated HTTP APIs accept the same browser session cookie. Mutating
browser requests additionally require the session's CSRF token in
`X-CSRF-Token`. A paired native app instead sends both of these headers; Bearer
requests do not use CSRF because the access token is not ambient browser state:

```http
Authorization: Bearer <accessToken>
X-Radio-Lite-Device-Id: <deviceId>
```

## Radio hardware HTTP API

| Method | Path | Permission | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/v1/hardware/discovery` | administrator | Discover Hamlib models, serial ports, audio devices, PTT methods and baud rates |
| `POST` | `/api/v1/hardware/test` | administrator | Run a non-persistent, read-only CAT/capability/audio-endpoint preflight for one draft profile |
| `GET` | `/api/v1/radios` | authenticated | Read the versioned radio-profile list |
| `POST` | `/api/v1/radios` | administrator | Create or replace one radio profile by `id` |

Discovery returns this shape; host-specific catalog and device arrays are
abbreviated here:

```json
{
  "hamlibModels": [
    {"modelId":1049,"manufacturer":"Yaesu","model":"FT-710","backendVersion":"20250101.0","status":"Stable"}
  ],
  "curatedPresets": [],
  "serialDevices": [
    {"id":"by-id:usb-Yaesu-if00","path":"/dev/serial/by-id/usb-Yaesu-if00","label":"Yaesu","stable":true}
  ],
  "audioInputs": [
    {"backend":"alsa","direction":"input","id":"hw:1,0","label":"USB Audio CODEC"}
  ],
  "audioOutputs": [
    {"backend":"alsa","direction":"output","id":"hw:1,0","label":"USB Audio CODEC"}
  ],
  "audioCards": [
    {
      "hardwareId":"usb:1234:5678:SN42",
      "label":"USB Audio CODEC (SN42)",
      "transport":"usb",
      "complete":true,
      "input":{"backend":"alsa","direction":"input","id":"hw:1,0","label":"USB Audio CODEC"},
      "output":{"backend":"alsa","direction":"output","id":"hw:1,0","label":"USB Audio CODEC"}
    }
  ],
  "pttMethods": ["RIG","DTR","RTS","Parallel","CM108","GPIO","GPION","None"],
  "baudRates": [1200,2400,4800,9600,19200,38400,57600,115200,230400],
  "warnings": []
}
```

`audioCards` is an additive paired-device view for new clients. The legacy
`audioInputs` and `audioOutputs` fields remain present so existing clients can
continue selecting and saving explicit endpoints. A card's stable `hardwareId`
is resolved to its current `input` and `output` endpoint IDs during preflight
and whenever a system media worker starts.

`POST /api/v1/hardware/test` accepts `{"profile": <complete-profile>}` using
the same profile validation as a save, but it does not write `radios.json`,
register a runtime or obtain a control lease. For a real rig the application
sends only the bounded read queries `get_freq`, `get_mode`, `get_ptt`,
`get_func TUNER`, `get_level ?` and `get_func ?`; it does not send PTT, tuner,
frequency or mode write commands. A managed-serial test starts its temporary
rigctld with PTT forced to `None` and omits the draft PTT path and GPIO bit, so
the preflight process does not initialize those external PTT devices.
Unsupported optional capability queries produce a warning without hiding a
successful frequency/mode readback.
Audio input and output are checked independently against read-only device
discovery. Dummy profiles return a deterministic synthetic result without
opening rigctld or host audio devices.

Managed serial paths are canonicalized before locking, so aliases such as
`/dev/ttyUSB0` and `/dev/serial/by-id/...` cannot run concurrently. An active or
initializing runtime returns `409 radio_device_busy`. If shutdown of a temporary
rigctld process cannot be confirmed, the endpoint returns
`503 hardware_cleanup_uncertain` and keeps that device quarantined until the
service is restarted instead of risking a second process opening the same radio.

The response always orders the four checks as CAT, capabilities, audio input
and audio output. `details` contains display-safe strings only:

```json
{
  "profileId": "main",
  "testedAtMs": 1787700000000,
  "readOnly": true,
  "overallStatus": "warning",
  "checks": [
    {
      "id": "cat",
      "status": "passed",
      "message": "CAT connection and frequency/mode readback succeeded",
      "details": {"frequencyHz":"14074000","mode":"PKTUSB","passbandHz":"3000"}
    },
    {
      "id": "capabilities",
      "status": "warning",
      "message": "CAT is available, but one or more optional capability queries are unsupported",
      "details": {"pttReadback":"true","internalTunerReadback":"false","readableLevels":"AF,RFPOWER"}
    },
    {"id":"audioInput","status":"passed","message":"Configured audio endpoint was found","details":{"backend":"alsa","id":"hw:1,0"}},
    {"id":"audioOutput","status":"passed","message":"Configured audio endpoint was found","details":{"backend":"alsa","id":"hw:1,0"}}
  ]
}
```

The `POST /api/v1/radios` body contains one complete profile:

```json
{
  "profile": {
    "id": "main",
    "name": "FT-710",
    "hamlibModelId": 1049,
    "connection": {
      "kind": "managed-serial",
      "devicePath": "/dev/serial/by-id/usb-Yaesu-if00",
      "baudRate": 38400
    },
    "audioInput": {"backend":"alsa","id":"hw:1,0","label":"USB Audio CODEC"},
    "audioOutput": {"backend":"alsa","id":"hw:1,0","label":"USB Audio CODEC"},
    "audioRoute": {"kind":"system-device","hardwareId":"usb:1234:5678:SN42","latency":"balanced"},
    "ptt": {"method":"DTR","path":"/dev/serial/by-id/usb-Yaesu-if01"},
    "station": {"callsign":"BI1ABC","grid":"OM89"},
    "hardwareTxEnabled": true
  },
  "hardwareTxConfirmation": "main"
}
```

`connection` is alternatively
`{"kind":"network-rigctld","host":"rig.local","port":4532}` or
`{"kind":"hamlib-dummy"}`. Audio endpoints use the discovered `alsa` or
`pulse` backend and device `id`. New clients may additionally save
`audioRoute` as `system-device` with a stable `hardwareId` and `low`,
`balanced`, or `stable` latency; the other additive route variants are
`{"kind":"driver-stream"}` and `{"kind":"none"}`. Old version-1 profiles
remain valid with only their explicit `audioInput` and `audioOutput`; the
server does not require or backfill `audioRoute`, so only clients that know the
new field save it. `ptt` defaults to `RIG` for an old real-radio profile and
`None` for an old Dummy profile. `RIG` does not take
a PTT path. `DTR`, `RTS`, `Parallel`, `CM108`, `GPIO` and `GPION` require an
absolute `/dev/...` path; GPIO/GPION may additionally provide `bit` from 0 to
7. `network-rigctld` accepts only `RIG`, because PTT options belong to that
external process. `None` cannot be combined with hardware transmission.

Enabling hardware TX requires `hardwareTxConfirmation` to equal the exact
profile `id`. A successful save de-keys active transmission, invalidates the
old digital, media and rig workers, and returns:

```json
{"radio":{"id":"main"},"reconnectRequired":true}
```

The returned `radio` is the full normalized profile. Subscribed media clients
also receive `media.error` with code `media_configuration_changed`; they may
immediately subscribe again, or reconnect both WebSockets as requested by the
HTTP response.

The hardware-foundation protocol boundary is additive. No existing message or
field is removed: old control clients retain `rig.state.get` and
`rig.controls.get`, while new clients may use the telemetry subscription
messages and the discovery `audioCards` field. Old profile writers may keep
saving explicit audio endpoints; `audioRoute` is optional and is saved only by
new clients.

## Station log HTTP API

The service stores one plain-text ADIF 3.1.7 file at
`<data-directory>/station-log.adif`. Unknown ADIF fields survive import and
export. The import limit is 16 MiB, and the maximum log accepted at startup is
256 MiB.

| Method | Path | Permission | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/v1/logs?limit=100&offset=0` | authenticated | Newest-first paginated QSO records |
| `POST` | `/api/v1/logs` | operator | Add a manual voice QSO from the iOS app |
| `GET` | `/api/v1/logs/grids?resolution=4` | authenticated | Aggregate QSOs into 2/4/6/8-character Maidenhead cells |
| `GET` | `/api/v1/logs/export` | authenticated | Download `radio-lite-log.adi` |
| `POST` | `/api/v1/logs/import` | administrator | Import and deduplicate ADIF records |

The manual-QSO request body is:

```json
{
  "radioId": "main",
  "call": "JA1ABC",
  "startedAtMs": 1787661000000,
  "endedAtMs": 1787661120000,
  "frequencyHz": 14250000,
  "band": "20M",
  "mode": "SSB",
  "submode": "USB",
  "rstSent": "59",
  "rstReceived": "57",
  "grid": "PM95",
  "txPowerWatts": 20,
  "comment": "Manual iOS log"
}
```

`endedAtMs`, `band`, `submode`, reports, grid, power and comment are optional.
The server supplies `MY_CALL` and `MY_GRIDSQUARE` from the selected radio
profile, derives the band when omitted, labels the record `VOICE_MANUAL`, and
returns HTTP 200 rather than creating a duplicate when the QSO fingerprint
already exists. Import accepts `application/adif`, `application/octet-stream`
or `text/plain`.

## Control channel

`/ws/control` uses strict JSON objects. Unknown fields are rejected. Mutating
radio commands require the per-radio `controlToken` returned by
`control.acquire`. `tx.start` returns a separate high-entropy `transmitToken`.

`rig.state.get` returns the normal frequency/mode/passband/PTT readback plus
`supportsInternalTuner`. Manual tuning is available when Hamlib reports a
`TUNE` operation. A rejected capability query is cached as unknown rather than
as an explicit negative, so the service probes the real command without adding
capability queries to every steady-state CAT poll. An unknown `TUNER` switch is
tried before `TUNE`; only an explicit `RPRT -11` downgrades that switch to
unsupported and continues with `TUNE`, while every other report is preserved.
The independent `TUNER` switch appears in `rig.controls` only when Hamlib
reports it as both readable and writable. When that switch is known writable,
the service sends `TUNER 1` before `TUNE`; when it is known unavailable, tuning
still starts with `TUNE` and shutdown skips the unsupported switch command.
Every tuning shutdown still sends emergency PTT OFF and requires an OFF
read-back before clearing the safety latch.

`rig.mode.set` carries a Hamlib mode token. Operator-facing DATA-U/DATA-L labels
map to `PKTUSB`/`PKTLSB` on the wire; the service also accepts the finite legacy
aliases `DATA-U`, `USB-DATA`, `DIGU`, `DATA-L`, `LSB-DATA`, and `DIGL` and
normalizes them before calling rigctld. A successful `rig.mode.confirmed` reply
returns the actual Hamlib read-back token. Hamlib rejection and failed read-back
use the stable error codes `rig_mode_rejected` and `rig_mode_unconfirmed`.

The client discovers safe radio adjustments instead of assuming that every
Hamlib backend exposes the same knobs:

```json
{"t":"rig.controls.get","radioId":"main","commandId":"controls-1"}
{"t":"rig.controls","radioId":"main","commandId":"controls-1","controls":[
  {"id":"level:RFPOWER","kind":"level","token":"RFPOWER","value":0.25,"minimum":0,"maximum":1,"step":0.01,"unit":"ratio","transmitLocked":true},
  {"id":"function:NB","kind":"function","token":"NB","value":1,"minimum":0,"maximum":1,"step":1,"unit":"boolean","transmitLocked":false},
  {"id":"function:TUNER","kind":"function","token":"TUNER","value":0,"minimum":0,"maximum":1,"step":1,"unit":"boolean","transmitLocked":true},
  {"id":"passband:CURRENT","kind":"passband","token":"CURRENT","value":3000,"minimum":100,"maximum":12000,"step":50,"unit":"hertz","transmitLocked":false}
]}
```

Only the readable/writable Hamlib capability intersection and the server's
finite safety allowlist are returned. Level granularity comes from rigctl's
`set_level <token> ?` query when the backend reports it. A write carries the
opaque discovered `id`, never a raw CAT or rigctl command, and the server reads
the value back before confirming it:

```json
{"t":"rig.control.set","radioId":"main","controlToken":"...","controlId":"level:RFPOWER","value":0.35,"commandId":"control-1"}
{"t":"rig.control.confirmed","radioId":"main","commandId":"control-1","control":{"id":"level:RFPOWER","kind":"level","token":"RFPOWER","value":0.35,"minimum":0,"maximum":1,"step":0.01,"unit":"ratio","transmitLocked":true}}
```

`RFPOWER`, `MICGAIN` and compressor controls are marked `transmitLocked` and
cannot change while any transmission lease is active. The server enforces this
atomically with transmit start/stop; the iOS disabled state is only a visual
hint. Unsupported controls are absent rather than presented as inert switches.

Clients may use `tx.start` only for `voice` and `tuning`. FT8/FT4 transmission
must go through the digital queue below; the server rejects a raw client
`tx.start` with `mode: "digital"` so a client cannot create an unmodulated
digital carrier outside UTC scheduling and the automatic safety controller.

Voice transmit startup is deliberately ordered as follows:

1. Open and authenticate `/ws/media` from the same browser session or device.
2. Send `media.subscribe` and wait for `media.subscribed`.
3. Send `tx.start` with `mode: "voice"` on `/ws/control`.
4. Send `media.uplink.bind` with the returned `transmitToken` within three
   seconds.
5. Send one `tx.heartbeat` about every two seconds while transmitting.
6. On PTT release, synchronously stop the local microphone/uplink, send
   `tx.stop`, and resume receive audio as soon as the WebSocket send completes;
   the UI does not wait for a slow CAT readback before restoring the speaker.

When a bound voice transmission ends, the media channel emits
`{"t":"media.uplink.ended","radioId":"main","transmitToken":"...","reason":"transmit_ended"}`.
The client must stop only the uplink with that exact token so a delayed event
from the previous PTT cannot cancel a replacement transmission.

The server refuses voice PTT without a ready same-principal media subscription.
It de-keys automatically if binding does not arrive, the media socket closes,
the worker fails, a heartbeat expires, or the continuous-transmit limit is
reached. Tuning transmissions do not accept microphone binding.

## FT8/FT4 control

The server commits one immutable decode batch only after a UTC slot finishes.
Each decode has a stable ID derived from radio, mode, slot, normalized message
and audio frequency. Duplicate native decode passes are collapsed before the
batch is broadcast as `digital.decode.batch`; clients therefore do not reorder
the visible list for every individual decoder result.

For a real radio, the server shares the existing mono sound-device capture with
the spectrum/Opus pipeline, continuously resamples it to 12 kHz, and assembles
exact UTC FT8 and FT4 PCM windows. Native WSJT-X encode/decode runs in a separate
process with one native thread and a bounded pending-slot queue. Digital transmit
PCM returns through the same radio playback device in real-time 20 ms chunks;
voice decoder residue is suppressed while it plays. A DSP exit, timeout or audio
failure follows the same server-owned PTT OFF path as a disconnected controller.

Read the current digital state with:

```json
{"t":"digital.snapshot.get","radioId":"main"}
```

The `digital.snapshot` reply contains recent decode batches, the call queue and
the active automatic-QSO state. Queue mutations require the same control lease
used for CAT commands:

```json
{"t":"digital.queue.add.decode","radioId":"main","controlToken":"...","decodeId":"decode_...","commandId":"q1"}
{"t":"digital.queue.add.manual","radioId":"main","controlToken":"...","targetCallsign":"JA1ABC","targetGrid":"PM95","mode":"FT8","audioFrequencyHz":1300,"txParity":"odd","commandId":"q2"}
{"t":"digital.queue.skip","radioId":"main","controlToken":"...","commandId":"q3"}
{"t":"digital.queue.remove","radioId":"main","controlToken":"...","entryId":"call_...","commandId":"q4"}
{"t":"digital.auto.stop","radioId":"main","controlToken":"...","requeue":false,"commandId":"q5"}
```

Adding a selected CQ automatically chooses the opposite even/odd transmit slot.
Manual calls specify parity explicitly. `targetGrid` and `requeue` are optional.
The control connection must continue its ordinary `control.heartbeat` while an
automatic QSO is active; closing it immediately cancels prepared audio, clears
that owner's queue entries and de-keys any active digital transmission.

The automatic caller exchange is server-owned: grid call, received report,
R-report, RR73/73 and final 73. Missing replies cause bounded retransmission and
then a visible `failed` state. A successful final transmission appends one
`FT8_AUTO` or `FT4_AUTO` record to ADIF before broadcasting
`digital.log.created`. Other server events are `digital.queue`, `digital.qso`,
`digital.tx.scheduled`, `digital.tx.started`, `digital.tx.stopped` and
`digital.error`. Clients should match command replies by `commandId`, because
events can arrive between a command and its reply.

## Media control messages

Text frames on `/ws/media` are:

```json
{"t":"media.subscribe","radioId":"main","spectrumVisible":true,"requestId":"01J..."}
{"t":"media.network","rttMs":80,"packetLossPercent":0.2,"bufferedBytes":0,"spectrumVisible":true,"requestId":"01J..."}
{"t":"media.uplink.bind","radioId":"main","transmitToken":"...","requestId":"01J..."}
{"t":"media.unsubscribe","requestId":"01J..."}
{"t":"ping"}
```

The server answers with `media.subscribed`, `media.policy`,
`media.uplink.bound`, `media.unsubscribed`, or `media.error`. A subscription
reply explicitly describes the spectrum source instead of making the client
guess whether an empty display is still loading:

Each of the four `media.*` requests above carries an opaque, non-empty
`requestId` of at most 64 characters. Its synchronous success or
`invalid_media_control` reply echoes that exact ID plus `requestType`; clients
must resolve only the pending request with both matching values. Asynchronous
errors such as `media_worker_failed`, `media_configuration_changed`, and
`ptt_stop_failed` deliberately omit both fields and are delivered only through
the media event path. This prevents one worker fault from also failing an
unrelated subscribe or uplink-bind request.

```json
{
  "t":"media.subscribed",
  "requestId":"01J...",
  "requestType":"media.subscribe",
  "radioId":"main",
  "radioSlot":0,
  "policy":{"tier":"normal","opusBitrate":20000,"opusFrameMs":20,"spectrumBins":512,"spectrumFps":5},
  "spectrum":{"available":true,"source":"audio-fft","simulated":false,"supportsWaterfall":true,"maxBins":512,"maxFps":5,"spanHz":3000}
}
```

`audio-fft` is a real FFT of the configured receive audio input, `synthetic` is
used only by Hamlib Dummy, and `none` carries the reason
`spectrum_source_unavailable`. With `none`, both spectrum policy fields remain
zero even after later good-network reports. When the app goes into the
background it should report `spectrumVisible: false`; this makes the server stop
sending spectrum frames for that client without interrupting receive audio or
another foreground subscriber's spectrum. A shared worker runs at the highest
frequency requested by its foreground subscribers, but the server independently
throttles and downsamples each client to its own 512x5, 256x3 or 128x1 policy.

If the receive-audio worker fails while subscribed, `media.error` includes
`reconnectRequired: true`, an unavailable `spectrum` capability, and the current
policy with `spectrumBins`/`spectrumFps` set to zero. Clients must immediately
discard the last frame and waterfall history before attempting a fresh
subscription; frozen data must never retain a live badge. This asynchronous
event has no `requestId` or `requestType`.

## Binary media frame

All integer fields use network byte order (big endian). The fixed header is 16
bytes:

```text
offset  size  field
0       1     protocol version (1)
1       1     kind: 1 audio downlink, 2 audio uplink, 3 spectrum, 4 statistics
2       1     flags
3       1     radio slot from media.subscribed
4       4     UInt32 sequence
8       8     UInt64 timestamp in microseconds
16      ...   payload
```

Audio payloads are one 20 ms Opus packet, mono at 16 kHz. An uplink packet is
limited to 1,500 bytes. Duplicate and out-of-order uplink sequences are
rejected. The server never enables WebSocket compression for binary media.

The spectrum payload begins with another 16-byte header. For the `audio-fft`
source, `center frequency` is the tuned radio reference and the FFT bins cover
the receive-audio baseband from 0 Hz through the advertised 3 kHz `span`; it is
not presented as a calibrated wideband SDR panadapter. Opus and digital PCM stay
at 16 kHz; only out-of-band spectrum bins are omitted:

```text
offset  size  field
0       8     UInt64 center frequency in Hz
8       4     UInt32 span in Hz
12      2     Int16 noise floor in tenths of dB
14      2     UInt16 bin count
16      ...   one UInt8 value per bin
```

Normal, constrained and severe policies use approximately 20/16/12 kbit/s
Opus and 512x5/256x3/128x1 spectrum points per second. Degradation is immediate;
recovery requires five consecutive good network reports. When the WebSocket
send buffer is congested, new audio/spectrum frames are discarded instead of
building a stale queue that could delay PTT control.
