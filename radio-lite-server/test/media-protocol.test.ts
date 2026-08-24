import assert from "node:assert/strict";
import { test } from "node:test";

import {
  decodeMediaFrame,
  encodeMediaFrame,
  MediaFrameError,
  MediaKind,
} from "../src/media/frame.ts";
import {
  decodeSpectrumPayload,
  encodeSpectrumPayload,
} from "../src/media/spectrum-payload.ts";
import {
  AdaptiveMediaPolicy,
  estimateMediaBytesPerHour,
} from "../src/media/adaptive-policy.ts";

test("binary media header round-trips without JSON or per-field overhead", () => {
  const encoded = encodeMediaFrame({
    kind: MediaKind.audioDownlink,
    flags: 1,
    radioSlot: 2,
    sequence: 0xffff_fffe,
    timestampUs: 1_725_000_000_123_456n,
    payload: Buffer.from([1, 2, 3, 4]),
  });
  assert.equal(encoded.length, 20);
  const decoded = decodeMediaFrame(encoded);
  assert.equal(decoded.version, 1);
  assert.equal(decoded.kind, MediaKind.audioDownlink);
  assert.equal(decoded.radioSlot, 2);
  assert.equal(decoded.sequence, 0xffff_fffe);
  assert.equal(decoded.timestampUs, 1_725_000_000_123_456n);
  assert.deepEqual(decoded.payload, Buffer.from([1, 2, 3, 4]));
});

test("media decoder rejects unknown versions, kinds and truncated frames", () => {
  assert.throws(() => decodeMediaFrame(Buffer.alloc(15)), MediaFrameError);
  const version = Buffer.alloc(16); version[0] = 2; version[1] = MediaKind.audioDownlink;
  assert.throws(() => decodeMediaFrame(version), /version/u);
  const kind = Buffer.alloc(16); kind[0] = 1; kind[1] = 99;
  assert.throws(() => decodeMediaFrame(kind), /kind/u);
});

test("spectrum payload carries exact UInt8 bins and RF metadata", () => {
  const bins = Uint8Array.from({ length: 512 }, (_, index) => index % 256);
  const encoded = encodeSpectrumPayload({
    centerFrequencyHz: 14_074_000,
    spanHz: 3_000,
    noiseFloorTenthsDbm: -1_150,
    bins,
  });
  const decoded = decodeSpectrumPayload(encoded);
  assert.equal(decoded.centerFrequencyHz, 14_074_000);
  assert.equal(decoded.spanHz, 3_000);
  assert.equal(decoded.noiseFloorTenthsDbm, -1_150);
  assert.deepEqual(decoded.bins, bins);
  assert.throws(() => decodeSpectrumPayload(encoded.subarray(0, -1)), /bin count/u);
});

test("weak-network policy degrades immediately and recovers with hysteresis", () => {
  const policy = new AdaptiveMediaPolicy();
  assert.equal(policy.current().tier, "normal");
  let current = policy.update({
    rttMs: 2_500,
    packetLossPercent: 10,
    bufferedBytes: 600_000,
    spectrumVisible: true,
  });
  assert.deepEqual(
    [current.tier, current.opusBitrate, current.spectrumBins, current.spectrumFps],
    ["severe", 12_000, 128, 1],
  );
  for (let index = 0; index < 4; index += 1) {
    current = policy.update({
      rttMs: 50, packetLossPercent: 0, bufferedBytes: 0, spectrumVisible: true,
    });
    assert.equal(current.tier, "severe");
  }
  current = policy.update({
    rttMs: 50, packetLossPercent: 0, bufferedBytes: 0, spectrumVisible: false,
  });
  assert.equal(current.tier, "normal");
  assert.equal(current.spectrumBins, 0);
  assert.equal(current.spectrumFps, 0);
});

test("default receive audio plus spectrum remains under the 35 MB/hour target", () => {
  const bytes = estimateMediaBytesPerHour(new AdaptiveMediaPolicy().current());
  assert.ok(bytes < 35 * 1_024 * 1_024, `${bytes} bytes/hour exceeded target`);
  assert.ok(bytes > 15 * 1_024 * 1_024, "estimate unexpectedly omitted media overhead");
});
