# Universal Radio Hamlib Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover Hamlib capabilities at runtime, expose accurate grouped descriptors and actions, and render only supported controls in native iOS.

**Architecture:** A Hamlib catalogue converts supported levels, functions, parameters, and explicit rigctld operations into the shared `RadioControl` descriptor. `HamlibDriver` owns normalization and command mapping; `RadioRuntime` enforces lease/transmit locks. New capability protocol messages are additive and the old flat-control response is derived from the same catalogue.

**Tech Stack:** Node.js 24.7.0, TypeScript 5.9, rigctld protocol, node:test, Swift 5.9, SwiftUI, iOS 17

**Spec:** `docs/superpowers/specs/2026-08-29-universal-radio-platform-design.md`

## Global Constraints

- Never show a working-looking control whose backend is unavailable.
- Preserve all existing PTT, tuner, media, FT8/FT4, voice, pairing, and control-lease behavior.
- `RFPOWER` is a transmit-power setting; actual power meters are read-only telemetry.
- Transmit-sensitive controls are disabled while transmitting and without the control lease.
- Existing `rig.controls.get` and numeric `rig.control.set` clients remain valid.
- Node is pinned to 24.7.0; iOS is 17+ with Swift 5.9.

---

### Task 1: Descriptor model and Hamlib catalogue

**Files:**
- Create: `radio-lite-server/src/rig/radio-control-catalogue.ts`
- Modify: `radio-lite-server/src/rig/radio-driver.ts`
- Modify: `radio-lite-server/src/rig/hamlib-rig.ts`
- Modify: `radio-lite-server/src/rig/hamlib-driver.ts`
- Test: `radio-lite-server/test/radio-control-catalogue.test.ts`
- Test: `radio-lite-server/test/hamlib-rig.test.ts`

**Interfaces:**
- Produces `RadioControl` with `group`, `access`, `presentation`, typed `value`, optional bounds/options/unit, and `transmitLocked`.
- Produces `HamlibControlCatalogue.discover()` and stable descriptor IDs based on generic Hamlib tokens.

- [ ] **Step 1: Write failing literal-fixture tests**

```ts
test("maps reported Hamlib tokens to grouped descriptors", async () => {
  const controls = await fixture.catalogue.discover({
    levels: ["RFPOWER", "STRENGTH", "MICGAIN"],
    functions: ["NB", "TUNER"],
    parameters: ["KEYSPD"],
  });
  assert.deepEqual(controls.map(({ id, group, access, presentation }) => ({ id, group, access, presentation })), [
    { id: "level:RFPOWER", group: "rf", access: "read-write", presentation: "slider" },
    { id: "level:STRENGTH", group: "rf", access: "read-only", presentation: "meter" },
    { id: "level:MICGAIN", group: "audio", access: "read-write", presentation: "slider" },
    { id: "function:NB", group: "rf", access: "read-write", presentation: "toggle" },
    { id: "action:TUNER", group: "rf", access: "action", presentation: "button" },
    { id: "parameter:KEYSPD", group: "cw", access: "read-write", presentation: "discrete" },
  ]);
});

test("omits malformed and unsupported advertised controls", async () => {
  const controls = await fixture.catalogue.discover({ levels: ["VENDOR_MAGIC", ""], functions: [] });
  assert.deepEqual(controls, []);
});
```

- [ ] **Step 2: Run and confirm missing catalogue failure**

Run: `node --experimental-strip-types --test test/radio-control-catalogue.test.ts test/hamlib-rig.test.ts`

Expected: FAIL because the descriptor catalogue does not exist.

- [ ] **Step 3: Implement the complete generic catalogue**

Cover RF tokens `RFPOWER`, `RF`, `NB`, `NR`, `AGC`, `PREAMP`, `ATT`, `APF`, `IF`, `PBT_IN`, `PBT_OUT`, `NOTCHF`, `ANF`, `MN`; audio tokens `AF`, `SQL`, `MICGAIN`, `COMP`, `MON`, `MONITOR_GAIN`, `VOX`, `VOXGAIN`, `ANTIVOX`, `VOXDELAY`, `BAL`, `MUTE`; operation tokens mode/passband, `SPLIT`, `RIT`, `XIT`, `LOCK`, `TUNER`; CW/repeater tokens `SBKIN`, `FBKIN`, `BKINDL`, `BKIN_DLYMS`, `CWPITCH`, `KEYSPD`, tuning step, repeater shift/offset, CTCSS, and DCS. Stable generic spectrum/system tokens may be mapped only when Hamlib reports usable bounds or options.

