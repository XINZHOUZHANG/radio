import assert from "node:assert/strict";
import { test } from "node:test";

import { AutoQsoSession } from "../src/digital/auto-qso.ts";
import type { DigitalCallQueueEntry } from "../src/digital/call-queue.ts";
import { DigitalDecodeStore } from "../src/digital/decode-store.ts";

test("caller QSO exchanges grid, reports and 73 then produces one FT8 ADIF input", () => {
  const session = new AutoQsoSession({
    entry: queueEntry(),
    myCallsign: "BI1XYZ",
    myGrid: "OM89AA",
    dialFrequencyHz: 14_074_000,
    startedAtMs: 45_000,
  });
  assert.equal(session.snapshot().outboundMessage, "JA1ABC BI1XYZ OM89");

  assert.equal(session.recordTransmission(45_000, 57_640).phase, "awaiting_report");
  const reportBatch = decodeBatch(60_000, "BI1XYZ JA1ABC -07", -12);
  assert.equal(session.ingest(reportBatch, reportBatch.decodes[0]), true);
  assert.equal(session.snapshot().outboundMessage, "JA1ABC BI1XYZ R-12");
  assert.equal(session.snapshot().reportReceived, "-07");

  assert.equal(session.recordTransmission(75_000, 87_640).phase, "awaiting_final");
  const finalBatch = decodeBatch(90_000, "BI1XYZ JA1ABC RR73", -10);
  assert.equal(session.ingest(finalBatch, finalBatch.decodes[0]), true);
  assert.equal(session.snapshot().outboundMessage, "JA1ABC BI1XYZ 73");
  assert.equal(session.recordTransmission(105_000, 117_640).phase, "complete");

  assert.deepEqual(session.toLogRecord(), {
    radioId: "main",
    source: "FT8_AUTO",
    call: "JA1ABC",
    startedAtMs: 45_000,
    endedAtMs: 117_640,
    frequencyHz: 14_074_000,
    mode: "FT8",
    rstSent: "-12",
    rstReceived: "-07",
    grid: "PM95",
    myCall: "BI1XYZ",
    myGrid: "OM89",
  });
});

test("unrelated decodes are ignored and unanswered stages fail after a bounded retry count", () => {
  const session = new AutoQsoSession({
    entry: queueEntry(),
    myCallsign: "BI1XYZ",
    myGrid: "OM89",
    dialFrequencyHz: 14_074_000,
    startedAtMs: 45_000,
    maximumAttemptsPerStage: 2,
  });
  session.recordTransmission(45_000, 57_640);
  const unrelated = decodeBatch(60_000, "BI1XYZ JA2ZZZ -03", -5);
  assert.equal(session.ingest(unrelated, unrelated.decodes[0]), false);
  assert.equal(session.receiveSlotClosed(75_000).phase, "calling");
  session.recordTransmission(75_000, 87_640);
  const failed = session.receiveSlotClosed(105_000);
  assert.equal(failed.phase, "failed");
  assert.match(failed.failureReason ?? "", /retry limit/u);
  assert.throws(() => session.toLogRecord(), /completed/u);
});

function queueEntry(): DigitalCallQueueEntry {
  return {
    id: "entry_1",
    radioId: "main",
    ownerId: "connection:one",
    targetCallsign: "JA1ABC",
    targetGrid: "PM95",
    mode: "FT8",
    audioFrequencyHz: 1_300,
    txParity: "odd",
    sourceDecodeId: "decode_source",
    enqueuedAtMs: 40_000,
    status: "active",
  };
}

function decodeBatch(slotStartMs: number, message: string, snrDb: number) {
  return new DigitalDecodeStore().commit({
    radioId: "main",
    mode: "FT8",
    slotStartMs,
    receivedAtMs: slotStartMs + 15_000,
    frames: [{ message, snrDb, deltaTimeSeconds: 0.1, audioFrequencyHz: 1_300 }],
  });
}
