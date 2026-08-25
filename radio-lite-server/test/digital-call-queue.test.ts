import assert from "node:assert/strict";
import { test } from "node:test";

import {
  addDigitalCallFromDecode,
  DigitalCallQueue,
} from "../src/digital/call-queue.ts";
import { DigitalDecodeStore } from "../src/digital/decode-store.ts";

test("call queue deduplicates targets and supports activate, skip, remove and stop", () => {
  let id = 0;
  const queue = new DigitalCallQueue("main", {
    now: () => 10_000,
    idFactory: () => `entry_${++id}`,
  });
  const first = queue.add({
    ownerId: "connection:one",
    targetCallsign: "ja1abc",
    targetGrid: "pm95",
    mode: "FT8",
    audioFrequencyHz: 1_200,
    txParity: "odd",
  });
  assert.equal(first.created, true);
  assert.equal(queue.add({
    ownerId: "connection:one",
    targetCallsign: "JA1ABC",
    mode: "FT8",
    audioFrequencyHz: 1_500,
    txParity: "even",
  }).created, false);
  queue.add({
    ownerId: "connection:one",
    targetCallsign: "JA2XYZ",
    mode: "FT8",
    audioFrequencyHz: 900,
    txParity: "odd",
  });

  assert.equal(queue.activateNext()?.targetCallsign, "JA1ABC");
  assert.equal(queue.skipActive()?.targetCallsign, "JA2XYZ");
  assert.equal(queue.stopActive()?.targetCallsign, "JA2XYZ");
  assert.equal(queue.snapshot().activeId, null);
  assert.equal(queue.activateNext()?.targetCallsign, "JA2XYZ");
  assert.equal(queue.finishActive()?.targetCallsign, "JA2XYZ");
  assert.equal(queue.remove(first.entry.id)?.targetCallsign, "JA1ABC");
  assert.equal(queue.snapshot().entries.length, 0);
});

test("selected CQ creates a queue target with the opposite UTC slot parity", () => {
  const decodes = new DigitalDecodeStore();
  const batch = decodes.commit({
    radioId: "main",
    mode: "FT8",
    slotStartMs: 30_000,
    receivedAtMs: 45_000,
    frames: [{
      message: "CQ JA1ABC PM95",
      snrDb: -12,
      deltaTimeSeconds: 0.1,
      audioFrequencyHz: 1_300,
    }],
  });
  const queue = new DigitalCallQueue("main", { idFactory: () => "entry_cq" });
  const added = addDigitalCallFromDecode(
    queue,
    "connection:one",
    batch,
    batch.decodes[0].id,
    "BI1XYZ",
  );
  assert.equal(added.entry.targetCallsign, "JA1ABC");
  assert.equal(added.entry.targetGrid, "PM95");
  assert.equal(added.entry.txParity, "odd");
  assert.equal(added.entry.sourceDecodeId, batch.decodes[0].id);
});
