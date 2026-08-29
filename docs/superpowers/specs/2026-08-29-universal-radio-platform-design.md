# Radio Lite Universal Radio Platform Design

**Status:** Approved by the user on 2026-08-29

## Goal

Turn Radio Lite into a capability-driven remote-radio platform rather than a
single-rig UI. The delivered system must expose the real controls and meters
reported by each radio, simplify normal audio setup to one USB sound-card
choice, support multiple radio transports, and add complete SSTV plus
receive-only Radiofax workflows without weakening the existing PTT and media
interlocks.

## Binding requirements

- Keep the native SwiftUI iOS client and the Radio Lite Node.js service.
- Preserve all existing FT8, FT4, voice, logbook, pairing and safety behavior.
- Never show a working-looking control whose backend is unavailable.
- Hamlib/rigctld users normally select one USB sound card; input, output,
  backend IDs, sample rate and buffers are automatic.
- Independent input/output overrides remain available under an advanced
  disclosure for troubleshooting.
- Connection kinds are: no-radio receive mode, managed Hamlib serial,
  external rigctld, ICOM WLAN and TCI/SunSDR.
- ICOM WLAN and TCI prefer their driver-provided network audio. A system USB
  sound card is an explicit advanced override, not a prerequisite.
- Per-radio CAT traffic is bounded to at most 2 commands/second in receive and
  4 commands/second while transmitting. Emergency PTT OFF remains outside the
  ordinary budget and keeps safety priority.
- S meter, SWR, ALC and actual RF power are read-only telemetry. `RFPOWER` is a
  transmit-power setting and must never be labelled as measured output.
- SSTV supports streaming receive and transmit with progressive image rows.
- Radiofax initially supports receive only, including IOC/LPM acquisition and
  partial-page preservation.
- The service remains deployable on Debian 13 under `/opt/testradio` and binds
  its configured public listener to `0.0.0.0`.
- iOS remains iOS 17+, Swift 5.9, unsigned device IPA output through the
  existing GitHub Actions workflow.
- Node remains pinned to 24.7.0.
- Only necessary automated and smoke tests are required; do not add large
  soak or extreme-test matrices in this delivery.

## Chosen architecture

### 1. Driver boundary

`RadioRuntime` depends on a transport-neutral `RadioDriver` rather than on a
concrete `HamlibRig`. The safety layer continues to depend only on strict PTT
write/read evidence.

```ts
export interface RadioDriver {
  initialize(): Promise<void>;
  close(): Promise<void>;
  capabilities(): Promise<RadioCapabilities>;
  readState(options?: RadioReadOptions): Promise<RadioState>;
  readTelemetry(mode: "receive" | "transmit"): Promise<RadioMeterSample>;
  readControls(): Promise<RadioControl[]>;
  setFrequency(frequencyHz: number): Promise<number>;
  setMode(mode: string, passbandHz?: number): Promise<RadioModeState>;
  setControl(id: string, value: RadioControlValue): Promise<RadioControl>;
  invokeAction(id: string): Promise<void>;
  writePtt(enabled: boolean): Promise<void>;
  readPtt(): Promise<boolean>;
}
```

Adapters:

- `HamlibDriver`: existing managed-serial and external-rigctld behavior.
- `IcomWlanDriver`: ICOM WLAN control, PTT and network audio when the installed
  driver reports those capabilities.
- `TciDriver`: TCI WebSocket control, meters and network audio.
- `NoRadioDriver`: receive/decode-only state with no transmit capability.
- `DummyDriver`: deterministic simulation used by tests and the demo profile.

The managed-rigctld supervisor remains Hamlib-specific. Driver health and
reconnect are surfaced through a generic runtime status; PTT recovery still
uses the existing interlock latch.

### 2. Capability and control model

The server sends descriptors; the client renders them. A descriptor contains
stable identity, access, presentation and grouping information:

```ts
type RadioControl = {
  id: string;
  token: string;
  group: "antenna" | "rf" | "audio" | "mode" | "cw" |
    "repeater" | "spectrum" | "system";
  access: "read-only" | "read-write" | "action";
  presentation: "meter" | "toggle" | "slider" | "discrete" |
    "enum" | "offset" | "button";
  value: boolean | number | string | null;
  unit?: "ratio" | "decibel" | "hertz" | "watts" |
    "milliseconds" | "index";
  minimum?: number;
  maximum?: number;
  step?: number;
  options?: Array<{ value: boolean | number | string; label: string }>;
  transmitLocked: boolean;
};
```

