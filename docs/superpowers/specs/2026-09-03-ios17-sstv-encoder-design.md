# iOS 17 SSTV Encoder Design

## Goal

Build a small standalone iOS 17.0+ SSTV transmitting application in the existing `liteRadio` repository. The first release must let a user select a still image, prepare it for a supported SSTV mode, encode a standards-compatible SSTV waveform, preview/play the audio locally, and export the same waveform as a WAV file.

The implementation must remain reusable so the encoder can later be integrated into Radio Lite without reimplementing SSTV DSP.

## Scope

### V1 included

- iOS 17.0 or newer.
- Native Swift 5.9 / SwiftUI implementation.
- No third-party runtime dependencies.
- Photo picker input.
- Deterministic crop/resize preview for the selected SSTV mode.
- Four transmit modes:
  - Robot 36 Color
  - Robot 72 Color
  - Martin M1
  - Scottie S1
- PCM waveform generation.
- Local playback through AVFoundation.
- WAV export/share.
- Encode progress and playback progress.
- Cancellation before or during encoding.
- Unit tests for protocol constants and waveform timing.
- A small compatibility-oriented UI designed primarily for iPhone.

### V1 excluded

- SSTV receive/decoding.
- Automatic radio PTT or CAT control.
- Remote Radio Lite server transmission.
- Background transmission.
- Cloud storage, user accounts, telemetry, advertisements, subscriptions, or analytics.
- Text/watermark editing beyond ordinary image crop/fit.
- Additional SSTV modes beyond the four listed above.

These exclusions are deliberate: V1 should prove interoperable SSTV encoding on iOS 17 before adding radio-control integration.

## Repository layout

Add two isolated components beside the existing Radio Lite client:

```text
ios/
  RadioLite/                 existing app
  RadioLiteTests/            existing tests
  SSTVKit/                   reusable pure-Swift SSTV encoder package
    Package.swift
    Sources/SSTVKit/
    Tests/SSTVKitTests/
  SSTVEncoder/               standalone iOS app
    project.yml
    App/
    Features/
```

`SSTVKit` must not import SwiftUI. It may use Foundation/CoreGraphics where needed for image/sample data representation, but SSTV timing and synthesis must remain UI-independent.

The standalone app depends on the local `SSTVKit` package. A later Radio Lite feature can depend on the same package.

## Architecture

### 1. SSTVMode

`SSTVMode` is the protocol description for one supported mode. It owns immutable mode metadata:

- display name;
- VIS code;
- image width and height;
- color model / scan component order;
- sync and porch frequencies/durations;
- pixel timing;
- line structure;
- nominal transmission duration.

The mode description is data, not UI logic. The encoder consumes it generically where possible. Mode-specific exceptions are implemented through small strategies rather than `switch` statements scattered through the app.

### 2. ImageProcessor

Responsibilities:

- accept the picked image;
- normalize orientation;
- convert to a defined RGB working color space;
- crop/scale to the exact raster required by the selected SSTV mode;
- provide deterministic pixel access to the encoder;
- generate the same prepared image shown in the preview.

The encoded pixels must match the previewed prepared image.

### 3. SSTVEncoder

`SSTVEncoder` converts a prepared raster plus `SSTVMode` into mono floating-point PCM.

The output pipeline is:

```text
leader tone
  -> break
  -> leader tone
  -> VIS start bit
  -> seven VIS data bits, LSB first
  -> VIS parity bit
  -> VIS stop bit
  -> per-line sync / porch / color scans
  -> PCM samples
```

The encoder uses a continuous phase accumulator so adjacent tones do not reset phase at each SSTV element boundary. This reduces clicks and preserves frequency continuity.

Pixel luminance/chroma or RGB channel values map to the SSTV video-frequency range defined by the relevant mode. Raster scanning and component ordering must follow each mode specification exactly.

Encoding is deterministic: the same normalized pixel buffer, mode, and sample rate must produce the same sample count and equivalent waveform.

### 4. AudioRenderer

`AudioRenderer` owns the PCM output format and WAV serialization.

V1 format:

- mono;
- 48 kHz sample rate;
- 16-bit signed PCM WAV export;
- floating-point internal synthesis before conversion.

The app must play and export the same encoded sample buffer rather than synthesizing twice using separate code paths.

### 5. PlaybackController

Playback uses AVFoundation and exposes:

- play;
- pause/stop;
- playback progress;
- end-of-file completion;
- audio-session interruption handling.

The app must stop playback cleanly if an interruption or route change invalidates the current output path.

No microphone permission is required in V1 because the app only emits audio.

### 6. App state / UI

The SwiftUI app is intentionally one-screen-first:

```text
Navigation title: SSTV Encoder

[image preview / select photo]

Mode
[Robot 36] [Robot 72] [Martin M1] [Scottie S1]

Prepared image information
resolution · estimated duration

[Encode]
progress bar

[Play / Stop]    [Export WAV]
```

The primary path must be obvious without hidden menus. Advanced signal controls are excluded from V1.

The Encode button is disabled until a valid image is selected. Play and Export remain disabled until a successful encode exists. Changing the image or mode invalidates the previous encoded waveform.

## Data flow

```text
PhotosPicker
   -> selected image data
   -> ImageProcessor
   -> prepared raster + preview
   -> SSTVEncoder(mode)
   -> Float PCM buffer
   -> AudioRenderer
      -> AVAudio playback
      -> 16-bit PCM WAV
```

Encoding runs away from the main actor. UI state updates return to the main actor. Cancellation is cooperative between scan lines so a user changing mode/image does not wait for a stale full encode.

## Error handling

User-visible failures are limited and actionable:

- selected image cannot be decoded;
- encoding cancelled;
- audio playback session cannot start;
- WAV file cannot be created/shared.

Protocol/programming errors such as invalid mode timing are test failures, not recoverable UI states.

Temporary WAV files are written under the app temporary directory and may be regenerated at any time. They are not treated as user-owned persistent storage.

## SSTV interoperability requirements

V1 is not considered correct merely because it produces audible tones. Verification must cover protocol timing and real decoding.

For each supported mode:

1. VIS code and parity must match the mode definition.
2. Leader/break/VIS tone frequencies and durations must be within a small sample-quantization tolerance.
3. Per-line sync, porch, channel ordering, and pixel dwell timing must produce the expected total line duration.
4. Encoded sample count must match the computed nominal transmission duration within sample-rounding tolerance.
5. A generated reference image must decode successfully in at least one independent SSTV decoder before release.

Robot 36 deserves explicit tests for its alternating chroma behavior and line pairing because it is the V1 default mode and the easiest place for an implementation to sound plausible while generating incorrect color.

## Tests

### SSTVKit unit tests

- VIS bit ordering.
- VIS even parity.
- Tone-to-sample count conversion.
- Tone frequency synthesis within tolerance.
- Continuous phase across adjacent elements.
- Video value to frequency mapping.
- Mode raster dimensions.
- Per-mode line duration.
- Whole-frame expected sample count.
- Robot 36 chroma alternation / line-pair behavior.
- WAV header and payload length.

### App tests

- selecting/changing a mode invalidates the prior encode;
- selecting/changing an image invalidates the prior encode;
- Encode is unavailable without an image;
- Play/Export are unavailable before encoding;
- progress reaches completion after a successful encode;
- cancellation does not publish a stale waveform.

### CI

Extend the existing iOS workflow so it generates/builds/tests the SSTV project on macOS in addition to the existing Radio Lite checks. The initial change must not weaken or remove existing Radio Lite tests.

## iOS compatibility

The deployment target is exactly iOS 17.0. APIs introduced after iOS 17.0 must not be used without availability guards and a working iOS 17 fallback.

The project should follow the existing repository baseline:

- Swift 5.9;
- XcodeGen;
- Xcode 16+ CI environment;
- SwiftUI;
- iPhone and iPad compilation, with iPhone-first layout.

## Safety and radio integration boundary

This standalone encoder emits audio only. It does not key a transmitter. That keeps V1 independent of Radio Lite's server-side transmit interlock and hardware safety model.

A later Radio Lite integration must not bypass the existing transmit interlock. SSTV transmission through a real radio must acquire a dedicated digital/transmit lease and must inherit de-key, disconnect, hard-timeout, and PTT readback protections already enforced by the Radio Lite server.

## Acceptance criteria

V1 is complete when all of the following are true:

- an iOS 17.0 deployment target builds successfully;
- the user can choose a photo and see the exact prepared SSTV raster;
- Robot 36, Robot 72, Martin M1, and Scottie S1 can be selected;
- each mode encodes to deterministic 48 kHz mono PCM;
- the encoded signal can be played on-device;
- the same signal can be exported as a valid 16-bit WAV;
- protocol/timing unit tests pass;
- at least one independent decoder successfully reconstructs a reference image for each supported mode;
- existing Radio Lite tests remain passing;
- no third-party runtime dependency is introduced.

## Follow-up after V1

Only after V1 interoperability is proven should the project add Radio Lite integration. The preferred next step is to import `SSTVKit` into Radio Lite, send the encoded audio through the existing media path, and have the server own PTT/transmit lifecycle under the current safety interlock. Receive/decode support can be evaluated separately.
