import assert from "node:assert/strict";
import { test } from "node:test";

import { PcmSpectrumAnalyzer } from "../src/media/spectrum-analyzer.ts";

test("PCM analyzer locates a stable tone and emits compact UInt8 bins", () => {
  const analyzer = new PcmSpectrumAnalyzer({ sampleRate: 16_000, fftSize: 2_048 });
  const pcm = Buffer.alloc(2_048 * 2);
  for (let index = 0; index < 2_048; index += 1) {
    const sample = Math.round(Math.sin(2 * Math.PI * 1_000 * index / 16_000) * 20_000);
    pcm.writeInt16LE(sample, index * 2);
  }
  analyzer.push(pcm.subarray(0, 1_778));
  analyzer.push(pcm.subarray(1_778));
  const result = analyzer.analyze(512);
  assert.ok(result !== null);
  assert.equal(result.bins.length, 512);
  const peak = result.bins.indexOf(Math.max(...result.bins));
  assert.ok(Math.abs(peak - 128) <= 1, `expected 1 kHz near bin 128, received ${peak}`);
  assert.ok(result.bins[peak] > result.bins[10] + 50);
  assert.ok(result.noiseFloorTenthsDbm <= -300);
});

test("PCM analyzer excludes a 5 kHz tone outside the 4 kHz baseband", () => {
  const analyzer = new PcmSpectrumAnalyzer({ sampleRate: 16_000, fftSize: 2_048 });
  const pcm = Buffer.alloc(2_048 * 2);
  for (let index = 0; index < 2_048; index += 1) {
    const sample = Math.round(Math.sin(2 * Math.PI * 5_000 * index / 16_000) * 20_000);
    pcm.writeInt16LE(sample, index * 2);
  }
  analyzer.push(pcm);
  const result = analyzer.analyze(512);
  assert.ok(result !== null);
  assert.ok(Math.max(...result.bins) < 20, `expected no 5 kHz peak, received ${Math.max(...result.bins)}`);
});

test("PCM analyzer calculates its noise floor from the retained 4 kHz baseband", () => {
  const analyzer = new PcmSpectrumAnalyzer({ sampleRate: 16_000, fftSize: 2_048 });
  const samples = new Float64Array(2_048);
  for (let frequencyBin = 512; frequencyBin < 1_024; frequencyBin += 1) {
    const phase = frequencyBin * 0.37;
    for (let index = 0; index < samples.length; index += 1) {
      samples[index] += Math.sin(2 * Math.PI * frequencyBin * index / samples.length + phase);
    }
  }
  const peak = Math.max(...samples.map((sample) => Math.abs(sample)));
  const pcm = Buffer.alloc(samples.length * 2);
  for (let index = 0; index < samples.length; index += 1) {
    pcm.writeInt16LE(Math.round(samples[index] / peak * 20_000), index * 2);
  }
  analyzer.push(pcm);
  const result = analyzer.analyze(512);
  assert.ok(result !== null);
  assert.ok(result.noiseFloorTenthsDbm <= -900, `expected quiet in-band floor, received ${result.noiseFloorTenthsDbm}`);
});

test("PCM analyzer keeps a bounded latest-sample window and validates bin counts", () => {
  const analyzer = new PcmSpectrumAnalyzer({ sampleRate: 16_000, fftSize: 2_048 });
  assert.equal(analyzer.analyze(128), null);
  analyzer.push(Buffer.alloc(100_000));
  assert.ok(analyzer.analyze(128) !== null);
  assert.throws(() => analyzer.analyze(127 as 128), /bins/u);
  assert.throws(() => analyzer.push(Buffer.alloc(3)), /16-bit/u);
});
