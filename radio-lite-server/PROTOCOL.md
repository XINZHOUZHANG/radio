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
{"t":"media.subscribe","radioId":"main","spectrumVisible":true}
{"t":"media.network","rttMs":80,"packetLossPercent":0.2,"bufferedBytes":0,"spectrumVisible":true}
{"t":"media.uplink.bind","radioId":"main","transmitToken":"..."}
{"t":"media.unsubscribe"}
{"t":"ping"}
```

The server answers with `media.subscribed`, `media.policy`,
`media.uplink.bound`, `media.unsubscribed`, or `media.error`. When the app goes
into the background it should report `spectrumVisible: false`; this makes the
server stop sending spectrum frames without interrupting receive audio.

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

The spectrum payload begins with another 16-byte header:

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
