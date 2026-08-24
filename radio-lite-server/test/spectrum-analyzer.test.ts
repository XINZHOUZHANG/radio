import assert from "node:assert/strict";
import { test } from "node:test";

import { PcmSpectrumAnalyzer } from "../src/media/spectrum-analyzer.ts";

test("PCM analyzer locates a stable tone and emits compact UInt8 bins", () => {
  const analyzer = new PcmSpectrumAnalyzer({ sampleRate: 16_000, fftSize: 1_024 });
  const pcm = Buffer.alloc(1_024 * 2);
  for (let index = 0; index < 1_024; index += 1) {
    const sample = Math.round(Math.sin(2 * Math.PI * 1_000 * index / 16_000) * 20_000);
    pcm.writeInt16LE(sample, index * 2);
  }
  analyzer.push(pcm.subarray(0, 778));
  analyzer.push(pcm.subarray(778));
  const result = analyzer.analyze(512);
  assert.ok(result !== null);
  assert.equal(result.bins.length, 512);
  const peak = result.bins.indexOf(Math.max(...result.bins));
  assert.ok(Math.abs(peak - 64) <= 1, `expected 1 kHz near bin 64, received ${peak}`);
  assert.ok(result.bins[peak] > result.bins[10] + 50);
  assert.ok(result.noiseFloorTenthsDbm <= -300);
});

test("PCM analyzer keeps a bounded latest-sample window and validates bin counts", () => {
  const analyzer = new PcmSpectrumAnalyzer({ sampleRate: 16_000, fftSize: 1_024 });
  assert.equal(analyzer.analyze(128), null);
  analyzer.push(Buffer.alloc(100_000));
  assert.ok(analyzer.analyze(128) !== null);
  assert.throws(() => analyzer.analyze(127 as 128), /bins/u);
  assert.throws(() => analyzer.push(Buffer.alloc(3)), /16-bit/u);
});
