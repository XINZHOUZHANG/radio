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
      NAME: "测试员",
      QTH: "测试城",
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
  assert.equal(store.list(10)[1].fields.NAME, "测试员");
  assert.equal(store.list(10)[1].fields.QTH, "测试城");
  const grids = store.gridSummary(4);
  assert.equal(grids.length, 1);
  assert.equal(grids[0].grid, "FN31");
  assert.equal(grids[0].qsoCount, 2);
  assert.deepEqual(grids[0].bands, { "20M": 2 });
  assert.deepEqual(grids[0].modes, { FT8: 1, SSB: 1 });

  const reopened = new AdifLogStore(join(directory, "station-log.adif"));
  assert.equal((await reopened.load()).count, 2);
  assert.equal(reopened.list(10)[1].fields.NAME, "测试员");
  assert.equal(reopened.list(10)[1].fields.QTH, "测试城");
});

test("ADIF store pages QSOs by bounded two or four character grid prefixes", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-adif-grid-page-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new AdifLogStore(join(directory, "station-log.adif"));
  await store.load();
  await store.import(serializeAdif([
    {
      CALL: "W1AAA",
      QSO_DATE: "20260825",
      TIME_ON: "120000",
      BAND: "20M",
      MODE: "FT8",
      GRIDSQUARE: "FN31PR",
    },
    {
      CALL: "W1BBB",
      QSO_DATE: "20260825",
      TIME_ON: "121500",
      BAND: "20M",
      MODE: "SSB",
      GRIDSQUARE: "FN31AA",
    },
    {
      CALL: "W1CCC",
      QSO_DATE: "20260825",
      TIME_ON: "123000",
      BAND: "40M",
      MODE: "CW",
      GRIDSQUARE: "FN32AB",
    },
    {
      CALL: "JA1DDD",
      QSO_DATE: "20260825",
      TIME_ON: "124500",
      BAND: "20M",
      MODE: "FT8",
      GRIDSQUARE: "PM95",
    },
    {
      CALL: "N0GRID",
      QSO_DATE: "20260825",
      TIME_ON: "130000",
      BAND: "20M",
      MODE: "FT8",
    },
  ]));

  const firstPage = store.pageByGrid(" fn31 ", 1, 0);
  assert.equal(firstPage.total, 2);
  assert.deepEqual(firstPage.records.map((record) => record.call), ["W1BBB"]);
  const secondPage = store.pageByGrid("FN31", 1, 1);
  assert.equal(secondPage.total, 2);
  assert.deepEqual(secondPage.records.map((record) => record.call), ["W1AAA"]);

  const fieldPage = store.pageByGrid("fn", 10, 0);
  assert.equal(fieldPage.total, 3);
  assert.deepEqual(fieldPage.records.map((record) => record.call), ["W1CCC", "W1BBB", "W1AAA"]);
  assert.equal(store.gridSummary(4).find((entry) => entry.grid === "FN31")?.qsoCount, firstPage.total);
  assert.equal(store.gridSummary(2).find((entry) => entry.grid === "FN")?.qsoCount, fieldPage.total);

  assert.throws(() => store.pageByGrid("FN31PR"), /2 or 4 character Maidenhead/u);
  assert.throws(() => store.pageByGrid("ZZ99"), /Maidenhead/u);
  assert.throws(() => store.pageByGrid("FN31", 1_001), /limit/u);
  assert.throws(() => store.pageByGrid("FN31", 1, -1), /offset/u);
});

test("ADIF store keeps grid pages bounded for about seven thousand matching QSOs", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-adif-grid-large-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new AdifLogStore(join(directory, "station-log.adif"));
  await store.load();

  const matchingCount = 7_005;
  const nonmatchingCount = 13;
  const startedAtMs = Date.UTC(2026, 0, 1, 0, 0, 0);
  const recordAt = (index: number, grid: string) => {
    const iso = new Date(startedAtMs + index * 1_000).toISOString();
    return {
      CALL: "W1AAA",
      QSO_DATE: iso.slice(0, 10).replaceAll("-", ""),
      TIME_ON: iso.slice(11, 19).replaceAll(":", ""),
      BAND: "20M",
      MODE: "FT8",
      GRIDSQUARE: grid,
    };
  };
  const matching = Array.from({ length: matchingCount }, (_, index) =>
    recordAt(index, index % 2 === 0 ? "FN31AA" : "FN32BB"));
  const nonmatching = Array.from({ length: nonmatchingCount }, (_, index) =>
    recordAt(matchingCount + index, "PM95AA"));
  await store.import(serializeAdif([...matching, ...nonmatching]));

  const firstPage = store.pageByGrid("FN", 50, 0);
  assert.equal(firstPage.total, matchingCount);
  assert.equal(firstPage.records.length, 50);
  assert.ok(firstPage.records.every((record) => record.grid?.startsWith("FN") === true));

  const deepPage = store.pageByGrid("FN", 50, 6_950);
  assert.equal(deepPage.total, matchingCount);
  assert.equal(deepPage.records.length, 50);

  const finalPage = store.pageByGrid("FN", 50, 7_000);
  assert.equal(finalPage.total, matchingCount);
  assert.equal(finalPage.records.length, 5);
  assert.ok(finalPage.records.every((record) => record.grid?.startsWith("FN") === true));
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