Hamlib support is discovered at runtime. Generic levels/functions/parameters
are mapped to descriptors, and explicit command adapters cover mode bandwidth,
Split, RIT/XIT, tuning step, repeater shift/offset, CTCSS/DCS and tuner action.
Vendor-only controls are exposed only by a driver that implements them.

The initial Hamlib catalogue covers:

- RF: RFPOWER, RF, NB, NR, AGC, PREAMP, ATT, APF, IF, PBT_IN, PBT_OUT,
  NOTCHF, ANF and MN.
- Audio: AF, SQL, MICGAIN, COMP, MON, MONITOR_GAIN, VOX, VOXGAIN, ANTIVOX,
  VOXDELAY, BAL and MUTE.
- Operation: mode/passband, Split, RIT/XIT, LOCK and TUNER.
- CW/repeater: SBKIN, FBKIN, BKINDL/BKIN_DLYMS, CWPITCH, KEYSPD, tuning step,
  repeater shift/offset, CTCSS and DCS.
- System/spectrum tokens are exposed only when Hamlib reports a stable generic
  capability. RBW/VBW and ICOM Audio IF remain vendor extensions.

Unsupported controls are omitted from normal UI. A diagnostics disclosure may
list unsupported or malformed capabilities without presenting enabled inputs.

### 3. Shared telemetry sampler

Each `RadioRuntime` owns one sampler and one cache, independent of client count.
Clients subscribe to `rig.telemetry`; they do not issue individual CAT meter
reads.

```ts
type RadioTelemetry = {
  radioId: string;
  sampledAtMs: number;
  state: RadioState;
  meters: {
    strengthDbRelativeS9?: number;
    swr?: number;
    alcRatio?: number;
    rfPowerRatio?: number;
    rfPowerWatts?: number;
  };
  availableMeters: string[];
};
```

Receive sampling every 2 seconds reads frequency, mode, strict/display PTT and
STRENGTH: four CAT commands, exactly 2 commands/second. Transmit sampling every
1 second reads strict PTT, SWR, ALC and one actual-power meter: at most four
commands/second. `RFPOWER_METER_WATTS` is preferred, then
`RFPOWER_METER`. State changes confirmed by a write update the cache
immediately. A missing or `RPRT -11` meter disables only that meter.

Emergency OFF may pre-empt telemetry. Telemetry requests use the droppable
queue. Samples older than three sampling periods are displayed as stale and
then cleared. Non-transmit SWR/ALC/power values display `—`, never stale zero.

The rig command trace becomes a fixed 1,024-entry ring buffer.

### 4. Audio-card identity and routing

Discovery returns both legacy endpoint lists and paired physical devices:

```ts
type DiscoveredAudioCard = {
  hardwareId: string;
  label: string;
  transport: "usb" | "pci" | "virtual" | "unknown";
  complete: boolean;
  input?: AudioEndpoint;
  output?: AudioEndpoint;
};
```

Linux identity priority is USB serial, then VID:PID plus USB topology path,
then ALSA card identity. Pulse/PipeWire properties are correlated with ALSA
card and bus properties. Monitor sources are excluded. A saved `hardwareId`
is resolved to current endpoint IDs at worker start, so ALSA card-number
changes do not break the profile.

The normal iOS form exposes one USB-card picker. Selecting it atomically saves
the stable identity and resolved input/output. If only one complete USB card
exists and the saved card is missing, the UI may suggest it but never silently
overwrite a still-valid selection. Duplicate cards include serial or USB port
in their label.

The worker opens a supported native rate, normally 48 kHz, and resamples to the
existing internal format. Three advanced latency profiles are `low`,
`balanced` and `stable`; normal mode uses `balanced`. Preflight must actually
open both directions and validate format negotiation. A disconnected USB card
is re-resolved by stable ID before a bounded reconnect attempt.

### 5. Connection-specific audio

`AudioRoute` is independent of `RadioDriver`:

```ts
type AudioRoute =
  | { kind: "system-device"; hardwareId: string; latency: "low" | "balanced" | "stable" }
  | { kind: "driver-stream" }
  | { kind: "none" };
```

Hamlib defaults to `system-device`. ICOM WLAN and TCI default to
`driver-stream`. A driver without network audio rejects that route during
preflight and offers the system-device override. No-radio mode may use either
a system input or no audio.

### 6. iOS presentation

The radio page keeps status and the large frequency outside the scroll view and
PTT in the bottom safe-area dock. A 52-point telemetry strip sits below the
frequency and above the spectrum:

- Receive: full-width S meter with S0–S9/S9+ labels.
- Transmit/tune: compact PWR, SWR and ALC bars.
- Unsupported or stale fields show `—`.

