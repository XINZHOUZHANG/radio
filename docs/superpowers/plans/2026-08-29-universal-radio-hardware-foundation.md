# Universal Radio Hardware Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a transport-neutral radio driver, one shared bounded telemetry stream per radio, stable USB sound-card selection, and the native iOS meter/audio UI without changing existing transmit safety behavior.

**Architecture:** `RadioRuntime` owns a `RadioDriver` and a single `RadioTelemetrySampler`; Hamlib is adapted behind that boundary while the existing interlock keeps strict PTT evidence. Hardware discovery pairs ALSA/Pulse endpoints into stable physical cards, and configuration resolves a saved card immediately before media start. Additive websocket events feed one telemetry cache in `RadioLiteSession`, rendered by a fixed telemetry strip.

**Tech Stack:** Node.js 24.7.0, TypeScript 5.9, node:test, Swift 5.9, SwiftUI, iOS 17, XcodeGen

**Spec:** `docs/superpowers/specs/2026-08-29-universal-radio-platform-design.md`

## Global Constraints

- Preserve FT8, FT4, voice, logbook, pairing and every existing transmit interlock.
- RX CAT traffic is at most 2 commands/second and TX CAT traffic is at most 4 commands/second; emergency PTT OFF is never rate limited.
- `RFPOWER` is a setting and must not be rendered as measured power.
- Normal Hamlib audio setup selects one USB card; separate endpoints remain under an advanced disclosure.
- Node is pinned to 24.7.0; iOS is 17+ with Swift 5.9.
- Configuration version 1 profiles remain readable.
- The rig command trace contains at most 1,024 entries.

---

### Task 1: Transport-neutral driver contract and Hamlib adapter

**Files:**
- Create: `radio-lite-server/src/rig/radio-driver.ts`
- Create: `radio-lite-server/src/rig/hamlib-driver.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/src/rig/hamlib-rig.ts`
- Test: `radio-lite-server/test/radio-driver.test.ts`
- Test: `radio-lite-server/test/radio-runtime.test.ts`
- Test: `radio-lite-server/test/digital-controller.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`

**Interfaces:**
- Produces `RadioDriver`, `RadioCapabilities`, `RadioState`, `RadioMeterSample`, `RadioControl`, `RadioControlValue`, `RadioModeState`, and `RadioReadOptions` from `radio-driver.ts`.
- Produces `HamlibDriver implements RadioDriver`, which delegates strict PTT operations and existing controls to `HamlibRig`.
- `RadioRuntime` consumes `RadioDriver`; its public compatibility methods retain their existing names and response shapes.

- [ ] **Step 1: Write the failing contract tests**

```ts
test("RadioRuntime accepts a transport-neutral driver and preserves strict PTT", async () => {
  const driver = new FakeRadioDriver();
  const runtime = new RadioRuntime(profile, driver);
  await runtime.initialize();
  assert.equal(driver.initializeCalls, 1);
  await runtime.close();
  assert.equal(driver.closeCalls, 1);
});

test("HamlibDriver never maps RFPOWER to measured RF power", async () => {
  const sample = await fixture.driver.readTelemetry("transmit");
  assert.equal(sample.rfPowerRatio, undefined);
  assert.equal(fixture.commands.includes("\\get_level RFPOWER"), false);
});
```

- [ ] **Step 2: Run the tests and confirm the missing-contract failure**

Run: `node --experimental-strip-types --test test/radio-driver.test.ts test/radio-runtime.test.ts`

Expected: FAIL because `radio-driver.ts` and `HamlibDriver` do not exist.

- [ ] **Step 3: Implement the contract and adapter**

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

Keep confirmed PTT ON as write plus strict read-back, tuner admission, and legacy flat-control compatibility in the Hamlib adapter; do not move safety decisions into a transport driver. `RigRuntimeSupervisor.startupObserve()` continues to own managed-rigctld startup and `supervisor.close()` continues to own safe dekey/dependency closure; wire driver initialize/close exactly once without double-starting or closing the transport before dekey evidence. Update `DigitalFakeRig` and `ApiFakeRig` to implement the same contract.

