# Universal Radio Network Drivers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add receive-only no-radio mode plus ICOM WLAN and TCI/SunSDR control/audio while keeping Hamlib profiles compatible and all transmit evidence strict.

**Architecture:** Stored profile parsing distinguishes secret-bearing configuration from public API models. Each connection kind creates a `RadioDriver`; ICOM and TCI adapters wrap pinned upstream libraries behind narrow local ports, and a driver-audio route feeds the existing media hub. Preflight validates control plus route capabilities before an atomic save; iOS exposes five connection forms and hides saved passwords after submission.

**Tech Stack:** Node.js 24.7.0, TypeScript 5.9, `icom-wlan-node@0.6.4`, `tci-client-node@0.2.0`, ws 8.21.3, Swift 5.9, SwiftUI

**Spec:** `docs/superpowers/specs/2026-08-29-universal-radio-platform-design.md`

## Global Constraints

- Preserve existing managed serial, external rigctld, Hamlib dummy, FT8/FT4, voice and safety behavior.
- Connection kinds are no-radio, managed Hamlib serial, external rigctld, ICOM WLAN, and TCI/SunSDR; Hamlib dummy remains a test/demo profile.
- ICOM WLAN and TCI default to driver audio; USB audio is an explicit advanced override.
- Secrets are stored by the existing 0600 atomic JSON policy and never returned by GET `/radios`, discovery, websocket welcome, logs, or errors.
- TCI WebSockets disable compression, bound payload size, and reject public endpoints unless explicitly allowed by the existing authenticated service configuration.
- TCI `sampleCount` is the scalar count across channels and must not be multiplied by channel count.
- Emergency PTT OFF remains outside ordinary command budgets.
- Node is pinned to 24.7.0; iOS is 17+ with Swift 5.9.

---

### Task 1: Version-compatible connection/audio configuration and public redaction

**Files:**
- Modify: `radio-lite-server/package.json`
- Modify: `radio-lite-server/package-lock.json`
- Modify: `radio-lite-server/src/config/types.ts`
- Modify: `radio-lite-server/src/config/radio-config-store.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Test: `radio-lite-server/test/config.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`

**Interfaces:**
- Produces stored connection unions `NoRadioConnection`, `IcomWlanConnection`, and `TciConnection` in addition to existing connections.
- Produces `PublicRadioProfile` and `toPublicRadioProfile(profile)` that never contain password/secret fields.
- Consumes `AudioRoute` from the hardware-foundation plan.

- [ ] **Step 1: Write failing parse/redaction tests**

```ts
test("loads an ICOM WLAN profile but redacts its password publicly", () => {
  const stored = parseRadioProfile(icomFixture);
  assert.equal(stored.connection.kind, "icom-wlan");
  assert.equal(stored.connection.password, "station-secret");
  const publicValue = toPublicRadioProfile(stored);
  assert.equal(JSON.stringify(publicValue).includes("station-secret"), false);
  assert.equal("password" in publicValue.connection, false);
});

test("loads every legacy version-1 profile unchanged", () => {
  assert.deepEqual(parseRadioConfig(legacyFixture), legacyExpected);
});
```

- [ ] **Step 2: Run and confirm unsupported-kind failure**

Run: `node --experimental-strip-types --test test/config.test.ts test/http-service.test.ts`

Expected: FAIL because the new connection unions/public projection do not exist.

- [ ] **Step 3: Add exact dependencies and implement schema/public projection**

Run: `npm install --save-exact icom-wlan-node@0.6.4 tci-client-node@0.2.0`

Connection shapes are exact-key parsed: no-radio has only `kind`; ICOM has `kind`, `host`, optional `port`, `username`, and write-only `password`; TCI has `kind`, `url`, `trx`, and optional explicit public-endpoint approval. New driver kinds do not require `hamlibModelId`; legacy kinds retain it. Driver-stream and none audio routes do not require legacy endpoints. Every public response goes through `toPublicRadioProfile`.

- [ ] **Step 4: Run checks**

Run: `node --experimental-strip-types --test test/config.test.ts test/http-service.test.ts`

Run: `npm run check`

Expected: exit 0 and no serialized response includes fixture secrets.

- [ ] **Step 5: Commit**

```bash
git add radio-lite-server/package.json radio-lite-server/package-lock.json radio-lite-server/src/config/types.ts radio-lite-server/src/config/radio-config-store.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/config.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: add secure network radio profiles"
```

### Task 2: No-radio receive driver

**Files:**
- Create: `radio-lite-server/src/rig/no-radio-driver.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Test: `radio-lite-server/test/no-radio-driver.test.ts`
- Test: `radio-lite-server/test/radio-runtime.test.ts`

