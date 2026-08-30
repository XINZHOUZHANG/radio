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

test("48 kHz capture chunks match whole-buffer 16 kHz conversion", () => {
  const input = Int16Array.from(
    { length: 4_803 },
    (_, index) => Math.round(Math.sin(index / 19) * 24_000),
  );
  const expected = resampleInt16(input, 48_000, 16_000);
  const streaming = new StreamingPcm16Resampler(48_000, 16_000);
  const chunks = [
    streaming.push(input.subarray(0, 701)),
    streaming.push(input.subarray(701, 2_222)),
    streaming.push(input.subarray(2_222)),
  ];

  assert.deepEqual(joinSamples(chunks), expected);
});

test("16 kHz playback chunks preserve the whole 48 kHz conversion including the tail", () => {
  const input = Int16Array.from(
    { length: 1_601 },
    (_, index) => Math.round(Math.cos(index / 13) * 20_000),
  );
  const expected = resampleInt16(input, 16_000, 48_000);
  const streaming = new StreamingPcm16Resampler(16_000, 48_000);
  const chunks = [
    streaming.push(input.subarray(0, 317)),
    streaming.push(input.subarray(317, 999)),
    streaming.push(input.subarray(999)),
    streaming.flush(),
  ];

  assert.deepEqual(joinSamples(chunks), expected);
});

function joinSamples(chunks: readonly Int16Array[]): Int16Array {
  const output = new Int16Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.length;
  }
  return output;
}
