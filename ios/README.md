# Radio Lite for iOS

This directory contains the native SwiftUI client for the repository's Radio
Lite protocol v1. The active application no longer wraps or depends on the
TX-5DR web UI. The legacy TX-5DR client sources remain temporarily in the tree
as visual/reference components while migration tests are retired.

## Implemented native features

- HTTP, HTTPS and Tailscale server addresses, including trusted plain HTTP;
- five-minute request and initial-authentication tolerance for very slow links;
- username/password sessions, first-server setup and one-time six-digit device
  pairing with Keychain persistence and rotating device credentials;
- multi-radio selection, exclusive control lease, Hamlib frequency/mode, held
  voice PTT and held internal tuner operation;
- one-port `/ws/control` and `/ws/media` clients using `radio-lite.v1`;
- native system Opus at 16 kHz mono, compact spectrum decoding and adaptive
  low-bandwidth policy reporting;
- FT8/FT4 immutable slot batches, selectable decodes, call queue and automatic
  QSO state;
- server-owned ADIF log list, manual voice records, import/export and worked-grid
  map;
- administrator account creation and six-digit pairing-code generation;
- administrator hardware setup with searchable full `rigctl -l` model catalog,
  CAT/baud, Hamlib PTT method and PulseAudio/PipeWire/ALSA endpoint selection;
- an administrator-only read-only configuration test that reports CAT
  frequency/mode readback, optional Hamlib capabilities and both audio endpoints
  before saving, without obtaining control or issuing PTT, tuner, frequency or
  mode write commands;
- non-empty passwords without complexity or character-count rules, with clear
  setup validation before submission;
- opt-in speaker playback, recoverable media-only retry and dismiss-once error
  notices so a temporary iOS audio-route failure does not block radio control.

Voice PTT deliberately removes the microphone input tap and switches the audio
session back to playback synchronously when the button is released, before it
waits for a network response. Connection loss and app backgrounding run the same
local shutdown path; the server independently de-keys on socket/heartbeat loss.

## Build on macOS

1. Install Xcode 16 or newer and XcodeGen.
2. Run `xcodegen generate --spec ios/TX5DRMobile/project.yml` from the repository root.
3. Open `ios/TX5DRMobile/TX5DRMobile.xcodeproj`.
4. Select a signing team and run on an iOS 17+ device.

GitHub Actions also builds and tests the simulator target and publishes an
unsigned device IPA on branch pushes. Unsigned IPAs still require a supported
sideload/signing workflow before iOS will launch them.

The wire contract is documented in `radio-lite-server/PROTOCOL.md`.
