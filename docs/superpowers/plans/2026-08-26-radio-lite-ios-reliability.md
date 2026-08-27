# Radio Lite iOS Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the native Radio Lite client safe and comprehensible on weak networks while preserving legacy-server operation and immediate local microphone release.

**Architecture:** Keep protocol decoding, ordering, safety presentation, and spectrum projection in small pure Swift value types; `RadioLiteSession` remains the `@MainActor` coordinator that owns sockets, audio, and published UI state. The server is the sole authority for persistent transmit/safety banners when it advertises `safetyAlerts`; local input supplies only transient request/stop progress and an explicitly stale fallback.

**Tech Stack:** Swift 5.9, SwiftUI, Combine, XCTest, URLSession WebSocket, AVFoundation/UIKit, XcodeGen, Node contract checker.

**Spec:** `docs/superpowers/specs/2026-08-26-radio-lite-safety-reliability-design.md` (sections 9, 13–15, 17, and implementation slices 7–8).

## Global Constraints

- Keep protocol version 1 and accept servers that omit all new feature flags; omitted flags are `false` and select an explicit compatibility presentation.
- HTTP request/resource timeout remains exactly 300 seconds and `waitsForConnectivity` remains enabled.
- Normal control-WebSocket requests timeout in exactly 15 seconds; timing out closes the stale socket, fails all pending requests, and enters existing reconnect handling.
- Stop and emergency-stop release microphone capture, media uplink, and the local AVAudioSession before awaiting any network response.
- A successful `tx.stop` reply clears only local stop-retry identity; it never clears a server safety banner.
- Only a complete matching `SafetyAlertSnapshot` set can replace or clear a disconnected stale persistent banner.
- `rig.state.ptt`, a held-button Boolean, and a transmit token are not persistent safety authority.
- The iOS display window is AppStorage-backed, 3000...4000 Hz, default 4000 Hz, and quantized in 100-Hz increments; it never reconnects or changes passband.
- Spectrum history is at most 32 rows; each accepted row has at most 512 raw bins; rendering is at most 96 columns after per-row crop.
- Preserve Dummy operation, HTTP/Tailscale input, existing control leases, digital/FT8 behavior, and current immediate microphone release.
- Do not commit generated `ios/RadioLite/RadioLite.xcodeproj`; generate it locally from `ios/RadioLite/project.yml` before every Xcode test run.
- Before starting Tasks 1–7 on macOS, run the following once in the same shell session; an operator may instead export a specific available destination. Every XCTest command below consumes this value and never assumes an `iPhone 16` exists:

```bash
SIMULATOR_UDID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; p=json.load(sys.stdin); print(next(d["udid"] for r,ds in p["devices"].items() if "iOS" in r for d in ds if d.get("isAvailable") and "iPhone" in d.get("name", "")))')
export RADIO_LITE_SIMULATOR_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"
```

---

## File Map and Interfaces

| File | Responsibility |
|---|---|
| `ios/RadioLite/Core/RadioLite/RadioLiteModels.swift` | Feature flags, health response, safety-wire models, and safety banner values. |
| `ios/RadioLite/Core/RadioLite/RadioLiteServer.swift` | Separate HTTP, normal WS, and stop retry timing constants. |
| `ios/RadioLite/Core/RadioLite/RadioLiteWebSocketChannel.swift` | Per-request WS deadlines and timeout-triggered socket failure. |
| `ios/RadioLite/Core/RadioLite/RadioLiteControlClient.swift` | 15-second ping cadence and typed timeout forwarding. |
| `ios/RadioLite/Core/RadioLite/RadioLiteHTTPClient.swift` | Health capability decoding, hardware-test-only 404 mapping, and the typed administrator SWR-trip reset request. |
| `ios/RadioLite/Core/RadioLite/RadioLiteRigStateRevision.swift` | Pure ownership tokens preventing stale rig polling results. |
| `ios/RadioLite/Core/RadioLite/RadioLiteRadioSelectionPresentation.swift` | Radio-scoped keyboard/popup ownership tokens and synchronous selection reset. |
| `ios/RadioLite/Core/RadioLite/RadioLiteTransmitStopState.swift` | Pure pending-stop identity, retries, and remote-unconfirmed fallback. |
| `ios/RadioLite/Core/RadioLite/RadioLiteSafetyAlertState.swift` | Atomic snapshot/event reducer, epoch/revision rules, and stale projection. |
| `ios/RadioLite/Core/RadioLite/RadioLiteMediaFrame.swift` | Bounded raw per-row spectrum history and crop-before-downsample projection. |
| `ios/RadioLite/Core/RadioLite/RadioLiteMediaClient.swift` | Decoder-boundary bin validation and published `SpectrumHistoryRow` values. |
| `ios/RadioLite/Core/RadioLite/RadioLiteSession.swift` | Integration owner for health, revisions, stop sequencing, safety events, reconnect fallback, emergency stop, keyboard/popover/FT8 stabilization, and haptics. |
| `ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift` | Server-authoritative banner, emergency action, administrator-confirmed SWR recovery, accessible hold controls, and spectrum window UI. |
| `ios/RadioLite/Features/RadioLite/RadioLiteSettingsView.swift` | Unencrypted-link warning, capabilities, window setting, and feature-gated administration links. |
| `ios/RadioLite/Features/RadioLite/RadioLiteDeviceConfigurationView.swift` | Feature-gated proof/preflight, range/SWR, and explicit runtime-stop preflight flow. |
| `ios/RadioLiteTests/*.swift` | Focused pure-state, protocol, spectrum, and accessibility-policy tests listed by task. |
| `scripts/check-ios-radio-lite-contract.mjs` | Add the new health keys, WS messages, safety event names, and spectrum contract assertions with their server/protocol counterparts. |

```swift
struct RadioLiteServerFeatures: Codable, Equatable, Sendable {
    let hardwarePreflight: Bool
    let preflightProof: Bool
    let emergencyStop: Bool
    let safetyAlerts: Bool
    let accountAdministration: Bool
    let spectrumDisplayWindow: Bool
    let swrTripReset: Bool
    static let unsupported = Self(hardwarePreflight: false, preflightProof: false,
        emergencyStop: false, safetyAlerts: false, accountAdministration: false,
        spectrumDisplayWindow: false, swrTripReset: false)
}

struct RadioLiteRigStateRequestToken: Equatable, Sendable { let revision: UInt64; let generation: UInt64 }

struct RadioLiteTransmitStopKey: Equatable, Sendable {
    let radioId: String; let transmitToken: String; let mode: String
    let startedAckRevision: UInt64
}

struct RadioLiteTransmitStopAttempt: Equatable, Sendable {
    let key: RadioLiteTransmitStopKey
    var stopPending: Bool
    var retryAttempt: Int
}

struct SpectrumHistoryRow: Equatable, Sendable {
    let bins: [UInt8]; let frameSpanHz: UInt32; let centerFrequencyHz: UInt64
}
```

### Task 1: Capability negotiation, endpoint-specific 404, and network deadlines

