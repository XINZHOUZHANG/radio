import assert from "node:assert/strict";
import { test } from "node:test";

import {
  int16ToPcm16Le,
  pcm16LeToInt16,
  resampleInt16,
  StreamingPcm16Resampler,
} from "../src/media/pcm-resampler.ts";

test("PCM helpers preserve signed little-endian samples", () => {
  const samples = new Int16Array([-32_768, -1, 0, 1, 32_767]);
  const bytes = int16ToPcm16Le(samples);
  assert.equal(bytes.readInt16LE(0), -32_768);
  assert.deepEqual(pcm16LeToInt16(bytes), samples);
  assert.throws(() => pcm16LeToInt16(Buffer.alloc(1)), /even/u);
});

test("streaming 16 kHz to 12 kHz resampling stays continuous across chunks", () => {
  const input = Int16Array.from({ length: 160 }, (_, index) => index * 100 - 8_000);
  const expected = resampleInt16(input, 16_000, 12_000);
  const streaming = new StreamingPcm16Resampler(16_000, 12_000);
  const first = streaming.push(input.subarray(0, 80));
  const second = streaming.push(input.subarray(80));
  const actual = new Int16Array(first.length + second.length);
  actual.set(first);
  actual.set(second, first.length);
  assert.equal(actual.length, expected.length);
  assert.deepEqual(actual, expected);

  streaming.reset();
  assert.equal(streaming.push(input.subarray(0, 16)).length, 12);
});
