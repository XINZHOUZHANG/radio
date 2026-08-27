import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

test("Node version contract is pinned to 24.7.0", async () => {
  assert.equal(
    await readFile(join(import.meta.dirname, "../../.node-version"), "utf8"),
    "24.7.0\n",
  );
});