**Interfaces:**
- Produces `NoRadioDriver implements RadioDriver` with a deterministic receive state, empty capabilities/meters/controls, and no transmit/action support.

- [ ] **Step 1: Write failing receive-only tests**

```ts
test("no-radio initializes for decode-only use and reports no TX", async () => {
  const driver = new NoRadioDriver();
  await driver.initialize();
  assert.equal((await driver.capabilities()).canTransmit, false);
  assert.deepEqual(await driver.readControls(), []);
  await assert.rejects(driver.writePtt(true), /receive-only/);
  await driver.writePtt(false);
});
```

- [ ] **Step 2: Run and confirm missing driver failure**

Run: `node --experimental-strip-types --test test/no-radio-driver.test.ts test/radio-runtime.test.ts`

Expected: FAIL because `NoRadioDriver` is absent.

- [ ] **Step 3: Implement no-radio semantics**

PTT ON, control writes, mode/frequency writes, and actions reject with stable unsupported errors. Emergency OFF is an idempotent no-op and `readPtt()` is always false so cleanup remains confirmable. Runtime transmit admission rejects before reserving a lease.

- [ ] **Step 4: Run checks and commit**

Run: `node --experimental-strip-types --test test/no-radio-driver.test.ts test/radio-runtime.test.ts`

Run: `npm run check`

```bash
git add radio-lite-server/src/rig/no-radio-driver.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/test/no-radio-driver.test.ts radio-lite-server/test/radio-runtime.test.ts
git commit -m "feat: add receive-only no-radio driver"
```

### Task 3: ICOM WLAN driver and network audio port

**Files:**
- Create: `radio-lite-server/src/rig/icom-wlan-port.ts`
- Create: `radio-lite-server/src/rig/icom-wlan-driver.ts`
- Create: `radio-lite-server/src/media/driver-audio.ts`
- Test: `radio-lite-server/test/icom-wlan-driver.test.ts`
- Test: `radio-lite-server/test/driver-audio.test.ts`

**Interfaces:**
- Produces `IcomWlanPort` wrapping `icom-wlan-node@0.6.4` and injectable for tests.
- Produces `IcomWlanDriver implements RadioDriver` and optional `DriverAudioSource/DriverAudioSink` at 12 kHz PCM.
- Produces `DriverAudioDuplex` shared with TCI.

- [ ] **Step 1: Write failing state/PTT/meter/audio tests against a real local fake port**

```ts
test("ICOM driver confirms PTT by read-back", async () => {
  await driver.writePtt(true);
  assert.equal(await driver.readPtt(), true);
  assert.deepEqual(port.calls.slice(-2), ["writePtt:true", "readPtt"]);
});

test("ICOM driver forwards exact 12 kHz mono PCM frame", async () => {
  port.emitAudio(Int16Array.of(100, -100, 200, -200));
  assert.deepEqual(await audio.read(), Int16Array.of(100, -100, 200, -200));
});
```

- [ ] **Step 2: Run and confirm missing adapter failure**

Run: `node --experimental-strip-types --test test/icom-wlan-driver.test.ts test/driver-audio.test.ts`

Expected: FAIL because the port, driver, and duplex do not exist.

- [ ] **Step 3: Implement narrow library wrapper**

Map only documented controls for IC-705/905/7300/9700/7610/7760. Normalize frequency/mode/PTT/split/RIT/XIT/meters through shared types. Do not log constructor options or credentials. Bound audio buffers; drop oldest RX audio on overflow; reject TX writes after close. Disconnect while owned TX must surface to the runtime supervisor for dekey recovery.

- [ ] **Step 4: Run checks and commit**

Run: `node --experimental-strip-types --test test/icom-wlan-driver.test.ts test/driver-audio.test.ts`

Run: `npm run check`

