import assert from "node:assert/strict";
import { test } from "node:test";

import { DummyDigitalWorker } from "../src/digital/dummy-worker.ts";
import { UtcSlotScheduler } from "../src/digital/slot-scheduler.ts";

test("UTC scheduler arms the next matching server-side slot and cancellation is final", async () => {
  let callback: (() => void) | null = null;
  let delayMs = -1;
  let cleared = false;
  const scheduler = new UtcSlotScheduler({
    now: () => 30_100,
    setTimer: (value, delay) => {
      callback = value;
      delayMs = delay;
      return { unref: () => undefined } as unknown as ReturnType<typeof setTimeout>;
    },
    clearTimer: () => { cleared = true; },
  });
  let firedAt = -1;
  assert.equal(scheduler.schedule("FT8", "odd", (slotStartMs) => { firedAt = slotStartMs; }), 45_000);
  assert.equal(delayMs, 14_900);
  callback!();
  await Promise.resolve();
  assert.equal(firedAt, 45_000);

  scheduler.schedule("FT8", "even", () => undefined);
  scheduler.cancel();
  assert.equal(cleared, true);
});

test("dummy worker exposes the same prepare, playback, decode and failure contract as native DSP", async () => {
  const worker = new DummyDigitalWorker({ playbackDelayMs: 1 });
  const decoded: string[] = [];
  const faults: string[] = [];
  await worker.start({
    decoded: (batch) => decoded.push(batch.frames[0]?.message ?? ""),
    fault: (error) => faults.push(error instanceof Error ? error.message : String(error)),
  });
  const prepared = await worker.prepare({
    requestId: "encode_1",
    radioId: "main",
    mode: "FT8",
    message: "JA1ABC BI1XYZ OM89",
    audioFrequencyHz: 1_300,
  });
  assert.equal(prepared.sampleRate, 12_000);
  assert.equal(prepared.durationMs, 12_640);
  await worker.transmit(prepared, new AbortController().signal);
  worker.injectDecodeBatch({
    radioId: "main",
    mode: "FT8",
    slotStartMs: 0,
    receivedAtMs: 15_000,
    frames: [{ message: "CQ JA1ABC PM95", snrDb: -10, deltaTimeSeconds: 0, audioFrequencyHz: 1_000 }],
  });
  worker.injectFault(new Error("simulated DSP exit"));
  assert.deepEqual(decoded, ["CQ JA1ABC PM95"]);
  assert.deepEqual(faults, ["simulated DSP exit"]);
  await worker.close();
});
