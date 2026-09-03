import assert from "node:assert/strict";
import { test } from "node:test";

import type { RadioProfile } from "../src/config/types.ts";
import { int16ToPcm16Le } from "../src/media/pcm-resampler.ts";
import type {
  DigitalAudioConsumer,
  DigitalAudioPort,
} from "../src/media/media-hub.ts";
import {
  SystemDigitalWorker,
  type WsjtxClient,
} from "../src/digital/system-digital-worker.ts";
import type { DigitalDecodeBatchInput } from "../src/digital/types.ts";

test("system digital worker decodes each complete UTC slot and shares audio for transmit", async (context) => {
  let consumer: DigitalAudioConsumer | null = null;
  const played: Int16Array[] = [];
  let stopCount = 0;
  const port: DigitalAudioPort = {
    sampleRate: 16_000,
    play: async (pcm) => { played.push(pcm.slice()); },
    stop: async () => { stopCount += 1; },
    close: async () => undefined,
  };
  const decodeCalls: Array<{ mode: "FT8" | "FT4"; samples: number }> = [];
  const client: WsjtxClient = {
    start: async () => undefined,
    encode: async ({ message }) => ({
      pcm: new Int16Array([10, 20, 30]),
      sampleRate: 12_000,
      durationMs: 1,
      messageSent: message,
    }),
    decode: async ({ mode, pcm }) => {
      decodeCalls.push({ mode, samples: pcm.length });
      return {
        frames: [{
          message: "CQ JA1ABC PM95",
          snrDb: -12,
          deltaTimeSeconds: 0.1,
          audioFrequencyHz: 1_300,
          confidence: 1,
        }],
      };
    },
    close: async () => undefined,
  };
  const batches: DigitalDecodeBatchInput[] = [];
  const worker = new SystemDigitalWorker(profile(), {
    openAudio: async (value) => { consumer = value; return port; },
    clientFactory: () => client,
    now: () => 20_000,
  });
  context.after(() => worker.close());
  await worker.start({
    decoded: (batch) => { batches.push(batch); },
    fault: (error) => { throw error; },
  });

  const capture = new Int16Array(16_000 * 15 + 2);
  consumer!.pcm({ pcm: int16ToPcm16Le(capture), sampleRate: 16_000, startedAtMs: 0 });
  await immediate();
  await immediate();
  assert.deepEqual(
    batches.map((batch) => [batch.mode, batch.slotStartMs]),
    [["FT8", 0], ["FT4", 0], ["FT4", 7_500]],
  );
  assert.deepEqual(decodeCalls.map((call) => call.samples), [180_000, 90_000, 90_000]);

  const prepared = await worker.prepare({
    requestId: "encode_1",
    radioId: "main",
    mode: "FT8",
    message: "CQ BI1XYZ OM89",
    audioFrequencyHz: 1_500,
  });
  await worker.transmit(prepared, new AbortController().signal);
  assert.deepEqual(played, [new Int16Array([10, 20, 30])]);
  await worker.stopTransmission();
  assert.equal(stopCount, 1);
});

test("system digital worker waits for decoded consumer before finishing a slot", async (context) => {
  let consumer: DigitalAudioConsumer | null = null;
  let releaseDecode!: () => void;
  const decodeReleased = new Promise<void>((resolve) => { releaseDecode = resolve; });
  const events: string[] = [];
  const port: DigitalAudioPort = {
    sampleRate: 12_000,
    play: async () => undefined,
    stop: async () => undefined,
    close: async () => undefined,
  };
  const client: WsjtxClient = {
    start: async () => undefined,
    encode: async ({ message }) => ({
      pcm: new Int16Array([1]), sampleRate: 12_000, durationMs: 1, messageSent: message,
    }),
    decode: async () => ({ frames: [] }),
    close: async () => undefined,
  };
  const worker = new SystemDigitalWorker(profile(), {
    openAudio: async (value) => { consumer = value; return port; },
    clientFactory: () => client,
    now: () => 13_000,
  });
  context.after(() => worker.close());
  await worker.start({
    decodeStarted: (slot) => { if (slot.mode === "FT8") events.push("started"); },
    decoded: async (batch) => {
      if (batch.mode === "FT8") {
        events.push("decoded");
        await decodeReleased;
      }
    },
    decodeFinished: (slot) => { if (slot.mode === "FT8") events.push("finished"); },
    fault: (error) => { throw error; },
  });
  consumer!.pcm({
    pcm: int16ToPcm16Le(new Int16Array(12_000 * 13)),
    sampleRate: 12_000,
    startedAtMs: 0,
  });
  await immediate();
  assert.deepEqual(events, ["started", "decoded"]);
  releaseDecode();
  await immediate();
  await immediate();
  assert.deepEqual(events, ["started", "decoded", "finished"]);
});

test("system digital worker starts FT4 and FT8 decoding before their slot boundaries", async (context) => {
  let consumer: DigitalAudioConsumer | null = null;
  let now = 0;
  const batches: DigitalDecodeBatchInput[] = [];
  const port: DigitalAudioPort = {
    sampleRate: 12_000,
    play: async () => undefined,
    stop: async () => undefined,
    close: async () => undefined,
  };
  const client: WsjtxClient = {
    start: async () => undefined,
    encode: async ({ message }) => ({
      pcm: new Int16Array([1]),
      sampleRate: 12_000,
      durationMs: 1,
      messageSent: message,
    }),
    decode: async () => ({ frames: [] }),
    close: async () => undefined,
  };
  const worker = new SystemDigitalWorker(profile(), {
    openAudio: async (value) => { consumer = value; return port; },
    clientFactory: () => client,
    now: () => now,
  });
  context.after(() => worker.close());
  await worker.start({
    decoded: (batch) => { batches.push(batch); },
    fault: (error) => { throw error; },
  });

  now = 6_000;
  consumer!.pcm({
    pcm: int16ToPcm16Le(new Int16Array(12_000 * 6)),
    sampleRate: 12_000,
    startedAtMs: 0,
  });
  await immediate();
  await immediate();
  assert.deepEqual(
    batches.map((batch) => [batch.mode, batch.slotStartMs]),
    [["FT4", 0]],
    "FT4 decoding must start 1.5 seconds before its 7.5 second boundary",
  );

  now = 13_000;
  consumer!.pcm({
    pcm: int16ToPcm16Le(new Int16Array(12_000 * 7)),
    sampleRate: 12_000,
    startedAtMs: 6_000,
  });
  await immediate();
  await immediate();
  assert.deepEqual(
    batches.map((batch) => [batch.mode, batch.slotStartMs]),
    [["FT4", 0], ["FT8", 0]],
    "FT8 decoding must start two seconds before its 15 second boundary",
  );
});

function profile(): RadioProfile {
  return {
    id: "main",
    name: "FT-710",
    hamlibModelId: 1049,
    connection: { kind: "network-rigctld", host: "127.0.0.1", port: 4532 },
    audioInput: { backend: "alsa", id: "hw:1,0" },
    audioOutput: { backend: "alsa", id: "hw:1,0" },
    ptt: { method: "RIG" },
    station: { callsign: "BI1XYZ", grid: "OM89" },
    hardwareTxEnabled: true,
  };
}

function immediate(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}