```bash
git add radio-lite-server/src/rig/icom-wlan-port.ts radio-lite-server/src/rig/icom-wlan-driver.ts radio-lite-server/src/media/driver-audio.ts radio-lite-server/test/icom-wlan-driver.test.ts radio-lite-server/test/driver-audio.test.ts
git commit -m "feat: add ICOM WLAN control and audio"
```

### Task 4: Secure TCI driver and network audio

**Files:**
- Create: `radio-lite-server/src/rig/tci-port.ts`
- Create: `radio-lite-server/src/rig/tci-driver.ts`
- Test: `radio-lite-server/test/tci-driver.test.ts`
- Test: `radio-lite-server/test/tci-port.test.ts`

**Interfaces:**
- Produces `TciPort` wrapping `tci-client-node@0.2.0` with injected WebSocket construction.
- Produces `TciDriver implements RadioDriver` and `DriverAudioDuplex`.

- [ ] **Step 1: Write failing secure transport and scalar sample-count tests**

```ts
test("TCI transport disables compression and bounds payloads", async () => {
  await port.connect();
  assert.deepEqual(socketFactory.lastOptions, { perMessageDeflate: false, maxPayload: 1_048_576 });
});

test("TCI sampleCount is not multiplied by channel count", () => {
  port.receiveAudio({ channels: 2, sampleCount: 4, samples: Float32Array.of(0.1, -0.1, 0.2, -0.2) });
  assert.equal(audio.lastFrame.length, 4);
});
```

Add a local mock handshake test covering frequency, mode, RX audio, PTT, and `TX_CHRONO` TX acknowledgement.

- [ ] **Step 2: Run and confirm missing driver failure**

Run: `node --experimental-strip-types --test test/tci-port.test.ts test/tci-driver.test.ts`

Expected: FAIL because the secure transport/driver do not exist.

- [ ] **Step 3: Implement the TCI adapter**

Accept `ws:` only for loopback/private addresses and `wss:` for other explicitly approved addresses. Inject ws with `perMessageDeflate: false`, `maxPayload: 1_048_576`, connection timeout, and bounded audio queues. Map receiver/transceiver selection, VFO, mode, sensors, PTT, RX audio, TX audio, and `TX_CHRONO`; retain strict PTT read-back semantics.

- [ ] **Step 4: Run checks and commit**

Run: `node --experimental-strip-types --test test/tci-port.test.ts test/tci-driver.test.ts`

Run: `npm run check`

```bash
git add radio-lite-server/src/rig/tci-port.ts radio-lite-server/src/rig/tci-driver.ts radio-lite-server/test/tci-port.test.ts radio-lite-server/test/tci-driver.test.ts
git commit -m "feat: add secure TCI control and audio"
```

### Task 5: Runtime factory, route preflight, and media-hub integration

**Files:**
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/src/config/hardware-preflight.ts`
- Modify: `radio-lite-server/src/media/media-hub.ts`
- Modify: `radio-lite-server/src/media/system-media-worker.ts`
- Test: `radio-lite-server/test/radio-runtime.test.ts`
- Test: `radio-lite-server/test/hardware-preflight.test.ts`
- Test: `radio-lite-server/test/media-hub.test.ts`

**Interfaces:**
- Consumes all five production driver kinds plus dummy.
- Routes `driver-stream` through `DriverAudioDuplex`, `system-device` through the existing worker, and `none` without an audio worker.

- [ ] **Step 1: Write failing factory/route tests**

```ts
test("ICOM and TCI default to driver-stream while Hamlib defaults to system-device", () => {
  assert.equal(defaultAudioRoute(icomProfile).kind, "driver-stream");
  assert.equal(defaultAudioRoute(tciProfile).kind, "driver-stream");
  assert.equal(defaultAudioRoute(hamlibProfile).kind, "system-device");
});

