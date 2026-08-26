# Radio Lite

Radio Lite is a self-contained low-bandwidth remote-radio system for Debian 13
and iOS. The active stack consists of the TypeScript server in
`radio-lite-server/` and the native SwiftUI client in `ios/RadioLite/`.

The server composes established radio components instead of reimplementing the
hardware layer:

- Hamlib `rigctld` for CAT, PTT, internal tuner control and multiple radio models;
- Opus and system audio for bidirectional voice;
- WSJT-X DSP workers for FT8/FT4 decoding, encoding and automatic QSO flow;
- compact binary spectrum frames designed for constrained links;
- standard ADIF files for server-owned logging and worked-grid views.

## Active components

- `radio-lite-server/`: accounts, six-digit pairing, device credentials,
  multi-radio configuration, control leases, transmit interlocks, audio,
  spectrum, FT8/FT4 automation and ADIF logging;
- `ios/RadioLite/`: the Radio Lite SwiftUI application;
- `ios/RadioLiteTests/`: focused client model, audio-policy and concurrency tests;
- `radio-lite-server/PROTOCOL.md`: the HTTP, WebSocket and binary-media contract;
- `docs/design/2026-08-24-radio-lite-server.md`: architecture and acceptance goals;
- `scripts/check-ios-radio-lite-contract.mjs`: server/client contract drift check.

The earlier Python control-plane experiment in `server/` and its static test UI
in `web/` are retained for historical comparison. They are not used by the
current iOS application or the TypeScript service.

## Server checks

Radio Lite Server requires Node.js 24.7 or newer.

```sh
cd radio-lite-server
npm install
npm run check
```

Run the server on loopback:

```sh
RADIO_LITE_DATA_DIR=./data npm start
```

Plain HTTP/WS outside loopback is rejected unless the administrator explicitly
sets `RADIO_LITE_ALLOW_INSECURE=1`. Use that override only on a trusted LAN or
Tailscale network. Internet-facing deployments require HTTPS/WSS termination.

## iOS checks

The cross-platform contract check runs without Xcode:

```sh
node scripts/check-ios-radio-lite-contract.mjs
```

Generate and test the native project on macOS as described in `ios/README.md`.
GitHub Actions builds the simulator tests and publishes an unsigned device IPA
for branch pushes.

## Hardware safety

Begin with Hamlib Dummy and synthetic audio. A real profile must pass the
administrator's read-only CAT/audio preflight before it is saved, and hardware
transmission remains disabled until the exact radio ID is explicitly confirmed.
PTT, digital transmission and the internal tuner share one server-side interlock.

Only deploy this checkout inside the directory you intend to manage. On the
project's Debian test host, all deployment work is confined to `/opt/testradio`.