- [ ] **Step 4: Run checks**

Run: `node --experimental-strip-types --test test/radio-control-catalogue.test.ts test/hamlib-rig.test.ts`

Run: `npm run check`

Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add radio-lite-server/src/rig/radio-control-catalogue.ts radio-lite-server/src/rig/radio-driver.ts radio-lite-server/src/rig/hamlib-rig.ts radio-lite-server/src/rig/hamlib-driver.ts radio-lite-server/test/radio-control-catalogue.test.ts radio-lite-server/test/hamlib-rig.test.ts
git commit -m "feat: describe complete Hamlib control capabilities"
```

### Task 2: Explicit Hamlib operations and actions

**Files:**
- Modify: `radio-lite-server/src/rig/hamlib-rig.ts`
- Modify: `radio-lite-server/src/rig/hamlib-driver.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Test: `radio-lite-server/test/hamlib-rig.test.ts`
- Test: `radio-lite-server/test/radio-runtime.test.ts`

**Interfaces:**
- Consumes shared descriptors from Task 1.
- Produces typed `setControl(id, value)` and `invokeAction(id)` mappings for mode bandwidth, split, RIT/XIT, tuning step, repeater shift/offset, CTCSS/DCS, and tuner.

- [ ] **Step 1: Write failing command-mapping and admission tests**

```ts
test("writes split and signed RIT through explicit rigctld commands", async () => {
  await fixture.driver.setControl("operation:SPLIT", true);
  await fixture.driver.setControl("operation:RIT", -450);
  assert.deepEqual(fixture.commands, ["\\set_split_vfo 1 VFOB", "\\set_rit -450"]);
});

test("runtime blocks transmit-locked operation before driver invocation", async () => {
  await assert.rejects(
    runtime.setControl(owner, token, "repeater:OFFSET", 600_000),
    RigControlTransmitLockedError,
  );
  assert.equal(driver.setControlCalls, 0);
});
```

- [ ] **Step 2: Run and verify expected missing mappings**

Run: `node --experimental-strip-types --test test/hamlib-rig.test.ts test/radio-runtime.test.ts`

Expected: FAIL on the first absent explicit operation.

- [ ] **Step 3: Implement validation and exact command adapters**

Validate enum membership, numeric bounds and increments before transport writes. Re-read the changed value when Hamlib supports it; otherwise return the normalized confirmed write value. Tuner action must continue to use the existing transmit interlock rather than a raw `TUNE 1` write.

- [ ] **Step 4: Run focused and full checks**

Run: `node --experimental-strip-types --test test/hamlib-rig.test.ts test/radio-runtime.test.ts`

Run: `npm run check`

Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add radio-lite-server/src/rig/hamlib-rig.ts radio-lite-server/src/rig/hamlib-driver.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/test/hamlib-rig.test.ts radio-lite-server/test/radio-runtime.test.ts
git commit -m "feat: add Hamlib operation and action adapters"
```

### Task 3: Additive capability websocket protocol

**Files:**
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/PROTOCOL.md`
- Test: `radio-lite-server/test/http-service.test.ts`

**Interfaces:**
- Produces `rig.capabilities.get` → `rig.capabilities`, generalized `rig.control.set`, and `rig.action.invoke` → `rig.action.confirmed`.
- Preserves the old flat `rig.controls` response, derived from the same descriptors.

- [ ] **Step 1: Write failing authenticated protocol tests**

```ts
test("capabilities response contains grouped descriptors but no unsupported controls", async () => {
  const reply = await authenticatedRequest({ t: "rig.capabilities.get", radioId: "main", commandId: "caps-1" });
  assert.equal(reply.t, "rig.capabilities");
  assert.equal(reply.controls.some((control) => control.id === "vendor:missing"), false);
  assert.equal(reply.controls.find((control) => control.id === "level:RFPOWER").group, "rf");
});

test("action invocation requires the control lease", async () => {
  const reply = await authenticatedRequest({ t: "rig.action.invoke", radioId: "main", id: "action:TUNER", commandId: "a-1" });
  assert.equal(reply.t, "command.error");
  assert.equal(reply.code, "invalid_control_lease");
});
```

