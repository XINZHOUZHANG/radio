import assert from "node:assert/strict";
import { test } from "node:test";

import { WsjtxProcessClient } from "../src/digital/wsjtx-process-client.ts";

test("isolated WSJT-X process encodes FT8 and accepts the PCM for decoding", { timeout: 60_000 }, async (context) => {
  const faults: string[] = [];
  const client = new WsjtxProcessClient({
    requestTimeoutMs: 45_000,
    onFault: (error) => faults.push(error instanceof Error ? error.message : String(error)),
  });
  context.after(() => client.close());
  await client.start();

  const encoded = await client.encode({
    mode: "FT8",
    message: "CQ BI1XYZ OM89",
    audioFrequencyHz: 1_500,
  });
  assert.equal(encoded.sampleRate, 12_000);
  assert.ok(encoded.pcm.length >= 151_000 && encoded.pcm.length <= 152_000);
  assert.ok(encoded.durationMs >= 12_500 && encoded.durationMs <= 12_800);
  assert.equal(encoded.messageSent, "CQ BI1XYZ OM89");

  const decoded = await client.decode({
    mode: "FT8",
    pcm: encoded.pcm,
    nominalFrequencyHz: 1_500,
    myCall: "BI1XYZ",
    myGrid: "OM89",
  });
  assert.ok(Array.isArray(decoded.frames));
  for (const frame of decoded.frames) {
    assert.equal(typeof frame.message, "string");
    assert.equal(typeof frame.snrDb, "number");
    assert.equal(typeof frame.deltaTimeSeconds, "number");
    assert.equal(typeof frame.audioFrequencyHz, "number");
  }
  assert.deepEqual(faults, []);
});