- [ ] **Step 4: Run focused and full server checks**

Run: `node --experimental-strip-types --test test/radio-driver.test.ts test/radio-runtime.test.ts`

Run: `npm run check`

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add radio-lite-server/src/rig/radio-driver.ts radio-lite-server/src/rig/hamlib-driver.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/src/rig/hamlib-rig.ts radio-lite-server/test/radio-driver.test.ts radio-lite-server/test/radio-runtime.test.ts radio-lite-server/test/digital-controller.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "refactor: add transport-neutral radio driver"
```

### Task 2: Hard CAT rate limiter and fixed 1,024-entry trace ring

**Files:**
- Create: `radio-lite-server/src/rig/cat-command-limiter.ts`
- Modify: `radio-lite-server/src/rig/transport.ts`
- Modify: `radio-lite-server/src/rig/hamlib-driver.ts`
- Test: `radio-lite-server/test/rigctld-transport.test.ts`
- Test: `radio-lite-server/test/cat-command-limiter.test.ts`

**Interfaces:**
- Produces `CatCommandLimiter.setMode("receive" | "transmit")` and `waitForBudget(signal?)`.
- `RigctldTransport.request()` sends ordinary commands no faster than 500 ms in receive and 250 ms in transmit.
- `priority: "safety", source: "ptt-off"` bypasses the limiter and preserves queue pre-emption.
- `commandTrace()` returns a chronological snapshot of a true fixed-capacity ring.

- [ ] **Step 1: Write failing hard-interval, bypass, and ring tests**

```ts
test("receive ordinary commands begin at least 500 ms apart", async () => {
  fixture.transport.setCommandMode("receive");
  const requests = [request("\\get_freq"), request("\\get_mode"), request("\\get_ptt")];
  await fixture.finishAll(requests);
  assert.deepEqual(fixture.startedAtMs, [0, 500, 1_000]);
});

test("emergency OFF bypasses the ordinary budget", async () => {
  fixture.transport.setCommandMode("receive");
  await fixture.start("\\get_freq", 0);
  const off = fixture.transport.request("\\set_ptt 0", { priority: "safety", source: "ptt-off" });
  await fixture.replyActive();
  assert.equal(fixture.nextStartedAtMs, 0);
  await off;
});

