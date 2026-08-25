import assert from "node:assert/strict";
import { test } from "node:test";

import { SyntheticMediaWorker } from "../src/media/synthetic-media-worker.ts";

test("synthetic worker advertises and emits the 4 kHz spectrum span", async (context) => {
  const frames: Array<{ spanHz: number }> = [];
  const worker = new SyntheticMediaWorker({
    audioDownlink: () => undefined,
    spectrum: (frame) => frames.push(frame),
    fault: (error) => { throw error; },
  });
  context.after(() => worker.close());

  assert.equal(worker.spectrumCapability.spanHz, 4_000);
  await new Promise((resolve) => setTimeout(resolve, 220));
  assert.equal(frames.length, 1);
  assert.equal(frames[0].spanHz, 4_000);
});
