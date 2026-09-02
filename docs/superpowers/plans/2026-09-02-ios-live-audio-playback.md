# iOS Live-Audio Playback Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iOS receive-audio queue count a frame until it has actually played through the output device, preventing local playback backlog from growing beyond the existing live-edge cap.

**Architecture:** Keep the existing `RadioLitePlaybackQueueState` and its 3-frame prebuffer / 12-frame maximum unchanged.  Declare the intended AVAudioPlayerNode completion semantics once, use that declaration in the receive scheduling call, and assert the declaration in the focused iOS unit test.  No server, protocol, radio-control, PTT, or deployment layer changes are involved.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, XCTest; server remains Node.js 24.7 without changes.

**Spec:** `docs/superpowers/specs/2026-09-02-ios-live-audio-playback-design.md`

## Global Constraints

- Change only `ios/RadioLite/Core/RadioLite/RadioLiteAudioEngine.swift` and `ios/RadioLiteTests/AudioRuntimePolicyTests.swift` in the implementation commit.
- Use `AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack`; do not increase the prebuffer or 12-frame maximum.
- Do not alter PTT admission/read-back, de-key confirmation, leases, transmit ownership, tuner, FT8/FT4, Opus bitrate, protocol, Debian, or any RF control path.
- Do not install Xcode or other software on Windows.  The focused XCTest is compiled and run by existing iOS CI; do not replace it with a source-text test.
- Do not run a full test suite merely because this is an iOS-only change.  The only permitted repository test command, if a server test becomes necessary, is `npm --prefix radio-lite-server run test:ci`.
- Keep `.superpowers/` untracked and out of every commit.

---

## File structure

- `ios/RadioLite/Core/RadioLite/RadioLiteAudioEngine.swift` owns receive-audio scheduling and the authoritative callback policy.
- `ios/RadioLiteTests/AudioRuntimePolicyTests.swift` owns pure iOS audio-policy regression tests without opening an audio route.

---

### Task 1: Lock receive-queue accounting to device-aware playback completion

**Files:**
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteAudioEngine.swift:272-308, 453-490`
- Modify: `ios/RadioLiteTests/AudioRuntimePolicyTests.swift:299-332`

**Interfaces:**
- Produces: `RadioLitePlaybackQueueState.receiveCompletionCallbackType: AVAudioPlayerNodeCompletionCallbackType` with the exact value `.dataPlayedBack`.
- Consumes: the existing `RadioLitePlaybackQueueState.enqueue() -> UInt64?`, `complete(generation:)`, `flush()`, and `AVAudioPlayerNode.scheduleBuffer(_:completionCallbackType:completionHandler:)` APIs.
- Preserves: `targetBuffers == 3`, `maximumBuffers == 12`, generation-based stale callback rejection, and the existing full-queue flush path.

- [ ] **Step 1: Write the failing focused XCTest**

  In `AudioRuntimePolicyTests.swift`, immediately after the existing full-queue
  tests, add this test:

  ```swift
  func testReceivePlaybackQueueUsesDevicePlayedBackCompletion() {
      XCTAssertEqual(
          RadioLitePlaybackQueueState.receiveCompletionCallbackType,
          .dataPlayedBack
      )
  }
  ```

  Do not instantiate `RadioLiteAudioEngine`, activate `AVAudioSession`, or
  create a real audio route in this test.

- [ ] **Step 2: Verify the test is initially red in iOS CI**

  Do not install or invoke Xcode on Windows.  The initial test will fail to
  compile because `receiveCompletionCallbackType` does not exist.  Record this
  expected pre-implementation CI result if an iOS CI run is requested; do not
  add a timeout or a substitute server test.

- [ ] **Step 3: Add the single queue-completion policy**

  In `RadioLitePlaybackQueueState`, add the exact immutable declaration:

  ```swift
  static let receiveCompletionCallbackType: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack
  ```

  Update the nearby state comment, if needed, to state that
  `scheduledBuffers` represents frames that have been scheduled but not yet
  played back through the device.  Leave `enqueue`, `complete`, `flush`,
  `requiresRecovery`, and `shouldStartPlayback` unchanged.

- [ ] **Step 4: Use the policy at the only receive scheduling call**

  Replace the default-completion scheduling call in `receiveOpusPacket` with:

  ```swift
  player.scheduleBuffer(
      buffer,
      completionCallbackType: RadioLitePlaybackQueueState.receiveCompletionCallbackType
  ) { [weak self] _ in
      Task { @MainActor [weak self] in
          self?.playbackQueue.complete(generation: queueGeneration)
      }
  }
  ```

  The completion body must keep the existing generation token.  It must not
  call `player.stop()`, modify PTT state, or enqueue a replacement buffer.

- [ ] **Step 5: Verify the implementation without widening scope**

  Run:

  ```powershell
  git diff --check
  git diff -- ios/RadioLite/Core/RadioLite/RadioLiteAudioEngine.swift ios/RadioLiteTests/AudioRuntimePolicyTests.swift
  ```

  Expected: no whitespace errors; the diff contains only the callback-policy
  declaration, the explicit `completionCallbackType` argument, and the one
  XCTest.

  Do not run a generic `npm test`, `test:watch`, Xcode installation, Debian
  deployment, Actions watch, or any radio command.

- [ ] **Step 6: Commit the isolated implementation**

  ```powershell
  git add -- ios/RadioLite/Core/RadioLite/RadioLiteAudioEngine.swift ios/RadioLiteTests/AudioRuntimePolicyTests.swift
  git commit -m "fix(ios): bound live audio by device playback"
  ```

  The commit message must explain that the former default `dataConsumed`
  callback let local playback backlog escape the 12-frame live-edge cap.

---

## Final acceptance

1. The focused XCTest is present and iOS CI compiles it.
2. The receive scheduling call explicitly uses `.dataPlayedBack` via the
   queue policy.
3. The existing 3/12 queue bounds and generation protection remain unchanged.
4. `git diff --check` passes.
5. A receive-only iPhone test over LAN, native IPv6, and Tailscale shows that
   audio no longer grows progressively further behind the radio.  This is an
   operator observation, not an automated RF test.
