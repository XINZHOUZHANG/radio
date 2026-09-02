import assert from "node:assert/strict";
import { test } from "node:test";

import {
  isSlotBoundary,
  nextSlotStart,
  oppositeSlotParity,
  slotDurationMs,
  slotParityAt,
  slotStartAt,
} from "../src/digital/slots.ts";

test("FT8 and FT4 slots stay aligned to UTC rather than client latency", () => {
  assert.equal(slotDurationMs("FT8"), 15_000);
  assert.equal(slotDurationMs("FT4"), 7_500);
  assert.equal(slotStartAt("FT8", 31_234), 30_000);
  assert.equal(slotStartAt("FT4", 31_234), 30_000);
  assert.equal(isSlotBoundary("FT8", 30_000), true);
  assert.equal(isSlotBoundary("FT4", 37_500), true);
  assert.equal(isSlotBoundary("FT8", 37_500), false);
});

test("next slot selection honors transmit parity and is always in the future", () => {
  assert.equal(slotParityAt("FT8", 30_000), "even");
  assert.equal(oppositeSlotParity("even"), "odd");
  assert.equal(nextSlotStart("FT8", 30_000), 45_000);
  assert.equal(nextSlotStart("FT8", 30_001, "even"), 60_000);
  assert.equal(nextSlotStart("FT4", 30_000, "odd"), 37_500);
});
