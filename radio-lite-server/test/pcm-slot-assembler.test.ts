import assert from "node:assert/strict";
import { test } from "node:test";

import {
  type CompletedPcmSlot,
  UtcPcmSlotAssembler,
} from "../src/digital/pcm-slot-assembler.ts";

test("UTC assembler drops an incomplete startup slot and emits one immutable FT4 slot", () => {
  const completed: CompletedPcmSlot[] = [];
  const assembler = new UtcPcmSlotAssembler({
    mode: "FT4",
    sampleRate: 1_000,
    maxMissingMs: 100,
    onSlot: (slot) => completed.push(slot),
  });

  assembler.push(new Int16Array(6_500).fill(1), 1_000);
  assert.equal(completed.length, 0);
  assembler.push(new Int16Array(3_000).fill(2), 7_500);
  assembler.push(new Int16Array(4_500).fill(3), 10_500);

  assert.equal(completed.length, 1);
  assert.equal(completed[0].slotStartMs, 7_500);
  assert.equal(completed[0].slotEndMs, 15_000);
  assert.equal(completed[0].pcm.length, 7_500);
  assert.equal(completed[0].pcm[2_999], 2);
  assert.equal(completed[0].pcm[3_000], 3);
});

test("UTC assembler fills a small capture gap with silence but rejects a large gap", () => {
  const completed: CompletedPcmSlot[] = [];
  const assembler = new UtcPcmSlotAssembler({
    mode: "FT4",
    sampleRate: 1_000,
    maxMissingMs: 100,
    onSlot: (slot) => completed.push(slot),
  });
  assembler.push(new Int16Array(3_000).fill(4), 0);
  assembler.push(new Int16Array(4_450).fill(5), 3_050);
  assert.equal(completed.length, 1);
  assert.deepEqual([...completed[0].pcm.subarray(3_000, 3_050)], new Array(50).fill(0));

  assembler.push(new Int16Array(3_000), 7_500);
  assembler.push(new Int16Array(4_000), 11_000);
  assert.equal(completed.length, 1);
});
