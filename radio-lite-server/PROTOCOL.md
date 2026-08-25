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
  "pttMethods": ["RIG","DTR","RTS","Parallel","CM108","GPIO","GPION","None"],
  "baudRates": [1200,2400,4800,9600,19200,38400,57600,115200,230400],
  "warnings": []
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
`pulse` backend and device `id`. `ptt` defaults to `RIG` for an old real-radio
profile and `None` for an old Dummy profile. `RIG` does not take
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

`rig.mode.set` carries a Hamlib mode token. Operator-facing DATA-U/DATA-L labels
map to `PKTUSB`/`PKTLSB` on the wire; the service also accepts the finite legacy
aliases `DATA-U`, `USB-DATA`, `DIGU`, `DATA-L`, `LSB-DATA`, and `DIGL` and
normalizes them before calling rigctld. A successful `rig.mode.confirmed` reply
returns the actual Hamlib read-back token. Hamlib rejection and failed read-back
use the stable error codes `rig_mode_rejected` and `rig_mode_unconfirmed`.

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
6. Send `tx.stop` when the PTT button is released, then immediately stop and
   release the iOS audio session.

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
  "spectrum":{"available":true,"source":"audio-fft","simulated":false,"supportsWaterfall":true,"maxBins":512,"maxFps":5,"spanHz":8000}
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
the one-sided receive-audio range from 0 Hz through `span`; it is not presented
as a calibrated wideband SDR panadapter:

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
