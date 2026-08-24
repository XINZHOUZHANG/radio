# Radio Lite Server

Low-bandwidth, multi-radio control service for Debian 13. This directory is a
new implementation and does not depend on TX-5DR or the historical Python
prototype in `../server`.

The initial core intentionally uses only Node.js built-ins. Hamlib, audio,
Opus and WSJT-X DSP are system services/workers, so they do not inflate the
application package. The only JavaScript runtime dependency is the small `ws`
WebSocket framing library; compression is disabled.

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
- Ogg/Opus packet framing with CRC validation and bounded process pipes;
- ALSA or PulseAudio capture/playback through Debian `opus-tools`;
- a synthetic waterfall for Hamlib Dummy profiles;
- microphone uplink binding to a voice transmit token;
- immediate PTT release on media disconnect, worker failure or token expiry;
- a three-second uplink-bind deadline so an unbound carrier cannot remain on; and
- stale-media dropping when a WebSocket client is congested.

FT8/FT4 DSP/automatic QSO, ADIF and the SwiftUI Radio Lite adapter are the next
implementation slices; see the design document for their exact boundaries.

On Debian 13, real audio currently requires `alsa-utils` or
`pulseaudio-utils`, plus `opus-tools`. These remain operating-system packages
and are not copied into the Node application.

## Local tests

Node.js 24.7 or newer is required because password hashing uses the built-in
Argon2id implementation.

```sh
npm test
npm run typecheck
```

See `PROTOCOL.md` for the wire contract and
`../docs/design/2026-08-24-radio-lite-server.md` for the approved design.
