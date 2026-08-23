# TX-5DR Remote for iOS

This is a native SwiftUI client for the TX-5DR HTTP, WebSocket, spectrum, FT8,
voice, CW, logbook, tuner, and capability protocols. It does not embed the
TX-5DR React application. Third-party plugin pages are the only planned area
where a constrained `WKWebView` may be used because plugin-defined user
interfaces cannot be modeled ahead of time.

The first audio transport is TX-5DR `ws-compat` with PCM S16LE frames. This is
implemented with `URLSessionWebSocketTask` and `AVAudioEngine`, so the initial
app has no third-party runtime dependency. TX-5DR's lower-latency
`rtc-data-audio` transport remains a later optional optimization.

## Open on macOS

1. Install Xcode 16 or newer and XcodeGen.
2. Run `xcodegen generate --spec ios/TX5DRMobile/project.yml` from the repository root.
3. Open `ios/TX5DRMobile/TX5DRMobile.xcodeproj`.
4. Select a signing team and run on an iOS 17+ device.

Debug builds permit HTTP for direct LAN acceptance testing. Release builds do
not permit arbitrary HTTP; use a valid HTTPS endpoint for real operation.

The app intentionally exposes only administrator and operator login flows. It
does not offer TX-5DR public-viewer mode.

## Authentication and first use

- Administrators can create username/password accounts from **Settings →
  Accounts and 6-digit pairing**.
- Six-digit pairing codes expire after two minutes and can be exchanged once.
- The app stores only the resulting JWT in the iOS Keychain; it does not retain
  a password or pairing code.
- Create or select an operator under **Settings → Operators and FT8 identity**
  before using FT8, voice PTT, or CW transmit controls.

The native client uses TX-5DR's REST and control WebSocket protocols, its
base64-wrapped Int16 little-endian spectrum frames, and the `TX5D` v1/v2 PCM
compatibility audio framing. Run the protocol guard whenever the pinned server
revision or iOS client changes:

```sh
node scripts/check-ios-tx5dr-contract.mjs
```

Swift unit tests cover server URL normalization, WebSocket envelopes, and TX5D
audio frame encoding/decoding. They must be run on macOS with Xcode because this
Windows development host cannot compile or sign an iOS application.
