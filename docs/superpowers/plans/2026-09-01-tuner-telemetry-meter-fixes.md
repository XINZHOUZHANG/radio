# Tuner and Telemetry Meter Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the internal tuner engaged after a successful tune, provide PWR/SWR/ALC samples while a tuning lease is active, and display receive strength as a correct amateur-radio S reading.

**Architecture:** Preserve the existing safety interlock. Model tuner engagement as a separate read/write control from the one-shot tune action, let telemetry sampling use an explicit transmit-activity signal rather than physical PTT alone, and move S-unit conversion into a pure iOS formatter covered by unit tests.

**Tech Stack:** TypeScript, Node test runner, Swift 5.9, XCTest, SwiftUI, GitHub Actions.

**Spec:** User-observed behavior in the Radio Lite project conversation on 2026-09-01.

## Global Constraints

- Do not weaken PTT/de-key safety checks.
- Do not perform real PTT, tuner, FT8/FT4, voice, or other RF writes during automated verification.
- Keep `action:TUNER` as the one-shot tune action and add/retain `function:TUNER` as the persistent tuner-engagement switch when the driver supports it.
- Receive mode must never present stale PWR/SWR/ALC values as current RF output.
- Tuning mode must sample transmit meters even when a radio reports physical PTT as false.
- Increment the iOS build number and include `[upload-ipa]` only in the final verified release commit.

---

### Task 1: Persistent tuner engagement

**Files:**
- Modify: `radio-lite-server/test/radio-control-catalogue.test.ts`
- Modify: `radio-lite-server/test/icom-wlan-driver.test.ts`
- Modify: `radio-lite-server/src/rig/radio-control-catalogue.ts`
- Modify: `radio-lite-server/src/rig/icom-wlan-port.ts`
- Modify: `radio-lite-server/src/rig/icom-wlan-driver.ts`

**Interfaces:**
- Produces `function:TUNER` as a read/write toggle when available.
- Keeps `action:TUNER` as a separate one-shot action.
- ICOM WLAN tune invocation enables the tuner, verifies it is not OFF, then starts manual tuning.

- [ ] Add catalogue and ICOM WLAN driver tests that expect both the switch and action.
- [ ] Run the focused server tests and confirm the new assertions fail for the missing switch/enable sequence.
- [ ] Implement the minimal catalogue and ICOM WLAN port/driver changes.
- [ ] Re-run the focused tests and confirm they pass.
- [ ] Commit the tuner fix.

### Task 2: Tuning transmit telemetry

**Files:**
- Modify: `radio-lite-server/test/radio-telemetry.test.ts`
- Modify: `radio-lite-server/test/radio-runtime.test.ts`
- Modify: `radio-lite-server/src/rig/radio-driver.ts`
- Modify: `radio-lite-server/src/rig/radio-telemetry.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`

**Interfaces:**
- Produces `RadioTelemetrySampler.confirmTransmitActivity(active: boolean)`.
- Runtime sets transmit activity only after a transmit lease commits and clears it only after stop/de-key is confirmed or no lease remains.

- [ ] Add a failing sampler test proving tuning samples PWR/SWR/ALC while `state.ptt` remains false.
- [ ] Add a failing runtime test proving a tuning lease activates transmit telemetry and stop restores receive telemetry.
- [ ] Implement explicit transmit-activity tracking without falsifying physical PTT state.
- [ ] Re-run focused telemetry/runtime tests.
- [ ] Commit the telemetry fix.

### Task 3: Correct S-meter presentation and tuner UI refresh

**Files:**
- Modify: `ios/RadioLiteTests/RadioLiteTelemetryTests.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteTelemetry.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteTelemetryStrip.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteControlDashboardView.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteSession.swift`

**Interfaces:**
- Produces a pure `RadioLiteSMeterReading` formatter for `S0...S9` and `S9+xx dB`.
- Tuner panel displays the persistent tuner switch separately from the tune action.
- Successful tune start refreshes or reflects the tuner switch without sending an extra action.

- [ ] Add failing XCTest coverage for S-unit mappings and abnormal values.
- [ ] Add/extend contract checks for separate tuner switch/action presentation.
- [ ] Implement the formatter and telemetry-strip copy.
- [ ] Expose the tuner switch in the tuner sheet and refresh its state after tune start/stop.
- [ ] Run XCTest and contract checks.
- [ ] Commit the iOS fix.

### Task 4: Full verification and release build

**Files:**
- Modify: `ios/RadioLite/project.yml`

- [ ] Run server check, web tests, protocol contracts, and iOS tests.
- [ ] Increment `CURRENT_PROJECT_VERSION` from 16 to 17.
- [ ] Commit with `[upload-ipa]` and push normally.
- [ ] Confirm every GitHub Actions job succeeds and the unsigned IPA artifact is uploaded.
- [ ] Report the final SHA, run ID, artifact name, and any remaining hardware-only verification risks.
