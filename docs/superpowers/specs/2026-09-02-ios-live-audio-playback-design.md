# iOS live-audio playback queue design

**Status:** approved design, awaiting written-spec review

**Date:** 2026-09-02

## 1. Single-change contract

```text
【假设】iOS 接收音频的 AVAudioPlayerNode 在数据被渲染器消费时就把播放队列
        计数减一，队列上限因此没有限制尚未从扬声器播出的音频，造成秒级累积延迟。
【证据】ios/RadioLite/Core/RadioLite/RadioLiteAudioEngine.swift:483 使用默认
        scheduleBuffer 完成回调；该回调的默认语义是 dataConsumed，而非 dataPlayedBack。
        Apple 对 dataPlayedBack 的定义包含播放器下游与输出设备延迟。
【改动】仅以 .dataPlayedBack 作为接收 Opus 播放队列的完成依据，并以回归测试锁定。
【真机判据】持续接收时，客户端自己的播放队列始终不超过 12 个 20 ms Opus 帧；
            局域网监听的延迟不再随运行时间单调累积。
```

The external reference for the completion semantics is Apple's
[AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack documentation](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/dataplayedback).

## 2. Root-cause evidence

`RadioLiteAudioEngine` starts playback after three decoded 20 ms buffers and
nominally caps its queue at twelve buffers.  It increments the modelled queue
before calling `player.scheduleBuffer`, then decrements it from the default
completion closure.

The default callback means that `AVAudioPlayerNode` has consumed the buffer,
not that the device has audibly played it.  As a result, the Swift-side model
can fall below twelve while the node still owns more buffers downstream.  A
fast inbound stream can therefore keep scheduling audio beyond the intended
240 ms live-edge budget.

The server already bounds WebSocket output per client and drops when its
transport backlog exceeds the configured limit.  The iOS media client also
drops network frames whose excess transit delay exceeds 400 ms.  Neither
mechanism can observe a backlog inside the local `AVAudioPlayerNode`, so they
cannot prevent this failure mode.

This is a static code-path finding.  The reported approximately three-second
LAN delay is the real-device symptom that validates its relevance; final
acceptance remains an operator observation on an iPhone.

## 3. Design

### 3.1 Queue-accounting boundary

Use the `scheduleBuffer` overload with
`completionCallbackType: .dataPlayedBack` for receive audio.  The completion
handler then decrements `RadioLitePlaybackQueueState` only after device-aware
playback completes.

The current queue policy remains unchanged:

- prebuffer: three 20 ms frames;
- maximum controlled queue: twelve 20 ms frames;
- live-edge recovery: flush the player when the controlled queue is full;
- generation tokens: discard completions from a pre-flush player queue.

This makes the existing maximum meaningful.  It does not promise a 240 ms
end-to-end latency: radio capture, encoding, transport, iOS system output and
route latency remain outside this local queue budget.

### 3.2 Testable policy declaration

Expose one internal, immutable completion-callback policy on
`RadioLiteAudioEngine`.  The scheduling call consumes that policy, and the
iOS unit test asserts that it is `.dataPlayedBack`.

This avoids a source-text test and avoids having a unit test activate an audio
route.  Existing pure queue tests continue to cover prebuffer, full-queue
recovery, and stale completion generation handling.

### 3.3 Non-goals and safety boundary

This change must not alter:

- PTT admission, PTT read-back, de-key confirmation, hard limits, leases, or
  transmit ownership;
- server audio capture/encoding, Opus bitrate, WebSocket protocol, network
  freshness thresholds, or Debian configuration;
- tuner, FT8/FT4, voice uplink, CAT commands, or real-radio operation.

No radio command is required to validate the source-level change.  The
eventual operator test is receive-only.

## 4. Files and commits

The implementation commit may change only:

1. `ios/RadioLite/Core/RadioLite/RadioLiteAudioEngine.swift`
2. `ios/RadioLiteTests/AudioRuntimePolicyTests.swift`

The specification is committed separately before implementation.  The
implementation commit message will explain that `dataConsumed` allowed local
playback backlog to escape the intended live-edge limit.

## 5. Verification and acceptance

Before changing implementation, add the focused iOS unit assertion for the
completion policy.  Do not increase any timeout and do not add a hardware
dependency.

After implementation:

1. run the repository-approved server test command only when required by the
   workspace rules: `npm --prefix radio-lite-server run test:ci`;
2. rely on the existing iOS build/test CI job for Swift compilation;
3. on a physical iPhone, receive continuous audio over LAN, native IPv6 and
   Tailscale without transmitting, and record whether the latency stays near
   the live edge rather than increasing over time.

The iPhone observation is explicitly not a substitute for automated safety
tests.  It only validates audio presentation latency.

## 6. Rollback

The implementation is one isolated iOS commit.  If it exposes a route-specific
playback regression, revert that commit; no server state, radio state, or
Debian service state needs recovery.
