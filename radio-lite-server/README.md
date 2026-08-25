# Radio Lite Server

Low-bandwidth, multi-radio control service for Debian 13. This directory is a
new implementation and does not depend on TX-5DR or the historical Python
prototype in `../server`.

The control and storage core uses Node.js built-ins. Hamlib, ALSA/PulseAudio
and Opus remain Debian services/tools. Runtime dependencies are the small `ws`
WebSocket library and the pinned `wsjtx-lib` native FT8/FT4 DSP package;
WebSocket compression is disabled.

Implemented in the first milestone:

- `users.json`/`devices.json` with atomic backup recovery;
- Argon2id passwords, browser sessions, CSRF, six-digit pairing and refresh
  token rotation/reuse revocation;
- Hamlib catalog, serial/audio discovery and multi-radio profiles;
- one control lease and one transmit interlock per radio;
- persistent rigctld extended-response transport with authoritative read-back;
- frequency, mode, voice/digital PTT and internal-tuner commands;
- authenticated `/ws/control` and `/ws/media` on the same listener; and
- append-only secret-filtered `audit.jsonl`.

The media milestone now also includes:

- a 16-byte binary media envelope and compact UInt8 spectrum payload;
- adaptive 20/16/12 kbit/s Opus and 512/256/128-bin spectrum policies;
- request-correlated media control replies kept separate from asynchronous worker faults;
- Ogg/Opus packet framing with CRC validation and bounded process pipes;
- ALSA or PulseAudio capture/playback through Debian `opus-tools`;
- a real receive-audio FFT waterfall for hardware profiles and a clearly
  labelled synthetic waterfall for Hamlib Dummy;
- explicit spectrum capability and unavailable-source responses, so clients
  never confuse missing hardware data with an endlessly loading graph;
- microphone uplink binding to a voice transmit token;
- immediate PTT release on media disconnect, worker failure or token expiry;
- a three-second uplink-bind deadline so an unbound carrier cannot remain on; and
- stale-media dropping when a WebSocket client is congested.

The logging milestone adds a database-free station log:

- plain-text ADIF 3.1.7 storage at `<data-directory>/station-log.adif`;
- atomic initial/recovery rewrites and `fsync` after every append;
- interrupted-tail recovery with the original retained as a `.corrupt-*` copy;
- stable QSO identifiers, duplicate suppression and preservation of unknown
  ADIF fields during import;
- manual voice entries plus FT8/FT4 automatic-entry source markers;
- paginated list, ADIF import/export and Maidenhead grid-summary HTTP APIs; and
- cookie/CSRF authentication for browsers or paired-device Bearer
  authentication for the native iOS app.

The ADIF import endpoint accepts at most 16 MiB per request, and the service
refuses to load a station log larger than 256 MiB.

The digital-control milestone now includes:

- exact UTC FT8 (15 s) and FT4 (7.5 s) slot calculation on the server;
- immutable per-slot decode batches with stable IDs and duplicate suppression,
  so the iOS list updates once per cycle instead of jumping per decode;
- common CQ, grid, signal-report, R-report, RRR, RR73 and 73 parsing;
- per-radio call queues with manual/selected-decode add, skip, remove and stop;
- a bounded automatic caller QSO state machine with retry failure states;
- server-timed encode/playback through an injectable native-worker contract;
- real `wsjtx-lib` FT8/FT4 encode/decode in an isolated Node child process;
- one shared sound-device capture/playback pipeline for voice, spectrum and
  digital modes, with continuous 16 kHz to 12 kHz PCM resampling;
- bounded UTC-slot PCM assembly and a capped decode backlog so DSP load cannot
  grow without limit;
- digital/voice/internal-tuner mutual exclusion and automatic PTT OFF on worker,
  control or playback failure; and
- automatic FT8/FT4 ADIF append after the final 73, with duplicate protection.

Hamlib Dummy profiles use the deterministic dummy digital worker for end-to-end
tests. Real profiles automatically use the isolated WSJT-X worker. A native DSP
crash, timeout, shared-audio failure or playback cancellation is reported to the
main controller, which cancels queued playback and de-keys through the existing
Hamlib transmit interlock. The native SwiftUI adapter is the next client slice.

On Debian 13, real audio currently requires `alsa-utils` or
`pulseaudio-utils`, plus `opus-tools`. These remain operating-system packages
and are not copied into the Node application.

## Radio hardware configuration

An administrator uses `GET /api/v1/hardware/discovery` to retrieve the full
installed Hamlib model catalog, curated presets, serial devices, ALSA or
PulseAudio inputs/outputs, supported PTT methods and serial baud rates. A
profile is created or replaced with `POST /api/v1/radios`; see `PROTOCOL.md`
for the complete JSON shape.

Managed serial and Dummy profiles start a private loopback-only `rigctld`.
Their PTT configuration supports Hamlib CLI methods `RIG`, `DTR`, `RTS`,
`Parallel`, `CM108`, `GPIO`, `GPION` and `None`. DTR/RTS, parallel, CM108 and
GPIO methods require an explicit `/dev/...` PTT path; GPIO/GPION may also set
bit 0 through 7. A `network-rigctld` profile always uses `RIG` because the
external rigctld process owns its PTT wiring.

Saving a profile first de-keys voice or digital transmission, then closes the
old media, digital and rig workers. The response sets `reconnectRequired` so
the client can resubscribe and rebuild all three paths from the saved profile.
Hamlib Dummy uses cached simulated PTT state only when its backend returns
`RPRT -11` for unavailable PTT read-back; real-radio Hamlib errors are never
suppressed.

## Local tests

Node.js 24.7 or newer is required because password hashing uses the built-in
Argon2id implementation.

```sh
npm test
npm run typecheck
```

See `PROTOCOL.md` for the wire contract and
`../docs/design/2026-08-24-radio-lite-server.md` for the approved design.
