import assert from "node:assert/strict";
import { appendFile, mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { parseAdif, serializeAdif } from "../src/log/adif.ts";
import { AdifLogStore } from "../src/log/adif-log-store.ts";

test("ADIF store appends manual and automatic QSOs and reloads without a database", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-adif-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "station-log.adif");
  let id = 0;
  const store = new AdifLogStore(path, { idFactory: () => `qso-${++id}` });
  assert.deepEqual(await store.load(), {
    count: 0,
    recoveredIncompleteTail: false,
    corruptCopyPath: null,
  });

  const voice = await store.append({
    radioId: "main",
    source: "VOICE_MANUAL",
    call: "ja1abc",
    startedAtMs: Date.UTC(2026, 7, 25, 12, 34, 56),
    endedAtMs: Date.UTC(2026, 7, 25, 12, 36, 1),
    frequencyHz: 14_250_000,
    mode: "SSB",
    rstSent: "59",
    rstReceived: "57",
    grid: "pm95",
    myCall: "BI1ABC",
    myGrid: "OM89",
    comment: "Good signal",
  });
  assert.equal(voice.created, true);
  assert.equal(voice.record.id, "qso-1");
  assert.equal(voice.record.band, "20M");
  assert.equal(voice.record.frequencyHz, 14_250_000);

  const automatic = await store.append({
    radioId: "main",
    source: "FT8_AUTO",
    call: "W1AW",
    startedAtMs: Date.UTC(2026, 7, 25, 12, 45, 0),
    frequencyHz: 14_074_000,
    mode: "FT8",
    rstSent: "-10",
    rstReceived: "-08",
    grid: "FN31PR",
    myCall: "BI1ABC",
    myGrid: "OM89",
  });
  assert.equal(automatic.record.source, "FT8_AUTO");
  assert.deepEqual(store.list(10).map((record) => record.call), ["W1AW", "JA1ABC"]);

  const onDisk = await readFile(path);
  assert.equal(parseAdif(onDisk).records.length, 2);
  assert.match(onDisk.toString("ascii"), /<APP_RADIO_LITE_SOURCE:12>VOICE_MANUAL/u);

  const reopened = new AdifLogStore(path);
  assert.equal((await reopened.load()).count, 2);
  assert.equal(reopened.list(1)[0].id, automatic.record.id);
  const duplicateImport = await reopened.import(onDisk);
  assert.deepEqual(duplicateImport, { imported: 0, duplicates: 2 });
});

test("ADIF import preserves unknown fields, deduplicates and aggregates grid cells", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-adif-import-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new AdifLogStore(join(directory, "station-log.adif"));
  await store.load();
  const imported = serializeAdif([
    {
      CALL: "W1AW",
      QSO_DATE: "20260825",
      TIME_ON: "120000",
      BAND: "20M",
      FREQ: "14.074",
      MODE: "FT8",
      GRIDSQUARE: "FN31PR",
      STATE: "CT",
    },
    {
      CALL: "K1ABC",
      QSO_DATE: "20260825",
      TIME_ON: "121500",
      BAND: "20M",
      FREQ: "14.250",
      MODE: "SSB",
      GRIDSQUARE: "FN31AA",
    },
  ]);
  assert.deepEqual(await store.import(imported), { imported: 2, duplicates: 0 });
  assert.equal(store.list(10)[1].fields.STATE, "CT");
  const grids = store.gridSummary(4);
  assert.equal(grids.length, 1);
  assert.equal(grids[0].grid, "FN31");
  assert.equal(grids[0].qsoCount, 2);
  assert.deepEqual(grids[0].bands, { "20M": 2 });
  assert.deepEqual(grids[0].modes, { FT8: 1, SSB: 1 });
});

test("ADIF store preserves a corrupt copy and repairs only an interrupted tail", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-adif-recover-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "station-log.adif");
  const store = new AdifLogStore(path, { now: () => 123_456 });
  await store.load();
  await store.append({
    radioId: "main",
    source: "VOICE_MANUAL",
    call: "W1AW",
    startedAtMs: Date.UTC(2026, 7, 25, 12, 0, 0),
    frequencyHz: 7_200_000,
    mode: "SSB",
    myCall: "BI1ABC",
  });
  await appendFile(path, "<CALL:5>JA1", "ascii");

  const reopened = new AdifLogStore(path, { now: () => 123_456 });
  const loaded = await reopened.load();
  assert.equal(loaded.count, 1);
  assert.equal(loaded.recoveredIncompleteTail, true);
  assert.match(loaded.corruptCopyPath ?? "", /corrupt-123456/u);
  assert.equal(parseAdif(await readFile(path)).records.length, 1);
  assert.ok((await readdir(directory)).some((name) => name.includes("corrupt-123456")));
});
