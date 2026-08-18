import test from "node:test";
import assert from "node:assert/strict";

import {
  formatFrequency,
  memoryCommand,
  snapshotView,
} from "../dashboard.js";


test("formats confirmed hertz as grouped MHz", () => {
  assert.equal(formatFrequency(14_074_000), "14.074.000");
  assert.equal(formatFrequency(7_074_000), "7.074.000");
});


test("maps snapshot without inventing unavailable values", () => {
  assert.deepEqual(
    snapshotView({
      revision: 9,
      lifecycle: "ready",
      frequency_hz: 14_074_000,
      mode: "USB",
      meters: {},
    }),
    {
      revision: 9,
      lifecycle: "ready",
      frequencyText: "14.074.000",
      modeText: "USB",
      swrText: "—",
    },
  );
  assert.equal(
    snapshotView({
      revision: 10,
      lifecycle: "ready",
      frequency_hz: 7_074_000,
      mode: null,
      meters: { SWR: 1.25 },
    }).swrText,
    "1.3",
  );
});


test("maps a memory element to confirmed backend commands", () => {
  assert.deepEqual(
    memoryCommand({
      dataset: { frequencyHz: "7074000", mode: "USB" },
    }),
    { frequencyHz: 7_074_000, mode: "USB" },
  );
});


test("rejects malformed memory data instead of guessing", () => {
  for (const dataset of [
    { frequencyHz: "7.074.000", mode: "USB" },
    { frequencyHz: "7074000", mode: "" },
    { frequencyHz: "true", mode: "USB" },
  ]) {
    assert.throws(() => memoryCommand({ dataset }), /memory/i);
  }
});