test("preflight rejects driver-stream when driver lacks network audio", async () => {
  await assert.rejects(preflight(noAudioIcomProfile), /driver audio unavailable/);
});
```

- [ ] **Step 2: Run and confirm route/factory failures**

Run: `node --experimental-strip-types --test test/radio-runtime.test.ts test/hardware-preflight.test.ts test/media-hub.test.ts`

Expected: FAIL because new drivers/routes are not wired.

- [ ] **Step 3: Implement connection factory and atomic preflight**

Initialize the candidate driver, read capabilities/state/PTT, open the selected audio route, verify format, then close all candidate resources before save. A failed close quarantines claimed serial/audio resources. On runtime disconnect while Radio Lite owns TX, invoke the existing supervisor recovery path. Ensure one exclusive system card cannot be active in two profiles.

- [ ] **Step 4: Run checks and commit**

Run: `node --experimental-strip-types --test test/radio-runtime.test.ts test/hardware-preflight.test.ts test/media-hub.test.ts`

Run: `npm run check`

```bash
git add radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/src/config/hardware-preflight.ts radio-lite-server/src/media/media-hub.ts radio-lite-server/src/media/system-media-worker.ts radio-lite-server/test/radio-runtime.test.ts radio-lite-server/test/hardware-preflight.test.ts radio-lite-server/test/media-hub.test.ts
git commit -m "feat: route network radio control and audio"
```

### Task 6: iOS five-connection setup and route UI

**Files:**
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteDeviceConfiguration.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteModels.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteSession.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteDeviceConfigurationView.swift`
- Create: `ios/RadioLite/Features/RadioLite/RadioLiteConnectionForms.swift`
- Modify: `scripts/check-ios-radio-lite-contract.mjs`
- Test: `ios/RadioLiteTests/RadioLiteDeviceConfigurationTests.swift`
- Test: `ios/RadioLiteTests/RadioLiteModelsTests.swift`

**Interfaces:**
- Consumes public profiles that never echo passwords and discovery/preflight responses for every connection kind.
- Produces five connection tabs, driver-specific fields, default route selection, and explicit advanced system-device override.

- [ ] **Step 1: Add failing Swift fixture tests and executable contract checks**

```swift
func testConnectionKindsUseExpectedDefaultAudioRoute() {
    XCTAssertEqual(RadioLiteConnectionKind.icomWlan.defaultAudioRoute, .driverStream)
    XCTAssertEqual(RadioLiteConnectionKind.tci.defaultAudioRoute, .driverStream)
    XCTAssertEqual(RadioLiteConnectionKind.managedSerial.defaultAudioRoute.kind, .systemDevice)
}

func testPublicProfileDecodesWithoutSavedIcomPassword() throws {
    let profile = try JSONDecoder().decode(RadioLiteRadioProfile.self, from: publicIcomFixture)
    XCTAssertEqual(profile.connection.kind, .icomWlan)
}
```

- [ ] **Step 2: Run contract test and confirm failure**

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Expected: FAIL because no-radio/ICOM/TCI forms and routes are absent.

- [ ] **Step 3: Implement forms and validation**

Show only fields required by the selected driver. Treat the password as write-only: clear it after successful save and never infer an empty response means the stored password was deleted. Default ICOM/TCI to driver audio; expose the stable USB picker only inside an advanced override. Keep dummy in diagnostics/demo, not the five primary choices.

- [ ] **Step 4: Run checks and commit**

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Run: `npm run check` from `radio-lite-server`

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteDeviceConfiguration.swift ios/RadioLite/Core/RadioLite/RadioLiteModels.swift ios/RadioLite/Core/RadioLite/RadioLiteSession.swift ios/RadioLite/Features/RadioLite/RadioLiteDeviceConfigurationView.swift ios/RadioLite/Features/RadioLite/RadioLiteConnectionForms.swift ios/RadioLiteTests/RadioLiteDeviceConfigurationTests.swift ios/RadioLiteTests/RadioLiteModelsTests.swift scripts/check-ios-radio-lite-contract.mjs
git commit -m "feat: configure five radio connection types on iOS"
```

### Task 7: Slice verification and protocol documentation

**Files:**
- Modify: `radio-lite-server/PROTOCOL.md`

- [ ] **Step 1: Run server, web, and contract gates**

Run: `npm run check` from `radio-lite-server`

Run: `npm test` from `web`

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Expected: all exit 0.

- [ ] **Step 2: Inspect secret and network boundaries**

Verify test output proves passwords absent from every public response/error, WebSocket compression disabled, payload bounded, TCI scalar sample counts preserved, and no-radio cannot reserve TX.

- [ ] **Step 3: Commit protocol details**

```bash
git add radio-lite-server/PROTOCOL.md
git commit -m "docs: describe network radio profiles"
```
