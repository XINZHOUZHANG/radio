# Radio Lite for iOS

`ios/RadioLite/` contains the native SwiftUI client for the repository's own
Radio Lite protocol v1. The application connects only to Radio Lite Server.

## Implemented native features

- HTTP, HTTPS and Tailscale server addresses, including explicitly trusted HTTP;
- five-minute request and initial-authentication tolerance for very slow links;
- username/password sessions, first-server setup and one-time six-digit pairing;
- rotating device credentials stored in the iOS Keychain;
- multi-radio selection, exclusive control lease and Hamlib frequency/mode control;
- held voice PTT, held internal tuner operation and immediate local microphone release;
- one-port `/ws/control` and `/ws/media` clients using `radio-lite.v1`;
- native Opus audio, compact spectrum decoding and adaptive low-bandwidth reporting;
- FT8/FT4 immutable batches, selectable decodes, call queue and automatic QSO state;
- server-owned ADIF records, manual voice logs and worked-grid views;
- administrator account, pairing and hardware configuration screens;
- searchable Hamlib model, serial/PTT and system-audio endpoint selection;
- read-only CAT, capability and audio preflight before a hardware profile is saved.

Voice PTT removes the microphone input tap and releases the recording session
synchronously when the button is released, before waiting for a network reply.
Connection loss, app backgrounding and audio-session interruption use the same
local shutdown path; the server independently de-keys on lease or socket loss.

## Build on macOS

1. Install Xcode 16 or newer and XcodeGen.
2. Run `xcodegen generate --spec ios/RadioLite/project.yml` from the repository root.
3. Open `ios/RadioLite/RadioLite.xcodeproj`.
4. Select a signing team and run on an iOS 17+ device.

The production Bundle ID is `xyz.992218.radio-lite.remote`. It intentionally no
longer shares identity or Keychain records with retired client builds.

GitHub Actions runs the simulator test target and publishes an unsigned device
IPA on branch pushes. Unsigned IPAs still require a supported signing or
sideloading workflow before iOS will launch them.

The wire contract is documented in `radio-lite-server/PROTOCOL.md` and checked
by `scripts/check-ios-radio-lite-contract.mjs`.
