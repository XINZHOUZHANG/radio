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

Opus media workers, binary spectrum frames, FT8/FT4 DSP/automatic QSO, ADIF and
the SwiftUI Radio Lite adapter are the next implementation slices; see the
design document for their exact boundaries.

## Local tests

Node.js 24.7 or newer is required because password hashing uses the built-in
Argon2id implementation.

```sh
npm test
```

See `../docs/design/2026-08-24-radio-lite-server.md` for the approved design.