The controls page renders descriptor groups. Toggles, sliders, discrete
segmented choices, enums, signed offsets and actions use native SwiftUI
controls. Destructive or transmit-sensitive controls remain disabled while
transmitting and while the client lacks the control lease.

The settings page uses five connection tabs. Only fields required by the
selected driver appear. Simple audio mode uses one USB picker; advanced mode
shows the resolved endpoints and overrides.

### 7. SSTV and Radiofax

The service integrates the MIT-licensed Rasterwave codec through its maintained
Node binding when a compatible prebuilt binary exists. If the binding cannot be
installed for Node 24/Debian, it is built as a pinned service-side helper; the
iOS app never embeds the native Node module.

SSTV RX consumes the existing shared 12/16 kHz PCM capture, auto-detects VIS,
and publishes session metadata plus progressive compressed image-row events.
Completed and partial images are stored under the Radio Lite data directory.
SSTV TX accepts a bounded JPEG/PNG upload, normalizes it server-side, streams
encoded PCM through the existing digital transmit interlock, and publishes
progress. Cancellation always follows the same confirmed-dekey path as FT8.

Radiofax RX publishes IOC, LPM, acquisition state and progressive grayscale
rows. Signal loss or EOF preserves a partial page. Radiofax TX is outside this
delivery because the reference product currently advertises receive-only fax.

Image traffic is row/delta based during reception and uses bounded thumbnails
for history. Original completed images are fetched on demand; they are never
broadcast repeatedly to every client.

### 8. Protocol compatibility

Existing messages remain valid. New messages are additive:

- `rig.capabilities.get` / `rig.capabilities`
- `rig.telemetry.subscribe` / `rig.telemetry` / `rig.telemetry.unsubscribe`
- generalized `rig.control.set` and `rig.action.invoke`
- `image.mode.subscribe`, `image.rx.state`, `image.rx.rows`,
  `image.tx.prepare`, `image.tx.start`, `image.tx.stop`

Old clients continue to use `rig.state.get` and `rig.controls.get`. The service
serves those from the shared cache/catalogue so they no longer multiply CAT
traffic. Configuration changes are additive and old version-1 profiles load
unchanged; new optional driver/audio fields are written only after successful
preflight.

### 9. Safety and resource ownership

- Voice, FT8/FT4, SSTV TX and tuner remain mutually exclusive.
- A driver or media disconnect while Radio Lite owns TX latches dekey recovery.
- Read-only telemetry cannot delay PTT OFF.
- Physical/manual PTT remains warning-only when Radio Lite does not own TX.
- One physical serial device and one exclusive system audio card cannot be
  claimed by two active radio profiles.
- Uploaded images are size, pixel-count and MIME bounded before decoding.
- ICOM WLAN credentials are stored with the existing service-side secret
  policy and are never echoed to iOS after save.
- TCI endpoints default to local/private addresses; public exposure requires
  the existing authenticated Radio Lite service rather than exposing TCI
  directly.

## Delivery slices

1. Hardware foundation: generic types/driver boundary, shared telemetry,
   bounded CAT trace, paired USB discovery and the iOS meter/audio UI.
2. Complete Hamlib surface: capability descriptors and explicit operation
   adapters, grouped iOS controls.
3. Network drivers: no-radio, ICOM WLAN and TCI with driver audio.
4. Image modes: SSTV RX/TX and Radiofax RX.
5. Release: necessary tests, version bump, GitHub IPA build, Debian update and
   service restart under `/opt/testradio`.

Each slice must leave a working server and iOS client. No later slice may be
required to restore safety or existing FT8/voice functionality broken by an
earlier slice.

## Acceptance criteria

- FT-710 exposes S meter in RX and actual PWR/SWR/ALC in TX when Hamlib reports
  the corresponding levels.
- Two connected clients do not increase per-radio CAT meter traffic.
- The transport trace remains bounded after continuous polling.
- A normal user selects one USB sound card; restart and ALSA card renumbering
  preserve the selection.
- Existing managed serial and external rigctld profiles still connect, control
  PTT and stream audio.
- Controls shown on iOS correspond to reported capabilities and use correct
  toggle/discrete/enum/range presentation.
- ICOM WLAN and TCI profiles pass preflight and can read state, key/unkey and
  transport audio on supported hardware/software.
- SSTV decodes progressive rows, transmits an uploaded image and always dekeys
  on finish/cancel/disconnect.
- Radiofax preserves a partial page after signal loss.
- Server tests, web tests and iOS unit/build jobs pass; an unsigned IPA is
  downloaded locally; Debian service health succeeds after restart.