test("trace ring retains chronological entries 76 through 1099", async () => {
  await fixture.completeCommands(1_100);
  const trace = fixture.transport.commandTrace();
  assert.equal(trace.length, 1_024);
  assert.equal(trace[0].command, "\\get_freq 76");
  assert.equal(trace.at(-1)?.command, "\\get_freq 1099");
});
```

- [ ] **Step 2: Run and confirm burst/unbounded failures**

Run: `node --experimental-strip-types --test test/cat-command-limiter.test.ts test/rigctld-transport.test.ts`

Expected: FAIL because ordinary commands start immediately and the trace is unbounded.

- [ ] **Step 3: Implement interruptible gating and a fixed circular array**

Inject monotonic time and a cancellable delay for deterministic tests. Gate command start, not enqueue or completion. A queued emergency OFF cancels a pending ordinary wait and starts as soon as the active request is safely pre-empted; it never consumes or advances the ordinary budget. Change to transmit mode only after confirmed PTT ON and back to receive after confirmed OFF. Store trace entries in a 1,024-slot circular array with write index/count; `commandTrace()` returns cloned entries oldest-first without mutating the ring.

- [ ] **Step 4: Run focused and full checks**

Run: `node --experimental-strip-types --test test/cat-command-limiter.test.ts test/rigctld-transport.test.ts`

Run: `npm run check`

Expected: exit 0; recorded start times satisfy the hard intervals and OFF bypass.

- [ ] **Step 5: Commit**

```bash
git add radio-lite-server/src/rig/cat-command-limiter.ts radio-lite-server/src/rig/transport.ts radio-lite-server/src/rig/hamlib-driver.ts radio-lite-server/test/cat-command-limiter.test.ts radio-lite-server/test/rigctld-transport.test.ts
git commit -m "feat: enforce CAT budgets and bound command trace"
```

### Task 3: Shared telemetry sampler and websocket fan-out

**Files:**
- Create: `radio-lite-server/src/rig/radio-telemetry.ts`
- Modify: `radio-lite-server/src/rig/hamlib-rig.ts`
- Modify: `radio-lite-server/src/rig/hamlib-driver.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/PROTOCOL.md`
- Test: `radio-lite-server/test/radio-telemetry.test.ts`
- Test: `radio-lite-server/test/radio-runtime.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`

**Interfaces:**
- Consumes `RadioDriver.readState` and `RadioDriver.readTelemetry` plus Task 2's transport budget.
- Produces `RadioTelemetrySampler.subscribe(listener)`, `snapshot()`, coalesced first sample, `start()`, and `close()`.
- Produces additive `rig.telemetry.subscribe`, `rig.telemetry`, and `rig.telemetry.unsubscribe`; legacy state/control reads use the same cache/catalogue.

- [ ] **Step 1: Write failing sharing, command-count, and fan-out tests**

```ts
test("two subscribers and a legacy state read share one receive sample", async () => {
  const driver = new CountingDriver({ ptt: false });
  const sampler = new RadioTelemetrySampler("main", driver, { clock });
  const first = collect(sampler);
  const second = collect(sampler);
  const legacy = sampler.readState();
  await clock.advanceBy(2_000);
  await legacy;
  assert.equal(driver.receiveCommandCount, 4);
  assert.deepEqual(first.values, second.values);
});

