import assert from "node:assert/strict";
import { test } from "node:test";

import {
  parseAdif,
  serializeAdif,
  serializeAdifRecord,
} from "../src/log/adif.ts";

test("ADIF records round-trip with a mainstream header and stable field order", () => {
  const encoded = serializeAdif([{
    APP_RADIO_LITE_ID: "qso-1",
    CALL: "JA1ABC",
    QSO_DATE: "20260825",
    TIME_ON: "123456",
    BAND: "20M",
    FREQ: "14.074",
    MODE: "FT8",
    GRIDSQUARE: "PM95",
    MY_CALL: "BI1ABC",
    MY_GRIDSQUARE: "OM89",
  }]);
  const text = encoded.toString("ascii");
  assert.match(text, /<ADIF_VER:5>3\.1\.7/u);
  assert.match(text, /<PROGRAMID:10>Radio Lite/u);
  assert.ok(text.indexOf("<QSO_DATE") < text.indexOf("<CALL"));
  const parsed = parseAdif(encoded);
  assert.equal(parsed.header.ADIF_VER, "3.1.7");
  assert.equal(parsed.records.length, 1);
  assert.equal(parsed.records[0].CALL, "JA1ABC");
  assert.equal(parsed.records[0].APP_RADIO_LITE_ID, "qso-1");
  assert.equal(parsed.trailingIncomplete, false);
});

test("ADIF parser accepts case-insensitive tags, leading-zero lengths and type hints", () => {
  const parsed = parseAdif(Buffer.from(
    "<call:0006:s>W1AW/4<qso_date:8:d>20260825<time_on:4>1234<mode:3>SSB<eor>",
    "ascii",
  ));
  assert.deepEqual(parsed.records, [{
    CALL: "W1AW/4",
    QSO_DATE: "20260825",
    TIME_ON: "1234",
    MODE: "SSB",
  }]);
});

test("ADIF recovery mode keeps complete records and marks an interrupted tail", () => {
  const first = serializeAdifRecord({
    CALL: "W1AW",
    QSO_DATE: "20260825",
    TIME_ON: "120000",
    BAND: "20M",
    MODE: "SSB",
  });
  const interrupted = Buffer.concat([first, Buffer.from("<CALL:5>JA1", "ascii")]);
  assert.throws(() => parseAdif(interrupted), /incomplete/u);
  const recovered = parseAdif(interrupted, { allowIncompleteTail: true });
  assert.equal(recovered.records.length, 1);
  assert.equal(recovered.records[0].CALL, "W1AW");
  assert.equal(recovered.trailingIncomplete, true);
});

test("ADIF writer and parser reject ambiguous or non-interoperable data", () => {
  assert.throws(() => serializeAdifRecord({ CALL: "北京" }), /ASCII/u);
  assert.throws(() => serializeAdifRecord({ "BAD-FIELD": "x" }), /field name/u);
  assert.throws(
    () => parseAdif(Buffer.from("<CALL:4>W1AW<CALL:4>W2AW<EOR>", "ascii")),
    /duplicate/u,
  );
  assert.throws(
    () => parseAdif(Buffer.from("<CALL:+4>W1AW<EOR>", "ascii")),
    /tag/u,
  );
});