**Files:**
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteModels.swift`, `RadioLiteServer.swift`, `RadioLiteWebSocketChannel.swift`, `RadioLiteControlClient.swift`, `RadioLiteHTTPClient.swift`, `RadioLiteSession.swift`
- Modify: `ios/RadioLiteTests/RadioLiteModelsTests.swift`, `RadioLiteServerTests.swift`, `RadioLiteHTTPErrorPresentationTests.swift`
- Modify: `scripts/check-ios-radio-lite-contract.mjs`, `radio-lite-server/PROTOCOL.md`

**Interfaces:**
- Produces `RadioLiteHealth.features: RadioLiteServerFeatures`, `RadioLiteNetworkPolicy.httpTimeout`, `webSocketCommandTimeout`, `stopSendTimeout`, and `RadioLiteControlClient.request(_:expecting:commandId:timeout:)`.
- `RadioLiteWebSocketChannel.request(_:expecting:commandId:requestType:timeout:)` calls `disconnect(notify: true)` after failing its own continuation and all other pending requests.

- [ ] **Step 1: Write failing decoding, deadline, and error-presentation tests**

```swift
func testMissingHealthFeaturesUsesExplicitLegacyCompatibility() throws {
    let health = try JSONDecoder().decode(RadioLiteHealth.self, from: Data(#"{"status":"ok","service":"radio-lite","protocolVersion":1}"#.utf8))
    XCTAssertEqual(health.features, .unsupported)
}

func testOlderSixFlagHealthDefaultsOnlySWRTripResetToFalse() throws {
    let data = Data(#"""
    {"status":"ok","service":"radio-lite","protocolVersion":1,"features":{
      "hardwarePreflight":true,"preflightProof":true,"emergencyStop":true,
      "safetyAlerts":true,"accountAdministration":true,"spectrumDisplayWindow":true}}
    """#.utf8)
    let health = try JSONDecoder().decode(RadioLiteHealth.self, from: data)
    XCTAssertTrue(health.features.hardwarePreflight)
    XCTAssertTrue(health.features.spectrumDisplayWindow)
    XCTAssertFalse(health.features.swrTripReset)
}

func testHealthDecodesAllSevenAdvertisedFeatureFlags() throws {
    let data = Data(#"""
    {"status":"ok","service":"radio-lite","protocolVersion":1,"features":{
      "hardwarePreflight":true,"preflightProof":true,"emergencyStop":true,
      "safetyAlerts":true,"accountAdministration":true,"spectrumDisplayWindow":true,
      "swrTripReset":true}}
    """#.utf8)
    let features = try JSONDecoder().decode(RadioLiteHealth.self, from: data).features
    XCTAssertEqual([
        features.hardwarePreflight, features.preflightProof, features.emergencyStop,
        features.safetyAlerts, features.accountAdministration,
        features.spectrumDisplayWindow, features.swrTripReset,
    ].filter { $0 }.count, 7)
}

func testHTTPIsFiveMinutesButNormalWebSocketCommandsAreFifteenSeconds() throws {
    XCTAssertEqual(RadioLiteNetworkPolicy.request(url: try XCTUnwrap(URL(string: "http://radio/healthz"))).timeoutInterval, 300)
    XCTAssertEqual(RadioLiteNetworkPolicy.webSocketCommandTimeout, 15)
}

func testOnlyHardwarePreflight404IsFeatureUnavailable() {
    XCTAssertEqual(RadioLiteHTTPError.presentationCode(status: 404, path: "/api/v1/hardware/test", serverCode: "http_404"), "server_feature_unavailable")
    XCTAssertEqual(RadioLiteHTTPError.presentationCode(status: 404, path: "/api/v1/radios/main/reconfiguration/preflight", serverCode: "http_404"), "server_feature_unavailable")
    XCTAssertEqual(RadioLiteHTTPError.presentationCode(status: 404, path: "/api/v1/logs", serverCode: "http_404"), "http_404")
}
```

- [ ] **Step 2: Run the focused tests and verify red**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteModelsTests -only-testing:RadioLiteTests/RadioLiteServerTests -only-testing:RadioLiteTests/RadioLiteHTTPErrorPresentationTests`

Expected: FAIL to compile because `features`, the seven-flag `unsupported`, `webSocketCommandTimeout`, and `presentationCode` do not exist; the existing test still establishes the old 300-second common timeout.

- [ ] **Step 3: Implement minimal typed capability and timeout behavior**

```swift
// RadioLiteModels.swift
struct RadioLiteHealth: Codable, Equatable, Sendable {
    let status: String; let service: String; let protocolVersion: Int
    let features: RadioLiteServerFeatures
    private enum CodingKeys: String, CodingKey { case status, service, protocolVersion, features }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status); service = try c.decode(String.self, forKey: .service)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        features = try c.decodeIfPresent(RadioLiteServerFeatures.self, forKey: .features) ?? .unsupported
    }
}

extension RadioLiteServerFeatures {
    private enum CodingKeys: String, CodingKey {
        case hardwarePreflight, preflightProof, emergencyStop, safetyAlerts
        case accountAdministration, spectrumDisplayWindow, swrTripReset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hardwarePreflight = try c.decodeIfPresent(Bool.self, forKey: .hardwarePreflight) ?? false
        preflightProof = try c.decodeIfPresent(Bool.self, forKey: .preflightProof) ?? false
        emergencyStop = try c.decodeIfPresent(Bool.self, forKey: .emergencyStop) ?? false
        safetyAlerts = try c.decodeIfPresent(Bool.self, forKey: .safetyAlerts) ?? false
        accountAdministration = try c.decodeIfPresent(Bool.self, forKey: .accountAdministration) ?? false
        spectrumDisplayWindow = try c.decodeIfPresent(Bool.self, forKey: .spectrumDisplayWindow) ?? false
        swrTripReset = try c.decodeIfPresent(Bool.self, forKey: .swrTripReset) ?? false
    }
}
// RadioLiteServer.swift
static let httpTimeout: TimeInterval = 300
static let webSocketCommandTimeout: TimeInterval = 15
static let stopSendTimeout: TimeInterval = 3
```

Use `httpTimeout` only in `configuration()` and `request()`. Pass `webSocketCommandTimeout` as the default request deadline; make `RadioLiteControlClient.startPings()` sleep for `.seconds(15)`. In `rawRequest`, pass the endpoint path into `presentationCode`; map exactly `/api/v1/hardware/test` and `/api/v1/radios/:radioId/reconfiguration/preflight` plus status 404 to the required Chinese message. Publish `health` in `RadioLiteSession` after `probeServer()` and authentication health refresh.

- [ ] **Step 4: Run focused tests and protocol contract green**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteModelsTests -only-testing:RadioLiteTests/RadioLiteServerTests -only-testing:RadioLiteTests/RadioLiteHTTPErrorPresentationTests && node scripts/check-ios-radio-lite-contract.mjs`

Expected: PASS; contract output begins `Verified` and includes all seven exact health feature keys, older six-key `features` decoding with `swrTripReset == false`, and the timeout contract assertions.

- [ ] **Step 5: Commit the independently testable capability boundary**

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteModels.swift ios/RadioLite/Core/RadioLite/RadioLiteServer.swift ios/RadioLite/Core/RadioLite/RadioLiteWebSocketChannel.swift ios/RadioLite/Core/RadioLite/RadioLiteControlClient.swift ios/RadioLite/Core/RadioLite/RadioLiteHTTPClient.swift ios/RadioLite/Core/RadioLite/RadioLiteSession.swift ios/RadioLiteTests/RadioLiteModelsTests.swift ios/RadioLiteTests/RadioLiteServerTests.swift ios/RadioLiteTests/RadioLiteHTTPErrorPresentationTests.swift radio-lite-server/PROTOCOL.md scripts/check-ios-radio-lite-contract.mjs
git commit -m "feat(ios): negotiate safety capabilities and WS deadlines"
```

### Task 2: Prevent stale rig-state replies and stabilize radio/FT8 UI state

**Files:**
- Create: `ios/RadioLite/Core/RadioLite/RadioLiteRigStateRevision.swift`, `ios/RadioLite/Core/RadioLite/RadioLiteRadioSelectionPresentation.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteSession.swift`, `ios/RadioLite/Core/RadioLite/RadioLiteOperationEpoch.swift`, `ios/RadioLite/Core/RadioLite/RadioLiteDecodeFeedState.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteFT8View.swift`, `ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift`
- Test: `ios/RadioLiteTests/RadioLiteRigStateRevisionTests.swift`, `ios/RadioLiteTests/RadioLiteRadioSelectionPresentationTests.swift`, `ios/RadioLiteTests/RadioLiteDecodeFeedStateTests.swift`

**Interfaces:**
- Produces `RadioLiteRigStateRevision.beginRefresh() -> RadioLiteRigStateRequestToken`, `advanceForConfirmedWrite()`, `mayPublish(_:)`, `invalidate()`.
- Produces `RadioLiteRadioSelectionPresentation.selectRadio(_:)`, `captureOwner()`, `mayApply(_:)`, `ownKeyboard(_:)`, and `ownPopup(_:)`; changing radio advances generation and clears both owners. `RadioLiteDecodeFeedState.changeRadio(to:)` clears its batch/selection and ignores a later `receive(_:radioId:)` for another radio.
- `RadioLiteSession.refreshRigState` captures one token before awaiting; `setFrequency`, `setMode`, and successful `setRigControl` call `advanceForConfirmedWrite()` before publishing replacement state.
- `selectedRadioId` changes invalidate both rig revision and FT8/digital displayed row selection; keyboard focus and popup state are not derived from an old async callback.

- [ ] **Step 1: Write failing pure ordering tests**

```swift
func testOldPollCannotPublishAfterConfirmedFrequencyWrite() {
    var revision = RadioLiteRigStateRevision()
    let poll = revision.beginRefresh()
    revision.advanceForConfirmedWrite()
    XCTAssertFalse(revision.mayPublish(poll))
}

func testOnlyNewestParallelRefreshMayPublish() {
    var revision = RadioLiteRigStateRevision()
    let old = revision.beginRefresh(); let new = revision.beginRefresh()
    XCTAssertFalse(revision.mayPublish(old)); XCTAssertTrue(revision.mayPublish(new))
}

func testRadioChangeInvalidatesOldRigRefreshOwner() {
    var revision = RadioLiteRigStateRevision(); let old = revision.beginRefresh()
    revision.invalidate(); XCTAssertFalse(revision.mayPublish(old))
}

func testRadioChangeClearsFT8RowAndKeyboardPopupOwnersAndRejectsDelayedOldCallbacks() {
    var feed = RadioLiteDecodeFeedState(); feed.changeRadio(to: "main")
    feed.receive(batch(mode: "FT8", slotStartMs: 15_000,
        decodes: [decode(id: "cq-main", message: "CQ JA1ABC PM95")]), radioId: "main")
    feed.select(decodeId: "cq-main")
    var ui = RadioLiteRadioSelectionPresentation(); ui.selectRadio("main")
    let oldOwner = ui.captureOwner(); ui.ownKeyboard(oldOwner); ui.ownPopup(oldOwner)

    feed.changeRadio(to: "backup"); ui.selectRadio("backup")
    feed.receive(batch(mode: "FT8", slotStartMs: 30_000,
        decodes: [decode(id: "cq-late", message: "CQ BG2TEST PN35")]), radioId: "main")

    XCTAssertNil(feed.displayedBatch); XCTAssertNil(feed.selectedDecodeId)
    XCTAssertNil(ui.keyboardOwner); XCTAssertNil(ui.popupOwner)
    XCTAssertFalse(ui.mayApply(oldOwner))
}
```

- [ ] **Step 2: Run the focused test and verify red**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteRigStateRevisionTests -only-testing:RadioLiteTests/RadioLiteRadioSelectionPresentationTests -only-testing:RadioLiteTests/RadioLiteDecodeFeedStateTests`

Expected: FAIL to compile because `RadioLiteRigStateRevision` and `RadioLiteRigStateRequestToken` are absent.

- [ ] **Step 3: Implement revision ownership and session integration**

```swift
struct RadioLiteRigStateRevision: Equatable, Sendable {
    private var revision: UInt64 = 0; private var nextGeneration: UInt64 = 0
    mutating func beginRefresh() -> RadioLiteRigStateRequestToken { nextGeneration &+= 1; return .init(revision: revision, generation: nextGeneration) }
    mutating func advanceForConfirmedWrite() { revision &+= 1; nextGeneration &+= 1 }
    mutating func invalidate() { revision &+= 1; nextGeneration &+= 1 }
    func mayPublish(_ token: RadioLiteRigStateRequestToken) -> Bool { token.revision == revision && token.generation == nextGeneration }
}
```

Add `private var rigStateRevision = RadioLiteRigStateRevision()` to `RadioLiteSession`. Capture `let token = rigStateRevision.beginRefresh()` before `control.request`; require `rigStateRevision.mayPublish(token)` with existing radio/reconnect/auth guards before `rigState = state`. Invalidate on radio selection, disconnect, sign-out, and configuration reconnect. Advance before assigning each confirmed local rig write. Keep FT8 queue, selected decode, sheet/popover, and frequency field state keyed by `radioId`; clear those keys synchronously when the radio changes so delayed batches cannot reopen a popup or restore keyboard focus.

Implement `RadioLiteRadioSelectionPresentation` as a pure value holding `radioId`, a wrapping
`UInt64 generation`, and optional `RadioLiteRadioUIOwnerToken` values for keyboard and popup. A
token contains both radio ID and generation; `mayApply` requires both to equal the current state.
`selectRadio` is a no-op for the same ID, otherwise advances generation and clears both owners.
`RadioLiteFT8View` observes `session.selectedRadioId`, calls `decodeFeed.changeRadio(to:)`, clears
`focusedField`, and dismisses radio-owned popup state synchronously. Its batch callback calls
`receive(_:radioId:)`, so a delayed main batch cannot repopulate backup. `RadioLiteRadioView` uses
the same selection generation to clear `frequencyFocused` before synchronizing its field. The pure
test above exercises the exact decode row plus keyboard/popup owner behavior, not only rig revision.

- [ ] **Step 4: Run focused ordering and existing concurrency tests**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteRigStateRevisionTests -only-testing:RadioLiteTests/RadioLiteRadioSelectionPresentationTests -only-testing:RadioLiteTests/RadioLiteConcurrencyOwnershipTests -only-testing:RadioLiteTests/RadioLiteDecodeFeedStateTests`

Expected: PASS; the prior ownership tests remain green and no stale rig/FT8 UI result can publish.

- [ ] **Step 5: Commit stale-reply protection**

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteRigStateRevision.swift ios/RadioLite/Core/RadioLite/RadioLiteRadioSelectionPresentation.swift ios/RadioLite/Core/RadioLite/RadioLiteSession.swift ios/RadioLite/Core/RadioLite/RadioLiteOperationEpoch.swift ios/RadioLite/Core/RadioLite/RadioLiteDecodeFeedState.swift ios/RadioLite/Features/RadioLite/RadioLiteFT8View.swift ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift ios/RadioLiteTests/RadioLiteRigStateRevisionTests.swift ios/RadioLiteTests/RadioLiteRadioSelectionPresentationTests.swift ios/RadioLiteTests/RadioLiteDecodeFeedStateTests.swift
git commit -m "fix(ios): discard stale rig state replies"
```

### Task 3: Stop-pending identity, retry ordering, and local PTT lifecycle

**Files:**
- Create: `ios/RadioLite/Core/RadioLite/RadioLiteTransmitStopState.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteSession.swift`, `RadioLiteWebSocketChannel.swift`, `RadioLiteControlClient.swift`
- Test: `ios/RadioLiteTests/RadioLiteTransmitStopStateTests.swift`, `RadioLiteTests/RadioLiteConcurrencyOwnershipTests.swift`, `RadioLiteTests/RadioLiteWebSocketChannelTests.swift`

**Interfaces:**
- Produces `RadioLiteTransmitStopState.begin(transmitToken:radioId:mode:startedAckRevision:) -> RadioLiteTransmitStopKey`, `beginStop() -> RadioLiteTransmitStopKey?`, `nextRetry() -> RadioLiteTransmitStopKey?`, `confirmStop(_ expected: RadioLiteTransmitStopKey) -> Bool`, `markDisconnected()`, and `current: RadioLiteTransmitStopAttempt?`. The immutable key excludes `stopPending` and `retryAttempt`; `confirmStop` compares only the key and returns false for an old token/revision.
- `RadioLiteWebSocketChannel.enqueueRequest(_:expecting:commandId:requestType:timeout:) async throws -> RadioLiteEnqueuedControlRequest` registers the exact pending reply before sending and returns only after the first frame's `URLSessionWebSocketTask.send` completion hands it to the local WebSocket transport. `RadioLiteEnqueuedControlRequest.response() async throws -> JSONValue` waits for the reply/deadline, and `RadioLiteControlClient.enqueueRequest` forwards the same two phases. If send fails or is cancelled, the channel atomically removes and fails that exact pending continuation before throwing; it cannot leak or be completed by a late reply. The existing `request` convenience awaits both phases. An internal test-only `frameSender` initializer defaults to the production socket send closure and exposes no production mutable hook.
- `RadioLiteSession.stopRemoteTransmit(_:)` uses that two-phase API for `tx.stop` with `timeout: RadioLiteNetworkPolicy.stopSendTimeout`, restores receive audio immediately after the first frame handoff, and continues reply waiting plus same-key retries in the background. Frame handoff is only an ordering boundary, never remote receipt or physical PTT-OFF evidence.

- [ ] **Step 1: Write failing stop-state and ordering tests**

```swift
func testFailedStopKeepsTokenAndSchedulesSameIdentityRetry() {
    var state = RadioLiteTransmitStopState()
    let key = state.begin(transmitToken: "tx-1", radioId: "main", mode: "voice", startedAckRevision: 7)
    XCTAssertEqual(state.beginStop()?.transmitToken, "tx-1")
    XCTAssertEqual(state.nextRetry(), key)
    XCTAssertEqual(state.current?.retryAttempt, 1)
    XCTAssertEqual(state.current?.key, key)
}

func testSecondRetryReplyClearsTheCurrentImmutableKey() {
    var state = RadioLiteTransmitStopState()
    let key = state.begin(transmitToken: "tx-1", radioId: "main", mode: "voice", startedAckRevision: 7)
    _ = state.beginStop(); _ = state.nextRetry(); _ = state.nextRetry()
    XCTAssertEqual(state.current?.retryAttempt, 2)
    XCTAssertTrue(state.confirmStop(key)); XCTAssertNil(state.current)
}

func testOldStoppedReplyCannotClearAReplacementIdentity() {
    var state = RadioLiteTransmitStopState()
    let old = state.begin(transmitToken: "tx-old", radioId: "main", mode: "voice", startedAckRevision: 7)
    let replacement = state.begin(transmitToken: "tx-new", radioId: "main", mode: "voice", startedAckRevision: 8)
    XCTAssertFalse(state.confirmStop(old))
    XCTAssertEqual(state.current?.key, replacement)
    XCTAssertTrue(state.confirmStop(replacement))
    XCTAssertNil(state.current)
}
```

Add a session test seam whose fake channel holds the first reply on an `AsyncGate` while recording
`stopMicrophoneCapture`, `stopUplink`, `send(tx.stop)`, `restoreReceive`, and
`retryCompleted`. Freeze this regression:

```swift
func testReceiveRestoresAfterFirstStopFrameHandoffBeforeDeferredReplyOrRetryCompletes() async throws {
    let fixture = RadioLiteStopOrderingFixture(firstReply: .deferredFailure)
    let ending = Task { await fixture.session.endVoicePTT() }
    await fixture.channel.waitUntilFirstFrameEnqueued()
    await fixture.waitUntilReceiveRestored()
    XCTAssertEqual(Array(fixture.events.prefix(4)), [
        "stopMicrophoneCapture", "stopUplink", "send(tx.stop)", "restoreReceive",
    ])
    XCTAssertFalse(fixture.events.contains("retryCompleted"))
    fixture.channel.failDeferredReply()
    await fixture.channel.waitUntilRetryCompletes(with: .stopped)
    await ending.value
    XCTAssertLessThan(try XCTUnwrap(fixture.events.firstIndex(of: "restoreReceive")),
                      try XCTUnwrap(fixture.events.firstIndex(of: "retryCompleted")))
}

func testFailedOrCancelledFirstFrameSendRemovesExactPendingWaiter() async {
    for failure in [RadioLiteFakeSendFailure.failed, .cancelled] {
        let fixture = RadioLiteStopOrderingFixture(firstReply: .sendFailure(failure))
        await fixture.session.endVoicePTT()
        XCTAssertEqual(fixture.channel.pendingRequestCount, 0)
        XCTAssertFalse(fixture.channel.deliverLateStopped(commandId: fixture.commandId))
        XCTAssertTrue(fixture.session.stopState.current?.stopPending == true)
        XCTAssertTrue(fixture.events.contains("restoreReceive"))
    }
}

func testProductionChannelRegistryRemovesWaiterWhenFrameSenderFails() async {
    for error in [RadioLiteFakeSendFailure.failed, .cancelled] {
        let channel = RadioLiteWebSocketChannel(frameSender: { _ in throw error })
        do {
            _ = try await channel.enqueueRequest(.fixtureStop(commandId: "stop-1"),
                expecting: ["tx.stopped"], commandId: "stop-1", requestType: "tx.stop", timeout: 3)
            XCTFail("send failure must throw")
        } catch {}
        XCTAssertEqual(channel.pendingRequestCountForTesting, 0)
        XCTAssertFalse(channel.receiveForTesting(.fixtureStopped(commandId: "stop-1")))
    }
}
```

`RadioLiteStopOrderingFixture` uses a concrete fake `RadioLiteWebSocketChanneling`: its first
`enqueueRequest` records `send(tx.stop)` and returns a receipt immediately, while that receipt's
response continuation stays suspended until `failDeferredReply()`; the next same-key request
returns `tx.stopped` and records `retryCompleted`. This proves the first frame was handed off before
local receive starts and that neither a deferred reply nor the retry sequence blocks receive audio.
Its `.sendFailure` mode records the pending waiter before invoking send, then verifies the production
channel removes/fails the same waiter on thrown error or cancellation; `deliverLateStopped` returns
false when no matching waiter remains.

- [ ] **Step 2: Run red tests**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteTransmitStopStateTests -only-testing:RadioLiteTests/RadioLiteConcurrencyOwnershipTests -only-testing:RadioLiteTests/RadioLiteWebSocketChannelTests`

Expected: FAIL to compile for `RadioLiteTransmitStopState`; the old implementation clears `activeTransmitToken` in `stopLocalTransmit()` before it can receive `tx.stopped`.

- [ ] **Step 3: Implement bounded retry without delaying local release**

```swift
mutating func nextRetry() -> RadioLiteTransmitStopKey? {
    guard var value = current, value.stopPending, value.retryAttempt < 3 else { return nil }
    value.retryAttempt += 1
    current = value
    return value.key
}

struct RadioLiteEnqueuedControlRequest {
    let response: @Sendable () async throws -> JSONValue
}
```

In `endVoicePTT`, call the existing local capture/uplink/AVAudioSession stop path synchronously, then create one immutable `RadioLiteTransmitStopKey` before removing the current token. Start one `Task` that calls `enqueueRequest` for the first `tx.stop`; after that await returns, immediately call `restoreOrRetryReceiveAudioAfterVoicePTT` without awaiting the receipt's response. A sibling/background continuation awaits `receipt.response()`, waits `0.35`, `0.70`, then `1.05` seconds between failures, and issues later requests with the same three-second deadline. Every retry and reply captures that same key while only `current.retryAttempt` changes; on matching `tx.stopped`, call `confirmStop(capturedKey)`. A reply for an old token/revision returns false and cannot clear a replacement, while a second- or third-attempt reply for the same key does clear it. On first-frame enqueue failure, do not claim the ordering boundary: retain `current`, publish `远端状态未确认`, restore receive audio as a local availability fallback, and let reconnect handling continue stop recovery. On exhausted replies/retries or socket failure, likewise retain `current` and publish the exact degraded copy. Ensure heartbeat failure, audio interruption, backgrounding, and connection loss enter this one state machine. `enqueueRequest` must register the reply continuation before calling `send`; its catch/cancellation handler must compare and remove the exact pending identity, fail that continuation once, cancel its timeout, then throw. A late reply cannot match it. `request` is implemented as `let receipt = try await enqueueRequest(...); return try await receipt.response()` so other commands preserve existing semantics.

- [ ] **Step 4: Run stop, microphone, and contract verification**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteTransmitStopStateTests -only-testing:RadioLiteTests/RadioLiteMicrophonePolicyTests -only-testing:RadioLiteTests/RadioLiteConcurrencyOwnershipTests -only-testing:RadioLiteTests/RadioLiteWebSocketChannelTests && node scripts/check-ios-radio-lite-contract.mjs`

Expected: PASS; microphone release remains immediate, the first `tx.stop` frame handoff precedes receive recovery, deferred reply/retry completion follows receive recovery, and failed stops retain identity rather than presenting confirmed idle.

- [ ] **Step 5: Commit stop reliability**

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteTransmitStopState.swift ios/RadioLite/Core/RadioLite/RadioLiteSession.swift ios/RadioLite/Core/RadioLite/RadioLiteWebSocketChannel.swift ios/RadioLite/Core/RadioLite/RadioLiteControlClient.swift ios/RadioLiteTests/RadioLiteTransmitStopStateTests.swift ios/RadioLiteTests/RadioLiteConcurrencyOwnershipTests.swift ios/RadioLiteTests/RadioLiteWebSocketChannelTests.swift scripts/check-ios-radio-lite-contract.mjs
git commit -m "fix(ios): retain pending stop state across weak links"
```

### Task 4: Server-authoritative safety snapshots, stale fallback, emergency/SWR recovery UI, accessibility, and haptics

**Files:**
- Create: `ios/RadioLite/Core/RadioLite/RadioLiteSafetyAlertState.swift`, `ios/RadioLite/Features/RadioLite/RadioLiteSafetyBannerView.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteModels.swift`, `RadioLiteSession.swift`, `RadioLiteControlClient.swift`, `RadioLiteWebSocketChannel.swift`, `RadioLiteMediaClient.swift`, `RadioLiteHTTPClient.swift`, `ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift`
- Test: `ios/RadioLiteTests/RadioLiteSafetyAlertStateTests.swift`, `ios/RadioLiteTests/RadioLiteSafetyPresentationPolicyTests.swift`
- Create: `ios/RadioLiteTests/RadioLiteEmergencyStopTests.swift`, `ios/RadioLiteTests/RadioLiteSWRTripResetTests.swift`
- Modify: `ios/RadioLiteTests/RadioLiteModelsTests.swift`
- Modify: `scripts/check-ios-radio-lite-contract.mjs`, `radio-lite-server/PROTOCOL.md`

**Interfaces:**
- `RadioLitePersistentSafetyAlertKind` contains `active`, `external_ptt`, `telemetry_uncertain`, `dekey_required`, `dekey_escalated`, `swr_trip_latched`, and `swr_rearm_pending`; `RadioLiteSafetyEventKind` adds only `recovered`. `RadioLiteSafetyAlertSnapshot.alert.kind` uses the persistent type, so a recovered snapshot is invalid JSON while both SWR states remain snapshot-safe and survive reconnects.
- `RadioLiteSafetyAlertSnapshot { safetyEpoch, radioId, revision, alert: RadioLiteSafetyAlert? }`; `alert: nil` is the only empty snapshot value.
- `RadioLiteSafetyAlertState.markConnected(connectionGeneration:)`, `beginSnapshot(epoch:connectionGeneration:)`, `ingestSnapshot(_:connectionGeneration:)`, `ingestEvent(_:connectionGeneration:)`, `endSnapshot(epoch:connectionGeneration:)`, `markDisconnected(connectionGeneration:)`, `banner(for:) -> RadioLiteSafetyBannerState?`; its internal `activeConnectionGeneration` is `UInt64?`. Only `markConnected` installs a generation. `markDisconnected` acts only when its captured generation still equals the active generation, then sets it to nil and discards the unfinished envelope/buffer while retaining committed alerts as stale; snapshot/event/disconnect calls with nil, an old generation, or a nonmatching envelope are ignored.
- `RadioLiteSession.emergencyStop() async throws` captures the current nonempty `selectedRadioId`, generates `commandId` with `UUID().uuidString`, sends `{"t":"tx.emergency-stop","radioId":selectedRadioId,"commandId":commandId}` without control or transmit tokens only if `health.features.emergencyStop` is true, and accepts a reply only when both `radioId` and `commandId` match that captured request.
- `RadioLiteHTTPClient.resetSWRTrip(radioId:physicalInspectionAcknowledged:) async throws` is the typed `POST /api/v1/radios/:radioId/swr-trip/reset` client. It can construct and send only `{ "acknowledgePhysicalInspection": true }`; false fails locally. `RadioLiteSession.resetSWRTripAfterPhysicalInspection()` additionally requires `health.features.swrTripReset`, the administrator role, the selected radio, and a current `.swr_trip_latched` server alert. A successful HTTP reply never clears or downgrades that alert; only a matching safety event/snapshot may project `.swr_rearm_pending` or later clear it.
- `RadioLiteWebSocketChanneling` freezes the existing connect/disconnect/send/request surface and changes `onJSON` to `(JSONValue, UInt64) -> Void` and `onDisconnect` to `(Error, UInt64) -> Void`; each physical connection captures its own monotonically increasing generation, so neither a delayed message nor a delayed disconnect can be relabelled with the latest generation. `RadioLiteControlClient.init(channel:)` defaults to the production channel and forwards both tagged callbacks.
- Internal `RadioLiteSession.init(control:commandIdGenerator:testState:)` defaults to production dependencies; tests inject a concrete `RadioLiteControlClient` backed by `RadioLiteFakeWebSocketChannel`, a fixed command ID, and `RadioLiteSessionTestState` containing ready health/radios/selection. `RadioLiteEmergencyStopError.replyIdentityMismatch` is `Equatable` and distinct from unsupported/not-connected errors.

```swift
@MainActor
protocol RadioLiteWebSocketChanneling: AnyObject {
    var onJSON: ((JSONValue, UInt64) -> Void)? { get set }
    var onDisconnect: ((Error, UInt64) -> Void)? { get set }
    func connect(server: RadioLiteServer, credential: RadioLiteCredential,
                 path: String, expectedChannel: String) async throws -> RadioLiteAuthWelcome
    func disconnect(notify: Bool)
    func send(_ value: JSONValue) async throws
    func enqueueRequest(_ value: JSONValue, expecting: Set<String>, commandId: String?,
                        requestType: String?, timeout: TimeInterval?) async throws
        -> RadioLiteEnqueuedControlRequest
    func request(_ value: JSONValue, expecting: Set<String>, commandId: String?,
                 requestType: String?, timeout: TimeInterval?) async throws -> JSONValue
}
```

`RadioLiteWebSocketChannel` conforms directly. Its receive loop invokes `onJSON(value,
capturedGeneration)` and `onDisconnect(error, capturedGeneration)` using the immutable generation
captured by `connect`; neither callback reads a mutable latest-generation property. The media client
updates both closures to ignore the second argument; the control client forwards both.

- [ ] **Step 1: Write failing snapshot reducer and presentation-policy tests**

```swift
func testSnapshotAndBufferedNewEpochEventsApplyAtomically() {
    var state = RadioLiteSafetyAlertState(); state.markConnected(connectionGeneration: 2)
    state.beginSnapshot(epoch: "boot-2", connectionGeneration: 2)
    state.ingestEvent(.init(safetyEpoch: "boot-2", radioId: "main", revision: 3, kind: .dekey_required, startedAtMs: 10, source: "software"), connectionGeneration: 2)
    state.ingestSnapshot(.init(safetyEpoch: "boot-2", radioId: "main", revision: 2, alert: nil), connectionGeneration: 2)
    XCTAssertNil(state.banner(for: "main")); state.endSnapshot(epoch: "boot-2", connectionGeneration: 2)
    XCTAssertEqual(state.banner(for: "main")?.kind, .dekey_required)
}

func testEventForCollectingEpochBuffersWhileOldEpochRemainsCommitted() {
    var state = RadioLiteSafetyAlertState(); state.markConnected(connectionGeneration: 2)
    state.beginSnapshot(epoch: "boot-1", connectionGeneration: 2)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 4,
                               alert: .init(kind: .external_ptt, startedAtMs: 1, source: "external")),
                         connectionGeneration: 2)
    state.endSnapshot(epoch: "boot-1", connectionGeneration: 2)

    state.beginSnapshot(epoch: "boot-2", connectionGeneration: 2)
    state.ingestEvent(.init(safetyEpoch: "boot-2", radioId: "main", revision: 2,
                            kind: .dekey_required, startedAtMs: 2, source: "software"),
                      connectionGeneration: 2)
    state.ingestSnapshot(.init(safetyEpoch: "boot-2", radioId: "main", revision: 1, alert: nil),
                         connectionGeneration: 2)
    XCTAssertEqual(state.banner(for: "main")?.kind, .external_ptt)
    state.endSnapshot(epoch: "boot-2", connectionGeneration: 2)
    XCTAssertEqual(state.banner(for: "main")?.kind, .dekey_required)
}

func testDelayedOldConnectionEndCannotCommitANewSnapshot() {
    var state = RadioLiteSafetyAlertState()
    state.markConnected(connectionGeneration: 20)
    state.beginSnapshot(epoch: "boot-1", connectionGeneration: 20)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 1,
                               alert: .init(kind: .external_ptt, startedAtMs: 1, source: "external")), connectionGeneration: 20)
    state.endSnapshot(epoch: "boot-1", connectionGeneration: 20)
    state.markConnected(connectionGeneration: 22)
    state.beginSnapshot(epoch: "boot-1", connectionGeneration: 22)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 2, alert: nil), connectionGeneration: 22)
    state.endSnapshot(epoch: "boot-1", connectionGeneration: 21)
    XCTAssertEqual(state.banner(for: "main")?.kind, .external_ptt)
    state.endSnapshot(epoch: "boot-1", connectionGeneration: 22)
    XCTAssertNil(state.banner(for: "main"))
}

func testSnapshotOutsideMatchingEnvelopeCannotChangeAuthoritativeState() {
    var state = RadioLiteSafetyAlertState()
    state.markConnected(connectionGeneration: 1)
    state.beginSnapshot(epoch: "boot-1", connectionGeneration: 1)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 1,
                               alert: .init(kind: .dekey_required, startedAtMs: 1, source: "software")), connectionGeneration: 1)
    state.endSnapshot(epoch: "boot-1", connectionGeneration: 1)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 99, alert: nil), connectionGeneration: 1)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 100, alert: nil), connectionGeneration: 0)
    XCTAssertEqual(state.banner(for: "main")?.kind, .dekey_required)
}

func testRecoveredIsEventOnlyAndCannotDecodeAsPersistentSnapshotKind() throws {
    let recovered = #"{"t":"safety.event","safetyEpoch":"boot","radioId":"main","revision":2,"kind":"recovered","startedAtMs":2,"source":"software"}"#.data(using: .utf8)!
    XCTAssertEqual(try JSONDecoder().decode(RadioLiteSafetyAlertEvent.self, from: recovered).kind, .recovered)
    let invalidSnapshot = #"{"t":"safety.snapshot","safetyEpoch":"boot","radioId":"main","revision":2,"alert":{"kind":"recovered","startedAtMs":2,"source":"software"}}"#.data(using: .utf8)!
    XCTAssertThrowsError(try JSONDecoder().decode(RadioLiteSafetyAlertSnapshot.self, from: invalidSnapshot))
}

func testRawSWRKindsDecodeAsEventsAndPersistentSnapshotsAndSurviveDisconnect() throws {
    for (raw, expected) in [
        ("swr_trip_latched", RadioLitePersistentSafetyAlertKind.swr_trip_latched),
        ("swr_rearm_pending", RadioLitePersistentSafetyAlertKind.swr_rearm_pending),
    ] {
        let data = Data("{\"t\":\"safety.snapshot\",\"safetyEpoch\":\"boot\",\"radioId\":\"main\",\"revision\":2,\"alert\":{\"kind\":\"\(raw)\",\"startedAtMs\":2,\"source\":\"software\"}}".utf8)
        let snapshot = try JSONDecoder().decode(RadioLiteSafetyAlertSnapshot.self, from: data)
        XCTAssertEqual(snapshot.alert?.kind, expected)
        let eventData = Data("{\"t\":\"safety.event\",\"safetyEpoch\":\"boot\",\"radioId\":\"main\",\"revision\":3,\"kind\":\"\(raw)\",\"startedAtMs\":3,\"source\":\"software\"}".utf8)
        let event = try JSONDecoder().decode(RadioLiteSafetyAlertEvent.self, from: eventData)
        XCTAssertEqual(event.kind.persistent, expected)
        var state = RadioLiteSafetyAlertState(); state.markConnected(connectionGeneration: 1)
        state.beginSnapshot(epoch: "boot", connectionGeneration: 1)
        state.ingestSnapshot(snapshot, connectionGeneration: 1)
        state.endSnapshot(epoch: "boot", connectionGeneration: 1)
        state.markDisconnected(connectionGeneration: 1)
        XCTAssertEqual(state.banner(for: "main")?.kind, expected)
        XCTAssertTrue(try XCTUnwrap(state.banner(for: "main")).isStale)
    }
}

func testDisconnectInvalidatesOldGenerationUntilANewCompleteSnapshot() {
    var state = RadioLiteSafetyAlertState(); state.markConnected(connectionGeneration: 1)
    state.beginSnapshot(epoch: "boot-1", connectionGeneration: 1)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 5, alert: .init(kind: .external_ptt, startedAtMs: 1, source: "external")), connectionGeneration: 1)
    state.endSnapshot(epoch: "boot-1", connectionGeneration: 1)
    state.markDisconnected(connectionGeneration: 1); XCTAssertTrue(state.banner(for: "main")!.isStale)
    state.ingestEvent(.init(safetyEpoch: "boot-1", radioId: "main", revision: 99, kind: .recovered, startedAtMs: 2, source: "software"), connectionGeneration: 1)
    state.beginSnapshot(epoch: "boot-1", connectionGeneration: 1)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 100, alert: nil), connectionGeneration: 1)
    state.endSnapshot(epoch: "boot-1", connectionGeneration: 1)
    XCTAssertEqual(state.banner(for: "main")?.kind, .external_ptt)

    var dekey = RadioLiteSafetyAlertState(); dekey.markConnected(connectionGeneration: 1)
    dekey.beginSnapshot(epoch: "boot-1", connectionGeneration: 1)
    dekey.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 8, alert: .init(kind: .dekey_required, startedAtMs: 3, source: "software")), connectionGeneration: 1)
    dekey.endSnapshot(epoch: "boot-1", connectionGeneration: 1)
    dekey.markDisconnected(connectionGeneration: 1); XCTAssertTrue(dekey.banner(for: "main")!.isStale)
    dekey.ingestEvent(.init(safetyEpoch: "boot-1", radioId: "main", revision: 100, kind: .recovered, startedAtMs: 4, source: "software"), connectionGeneration: 1)
    XCTAssertEqual(dekey.banner(for: "main")?.kind, .dekey_required)

    state.markConnected(connectionGeneration: 2)
    state.beginSnapshot(epoch: "boot-1", connectionGeneration: 2)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 101, alert: nil), connectionGeneration: 2)
    state.endSnapshot(epoch: "boot-1", connectionGeneration: 2)
    XCTAssertNil(state.banner(for: "main"))
}

func testDelayedOldDisconnectCannotInvalidateNewConnectionGeneration() {
    var state = RadioLiteSafetyAlertState(); state.markConnected(connectionGeneration: 1)
    state.beginSnapshot(epoch: "boot-1", connectionGeneration: 1)
    state.ingestSnapshot(.init(safetyEpoch: "boot-1", radioId: "main", revision: 5,
                               alert: .init(kind: .dekey_required, startedAtMs: 1, source: "software")),
                         connectionGeneration: 1)
    state.endSnapshot(epoch: "boot-1", connectionGeneration: 1)

    state.markConnected(connectionGeneration: 2)
    state.markDisconnected(connectionGeneration: 1)
    state.beginSnapshot(epoch: "boot-2", connectionGeneration: 2)
    state.ingestSnapshot(.init(safetyEpoch: "boot-2", radioId: "main", revision: 1, alert: nil),
                         connectionGeneration: 2)
    state.endSnapshot(epoch: "boot-2", connectionGeneration: 2)
    XCTAssertNil(state.banner(for: "main"))
}

func testLocalStartAndStoppedReplyDoNotClearServerBanner() {
    XCTAssertFalse(RadioLiteSafetyPresentationPolicy.shouldShowPersistentBanner(localStartPending: true, serverBanner: nil))
    XCTAssertTrue(RadioLiteSafetyPresentationPolicy.shouldRetainServerBannerAfterStopReply)
}

func testEmergencyStopTargetsTheSelectedNonMainRadio() async throws {
    let fixture = RadioLiteSessionFixture(selectedRadioId: "backup")
    try await fixture.session.emergencyStop()
    XCTAssertEqual(fixture.lastRequest?["t"]?.stringValue, "tx.emergency-stop")
    XCTAssertEqual(fixture.lastRequest?["radioId"]?.stringValue, "backup")
    XCTAssertNotEqual(fixture.lastRequest?["radioId"]?.stringValue, "main")
}

func testEmergencyStopRejectsMismatchedAcceptedReplyIdentity() async {
    for reply in [
        ["t": "tx.emergency-stop.accepted", "radioId": "main", "commandId": "expected"],
        ["t": "tx.emergency-stop.accepted", "radioId": "backup", "commandId": "wrong"],
    ] {
        let fixture = RadioLiteSessionFixture(selectedRadioId: "backup", fixedCommandId: "expected", reply: reply)
        do {
            try await fixture.session.emergencyStop()
            XCTFail("mismatched accepted reply must fail")
        } catch let error as RadioLiteEmergencyStopError {
            XCTAssertEqual(error, .replyIdentityMismatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(fixture.lastRequest?["t"]?.stringValue, "tx.emergency-stop")
        XCTAssertEqual(fixture.lastRequest?["radioId"]?.stringValue, "backup")
        XCTAssertEqual(fixture.lastRequest?["commandId"]?.stringValue, "expected")
        XCTAssertTrue(fixture.session.emergencyStopPending)
    }
}

func testSafetyStreamIngestsBackupBeforeSelectedRadioGuard() async throws {
    let fixture = RadioLiteSessionFixture(selectedRadioId: "main", connectionGeneration: 8)
    fixture.deliverSafetySnapshotSet(epoch: "boot", snapshots: [
        .init(safetyEpoch: "boot", radioId: "main", revision: 0, alert: nil),
        .init(safetyEpoch: "boot", radioId: "backup", revision: 4,
              alert: .init(kind: .dekey_required, startedAtMs: 4, source: "software")),
    ])
    await fixture.session.selectRadio("backup")
    XCTAssertEqual(fixture.session.safetyBanner?.kind, .dekey_required)
}

func testSWRTripResetUsesExactRouteAndLiteralPhysicalInspectionAcknowledgement() throws {
    XCTAssertEqual(RadioLiteSWRTripResetRoute.path(radioId: "backup"),
                   "/api/v1/radios/backup/swr-trip/reset")
    let request = try RadioLiteSWRTripResetRequest(physicalInspectionAcknowledged: true)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
    XCTAssertEqual(json["acknowledgePhysicalInspection"] as? Bool, true)
    XCTAssertThrowsError(try RadioLiteSWRTripResetRequest(physicalInspectionAcknowledged: false))
}

func testSWRResetControlRequiresAdminFeatureTripAndNeverLocallyClearsTheBanner() {
    XCTAssertFalse(RadioLiteSWRResetPresentation.canOffer(
        kind: .swr_trip_latched, features: .unsupported, isAdmin: true))
    XCTAssertFalse(RadioLiteSWRResetPresentation.canOffer(
        kind: .swr_trip_latched, features: .allEnabled, isAdmin: false))
    XCTAssertFalse(RadioLiteSWRResetPresentation.canOffer(
        kind: .swr_rearm_pending, features: .allEnabled, isAdmin: true))
    XCTAssertTrue(RadioLiteSWRResetPresentation.canOffer(
        kind: .swr_trip_latched, features: .allEnabled, isAdmin: true))
    XCTAssertEqual(RadioLiteSWRResetPresentation.bannerTitle(kind: .swr_trip_latched, isAdmin: true),
                   "SWR 保护已锁定，禁止发射")
    XCTAssertEqual(RadioLiteSWRResetPresentation.bannerTitle(kind: .swr_trip_latched, isAdmin: false),
                   "SWR 保护已锁定，禁止发射；请联系管理员现场检查并复位")
    XCTAssertEqual(RadioLiteSWRResetPresentation.bannerTitle(kind: .swr_rearm_pending, isAdmin: false),
                   "下一次发射是一次性受监测复位")
    XCTAssertTrue(RadioLiteSafetyPresentationPolicy.shouldRetainServerBannerAfterSWRResetReply)
}

func testSWRResetErrorPresentationRetainsFailClosedState() {
    XCTAssertEqual(RadioLiteSWRResetPresentation.message(status: 403),
                   "仅管理员可确认现场检查并复位 SWR 锁定")
    XCTAssertEqual(RadioLiteSWRResetPresentation.message(status: 409),
                   "无法复位：必须先确认 PTT 已关闭，并完成停发恢复或配置预检")
    XCTAssertEqual(RadioLiteSWRResetPresentation.message(status: nil),
                   "复位结果未确认；请以服务器安全横幅为准")
    XCTAssertTrue(RadioLiteSafetyPresentationPolicy.shouldRetainServerBannerAfterSWRResetFailure)
}
```

Declare `RadioLiteEmergencyStopTests` and every test fixture touching `RadioLiteSession` as
`@MainActor`. The fixture is concrete, not an assumed helper:

```swift
@MainActor
final class RadioLiteSessionFixture {
    let channel: RadioLiteFakeWebSocketChannel
    let control: RadioLiteControlClient
    let session: RadioLiteSession
    var lastRequest: JSONValue? { channel.lastRequest }

    init(selectedRadioId: String, connectionGeneration: UInt64 = 1,
         fixedCommandId: String = "expected", reply: [String: String]? = nil) {
        let channel = RadioLiteFakeWebSocketChannel(connectionGeneration: connectionGeneration,
            reply: reply ?? ["t": "tx.emergency-stop.accepted",
                             "radioId": selectedRadioId, "commandId": fixedCommandId])
        let control = RadioLiteControlClient(channel: channel)
        let session = RadioLiteSession(control: control, commandIdGenerator: { fixedCommandId },
            testState: .ready(features: .allEnabled,
                              radios: [.fixture(id: "main"), .fixture(id: "backup")],
                              selectedRadioId: selectedRadioId))
        self.channel = channel
        self.control = control
        self.session = session
    }

    func deliverSafetySnapshotSet(epoch: String, snapshots: [RadioLiteSafetyAlertSnapshot]) {
        channel.emit(.snapshotBegin(epoch: epoch)); snapshots.forEach { channel.emit(.snapshot($0)) }
        channel.emit(.snapshotEnd(epoch: epoch))
    }
}
```

`RadioLiteFakeWebSocketChannel` implements `RadioLiteWebSocketChanneling`, records the exact
request, returns the configured reply only after recording, and emits every test message with its
captured connection generation. `.allEnabled` (all seven capability flags, including
`swrTripReset`), radio fixtures, and the three snapshot JSON helpers
are test-only constructors declared in `RadioLiteEmergencyStopTests.swift`; they do not alter wire
models.

- [ ] **Step 2: Run snapshot tests and verify red**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteSafetyAlertStateTests -only-testing:RadioLiteTests/RadioLiteSafetyPresentationPolicyTests -only-testing:RadioLiteTests/RadioLiteEmergencyStopTests -only-testing:RadioLiteTests/RadioLiteSWRTripResetTests -only-testing:RadioLiteTests/RadioLiteModelsTests`

Expected: FAIL to compile because safety snapshot/event/banner models and the reducer do not exist.

- [ ] **Step 3: Implement the reducer and wire only authoritative state to the banner**

```swift
enum RadioLitePersistentSafetyAlertKind: String, Codable, Sendable {
    case active, external_ptt, telemetry_uncertain, dekey_required, dekey_escalated
    case swr_trip_latched, swr_rearm_pending
}

enum RadioLiteSafetyEventKind: String, Codable, Sendable {
    case active, external_ptt, telemetry_uncertain, dekey_required, dekey_escalated
    case swr_trip_latched, swr_rearm_pending, recovered
    var persistent: RadioLitePersistentSafetyAlertKind? {
        self == .recovered ? nil : RadioLitePersistentSafetyAlertKind(rawValue: rawValue)
    }
}

mutating func ingestEvent(_ event: RadioLiteSafetyAlertEvent, connectionGeneration: UInt64) {
    guard connectionGeneration == activeConnectionGeneration else { return }
    if let collectingEpoch {
        guard event.safetyEpoch == collectingEpoch else { return }
        bufferedEvents.append(event)
        return
    }
    guard event.safetyEpoch == epoch else { return }
    if let previous = revisions[event.radioId] {
        guard event.revision > previous else { return }
    }
    revisions[event.radioId] = event.revision
    alerts[event.radioId] = event.kind.persistent.map {
        .init(kind: $0, startedAtMs: event.startedAtMs, source: event.source)
    }
}

struct RadioLiteSWRTripResetRequest: Encodable, Equatable {
    let acknowledgePhysicalInspection: Bool
    init(physicalInspectionAcknowledged: Bool) throws {
        guard physicalInspectionAcknowledged else {
            throw RadioLiteSWRTripResetError.physicalInspectionNotAcknowledged
        }
        acknowledgePhysicalInspection = true
    }
}

enum RadioLiteSWRTripResetRoute {
    static func path(radioId: String) -> String {
        "/api/v1/radios/\(radioId)/swr-trip/reset"
    }
}

enum RadioLiteSWRTripResetError: Error, Equatable {
    case featureUnavailable
    case administratorRequired
    case physicalInspectionNotAcknowledged
    case noLatchedTripForSelectedRadio
}

enum RadioLiteSWRResetPresentation {
    static func canOffer(kind: RadioLitePersistentSafetyAlertKind?,
                         features: RadioLiteServerFeatures, isAdmin: Bool) -> Bool {
        features.swrTripReset && isAdmin && kind == .swr_trip_latched
    }

    static func message(status: Int?) -> String {
        switch status {
        case 403: return "仅管理员可确认现场检查并复位 SWR 锁定"
        case 409: return "无法复位：必须先确认 PTT 已关闭，并完成停发恢复或配置预检"
        default: return "复位结果未确认；请以服务器安全横幅为准"
        }
    }

    static func bannerTitle(kind: RadioLitePersistentSafetyAlertKind, isAdmin: Bool) -> String? {
        switch kind {
        case .swr_trip_latched where !isAdmin:
            return "SWR 保护已锁定，禁止发射；请联系管理员现场检查并复位"
        case .swr_trip_latched: return "SWR 保护已锁定，禁止发射"
        case .swr_rearm_pending: return "下一次发射是一次性受监测复位"
        default: return nil
        }
    }
}

func resetSWRTrip(radioId: String, physicalInspectionAcknowledged: Bool) async throws {
    let request = try RadioLiteSWRTripResetRequest(
        physicalInspectionAcknowledged: physicalInspectionAcknowledged)
    let body = try JSONEncoder().encode(request)
    _ = try await rawRequest(method: "POST", path: RadioLiteSWRTripResetRoute.path(radioId: radioId),
                             contentType: "application/json", body: body)
}
```

Decode `safety.snapshot.begin`, `safety.snapshot`, `safety.snapshot.end`, and `safety.event` in `handleControlEvent(_:connectionGeneration:)` before the existing `radioId == selectedRadioId` guard; safety messages always enter the all-radio reducer, while the guard continues to filter ordinary single-radio UI events. `RadioLiteWebSocketChannel` assigns the generation when each physical connection is created and includes that captured value in every message and disconnect callback; `RadioLiteControlClient` must not read a mutable latest generation when forwarding either delayed callback. After `auth.ok`, call `markConnected` with that physical connection's captured generation before requesting the complete stream. `beginSnapshot` may only install `collectingEpoch` for the already active generation and leaves the committed `epoch` visible until end. `ingestSnapshot` accepts only that collecting epoch/generation; an orphan snapshot is ignored. While `collectingEpoch != nil`, `ingestEvent` compares against the collecting epoch and buffers it; only outside an envelope does it compare against the committed epoch and apply directly. It must never guard against the old committed epoch before choosing the buffering branch. `endSnapshot` commits only when epoch and generation both match, atomically installs the buffered snapshot, then replays only newer per-radio revisions. `markDisconnected(connectionGeneration:)` first verifies that the callback's captured generation still owns the active connection; only then may it set the active generation to nil and discard `collectingEpoch`, partial snapshots, and buffered events. Thus an old connection's delayed disconnect cannot invalidate a newer connection, and delayed recovered/begin/snapshot/end messages tagged with a formerly valid generation cannot clear stale state. A newly authenticated generation still cannot clear stale state until its matching complete snapshot ends. The distinct event-kind conversion makes recovered clear the entry without ever constructing a persistent recovered alert; local PTT end never clears the reducer.

Implement `emergencyStop()` by first capturing the nonempty `selectedRadioId`, then generating `commandId = UUID().uuidString` and calling `control.request(.object(["t": .string("tx.emergency-stop"), "radioId": .string(radioId), "commandId": .string(commandId)]), expecting: ["tx.emergency-stop.accepted"], commandId: commandId, timeout: RadioLiteNetworkPolicy.stopSendTimeout)`. After the request helper matches `commandId`, also require the accepted reply's `radioId` to equal the captured radio; either mismatch is a protocol error and retains pending/unconfirmed state. For absent `safetyAlerts`, publish a compatibility banner stating the server cannot provide authoritative safety status; for a retained stop identity, add stale remote-unconfirmed state. `RadioLiteSafetyBannerView` maps `.active` to red, `.external_ptt` to orange with `只告警，未自动干预`, `.dekey_required`/`.dekey_escalated` to dark red, `.swr_trip_latched` to dark red with `SWR 保护已锁定，禁止发射`, and `.swr_rearm_pending` to amber with `下一次发射是一次性受监测复位`; it includes elapsed seconds, stale wording, VoiceOver label/value/hint, and a button calling `emergencyStop`. Preserve the server severity order `dekey_escalated > dekey_required > swr_trip_latched > swr_rearm_pending > active > external_ptt > telemetry_uncertain` in presentation tests.

When the selected server advertises `swrTripReset`, show an administrator-only reset action only on `.swr_trip_latched`. It opens a non-repeating confirmation sheet with an unchecked control labelled `我已现场检查天线、馈线及功放，并确认电台 PTT 已关闭`; keep the destructive `确认检查并申请一次受监测复位` button disabled until checked. The client sends literal true, while the server still performs the authoritative fresh PTT-OFF/dekey/fence checks. A 2xx reply changes only request progress; continue showing the current server alert until `.swr_rearm_pending` arrives. Hide the action for operators, legacy servers, `.swr_rearm_pending`, and every other alert; an operator still sees the exact persistent copy `SWR 保护已锁定，禁止发射；请联系管理员现场检查并复位`. Map 403, 409, timeout/transport uncertainty to the exact XCTest messages above, retain the existing alert in every failure path, and never represent an HTTP reply as physical OFF or a successful rearm. Keep `RadioLiteHoldButton` press/release but add `accessibilityAction(named: "开始发射")` and `accessibilityAction(named: "停止发射")`; issue UIKit impact/notification feedback from explicit session transitions only.

Refactor the existing no-argument `RadioLiteSession.init()` into the internal dependency initializer
from Interfaces while preserving `RadioLiteSession()` as the production call through default
arguments. Store the injected `commandIdGenerator`; do not call `UUID()` directly in
`emergencyStop`. When `testState` is non-nil, assign only the supplied phase/health/radios/selected
radio after normal control/audio callback wiring, without opening sockets. Production passes nil.
Set `emergencyStopPending` before request and clear it only after an exact accepted reply; throw
`.replyIdentityMismatch` for either reply field mismatch and leave it true. Unsupported feature,
empty selection, and transport errors keep their distinct error cases, so the mismatch XCTest
cannot pass through a catch-all path.

- [ ] **Step 4: Run safety tests, UI build, and contract checker**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteSafetyAlertStateTests -only-testing:RadioLiteTests/RadioLiteSafetyPresentationPolicyTests -only-testing:RadioLiteTests/RadioLiteEmergencyStopTests -only-testing:RadioLiteTests/RadioLiteSWRTripResetTests -only-testing:RadioLiteTests/RadioLiteModelsTests && xcodebuild build -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" && node scripts/check-ios-radio-lite-contract.mjs`

Expected: PASS; stale external/dekey/SWR banners survive disconnect, only matching complete snapshots replace them, the administrator reset sends the exact route and literal acknowledgement without locally clearing a banner, and the contract checker finds `tx.emergency-stop`, the SWR reset route/feature, plus every safety message type in client/server/protocol.

- [ ] **Step 5: Commit authoritative safety UI**

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteSafetyAlertState.swift ios/RadioLite/Core/RadioLite/RadioLiteModels.swift ios/RadioLite/Core/RadioLite/RadioLiteSession.swift ios/RadioLite/Core/RadioLite/RadioLiteControlClient.swift ios/RadioLite/Core/RadioLite/RadioLiteWebSocketChannel.swift ios/RadioLite/Core/RadioLite/RadioLiteMediaClient.swift ios/RadioLite/Core/RadioLite/RadioLiteHTTPClient.swift ios/RadioLite/Features/RadioLite/RadioLiteSafetyBannerView.swift ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift ios/RadioLiteTests/RadioLiteSafetyAlertStateTests.swift ios/RadioLiteTests/RadioLiteSafetyPresentationPolicyTests.swift ios/RadioLiteTests/RadioLiteEmergencyStopTests.swift ios/RadioLiteTests/RadioLiteSWRTripResetTests.swift ios/RadioLiteTests/RadioLiteModelsTests.swift radio-lite-server/PROTOCOL.md scripts/check-ios-radio-lite-contract.mjs
git commit -m "feat(ios): present server-authoritative transmit safety"
```

### Task 5: Feature-gated preflight, radio safety settings, and account administration

**Files:**
- Create: `ios/RadioLite/Core/RadioLite/RadioLiteAccountAdministration.swift`, `ios/RadioLite/Features/RadioLite/RadioLiteAccountAdministrationView.swift`, `ios/RadioLite/Features/RadioLite/RadioLitePasswordChangeView.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteDeviceConfiguration.swift`, `RadioLiteHTTPClient.swift`, `RadioLiteSession.swift`, `RadioLiteModels.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteDeviceConfigurationView.swift`, `RadioLiteSettingsView.swift`
- Test: `ios/RadioLiteTests/RadioLiteDeviceConfigurationTests.swift`, `RadioLiteTests/RadioLiteHTTPErrorPresentationTests.swift`, `RadioLiteTests/RadioLiteAccountAdministrationTests.swift`, `RadioLiteTests/RadioLiteModelsTests.swift`

**Interfaces:**
- Add `RadioLiteTransmitRange { let lowerHz: Int64; let upperHz: Int64 }`, `RadioLiteSWRPolicy` including decode-only `.configurationRequired`, and `RadioLiteReconfigurationFenceRef { reconfigurationEpoch: String; reconfigurationGeneration: UInt64 }`. `RadioLitePreflightProof` and `RadioLiteHardwarePreflightResult` expose the optional complete fence ref, never a generation alone.
- Extend `RadioLiteHardwarePreflightCheckID` with `.swr` and `.txSafetyConfig = "tx_safety_config"`. Add `RadioLiteAcknowledgedPreflightWarnings { let swrUnavailable: Bool }` to the result; its custom decoder defaults a missing object to `swrUnavailable: false` so legacy four-check responses remain decodable.
- Split the role-aware `RadioLiteRadioProfileRead` response model (hardware identifiers optional/redacted) from the complete `RadioLiteRadioProfile` write model. Only an administrator read with every required identifier can become an editable/write profile.
- Add `RadioLiteHTTPClient.reconfigurationPreflight(radioId:profile:)`, `cancelReconfigurationPreflight(radioId:fence:)`, and `resumeReconfiguration(radioId:fence:)`. `RadioLiteRadioUpsertRequest` has a private envelope and only three throwing factories—`receiveOnly(profile:)`, `enabledOrdinary(profile:proof:)`, and `enabledFenced(profile:proof:fence:)`—so no generic optional-field initializer can represent a fourth shape. Dummy or hardware-TX-disabled omits confirmation/proof/fence; enabled real hardware outside a fence sends `hardwareTxConfirmation = profile.id` plus the ordinary passed proof and omits both ref fields; enabled real hardware inside a fence sends that confirmation, the proof, and the complete ref from the same draft.
- Add `RadioLiteAccountAdministrationState` and typed HTTP/session methods for `GET /api/v1/users`, `POST /api/v1/users`, `PATCH /api/v1/users/:userId`, `POST /api/v1/session/password`, `GET /api/v1/devices`, `PATCH /api/v1/devices/:deviceId`, `DELETE /api/v1/devices/:deviceId`, and `GET /api/v1/audit` with optional integer `limit` and opaque `cursor` query items. `RadioLiteAuditQuery.items(limit:cursor:)` appends `cursor` only when non-nil.

- [ ] **Step 1: Write failing feature-gate and explicit-preflight tests**

```swift
func testLegacyServerDoesNotOfferRuntimeStoppingPreflightOrAdminControls() {
    XCTAssertFalse(RadioLiteServerFeatures.unsupported.hardwarePreflight)
    XCTAssertFalse(RadioLiteSettingsPresentation(features: .unsupported, isAdmin: true).showsAccountAdministration)
}

func testAccountAdministrationAllowsOnlyAdminAndOperatorAndNonemptyPasswords() {
    XCTAssertEqual(RadioLiteUserRole.allCases, [.admin, .operator])
    XCTAssertFalse(RadioLiteAccountAdministrationState.canSubmitPassword(""))
    XCTAssertTrue(RadioLiteAccountAdministrationState.canSubmitPassword("任意 Unicode 密码"))
}

func testReconfigurationPreflightUsesExactRadioScopedRoutes() {
    XCTAssertEqual(RadioLiteReconfigurationRoute.preflight(radioId: "main"), "/api/v1/radios/main/reconfiguration/preflight")
    XCTAssertEqual(RadioLiteReconfigurationRoute.cancel(radioId: "main"), "/api/v1/radios/main/reconfiguration/cancel")
    XCTAssertEqual(RadioLiteReconfigurationRoute.resume(radioId: "main"), "/api/v1/radios/main/reconfiguration/resume")
}

func testReconfigurationCompletionCarriesTheCompleteFenceReference() throws {
    let fence = RadioLiteReconfigurationFenceRef(reconfigurationEpoch: "epoch-a", reconfigurationGeneration: 17)
    let body = RadioLiteReconfigurationCompletionRequest(fence: fence)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
    XCTAssertEqual(json["reconfigurationEpoch"] as? String, "epoch-a")
    XCTAssertEqual((json["reconfigurationGeneration"] as? NSNumber)?.uint64Value, 17)
}

func testPreflightResultAndProofExposeTheSameFenceReference() {
    let fence = RadioLiteReconfigurationFenceRef(reconfigurationEpoch: "epoch-a", reconfigurationGeneration: 17)
    let result = RadioLiteHardwarePreflightResult.fixture(fence: fence, proof: .fixture(fence: fence))
    XCTAssertEqual(result.fence, fence)
    XCTAssertEqual(result.preflightProof?.fence, fence)
}

func testFencedRadioUpsertCarriesProofAndTheSameDraftFence() throws {
    let fence = RadioLiteReconfigurationFenceRef(reconfigurationEpoch: "epoch-a", reconfigurationGeneration: 17)
    let profile = RadioLiteRadioProfile.fixture(id: "main", hardwareTxEnabled: true)
    let request = try RadioLiteRadioUpsertRequest.enabledFenced(
        profile: profile, proof: .fixture(proof: "proof-17", fence: fence), fence: fence
    )
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
    XCTAssertEqual(json["hardwareTxConfirmation"] as? String, "main")
    XCTAssertNil(json["confirmHardwareTransmission"])
    XCTAssertEqual(json["preflightProof"] as? String, "proof-17")
    XCTAssertEqual(json["reconfigurationEpoch"] as? String, "epoch-a")
    XCTAssertEqual((json["reconfigurationGeneration"] as? NSNumber)?.uint64Value, 17)
}

func testDummyAndHardwareDisabledRadioUpsertsOmitTransmitProofAndFenceFields() throws {
    for profile in [
        RadioLiteRadioProfile.fixture(id: "main", hardwareTxEnabled: false),
        RadioLiteRadioProfile.fixture(
            id: "dummy", connectionKind: .hamlibDummy, hardwareTxEnabled: true
        ),
    ] {
        let request = try RadioLiteRadioUpsertRequest.receiveOnly(profile: profile)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as! [String: Any]
        XCTAssertNil(json["hardwareTxConfirmation"])
        XCTAssertNil(json["confirmHardwareTransmission"])
        XCTAssertNil(json["preflightProof"])
        XCTAssertNil(json["reconfigurationEpoch"])
        XCTAssertNil(json["reconfigurationGeneration"])
    }
}

func testEnabledHardwareOrdinaryUpsertCarriesConfirmationAndProofOnly() throws {
    let request = try RadioLiteRadioUpsertRequest.enabledOrdinary(
        profile: .fixture(id: "main", hardwareTxEnabled: true),
        proof: .fixture(proof: "ordinary-proof", fence: nil)
    )
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
    XCTAssertEqual(json["hardwareTxConfirmation"] as? String, "main")
    XCTAssertNil(json["confirmHardwareTransmission"])
    XCTAssertEqual(json["preflightProof"] as? String, "ordinary-proof")
    XCTAssertNil(json["reconfigurationEpoch"])
    XCTAssertNil(json["reconfigurationGeneration"])
}

func testRadioUpsertFactoriesRejectEveryInvalidEnvelopeCombination() {
    let enabled = RadioLiteRadioProfile.fixture(id: "main", hardwareTxEnabled: true)
    let disabled = RadioLiteRadioProfile.fixture(id: "main", hardwareTxEnabled: false)
    let fence = RadioLiteReconfigurationFenceRef(
        reconfigurationEpoch: "epoch-a", reconfigurationGeneration: 17
    )
    let otherFence = RadioLiteReconfigurationFenceRef(
        reconfigurationEpoch: "epoch-b", reconfigurationGeneration: 17
    )
    XCTAssertThrowsError(try RadioLiteRadioUpsertRequest.receiveOnly(profile: enabled))
    XCTAssertThrowsError(try RadioLiteRadioUpsertRequest.enabledOrdinary(
        profile: disabled, proof: .fixture(proof: "proof", fence: nil)
    ))
    XCTAssertThrowsError(try RadioLiteRadioUpsertRequest.enabledOrdinary(
        profile: enabled, proof: .fixture(proof: "proof", fence: fence)
    ))
    XCTAssertThrowsError(try RadioLiteRadioUpsertRequest.enabledFenced(
        profile: enabled, proof: .fixture(proof: "proof", fence: otherFence), fence: fence
    ))
}

func testRawPreflightDecodesSWRWarningAndAcknowledgement() throws {
    let data = Data(#"""
    {"profileId":"main","testedAtMs":1787700000000,"readOnly":true,
     "overallStatus":"passed",
     "checks":[{"id":"swr","status":"warning","message":"SWR unavailable","details":{}}],
     "acknowledgedWarnings":{"swrUnavailable":true}}
    """#.utf8)
    let result = try JSONDecoder().decode(RadioLiteHardwarePreflightResult.self, from: data)
    XCTAssertEqual(result.checks.map(\.id), [.swr])
    XCTAssertEqual(result.checks.first?.status, .warning)
    XCTAssertTrue(result.acknowledgedWarnings.swrUnavailable)
}

func testRawPreflightDecodesFailedTransmitSafetyConfiguration() throws {
    let data = Data(#"""
    {"profileId":"main","testedAtMs":1787700000001,"readOnly":true,
     "overallStatus":"failed",
     "checks":[{"id":"tx_safety_config","status":"failed","message":"Configure TX safety","details":{}}],
     "acknowledgedWarnings":{"swrUnavailable":false}}
    """#.utf8)
    let result = try JSONDecoder().decode(RadioLiteHardwarePreflightResult.self, from: data)
    XCTAssertEqual(result.checks.map(\.id), [.txSafetyConfig])
    XCTAssertEqual(result.checks.first?.status, .failed)
    XCTAssertFalse(result.acknowledgedWarnings.swrUnavailable)
}

func testRawPassedPreflightDecodesMatchingProofAndTopLevelFence() throws {
    let data = Data(#"""
    {"profileId":"main","testedAtMs":1787700000002,"readOnly":true,"overallStatus":"passed",
     "checks":[],"acknowledgedWarnings":{"swrUnavailable":false},
     "preflightProof":{"proof":"proof-17","profileFingerprint":"abc","issuedAtMs":1787700000002,
       "expiresAtMs":1787700600002,"preflightPassed":true,
       "fence":{"reconfigurationEpoch":"epoch-a","reconfigurationGeneration":17}},
     "reconfigurationEpoch":"epoch-a","reconfigurationGeneration":17}
    """#.utf8)
    let result = try JSONDecoder().decode(RadioLiteHardwarePreflightResult.self, from: data)
    XCTAssertEqual(result.fence, .init(reconfigurationEpoch: "epoch-a", reconfigurationGeneration: 17))
    XCTAssertEqual(result.preflightProof?.fence, result.fence)
}

func testRawPreflightRejectsAnIncompleteTopLevelFence() {
    for fragment in [#""reconfigurationEpoch":"epoch-a""#, #""reconfigurationGeneration":17"#] {
        let data = Data("{\"profileId\":\"main\",\"testedAtMs\":1,\"readOnly\":true,\"overallStatus\":\"passed\",\"checks\":[],\(fragment)}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RadioLiteHardwarePreflightResult.self, from: data))
    }
}

func testAuditQueryOmitsNilCursorAndRoundTripsOpaqueCursor() throws {
    var first = URLComponents(string: "http://radio/api/v1/audit")!
    first.queryItems = RadioLiteAuditQuery.items(limit: 50, cursor: nil)
    XCTAssertFalse(try XCTUnwrap(first.url).absoluteString.contains("cursor"))

    let opaque = "generation/7+offset=42"
    var next = URLComponents(string: "http://radio/api/v1/audit")!
    next.queryItems = RadioLiteAuditQuery.items(limit: 50, cursor: opaque)
    XCTAssertEqual(next.queryItems?.first(where: { $0.name == "cursor" })?.value, opaque)
    XCTAssertTrue(try XCTUnwrap(next.url).absoluteString.contains("cursor="))
}

func testOldSaveCompletionCannotClearAReplacementFence() {
    let old = RadioLiteReconfigurationFenceRef(reconfigurationEpoch: "epoch-old", reconfigurationGeneration: 17)
    let replacement = RadioLiteReconfigurationFenceRef(reconfigurationEpoch: "epoch-new", reconfigurationGeneration: 17)
    var state = RadioLiteRadioConfigurationState(); state.installFence(replacement)
    state.handleSaveFailure(.staleReconfigurationGeneration, requestFence: old)
    XCTAssertEqual(state.fence, replacement)
}

func testRawLegacyProfileMissingRangeAndSWRDecodesAsConfigurationRequired() throws {
    let data = #"{"id":"main","name":"FT-710","hamlibModelId":1049,"connection":{"kind":"managed-serial","devicePath":"/dev/ttyUSB0","baudRate":38400},"audioInput":{"backend":"alsa","id":"hw:1,0"},"audioOutput":{"backend":"alsa","id":"hw:1,0"},"ptt":{"method":"RIG"},"station":{"callsign":"BI1ABC"},"hardwareTxEnabled":true}"#.data(using: .utf8)!
    let read = try JSONDecoder().decode(RadioLiteRadioProfileRead.self, from: data)
    XCTAssertEqual(read.allowedTransmitRangesHz, [])
    XCTAssertEqual(read.swrPolicy, .configurationRequired)
    XCTAssertTrue(RadioLiteDeviceConfigurationPresentation(profile: read).showsTransmitSafetyRequired)
}

func testRawOperatorRedactedProfileDecodesForRadioListButCannotBecomeEditable() throws {
    let data = #"{"id":"main","name":"FT-710","hamlibModelId":1049,"connection":{"kind":"managed-serial"},"audioInput":{"backend":"alsa"},"audioOutput":{"backend":"alsa"},"ptt":{"method":"RIG"},"station":{"callsign":"BI1ABC"},"hardwareTxEnabled":true,"allowedTransmitRangesHz":[{"lowerHz":14000000,"upperHz":14350000}],"swrPolicy":{"mode":"require_swr","trip":3,"reset":2}}"#.data(using: .utf8)!
    let read = try JSONDecoder().decode(RadioLiteRadioProfileRead.self, from: data)
    XCTAssertEqual(read.id, "main")
    XCTAssertNil(read.audioInput.id)
    XCTAssertThrowsError(try read.requireEditableProfile())
}

func testRealHardwareProfileEncodesRangeSWRAndProofOnlyAfterPassedPreflight() throws {
    let draft = RadioLiteRadioConfigurationDraft.fixture(hardwareTxEnabled: true)
    XCTAssertThrowsError(try draft.makeProfile())
    let completed = draft.with(ranges: [.init(lowerHz: 14_000_000, upperHz: 14_350_000)], swrPolicy: .acknowledgedInternalProtection, proof: .fixture)
    XCTAssertTrue(try completed.makeProfile().hardwareTxEnabled)
}
```

- [ ] **Step 2: Run red settings tests**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteDeviceConfigurationTests -only-testing:RadioLiteTests/RadioLiteHTTPErrorPresentationTests -only-testing:RadioLiteTests/RadioLiteAccountAdministrationTests -only-testing:RadioLiteTests/RadioLiteModelsTests`

Expected: FAIL because range, SWR, proof, radio-scoped reconfiguration routes, account administration state, and typed account/device/audit APIs are absent.

- [ ] **Step 3: Implement feature-gated settings without implicit runtime interruption**

```swift
func reconfigurationPreflight(radioId: String, profile: RadioLiteRadioProfile) async throws -> RadioLiteHardwarePreflightResult {
    struct Body: Encodable { let profile: RadioLiteRadioProfile }
    let result: RadioLiteHardwarePreflightResult = try await send(method: "POST", path: "/api/v1/radios/\(radioId)/reconfiguration/preflight", body: Body(profile: profile))
    guard result.fence != nil else { throw RadioLiteDeviceConfigurationError.missingReconfigurationFence }
    return result
}

func cancelReconfigurationPreflight(radioId: String, fence: RadioLiteReconfigurationFenceRef) async throws {
    let body = RadioLiteReconfigurationCompletionRequest(fence: fence)
    _ = try await send(method: "POST", path: "/api/v1/radios/\(radioId)/reconfiguration/cancel", body: body) as RadioLiteEmptyResponse
}

func resumeReconfiguration(radioId: String, fence: RadioLiteReconfigurationFenceRef) async throws {
    let body = RadioLiteReconfigurationCompletionRequest(fence: fence)
    _ = try await send(method: "POST", path: "/api/v1/radios/\(radioId)/reconfiguration/resume", body: body) as RadioLiteEmptyResponse
}

func revokeDevice(_ deviceId: String) async throws {
    _ = try await rawRequest(method: "DELETE", path: "/api/v1/devices/\(deviceId)", contentType: nil, body: nil)
}

func updateUser(_ userId: String, enabled: Bool, role: RadioLiteUserRole, canTransmit: Bool) async throws -> RadioLiteUser {
    struct Body: Encodable { let enabled: Bool; let role: RadioLiteUserRole; let canTransmit: Bool }
    return try await send(method: "PATCH", path: "/api/v1/users/\(userId)", body: Body(enabled: enabled, role: role, canTransmit: canTransmit))
}

func changeOwnPassword(currentPassword: String, newPassword: String) async throws {
    struct Body: Encodable { let currentPassword: String; let newPassword: String }
    guard RadioLiteAccountAdministrationState.canSubmitPassword(newPassword) else { throw RadioLiteAccountAdministrationError.emptyPassword }
    _ = try await send(method: "POST", path: "/api/v1/session/password", body: Body(currentPassword: currentPassword, newPassword: newPassword)) as RadioLiteEmptyResponse
}

struct RadioLiteReconfigurationCompletionRequest: Codable, Equatable {
    let reconfigurationEpoch: String
    let reconfigurationGeneration: UInt64
    init(fence: RadioLiteReconfigurationFenceRef) {
        reconfigurationEpoch = fence.reconfigurationEpoch
        reconfigurationGeneration = fence.reconfigurationGeneration
    }
}

struct RadioLiteRadioUpsertRequest: Encodable {
    private enum Envelope {
        case receiveOnly(profile: RadioLiteRadioProfile)
        case enabledOrdinary(profile: RadioLiteRadioProfile, proof: RadioLitePreflightProof)
        case enabledFenced(profile: RadioLiteRadioProfile, proof: RadioLitePreflightProof,
                           fence: RadioLiteReconfigurationFenceRef)
    }

    private let envelope: Envelope
    private init(_ envelope: Envelope) { self.envelope = envelope }
    private static func isDummy(_ profile: RadioLiteRadioProfile) -> Bool {
        profile.connection.kind == RadioLiteConnectionKind.hamlibDummy.rawValue
    }

    static func receiveOnly(profile: RadioLiteRadioProfile) throws -> Self {
        guard isDummy(profile) || !profile.hardwareTxEnabled else {
            throw RadioLiteDeviceConfigurationError.invalidUpsertEnvelope
        }
        return Self(.receiveOnly(profile: profile))
    }

    static func enabledOrdinary(profile: RadioLiteRadioProfile,
                                proof: RadioLitePreflightProof) throws -> Self {
        guard !isDummy(profile), profile.hardwareTxEnabled, proof.preflightPassed,
              proof.fence == nil else {
            throw RadioLiteDeviceConfigurationError.invalidUpsertEnvelope
        }
        return Self(.enabledOrdinary(profile: profile, proof: proof))
    }

    static func enabledFenced(profile: RadioLiteRadioProfile,
                              proof: RadioLitePreflightProof,
                              fence: RadioLiteReconfigurationFenceRef) throws -> Self {
        guard !isDummy(profile), profile.hardwareTxEnabled, proof.preflightPassed,
              proof.fence == fence else {
            throw RadioLiteDeviceConfigurationError.invalidUpsertEnvelope
        }
        return Self(.enabledFenced(profile: profile, proof: proof, fence: fence))
    }

    private enum CodingKeys: String, CodingKey {
        case profile, hardwareTxConfirmation, preflightProof
        case reconfigurationEpoch, reconfigurationGeneration
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch envelope {
        case let .receiveOnly(profile):
            try values.encode(profile, forKey: .profile)
        case let .enabledOrdinary(profile, proof):
            try values.encode(profile, forKey: .profile)
            try values.encode(profile.id, forKey: .hardwareTxConfirmation)
            try values.encode(proof.proof, forKey: .preflightProof)
        case let .enabledFenced(profile, proof, fence):
            try values.encode(profile, forKey: .profile)
            try values.encode(profile.id, forKey: .hardwareTxConfirmation)
            try values.encode(proof.proof, forKey: .preflightProof)
            try values.encode(fence.reconfigurationEpoch, forKey: .reconfigurationEpoch)
            try values.encode(fence.reconfigurationGeneration, forKey: .reconfigurationGeneration)
        }
    }
}

enum RadioLiteHardwarePreflightCheckID: String, Codable, Equatable, Hashable, Sendable {
    case cat, capabilities, audioInput, audioOutput, swr
    case txSafetyConfig = "tx_safety_config"
}

struct RadioLiteAcknowledgedPreflightWarnings: Codable, Equatable, Sendable {
    let swrUnavailable: Bool
    static let none = Self(swrUnavailable: false)
}

struct RadioLitePreflightProof: Decodable, Equatable, Sendable {
    let proof: String
    let profileFingerprint: String
    let issuedAtMs: Int64
    let expiresAtMs: Int64
    let preflightPassed: Bool
    let fence: RadioLiteReconfigurationFenceRef?
}

struct RadioLiteHardwarePreflightResult: Decodable, Equatable, Sendable {
    let profileId: String
    let testedAtMs: Int64
    let readOnly: Bool
    let overallStatus: RadioLiteHardwarePreflightStatus
    let checks: [RadioLiteHardwarePreflightCheck]
    let acknowledgedWarnings: RadioLiteAcknowledgedPreflightWarnings
    let preflightProof: RadioLitePreflightProof?
    let fence: RadioLiteReconfigurationFenceRef?
}

extension RadioLiteHardwarePreflightResult {
    private enum CodingKeys: String, CodingKey {
        case profileId, testedAtMs, readOnly, overallStatus, checks
        case acknowledgedWarnings, preflightProof
        case reconfigurationEpoch, reconfigurationGeneration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try container.decode(String.self, forKey: .profileId)
        testedAtMs = try container.decode(Int64.self, forKey: .testedAtMs)
        readOnly = try container.decode(Bool.self, forKey: .readOnly)
        overallStatus = try container.decode(RadioLiteHardwarePreflightStatus.self, forKey: .overallStatus)
        checks = try container.decode([RadioLiteHardwarePreflightCheck].self, forKey: .checks)
        acknowledgedWarnings = try container.decodeIfPresent(
            RadioLiteAcknowledgedPreflightWarnings.self, forKey: .acknowledgedWarnings
        ) ?? .none
        preflightProof = try container.decodeIfPresent(RadioLitePreflightProof.self, forKey: .preflightProof)
        let epoch = try container.decodeIfPresent(String.self, forKey: .reconfigurationEpoch)
        let generation = try container.decodeIfPresent(UInt64.self, forKey: .reconfigurationGeneration)
        switch (epoch, generation) {
        case let (.some(epoch), .some(generation)):
            fence = .init(reconfigurationEpoch: epoch, reconfigurationGeneration: generation)
        case (nil, nil):
            fence = nil
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .reconfigurationEpoch, in: container,
                debugDescription: "reconfiguration fence requires both epoch and generation"
            )
        }
    }
}

struct RadioLiteAudioEndpointRead: Decodable, Equatable {
    let backend: String
    let id: String?
    let label: String?
}

// In RadioLiteRadioProfileRead.init(from:), after decoding the existing common fields:
allowedTransmitRangesHz = try container.decodeIfPresent(
    [RadioLiteTransmitRange].self, forKey: .allowedTransmitRangesHz
) ?? []
swrPolicy = try container.decodeIfPresent(
    RadioLiteSWRPolicy.self, forKey: .swrPolicy
) ?? .configurationRequired
private struct RadioLiteEmptyResponse: Decodable {}

func auditPage(limit: Int, cursor: String?) async throws -> RadioLiteAuditPage {
    try await send(method: "GET", path: "/api/v1/audit",
                   queryItems: RadioLiteAuditQuery.items(limit: limit, cursor: cursor))
}

enum RadioLiteAuditQuery {
    static func items(limit: Int, cursor: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
    }
}
```

Gate device configuration controls by `health.features.hardwarePreflight && health.features.preflightProof`; hide them with a precise legacy notice otherwise. Display proof expiration, test status, and the returned complete fence ref; retain the ref with that draft and pass the same pair to upsert, cancel, or resume. The proof's exposed ref and preflight result ref must match before enabling a fenced save, and raw decoding must reject a partial top-level pair. `saveRadioConfiguration` switches on the draft's typed authorization state and calls exactly one of the three factories; it has no catch/fallback that strips a proof or fence after factory rejection. An enabled real-hardware ordinary save retains its passed ordinary proof and exact profile confirmation even though its fence is nil; only Dummy or hardware-disabled saves omit both. On identifiable `preflight_requires_runtime_stop`, leave the draft intact and expose a destructive, explicitly labelled `停止该电台并预检` action calling `POST /api/v1/radios/:radioId/reconfiguration/preflight`; cancellation and resume send both fields. Clear the stored ref only after a matching request completes. A delayed old save/cancel/resume completion may not clear or replace a newer ref, even when numeric generations are equal across different epochs. Its confirmation explains temporary disconnection.

Decode `/api/v1/radios` into `RadioLiteRadioProfileRead`: common control/list fields stay required, while serial path, PTT path, and audio IDs are optional because operator projection deliberately removes them. The radio list and control page consume this read model. `requireEditableProfile()` is admin-only and fails with a precise redaction error unless every identifier required by strict save is present; never encode the read model directly. Legacy raw JSON that omits ranges/SWR decodes to `[]` plus `.configurationRequired`, not acknowledged internal protection. Add allowed-range editors and an explicit SWR choice only for real hardware profiles; `.configurationRequired` renders `需要选择 SWR 安全策略` and cannot produce an upsert. Dummy stays exempt. A migrated real profile remains visible for receive/control but cannot PTT or obtain a proof until an administrator explicitly supplies ranges, chooses `require_swr` or `acknowledged_internal_protection`, passes preflight, and sends the matching fence ref when fenced.

Make `RadioLiteUserRole: CaseIterable`; its only cases remain `.admin` and `.operator`. Create `RadioLiteAccountAdministrationState` with `users: [RadioLiteUser]`, `devices: [RadioLitePairedDevice]`, `audit: RadioLiteAuditPage?`, and `static func canSubmitPassword(_ value: String) -> Bool { !value.isEmpty }`; this preserves arbitrary nonempty Unicode passwords without a client complexity rule. Add `createUser(username:password:role:canTransmit:mustChangePassword:)` using `POST /api/v1/users`, `devices()` using `GET /api/v1/devices`, `renameDevice(_:name:)` using `PATCH /api/v1/devices/:deviceId`, and the functions shown above. `RadioLitePasswordChangeView` is available to every authenticated admin or operator and changes only the current account. `RadioLiteAccountAdministrationView` is admin-only and presents user list/create/editor, device rename/revoke confirmation, and audit cursor pagination using the returned `nextCursor`. In settings, show the persistent HTTP warning whenever `server.baseURL.scheme == "http"`, feature names/status, the self-password destination whenever `accountAdministration` is available, and the administration destination only when `accountAdministration && isAdmin`.

- [ ] **Step 4: Run settings tests and full simulator test target**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION"`

Expected: PASS; old servers keep existing configuration flow, only real profiles require accepted safety fields, and a normal save never calls the runtime-stopping reconfiguration route.

- [ ] **Step 5: Commit optional-capability administration**

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteAccountAdministration.swift ios/RadioLite/Core/RadioLite/RadioLiteDeviceConfiguration.swift ios/RadioLite/Core/RadioLite/RadioLiteHTTPClient.swift ios/RadioLite/Core/RadioLite/RadioLiteModels.swift ios/RadioLite/Core/RadioLite/RadioLiteSession.swift ios/RadioLite/Features/RadioLite/RadioLiteAccountAdministrationView.swift ios/RadioLite/Features/RadioLite/RadioLitePasswordChangeView.swift ios/RadioLite/Features/RadioLite/RadioLiteDeviceConfigurationView.swift ios/RadioLite/Features/RadioLite/RadioLiteSettingsView.swift ios/RadioLiteTests/RadioLiteAccountAdministrationTests.swift ios/RadioLiteTests/RadioLiteDeviceConfigurationTests.swift ios/RadioLiteTests/RadioLiteHTTPErrorPresentationTests.swift ios/RadioLiteTests/RadioLiteModelsTests.swift
git commit -m "feat(ios): gate hardware and admin settings by server capabilities"
```

### Task 6: Per-row spectrum spans, display window persistence, and waterfall projection

**Files:**
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteMediaFrame.swift`, `RadioLiteMediaClient.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift`, `RadioLiteSettingsView.swift`
- Test: `ios/RadioLiteTests/RadioLiteMediaFrameTests.swift`, `RadioLiteTests/RadioLiteSpectrumDisplayWindowTests.swift`
- Modify: `scripts/check-ios-radio-lite-contract.mjs`, `radio-lite-server/PROTOCOL.md`

**Interfaces:**
- `RadioLiteSpectrumHistory.rows: [SpectrumHistoryRow]`; `append(_:)` preserves raw bins, clears only for changed `centerFrequencyHz`, and retains no more than 32 rows.
- `SpectrumHistoryRow.croppedBins(requestedHz:capabilitySpanHz:) -> [UInt8]` and `downsampledColumns(_:requestedHz:capabilitySpanHz:) -> [UInt8]` crop before rendering at no more than 96 columns.
- `RadioLiteSpectrumFrameAdmission.accepts(binCount:capability:) -> Bool` applies the smaller of protocol 512 and the subscribed server capability before `RadioLiteMediaClient` publishes a frame or history row.
- `RadioLiteSpectrumDisplayWindow.normalize(_:) -> Int` returns a 3000...4000 value on a 100-Hz step.

- [ ] **Step 1: Write failing spectrum math and persistence tests**

```swift
func testRowsCropUsingTheirOwnSpanBeforeDownsampling() {
    let old = SpectrumHistoryRow(bins: (0..<80).map(UInt8.init), frameSpanHz: 8_000, centerFrequencyHz: 14_074_000)
    let current = SpectrumHistoryRow(bins: (0..<40).map(UInt8.init), frameSpanHz: 4_000, centerFrequencyHz: 14_074_000)
    XCTAssertEqual(old.croppedBins(requestedHz: 4_000, capabilitySpanHz: 4_000).count, 40)
    XCTAssertEqual(current.croppedBins(requestedHz: 3_000, capabilitySpanHz: 4_000).count, 30)
}

func testSpanChangeKeepsHistoryButCenterFrequencyChangeClearsIt() {
    var history = RadioLiteSpectrumHistory(maxRows: 32, maxColumns: 96)
    history.append(.init(bins: Array(repeating: 1, count: 80), frameSpanHz: 8_000, centerFrequencyHz: 14_074_000))
    history.append(.init(bins: Array(repeating: 2, count: 40), frameSpanHz: 4_000, centerFrequencyHz: 14_074_000))
    XCTAssertEqual(history.rows.count, 2)
    history.append(.init(bins: Array(repeating: 3, count: 40), frameSpanHz: 4_000, centerFrequencyHz: 7_074_000))
    XCTAssertEqual(history.rows.count, 1)
}

func testDisplayWindowClampsAndQuantizes() {
    XCTAssertEqual(RadioLiteSpectrumDisplayWindow.normalize(2_999), 3_000)
    XCTAssertEqual(RadioLiteSpectrumDisplayWindow.normalize(3_051), 3_100)
    XCTAssertEqual(RadioLiteSpectrumDisplayWindow.normalize(4_999), 4_000)
}

func testSubscribedCapabilityRejectsFramesAboveItsSmallerBinLimit() {
    let capability = RadioLiteSpectrumCapability(
        available: true, source: "audio-fft", simulated: false,
        supportsWaterfall: true, maxBins: 256, maxFps: 5,
        spanHz: 4_000, reason: nil
    )
    XCTAssertTrue(RadioLiteSpectrumFrameAdmission.accepts(binCount: 256, capability: capability))
    XCTAssertFalse(RadioLiteSpectrumFrameAdmission.accepts(binCount: 257, capability: capability))
    XCTAssertFalse(RadioLiteSpectrumFrameAdmission.accepts(binCount: 513, capability: capability))
}
```

- [ ] **Step 2: Run red spectrum tests**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteMediaFrameTests -only-testing:RadioLiteTests/RadioLiteSpectrumDisplayWindowTests`

Expected: FAIL because rows are `[[UInt8]]`, history resets for span/bin count changes, decoder accepts up to 4096 bins, and the window/admission helpers are absent.

- [ ] **Step 3: Implement bounded raw rows and crop-before-downsample rendering**

```swift
func croppedBins(requestedHz: Int, capabilitySpanHz: Int?) -> [UInt8] {
    let cap = capabilitySpanHz ?? Int(frameSpanHz)
    let effective = max(0, min(requestedHz, cap, Int(frameSpanHz)))
    let count = min(bins.count, Int((Double(bins.count) * Double(effective) / Double(frameSpanHz)).rounded(.down)))
    return Array(bins.prefix(count))
}

static func accepts(binCount: Int, capability: RadioLiteSpectrumCapability?) -> Bool {
    guard let capability, capability.available else { return false }
    let maximum = min(512, max(0, capability.maxBins))
    return maximum >= 16 && (16...maximum).contains(binCount)
}
```

Reject media frames at `decodeSpectrum` when count is outside `16...512`; retain existing malformed-frame behavior. After decoding and before AGC normalization, current-frame publication, or history append, `RadioLiteMediaClient` must call `RadioLiteSpectrumFrameAdmission.accepts` with its subscribed `spectrumCapability`; a frame above `min(512, capability.maxBins)` is diagnosed and discarded. Replace the old `Axis` equality reset with a stored current center frequency only. In `RadioLiteMediaClient`, publish `[SpectrumHistoryRow]`. In `RadioLiteRadioView`, use the current frame effective span only for axis text/accessibility; render every waterfall row using its own `frameSpanHz`, first cropped then downsampled. Add `@AppStorage("radio-lite.spectrum-display-window-hz") private var spectrumWindowHz = 4000`, normalize on read/change, and use a 3000...4000 step-100 control only when `spectrumDisplayWindow` is advertised; legacy servers use 4000 with a compatibility label.

- [ ] **Step 4: Run spectrum tests, simulator build, and contract checker**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" -only-testing:RadioLiteTests/RadioLiteMediaFrameTests -only-testing:RadioLiteTests/RadioLiteSpectrumDisplayWindowTests && xcodebuild build -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION" && node scripts/check-ios-radio-lite-contract.mjs`

Expected: PASS; 4k→4k displays all bins, 4k→3k displays 75%, 8k→4k displays 50%, mixed 8k/4k rows preserve individual scales, a 256-bin capability rejects a 257-bin frame before history storage, and the contract documents fixed production 0–4 kHz frames.

- [ ] **Step 5: Commit spectrum display reliability**

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteMediaFrame.swift ios/RadioLite/Core/RadioLite/RadioLiteMediaClient.swift ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift ios/RadioLite/Features/RadioLite/RadioLiteSettingsView.swift ios/RadioLiteTests/RadioLiteMediaFrameTests.swift ios/RadioLiteTests/RadioLiteSpectrumDisplayWindowTests.swift radio-lite-server/PROTOCOL.md scripts/check-ios-radio-lite-contract.mjs
git commit -m "feat(ios): crop waterfall rows by their own spectrum span"
```

### Task 7: Full iOS, contract, and unsigned-device verification

**Files:**
- Create: `ios/RadioLiteTests/RadioLiteReliabilityRegressionTests.swift`
- Verify: `ios/RadioLite/project.yml`, `.github/workflows/ios.yml`, `scripts/check-ios-radio-lite-contract.mjs`

**Interfaces:**
- Consumes all interfaces in Tasks 1–6. Produces verified Debug simulator and unsigned Release device artifacts without changing the version fields in `project.yml`.

- [ ] **Step 1: Write a cross-policy regression test before full verification**

```swift
final class RadioLiteReliabilityRegressionTests: XCTestCase {
    func testSafetyAndSpectrumDefaultsRemainConservative() {
        XCTAssertEqual(RadioLiteNetworkPolicy.httpTimeout, 300)
        XCTAssertEqual(RadioLiteNetworkPolicy.webSocketCommandTimeout, 15)
        XCTAssertEqual(RadioLiteSpectrumDisplayWindow.normalize(4_000), 4_000)
        XCTAssertFalse(RadioLiteServerFeatures.unsupported.hardwarePreflight)
        XCTAssertFalse(RadioLiteServerFeatures.unsupported.preflightProof)
        XCTAssertFalse(RadioLiteServerFeatures.unsupported.emergencyStop)
        XCTAssertFalse(RadioLiteServerFeatures.unsupported.safetyAlerts)
        XCTAssertFalse(RadioLiteServerFeatures.unsupported.accountAdministration)
        XCTAssertFalse(RadioLiteServerFeatures.unsupported.spectrumDisplayWindow)
        XCTAssertFalse(RadioLiteServerFeatures.unsupported.swrTripReset)
    }
}
```

- [ ] **Step 2: Run the entire generated-project simulator test suite**

Run: `xcodegen generate --spec ios/RadioLite/project.yml && xcodebuild test -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -destination "$RADIO_LITE_SIMULATOR_DESTINATION"`

Expected: PASS with every `RadioLiteTests` case executed; no generated project file is staged.

- [ ] **Step 3: Run the cross-boundary contract check**

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Expected: PASS with `Verified` output; it verifies all seven health features, selected-radio emergency-stop command/reply identity, safety snapshot/event kind split including both persistent SWR kinds and begin/end handling, the typed SWR reset route/body, radio preflight/upsert endpoints plus paired `reconfigurationEpoch`/`reconfigurationGeneration`, role-aware profile fixtures, and spectrum boundaries in iOS, server, and `PROTOCOL.md`.

- [ ] **Step 4: Build Debug and unsigned Release device archives**

```bash
xcodegen generate --spec ios/RadioLite/project.yml
xcodebuild build -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild archive -project ios/RadioLite/RadioLite.xcodeproj -scheme RadioLite -configuration Release -sdk iphoneos -archivePath "$PWD/build/RadioLite-Release.xcarchive" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: PASS; output contains an unsigned Debug device build and `build/RadioLite-Release.xcarchive`, while `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` continue to come solely from `ios/RadioLite/project.yml`.

- [ ] **Step 5: Execute manual Dummy acceptance using the checked server contract**

```text
1. Connect an iOS simulator/device to the Dummy profile through an HTTP address; confirm the persistent unencrypted warning.
2. Verify legacy health without features shows compatibility status and hides unsupported admin/preflight/emergency controls.
3. With main selected, receive a complete main+backup snapshot where backup is dekey_required, then switch to backup; force a recovered increment followed by `alert:null`, disconnect/reconnect, and inject an old-connection delayed end; verify all-radio state was retained and stale severity changes only on the matching new end.
4. Hold then release voice PTT while receive audio is active; verify microphone indicator stops immediately, tx.stop precedes receive audio, and a failed stop becomes remote-unconfirmed.
5. Feed 8-kHz and 4-kHz spectrum frames, switch 4000/3000 Hz, and change center frequency; verify required crop ratios and history clearing only on center change.
6. Use VoiceOver actions for start/stop, verify elapsed/risk wording, and verify press/start/release/failure haptic feedback.
7. Log in as operator and load a redacted radio response; verify the control list works and hardware editing is unavailable. As admin, decode a legacy missing-range/SWR profile, explicitly choose both safety fields, run fenced preflight, and verify upsert sends the same epoch/generation as its proof.
8. Inject `swr_trip_latched`; verify it survives disconnect, operators see `SWR 保护已锁定，禁止发射；请联系管理员现场检查并复位`, operators and six-flag legacy servers see no reset action, and an administrator must check the physical-inspection acknowledgement before the exact reset POST is enabled. Return 403, 409, and a timeout in turn and verify the latch remains. Then return 2xx and verify the old banner remains until a matching `.swr_rearm_pending` safety event arrives and explains that the next transmission is the single monitored rearm attempt.
```

Expected: Every listed observation holds; no action reports local `rigState.ptt` as the safety authority.

- [ ] **Step 6: Commit the regression gate after all verification is green**

```bash
git status --short
git add ios/RadioLiteTests/RadioLiteReliabilityRegressionTests.swift
git commit -m "test(ios): verify reliability safety paths"
```

Expected: `git status --short` excludes `ios/RadioLite/RadioLite.xcodeproj` and build output; the commit contains the regression test and no generated project or build artifact.

## Plan Self-Review

- Capability flags, hardware-test 404, 300-second HTTP, and 15-second WS deadlines are implemented in Task 1.
- Rig revision plus radio/keyboard/popup/FT8 stale-publication suppression is implemented in Task 2.
- Immediate microphone release, stop-before-receive ordering, token retention, and bounded retries are implemented in Task 3.
- Complete all-radio snapshots, event/persistent-kind separation including both SWR states, connection-generation end matching, stale preservation, exact-reply emergency stop, feature-gated administrator physical-inspection reset, accessibility, and haptics are implemented in Task 4.
- Boot-unique fence refs, real upsert envelopes, legacy/unconfigured and operator-redacted profile decoding, explicit range/SWR/proof choice, and account settings are feature-gated in Task 5.
- Per-row span preservation, fixed bounds, crop-before-downsample, and persisted window policy are implemented in Task 6.
- Task 7 verifies XCTest, contract, simulator/device builds, and Dummy acceptance without expanding operational scope.