test("transmit telemetry never uses the safety-priority PTT read", async () => {
  await fixture.driver.readTelemetry("transmit");
  assert.equal(fixture.requests.find((value) => value.command === "\\get_ptt")?.source, "telemetry");
  assert.equal(fixture.requests.filter((value) => value.priority === "safety").length, 0);
});
```

Add an HTTP test with two authenticated sockets, one fake tick, one driver sample, and two equal `rig.telemetry` events.

- [ ] **Step 2: Run and confirm missing sampler/messages**

Run: `node --experimental-strip-types --test test/radio-telemetry.test.ts test/radio-runtime.test.ts test/http-service.test.ts`

Expected: FAIL because the sampler/cache/subscription messages are absent.

- [ ] **Step 3: Implement sampling and per-socket subscription ownership**

```ts
export type RadioTelemetry = {
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

RX samples frequency, mode, telemetry-source PTT, and STRENGTH; TX samples telemetry-source strict PTT, SWR, ALC, and exactly one actual-power token (`RFPOWER_METER_WATTS`, then `RFPOWER_METER`). `RadioMeterSample` carries PTT so the four-command TX budget also updates state. `RPRT -11` disables only that meter; `RigTelemetryDroppedError` drops only the current tick. Confirmed writes update the cache. Closing a socket releases only its subscriptions; closing the runtime stops the sole sampler.

- [ ] **Step 4: Run focused and full checks**

Run: `node --experimental-strip-types --test test/radio-telemetry.test.ts test/radio-runtime.test.ts test/http-service.test.ts`

Run: `npm run check`

Expected: exit 0 and two clients still cause one sample.

- [ ] **Step 5: Commit**

```bash
git add radio-lite-server/src/rig/radio-telemetry.ts radio-lite-server/src/rig/hamlib-rig.ts radio-lite-server/src/rig/hamlib-driver.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/PROTOCOL.md radio-lite-server/test/radio-telemetry.test.ts radio-lite-server/test/radio-runtime.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: publish shared bounded radio telemetry"
```

### Task 4: Stable USB sound-card pairing and compatible configuration

**Files:**
- Create: `radio-lite-server/src/config/audio-cards.ts`
- Modify: `radio-lite-server/src/config/discovery.ts`
- Modify: `radio-lite-server/src/config/hardware-discovery.ts`
- Modify: `radio-lite-server/src/config/types.ts`
- Test: `radio-lite-server/test/audio-cards.test.ts`
- Test: `radio-lite-server/test/config.test.ts`
- Test: `radio-lite-server/test/hardware-discovery.test.ts`

**Interfaces:**
- Produces `DiscoveredAudioCard { hardwareId, label, transport, complete, input?, output? }` and additive discovery `audioCards` while retaining endpoint lists.
- Produces `AudioRoute = { kind: "system-device"; hardwareId; latency } | { kind: "driver-stream" } | { kind: "none" }`.
- Loads version-1 legacy endpoints without `audioRoute`; new saves atomically include stable ID and resolved endpoints.

- [ ] **Step 1: Write failing identity/pairing/compatibility tests**

```ts
test("prefers USB serial and pairs Pulse endpoints through ALSA identity", () => {
  assert.deepEqual(pairAudioCards(pairedUsbFixture), [{
    hardwareId: "usb:1234:5678:SN42",
    label: "USB Audio CODEC (SN42)",
    transport: "usb",
    complete: true,
    input: pairedUsbFixture.inputs[0],
    output: pairedUsbFixture.outputs[0],
  }]);
});

test("excludes monitor sources and disambiguates duplicate serial-less cards", () => {
  const cards = pairAudioCards(duplicateFixture);
  assert.equal(cards.some((card) => card.input?.id.endsWith(".monitor")), false);
  assert.notEqual(cards[0].label, cards[1].label);
});

test("legacy version-1 profile remains valid without audioRoute", () => {
  assert.equal(parseRadioConfig(legacyFixture).radios[0].audioRoute, undefined);
});
```

- [ ] **Step 2: Run and confirm missing pairing/schema failures**

Run: `node --experimental-strip-types --test test/audio-cards.test.ts test/config.test.ts test/hardware-discovery.test.ts`

Expected: FAIL because stable card pairing and `audioRoute` are absent.

- [ ] **Step 3: Implement stable pairing and additive schema**

Retain Pulse/PipeWire `device.serial`, VID/PID, `device.bus_path`, and `alsa.card` metadata. Prefer USB serial, then VID:PID plus physical topology, then stable ALSA card ID; never use mutable ALSA card number as identity. Exclude monitor sources/classes. Mark incomplete cards honestly and add serial/port to duplicate labels. Preserve legacy explicit endpoints and exact-key validation while making new route fields optional for version-1 loads.

- [ ] **Step 4: Run checks and commit**

Run: `node --experimental-strip-types --test test/audio-cards.test.ts test/config.test.ts test/hardware-discovery.test.ts`

Run: `npm run check`

```bash
git add radio-lite-server/src/config/audio-cards.ts radio-lite-server/src/config/discovery.ts radio-lite-server/src/config/hardware-discovery.ts radio-lite-server/src/config/types.ts radio-lite-server/test/audio-cards.test.ts radio-lite-server/test/config.test.ts radio-lite-server/test/hardware-discovery.test.ts
git commit -m "feat: pair stable USB audio cards"
```

### Task 5: Startup re-resolution, real duplex preflight, and 48 kHz device conversion

**Files:**
- Modify: `radio-lite-server/src/config/hardware-preflight.ts`
- Modify: `radio-lite-server/src/media/system-media-worker.ts`
- Modify: `radio-lite-server/src/media/pcm-resampler.ts`
- Test: `radio-lite-server/test/hardware-preflight.test.ts`
- Test: `radio-lite-server/test/system-media-worker.test.ts`
- Test: `radio-lite-server/test/pcm-resampler.test.ts`

**Interfaces:**
- Consumes Task 4's stable `hardwareId` and current discovery.
- Produces `resolveAudioRoute()` and an injectable duplex probe that actually opens capture/playback and returns negotiated rates.
- Worker keeps the internal 16 kHz mono format and streams through `StreamingPcm16Resampler` to/from the normally selected 48 kHz native device rate.

- [ ] **Step 1: Write failing re-resolution, probe, and streaming conversion tests**

```ts
test("resolves saved USB card after ALSA renumbering", () => {
  const resolved = resolveAudioRoute(savedRoute, discoveryAfterRenumber);
  assert.equal(resolved.input.id, "hw:3,0");
  assert.equal(resolved.output.id, "hw:3,0");
});

test("preflight opens both directions and records negotiated rates", async () => {
  const result = await audioCheck(profile, discovery, duplexProbe);
  assert.deepEqual(duplexProbe.opened, ["capture:hw:3,0", "playback:hw:3,0"]);
  assert.deepEqual(result.negotiatedRates, { input: 48_000, output: 48_000 });
});

test("48 kHz chunks remain continuous across 16 kHz resampler boundaries", () => {
  const output = fixture.resampleInChunks(48_000, 16_000, fixture.tone);
  assert.deepEqual(output, fixture.resampleWhole(48_000, 16_000, fixture.tone));
});
```

- [ ] **Step 2: Run and confirm enumeration-only/fixed-rate failures**

Run: `node --experimental-strip-types --test test/hardware-preflight.test.ts test/system-media-worker.test.ts test/pcm-resampler.test.ts`

Expected: FAIL because preflight does not open devices, startup does not re-resolve, and commands are fixed at 16 kHz.

- [ ] **Step 3: Implement real probe and streaming rate conversion**

At preflight and worker start, discover again and resolve `hardwareId`; fail rather than silently switching to another card. Probe capture and playback separately with bounded timeouts and validate signed-16 mono negotiation. Prefer 48 kHz, then another explicitly supported native rate. Map low/balanced/stable to fixed period/buffer targets. Resample capture native→16 kHz before Opus/spectrum/decode and playback 16 kHz→native after decode/digital mix. On disconnect, re-resolve the same ID and make one bounded reconnect attempt.

- [ ] **Step 4: Run checks and commit**

Run: `node --experimental-strip-types --test test/hardware-preflight.test.ts test/system-media-worker.test.ts test/pcm-resampler.test.ts`

Run: `npm run check`

```bash
git add radio-lite-server/src/config/hardware-preflight.ts radio-lite-server/src/media/system-media-worker.ts radio-lite-server/src/media/pcm-resampler.ts radio-lite-server/test/hardware-preflight.test.ts radio-lite-server/test/system-media-worker.test.ts radio-lite-server/test/pcm-resampler.test.ts
git commit -m "feat: probe and resample USB audio devices"
```

### Task 6: iOS telemetry models, subscription, strip, and simple audio picker

**Files:**
- Create: `ios/RadioLite/Core/RadioLite/RadioLiteTelemetry.swift`
- Create: `ios/RadioLite/Features/RadioLite/RadioLiteTelemetryStrip.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteDeviceConfiguration.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteSession.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteDeviceConfigurationView.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift`
- Modify: `scripts/check-ios-radio-lite-contract.mjs`
- Test: `ios/RadioLiteTests/RadioLiteTelemetryTests.swift`
- Test: `ios/RadioLiteTests/RadioLiteDeviceConfigurationTests.swift`

**Interfaces:**
- Consumes server `RadioTelemetry`, `audioCards`, and `AudioRoute` JSON.
- Produces `RadioLiteTelemetry`, `RadioLiteMeterSample`, `RadioLiteAudioCard`, `RadioLiteAudioRoute`, and one `@Published private(set) var telemetry` cache.
- Session subscribes after authentication/radio selection and unsubscribes before radio switch or disconnect.

- [ ] **Step 1: Add failing Swift model/session tests and executable contract checks**

```swift
func testDecodesTransmitTelemetryWithoutTreatingRFPowerSettingAsMeter() throws {
    let value = try JSONDecoder().decode(RadioLiteTelemetry.self, from: fixture)
    XCTAssertEqual(value.meters.rfPowerWatts, 37.5)
    XCTAssertEqual(value.meters.swr, 1.4)
}

func testTelemetryBecomesStaleAfterThreeSamplePeriods() {
    XCTAssertTrue(sample.isStale(nowMs: sample.sampledAtMs + 6_001, periodMs: 2_000))
}
```

Extend the Node contract script to execute the protocol fixture checks for `rig.telemetry.subscribe`, `rig.telemetry`, `rig.telemetry.unsubscribe`, and `audioCards` rather than merely searching for names.

- [ ] **Step 2: Run the Windows contract test and confirm it fails**

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Expected: FAIL because the Swift telemetry/audio-card models and subscription messages are absent.

- [ ] **Step 3: Implement models, session ownership, and views**

```swift
struct RadioLiteTelemetry: Codable, Equatable, Sendable {
    let t: String
    let radioId: String
    let sampledAtMs: UInt64
    let state: RadioLiteRigState
    let meters: RadioLiteMeterSample
    let availableMeters: [String]
}
```

Render RX as a full-width S meter and TX/tune as compact PWR, SWR, and ALC bars in a 52-point strip below frequency. Unsupported, transmit-inapplicable, or stale values render `—`. Keep PTT in the bottom safe-area dock. The normal setup shows one complete USB-card picker; an advanced disclosure shows input/output overrides and the low/balanced/stable latency choice.

- [ ] **Step 4: Run contract and server checks**

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Run: `npm run check` from `radio-lite-server`

Expected: both exit 0. Swift compilation/XCTest is deferred only to the existing macOS GitHub job in the release plan.

- [ ] **Step 5: Commit**

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteTelemetry.swift ios/RadioLite/Features/RadioLite/RadioLiteTelemetryStrip.swift ios/RadioLite/Core/RadioLite/RadioLiteDeviceConfiguration.swift ios/RadioLite/Core/RadioLite/RadioLiteSession.swift ios/RadioLite/Features/RadioLite/RadioLiteDeviceConfigurationView.swift ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift ios/RadioLiteTests/RadioLiteTelemetryTests.swift ios/RadioLiteTests/RadioLiteDeviceConfigurationTests.swift scripts/check-ios-radio-lite-contract.mjs
git commit -m "feat: show shared telemetry and USB audio cards on iOS"
```

### Task 7: Slice verification and protocol compatibility

**Files:**
- Modify: `radio-lite-server/PROTOCOL.md`
- Modify: `docs/superpowers/specs/2026-08-29-universal-radio-platform-design.md`

- [ ] **Step 1: Run complete server, web, and iOS contract gates**

Run: `npm run check` from `radio-lite-server`

Run: `npm test` from `web`

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Expected: all commands exit 0.

- [ ] **Step 2: Verify acceptance behavior from tests**

Confirm the fresh test output includes: two subscribers/one sampler, receive four-command budget, transmit four-command budget, 1,024-entry trace, legacy profile load, and stable card re-resolution.

- [ ] **Step 3: Document the additive compatibility boundary**

Record that old clients retain `rig.state.get`/`rig.controls.get`, old profiles retain explicit endpoints, and only new clients save `audioRoute`. No protocol field is removed.

- [ ] **Step 4: Commit documentation if changed**

```bash
git add radio-lite-server/PROTOCOL.md docs/superpowers/specs/2026-08-29-universal-radio-platform-design.md
git commit -m "docs: record hardware foundation compatibility"
```
