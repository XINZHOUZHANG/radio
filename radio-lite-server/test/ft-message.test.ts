import assert from "node:assert/strict";
import { test } from "node:test";

import {
  formatDirectedMessage,
  formatSignalReport,
  parseFtMessage,
} from "../src/digital/ft-message.ts";

test("parses common CQ, grid, report and completion messages", () => {
  assert.deepEqual(parseFtMessage(" CQ   DX  JA1ABC  PM95 "), {
    kind: "cq",
    text: "CQ DX JA1ABC PM95",
    senderCallsign: "JA1ABC",
    grid: "PM95",
    qualifier: "DX",
  });
  assert.deepEqual(parseFtMessage("JA1ABC BI1XYZ OM89"), {
    kind: "grid",
    text: "JA1ABC BI1XYZ OM89",
    recipientCallsign: "JA1ABC",
    senderCallsign: "BI1XYZ",
    grid: "OM89",
  });
  assert.equal(parseFtMessage("BI1XYZ JA1ABC -08").kind, "report");
  assert.equal(parseFtMessage("BI1XYZ JA1ABC R+03").kind, "roger_report");
  assert.equal(parseFtMessage("BI1XYZ JA1ABC RR73").kind, "rr73");
  assert.equal(parseFtMessage("TNX FER QSO").kind, "free_text");
});

test("formats bounded reports and directed messages for the native encoder", () => {
  assert.equal(formatSignalReport(-7.6), "-08");
  assert.equal(formatSignalReport(0), "+00");
  assert.equal(formatSignalReport(90), "+49");
  assert.equal(formatDirectedMessage("ja1abc", "bi1xyz", "r-08"), "JA1ABC BI1XYZ R-08");
  assert.throws(() => parseFtMessage("BI1XYZ JA1ABC -99"), /outside/u);
});
