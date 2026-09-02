import assert from "node:assert/strict";
import { test } from "node:test";

import { DigitalDecodeStore } from "../src/digital/decode-store.ts";

test("one completed slot becomes one stable sorted batch with duplicate suppression", () => {
  const store = new DigitalDecodeStore();
  const batch = store.commit({
    radioId: "main",
    mode: "FT8",
    slotStartMs: 30_000,
    receivedAtMs: 45_100,
    frames: [
      { message: "  cq   ja1abc   pm95 ", snrDb: -18, deltaTimeSeconds: 0.2, audioFrequencyHz: 1_500 },
      { message: "CQ JA1ABC PM95", snrDb: -10, deltaTimeSeconds: 0.1, audioFrequencyHz: 1_500 },
      { message: "BI1ABC JA2XYZ -08", snrDb: -8, deltaTimeSeconds: -0.1, audioFrequencyHz: 900 },
    ],
  });

  assert.equal(batch.revision, 1);
  assert.equal(batch.decodes.length, 2);
  assert.deepEqual(batch.decodes.map((decode) => decode.audioFrequencyHz), [900, 1_500]);
  assert.equal(batch.decodes[1].snrDb, -10);
  assert.match(batch.decodes[0].id, /^decode_[A-Za-z0-9_-]{24}$/u);

  const replay = store.commit({
    radioId: "main",
    mode: "FT8",
    slotStartMs: 30_000,
    receivedAtMs: 45_100,
    frames: [
      { message: "BI1ABC JA2XYZ -08", snrDb: -8, deltaTimeSeconds: -0.1, audioFrequencyHz: 900 },
      { message: "CQ JA1ABC PM95", snrDb: -10, deltaTimeSeconds: 0.1, audioFrequencyHz: 1_500 },
    ],
  });
  assert.equal(replay.revision, 1);
  assert.equal(store.snapshot("main").revision, 1);
});

test("committed slots are immutable and history is bounded", () => {
  const store = new DigitalDecodeStore({ historySlots: 2 });
  for (const slotStartMs of [0, 15_000, 30_000]) {
    store.commit({
      radioId: "main",
      mode: "FT8",
      slotStartMs,
      receivedAtMs: slotStartMs + 15_000,
      frames: [{
        message: `CQ JA1AB${slotStartMs / 15_000} PM95`,
        snrDb: -10,
        deltaTimeSeconds: 0,
        audioFrequencyHz: 1_000,
      }],
    });
  }
  const snapshot = store.snapshot("main");
  assert.equal(snapshot.revision, 3);
  assert.deepEqual(snapshot.batches.map((batch) => batch.slotStartMs), [30_000, 15_000]);

  assert.throws(() => store.commit({
    radioId: "main",
    mode: "FT8",
    slotStartMs: 30_000,
    receivedAtMs: 45_000,
    frames: [{
      message: "CQ DIFFERENT PM95",
      snrDb: -10,
      deltaTimeSeconds: 0,
      audioFrequencyHz: 1_000,
    }],
  }), /already committed/u);
});