- [ ] **Step 2: Run and confirm unknown-message failures**

Run: `node --experimental-strip-types --test test/http-service.test.ts`

Expected: FAIL because the capability and action messages are not handled.

- [ ] **Step 3: Implement handlers and compatibility projection**

Return only public descriptor data. Require authentication for reads and the active control token for writes/actions. Include `requestId` and `requestType` correlation on errors. Map typed boolean/number/string values without coercing arbitrary strings to numbers.

- [ ] **Step 4: Run checks**

Run: `node --experimental-strip-types --test test/http-service.test.ts`

Run: `npm run check`

Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/PROTOCOL.md radio-lite-server/test/http-service.test.ts
git commit -m "feat: expose grouped radio capabilities"
```

### Task 4: Native iOS grouped capability controls

**Files:**
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteRigControls.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteSession.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteRigControlsView.swift`
- Create: `ios/RadioLite/Features/RadioLite/RadioLiteCapabilityGroupView.swift`
- Create: `ios/RadioLite/Features/RadioLite/RadioLiteCapabilityControlRow.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift`
- Modify: `scripts/check-ios-radio-lite-contract.mjs`
- Test: `ios/RadioLiteTests/RadioLiteCapabilityControlsTests.swift`
- Test: `ios/RadioLiteTests/RadioLiteRigControlsTests.swift`

**Interfaces:**
- Consumes `rig.capabilities`, typed control confirmations, and action confirmations.
- Produces Swift enums for group/access/presentation/unit, typed JSON control values, grouped ordering, and native rows for meter/toggle/slider/discrete/enum/offset/button.

- [ ] **Step 1: Write failing model/behavior tests and contract fixture checks**

```swift
func testGroupsControlsInStableProductOrder() throws {
    let controls = try decodeCapabilitiesFixture()
    XCTAssertEqual(RadioLiteCapabilityGroups(controls).groups.map(\.id), [.rf, .audio, .cw])
}

func testTransmitLockedControlIsDisabledDuringTransmit() throws {
    let control = try XCTUnwrap(decodeCapabilitiesFixture().first)
    XCTAssertFalse(control.displayState(isTransmitting: true, hasControl: true).isEnabled)
}
```

Make the Node contract script feed literal `rig.capabilities` JSON through the Swift model field list and assert request message shapes for capability read, typed set, and action invocation.

- [ ] **Step 2: Run and confirm the contract test fails**

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Expected: FAIL because capability models and request shapes are absent.

- [ ] **Step 3: Implement grouped controls and session ownership**

Render native toggles, continuous sliders, stepped choices, menus/pickers, signed offsets, read-only meters, and buttons. Disable writes without the lease and all `transmitLocked` controls during TX. Keep the tuner button in the safe-area dock, but source its availability/action from the descriptor catalogue. Unsupported controls are absent from the normal list.

- [ ] **Step 4: Run contract and server checks**

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Run: `npm run check` from `radio-lite-server`

Expected: exit 0. Swift XCTest/build runs on macOS in the release plan.

- [ ] **Step 5: Commit**

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteRigControls.swift ios/RadioLite/Core/RadioLite/RadioLiteSession.swift ios/RadioLite/Features/RadioLite/RadioLiteRigControlsView.swift ios/RadioLite/Features/RadioLite/RadioLiteCapabilityGroupView.swift ios/RadioLite/Features/RadioLite/RadioLiteCapabilityControlRow.swift ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift ios/RadioLiteTests/RadioLiteCapabilityControlsTests.swift ios/RadioLiteTests/RadioLiteRigControlsTests.swift scripts/check-ios-radio-lite-contract.mjs
git commit -m "feat: render grouped radio capabilities on iOS"
```

### Task 5: Slice verification

**Files:**
- Modify: `radio-lite-server/PROTOCOL.md`

- [ ] **Step 1: Run complete gates**

Run: `npm run check` from `radio-lite-server`

Run: `npm test` from `web`

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Expected: all exit 0.

- [ ] **Step 2: Inspect protocol fixtures for compatibility**

Verify old `rig.controls.get` returns usable flat entries; new capability reads expose all supported catalogue groups; unknown controls are absent; action/write failures preserve request correlation.

- [ ] **Step 3: Commit any protocol clarification**

```bash
git add radio-lite-server/PROTOCOL.md
git commit -m "docs: describe Hamlib capability controls"
```
