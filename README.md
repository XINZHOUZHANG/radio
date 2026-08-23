# Remote Radio / TX-5DR Mobile

This repository now uses the official [TX-5DR](https://github.com/boybook/tx-5dr)
server as its primary radio backend and adds a native SwiftUI iOS client. The
earlier Python `server/` and browser `web/` implementation remains in the tree
as a historical prototype; new radio functionality should target TX-5DR.

## What is included

- `deploy/tx5dr/`: reproducible Debian Docker deployment pinned to TX-5DR commit
  `f9e07fec6c5fb67b5c904936b5df03c1e3b0f5dc`;
- `deploy/tx5dr/patches/`: a reviewed server extension for single-use six-digit
  iOS pairing codes;
- `deploy/tx5dr/dummy-rig/`: Hamlib model 1 CAT/PTT/tuner simulator;
- `deploy/tx5dr/dummy-audio/`: PulseAudio full-duplex loopback for real TX-5DR
  audio, spectrum, FT8 and transmit-pipeline testing;
- `ios/TX5DRMobile/`: native SwiftUI client for radio control, spectrum, FT8,
  voice PTT/audio, CW, tuner, logbook, accounts and server settings;
- `docs/tx5dr/contract.json`: extracted upstream HTTP/WebSocket/audio contract;
- `scripts/check-ios-tx5dr-contract.mjs`: drift guard between the pinned TX-5DR
  protocol and the iOS implementation.

## Debian dummy deployment

Only deploy this checkout below `/opt/testradio`; the scripts refuse to prepare
TX-5DR anywhere else.

```sh
cd /opt/testradio/deploy/tx5dr
cp .env.example .env
chmod +x prepare-upstream.sh start-dummy.sh
./start-dummy.sh
```

The HTTP, HTTPS, realtime UDP, and optional rigctld bridge mappings explicitly
bind to `0.0.0.0`. See `deploy/tx5dr/README.md` for ports, acceptance checks,
hardware overrides and RF safety notes.

## Local checks

```sh
node --test scripts/tests/*.test.mjs deploy/tx5dr/tests/*.test.mjs
node scripts/check-ios-tx5dr-contract.mjs
```

Generate and test the iOS project on macOS as described in `ios/README.md`.

## Upstream and licensing

TX-5DR is GPL-3.0 software. The deployment fetches the exact upstream commit,
verifies its origin and applies the tracked pairing patch without hiding source
changes. The TX-5DR-derived patch is distributed under GPL-3.0; retain upstream
copyright and license notices when redistributing a built server image. See
`THIRD_PARTY_NOTICES.md` for provenance. The separate legacy prototype and
native client remain subject to the repository owner's licensing decision.
