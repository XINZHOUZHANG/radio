import assert from "node:assert/strict";
import { test } from "node:test";

import { maidenheadCenter, normalizeMaidenhead } from "../src/log/maidenhead.ts";

test("Maidenhead locators normalize and map to their geographic cell center", () => {
  assert.equal(normalizeMaidenhead("om89aa"), "OM89AA");
  assert.deepEqual(maidenheadCenter("OM89"), {
    grid: "OM89",
    latitude: 39.5,
    longitude: 117,
    latitudeSpan: 1,
    longitudeSpan: 2,
  });
  const detailed = maidenheadCenter("FN31PR");
  assert.ok(Math.abs(detailed.latitude - 41.729_166_7) < 0.000_1);
  assert.ok(Math.abs(detailed.longitude - -72.708_333_3) < 0.000_1);
});

test("Maidenhead validation accepts 2/4/6/8 characters and rejects bad pairs", () => {
  for (const grid of ["OM", "OM89", "OM89AA", "OM89AA12"]) {
    assert.equal(normalizeMaidenhead(grid), grid);
  }
  for (const grid of ["", "SM89", "OM8", "OM89AZ", "OM89AA1X", "OM89AA1234"]) {
    assert.throws(() => normalizeMaidenhead(grid), /Maidenhead/u);
  }
});
