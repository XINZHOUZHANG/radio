import { createHash, randomUUID } from "node:crypto";
import { mkdir, open, readFile } from "node:fs/promises";
import { dirname } from "node:path";

import { parseAdif, serializeAdif, serializeAdifRecord, type AdifFields } from "./adif.ts";
import { maidenheadCenter, normalizeMaidenhead } from "./maidenhead.ts";
import { writeFileAtomic } from "../storage/atomic-file.ts";

export type QsoSource = "VOICE_MANUAL" | "FT8_AUTO" | "FT4_AUTO" | "IMPORT";

export type NewQso = {
  radioId: string;
  source: Exclude<QsoSource, "IMPORT">;
  call: string;
  startedAtMs: number;
  endedAtMs?: number;
  frequencyHz: number;
  band?: string;
  mode: string;
  submode?: string;
  rstSent?: string;
  rstReceived?: string;
  grid?: string;
  myCall: string;
  myGrid?: string;
  txPowerWatts?: number;
  comment?: string;
};

export type QsoLogRecord = {
  id: string;
  radioId: string | null;
  source: QsoSource;
  call: string;
  startedAtMs: number;
  endedAtMs: number | null;
  frequencyHz: number | null;
  band: string;
  mode: string;
  submode: string | null;
  rstSent: string | null;
  rstReceived: string | null;
  grid: string | null;
  myCall: string | null;
  myGrid: string | null;
  fields: AdifFields;
};

export type GridSummary = {
  grid: string;
  latitude: number;
  longitude: number;
  latitudeSpan: number;
  longitudeSpan: number;
  qsoCount: number;
  lastQsoAtMs: number;
  bands: Record<string, number>;
  modes: Record<string, number>;
};

export type AdifLogStoreOptions = {
  now?: () => number;
  idFactory?: () => string;
};

type IndexedQso = {
  record: QsoLogRecord;
  fingerprint: string;
};

const MAX_STORED_LOG_BYTES = 256 * 1_024 * 1_024;
const MAX_IMPORT_BYTES = 16 * 1_024 * 1_024;

export class AdifLogStore {
  readonly #path: string;
  readonly #now: () => number;
  readonly #idFactory: () => string;
  #records: IndexedQso[] = [];
  #ids = new Set<string>();
  #fingerprints = new Set<string>();
  #loaded = false;
  #tail: Promise<void> = Promise.resolve();

  constructor(path: string, options: AdifLogStoreOptions = {}) {
    if (!path) {
      throw new Error("ADIF log path is required");
    }
    this.#path = path;
    this.#now = options.now ?? Date.now;
    this.#idFactory = options.idFactory ?? (() => `qso_${randomUUID()}`);
  }

  get count(): number {
    this.#assertLoaded();
    return this.#records.length;
  }

  load(): Promise<{
    count: number;
    recoveredIncompleteTail: boolean;
    corruptCopyPath: string | null;
  }> {
    return this.#serialize(async () => {
      if (this.#loaded) {
        return {
          count: this.#records.length,
          recoveredIncompleteTail: false,
          corruptCopyPath: null,
        };
      }
      let content: Buffer;
      try {
        content = await readFile(this.#path);
      } catch (error) {
        if (!isMissing(error)) {
          throw error;
        }
        content = serializeAdif([]);
        await writeFileAtomic(this.#path, content);
      }
      const parsed = parseAdif(content, {
        allowIncompleteTail: true,
        maxBytes: MAX_STORED_LOG_BYTES,
      });
      const indexed = parsed.records.map((fields) => indexAdifRecord(fields));
      ensureUnique(indexed);
      let corruptCopyPath: string | null = null;
      if (parsed.trailingIncomplete) {
        corruptCopyPath = `${this.#path}.corrupt-${Math.trunc(this.#now())}`;
        await writeFileAtomic(corruptCopyPath, content);
        await writeFileAtomic(
          this.#path,
          serializeAdif(indexed.map((entry) => entry.record.fields)),
        );
      }
      this.#replaceIndex(indexed);
      this.#loaded = true;
      return {
        count: indexed.length,
        recoveredIncompleteTail: parsed.trailingIncomplete,
        corruptCopyPath,
      };
    });
  }

  append(input: NewQso): Promise<{ record: QsoLogRecord; created: boolean }> {
    return this.#serialize(async () => {
      this.#assertLoaded();
      const fields = fieldsForNewQso(input, this.#idFactory());
      const indexed = indexAdifRecord(fields);
      const existing = this.#records.find((candidate) =>
        candidate.record.id === indexed.record.id || candidate.fingerprint === indexed.fingerprint,
      );
      if (existing !== undefined) {
        return { record: cloneRecord(existing.record), created: false };
      }
      await this.#appendFields([indexed.record.fields]);
      this.#addIndex(indexed);
      return { record: cloneRecord(indexed.record), created: true };
    });
  }

  import(input: Uint8Array): Promise<{ imported: number; duplicates: number }> {
    return this.#serialize(async () => {
      this.#assertLoaded();
      const parsed = parseAdif(input, { maxBytes: MAX_IMPORT_BYTES });
      const staged: IndexedQso[] = [];
      const stagedIds = new Set<string>();
      const stagedFingerprints = new Set<string>();
      let duplicates = 0;
      for (const fields of parsed.records) {
        const indexed = indexAdifRecord(fields, "IMPORT");
        if (
          this.#ids.has(indexed.record.id) ||
          this.#fingerprints.has(indexed.fingerprint) ||
          stagedIds.has(indexed.record.id) ||
          stagedFingerprints.has(indexed.fingerprint)
        ) {
          duplicates += 1;
          continue;
        }
        staged.push(indexed);
        stagedIds.add(indexed.record.id);
        stagedFingerprints.add(indexed.fingerprint);
      }
      if (staged.length > 0) {
        await this.#appendFields(staged.map((entry) => entry.record.fields));
        for (const entry of staged) {
          this.#addIndex(entry);
        }
      }
      return { imported: staged.length, duplicates };
    });
  }

  list(limit = 100, offset = 0): QsoLogRecord[] {
    this.#assertLoaded();
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1_000) {
      throw new Error("log limit must be in 1..1000");
    }
    if (!Number.isSafeInteger(offset) || offset < 0) {
      throw new Error("log offset must be a non-negative integer");
    }
    return this.#records
      .slice()
      .reverse()
      .slice(offset, offset + limit)
      .map((entry) => cloneRecord(entry.record));
  }

  gridSummary(resolution: 2 | 4 | 6 | 8 = 4): GridSummary[] {
    this.#assertLoaded();
    if (resolution !== 2 && resolution !== 4 && resolution !== 6 && resolution !== 8) {
      throw new Error("grid resolution must be 2, 4, 6 or 8");
    }
    const grouped = new Map<string, GridSummary>();
    for (const { record } of this.#records) {
      if (record.grid === null) {
        continue;
      }
      const grid = record.grid.slice(0, Math.min(resolution, record.grid.length));
      const existing = grouped.get(grid);
      const summary = existing ?? {
        ...maidenheadCenter(grid),
        qsoCount: 0,
        lastQsoAtMs: 0,
        bands: {},
        modes: {},
      };
      summary.qsoCount += 1;
      summary.lastQsoAtMs = Math.max(summary.lastQsoAtMs, record.startedAtMs);
      summary.bands[record.band] = (summary.bands[record.band] ?? 0) + 1;
      summary.modes[record.mode] = (summary.modes[record.mode] ?? 0) + 1;
      grouped.set(grid, summary);
    }
    return [...grouped.values()].sort(
      (left, right) => right.qsoCount - left.qsoCount || left.grid.localeCompare(right.grid),
    );
  }

  async export(): Promise<Buffer> {
    this.#assertLoaded();
    return readFile(this.#path);
  }

  async #appendFields(records: readonly AdifFields[]): Promise<void> {
    if (records.length === 0) {
      return;
    }
    await mkdir(dirname(this.#path), { recursive: true, mode: 0o700 });
    const handle = await open(this.#path, "a", 0o600);
    try {
      await handle.writeFile(Buffer.concat(records.map(serializeAdifRecord)));
      await handle.sync();
    } finally {
      await handle.close();
    }
  }

  #replaceIndex(records: IndexedQso[]): void {
    this.#records = records;
    this.#ids = new Set(records.map((entry) => entry.record.id));
    this.#fingerprints = new Set(records.map((entry) => entry.fingerprint));
  }

  #addIndex(entry: IndexedQso): void {
    this.#records.push(entry);
    this.#ids.add(entry.record.id);
    this.#fingerprints.add(entry.fingerprint);
  }

  #assertLoaded(): void {
    if (!this.#loaded) {
      throw new Error("ADIF log store is not loaded");
    }
  }

  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

function fieldsForNewQso(input: NewQso, id: string): AdifFields {
  const startedAtMs = timestamp(input.startedAtMs, "startedAtMs");
  const endedAtMs = input.endedAtMs === undefined
    ? null
    : timestamp(input.endedAtMs, "endedAtMs");
  if (endedAtMs !== null && endedAtMs < startedAtMs) {
    throw new Error("endedAtMs must not precede startedAtMs");
  }
  const frequencyHz = positiveInteger(input.frequencyHz, "frequencyHz");
  const mode = boundedUpper(input.mode, "mode", 1, 32, /^[A-Z0-9 _-]+$/u);
  if (input.source === "FT8_AUTO" && mode !== "FT8") {
    throw new Error("FT8_AUTO records must use FT8 mode");
  }
  if (input.source === "FT4_AUTO" && mode !== "FT4") {
    throw new Error("FT4_AUTO records must use FT4 mode");
  }
  const fields: AdifFields = {
    ...dateTimeFields(startedAtMs, ""),
    CALL: callsign(input.call, "call"),
    BAND: input.band === undefined
      ? bandForFrequency(frequencyHz)
      : boundedUpper(input.band, "band", 1, 16, /^[A-Z0-9]+$/u),
    FREQ: frequencyMhz(frequencyHz),
    MODE: mode,
    MY_CALL: callsign(input.myCall, "myCall"),
    APP_RADIO_LITE_ID: boundedAscii(id, "id", 1, 128),
    APP_RADIO_LITE_RADIO_ID: boundedAscii(input.radioId, "radioId", 1, 32),
    APP_RADIO_LITE_SOURCE: input.source,
  };
  if (endedAtMs !== null) {
    Object.assign(fields, dateTimeFields(endedAtMs, "_OFF"));
  }
  optional(fields, "SUBMODE", input.submode, (value) => boundedUpper(value, "submode", 1, 32, /^[A-Z0-9 _-]+$/u));
  optional(fields, "RST_SENT", input.rstSent, (value) => boundedAscii(value, "rstSent", 1, 16));
  optional(fields, "RST_RCVD", input.rstReceived, (value) => boundedAscii(value, "rstReceived", 1, 16));
  optional(fields, "GRIDSQUARE", input.grid, normalizeMaidenhead);
  optional(fields, "MY_GRIDSQUARE", input.myGrid, normalizeMaidenhead);
  optional(fields, "COMMENT", input.comment, (value) => printableAscii(value, "comment", 1, 256));
  if (input.txPowerWatts !== undefined) {
    if (typeof input.txPowerWatts !== "number" || !Number.isFinite(input.txPowerWatts) || input.txPowerWatts < 0 || input.txPowerWatts > 100_000) {
      throw new Error("txPowerWatts must be in 0..100000");
    }
    fields.TX_PWR = String(input.txPowerWatts);
  }
  return fields;
}

function indexAdifRecord(fields: AdifFields, defaultSource?: QsoSource): IndexedQso {
  const normalized: AdifFields = { ...fields };
  normalized.CALL = callsign(required(normalized, "CALL"), "CALL");
  normalized.QSO_DATE = qsoDate(required(normalized, "QSO_DATE"));
  normalized.TIME_ON = qsoTime(required(normalized, "TIME_ON"));
  normalized.MODE = boundedUpper(required(normalized, "MODE"), "MODE", 1, 32, /^[A-Z0-9 _-]+$/u);
  if (normalized.BAND === undefined && normalized.FREQ === undefined) {
    throw new Error("ADIF QSO requires BAND or FREQ");
  }
  const frequencyHz = normalized.FREQ === undefined ? null : parseFrequency(normalized.FREQ);
  const band = normalized.BAND === undefined
    ? bandForFrequency(frequencyHz!)
    : boundedUpper(normalized.BAND, "BAND", 1, 16, /^[A-Z0-9]+$/u);
  if (normalized.GRIDSQUARE !== undefined) {
    normalized.GRIDSQUARE = normalizeMaidenhead(normalized.GRIDSQUARE);
  }
  if (normalized.MY_GRIDSQUARE !== undefined) {
    normalized.MY_GRIDSQUARE = normalizeMaidenhead(normalized.MY_GRIDSQUARE);
  }
  for (const field of ["MY_CALL", "STATION_CALLSIGN"] as const) {
    if (normalized[field] !== undefined) {
      normalized[field] = callsign(normalized[field], field);
    }
  }
  const fingerprint = qsoFingerprint(normalized, band);
  const id = normalized.APP_RADIO_LITE_ID === undefined
    ? derivedId(fingerprint)
    : boundedAscii(normalized.APP_RADIO_LITE_ID, "APP_RADIO_LITE_ID", 1, 128);
  normalized.APP_RADIO_LITE_ID = id;
  const source = qsoSource(normalized.APP_RADIO_LITE_SOURCE, defaultSource);
  normalized.APP_RADIO_LITE_SOURCE = source;
  const startedAtMs = parseAdifDateTime(normalized.QSO_DATE, normalized.TIME_ON);
  const endedAtMs = normalized.QSO_DATE_OFF === undefined && normalized.TIME_OFF === undefined
    ? null
    : parseAdifDateTime(
        qsoDate(normalized.QSO_DATE_OFF ?? normalized.QSO_DATE),
        qsoTime(required(normalized, "TIME_OFF")),
      );
  return {
    fingerprint,
    record: {
      id,
      radioId: normalized.APP_RADIO_LITE_RADIO_ID ?? null,
      source,
      call: normalized.CALL,
      startedAtMs,
      endedAtMs,
      frequencyHz,
      band,
      mode: normalized.MODE,
      submode: normalized.SUBMODE ?? null,
      rstSent: normalized.RST_SENT ?? null,
      rstReceived: normalized.RST_RCVD ?? null,
      grid: normalized.GRIDSQUARE ?? null,
      myCall: normalized.MY_CALL ?? normalized.STATION_CALLSIGN ?? null,
      myGrid: normalized.MY_GRIDSQUARE ?? null,
      fields: normalized,
    },
  };
}

function ensureUnique(records: IndexedQso[]): void {
  const ids = new Set<string>();
  const fingerprints = new Set<string>();
  for (const entry of records) {
    if (ids.has(entry.record.id)) {
      throw new Error(`ADIF log contains duplicate id ${entry.record.id}`);
    }
    if (fingerprints.has(entry.fingerprint)) {
      throw new Error("ADIF log contains a duplicate QSO");
    }
    ids.add(entry.record.id);
    fingerprints.add(entry.fingerprint);
  }
}

function qsoFingerprint(fields: AdifFields, band: string): string {
  return [
    fields.QSO_DATE,
    fields.TIME_ON,
    fields.CALL,
    band,
    fields.FREQ ?? "",
    fields.MODE,
    fields.SUBMODE ?? "",
  ].join("\0");
}

function derivedId(fingerprint: string): string {
  return `qso_${createHash("sha256").update(fingerprint).digest("base64url").slice(0, 24)}`;
}

function qsoSource(value: string | undefined, fallback: QsoSource = "IMPORT"): QsoSource {
  return value === "VOICE_MANUAL" || value === "FT8_AUTO" || value === "FT4_AUTO" || value === "IMPORT"
    ? value
    : fallback;
}

function dateTimeFields(value: number, suffix: "" | "_OFF"): AdifFields {
  const date = new Date(value);
  return {
    [`QSO_DATE${suffix}`]: [
      date.getUTCFullYear().toString().padStart(4, "0"),
      (date.getUTCMonth() + 1).toString().padStart(2, "0"),
      date.getUTCDate().toString().padStart(2, "0"),
    ].join(""),
    [`TIME${suffix === "" ? "_ON" : "_OFF"}`]: [
      date.getUTCHours().toString().padStart(2, "0"),
      date.getUTCMinutes().toString().padStart(2, "0"),
      date.getUTCSeconds().toString().padStart(2, "0"),
    ].join(""),
  };
}

function parseAdifDateTime(dateValue: string, timeValue: string): number {
  const year = Number(dateValue.slice(0, 4));
  const month = Number(dateValue.slice(4, 6));
  const day = Number(dateValue.slice(6, 8));
  const paddedTime = timeValue.length === 4 ? `${timeValue}00` : timeValue;
  const hour = Number(paddedTime.slice(0, 2));
  const minute = Number(paddedTime.slice(2, 4));
  const second = Number(paddedTime.slice(4, 6));
  const timestamp = Date.UTC(year, month - 1, day, hour, minute, second);
  const verified = new Date(timestamp);
  if (
    verified.getUTCFullYear() !== year ||
    verified.getUTCMonth() !== month - 1 ||
    verified.getUTCDate() !== day ||
    verified.getUTCHours() !== hour ||
    verified.getUTCMinutes() !== minute ||
    verified.getUTCSeconds() !== second
  ) {
    throw new Error("ADIF QSO date/time is invalid");
  }
  return timestamp;
}

function qsoDate(value: string): string {
  if (!/^[0-9]{8}$/u.test(value)) {
    throw new Error("ADIF QSO_DATE must use YYYYMMDD");
  }
  return value;
}

function qsoTime(value: string): string {
  if (!/^(?:[0-9]{4}|[0-9]{6})$/u.test(value)) {
    throw new Error("ADIF TIME_ON/TIME_OFF must use HHMM or HHMMSS");
  }
  return value;
}

function parseFrequency(value: string): number {
  if (!/^(?:[0-9]+)(?:\.[0-9]+)?$/u.test(value)) {
    throw new Error("ADIF FREQ must be decimal MHz");
  }
  const frequencyHz = Math.round(Number(value) * 1_000_000);
  return positiveInteger(frequencyHz, "ADIF FREQ");
}

export function bandForFrequency(frequencyHz: number): string {
  const ranges: Array<[number, number, string]> = [
    [135_700, 137_800, "2190M"], [472_000, 479_000, "630M"],
    [1_800_000, 2_000_000, "160M"], [3_500_000, 4_000_000, "80M"],
    [5_000_000, 5_500_000, "60M"], [7_000_000, 7_300_000, "40M"],
    [10_100_000, 10_150_000, "30M"], [14_000_000, 14_350_000, "20M"],
    [18_068_000, 18_168_000, "17M"], [21_000_000, 21_450_000, "15M"],
    [24_890_000, 24_990_000, "12M"], [28_000_000, 29_700_000, "10M"],
    [50_000_000, 54_000_000, "6M"], [144_000_000, 148_000_000, "2M"],
    [420_000_000, 450_000_000, "70CM"],
  ];
  const match = ranges.find(([minimum, maximum]) => frequencyHz >= minimum && frequencyHz <= maximum);
  if (match === undefined) {
    throw new Error("frequency is outside the built-in amateur band table");
  }
  return match[2];
}

function frequencyMhz(frequencyHz: number): string {
  return (frequencyHz / 1_000_000).toFixed(6).replace(/(?:\.0+|(?<=\.[0-9]*?)0+)$/u, "");
}

function callsign(value: string, field: string): string {
  return boundedUpper(value, field, 3, 32, /^[A-Z0-9/.-]+$/u);
}

function boundedUpper(
  value: string,
  field: string,
  minimum: number,
  maximum: number,
  pattern: RegExp,
): string {
  const normalized = boundedAscii(value, field, minimum, maximum).trim().toUpperCase();
  if (!pattern.test(normalized)) {
    throw new Error(`${field} has invalid characters`);
  }
  return normalized;
}

function boundedAscii(value: string, field: string, minimum: number, maximum: number): string {
  if (typeof value !== "string" || value.length < minimum || value.length > maximum || !/^[\x20-\x7e]+$/u.test(value)) {
    throw new Error(`${field} must be ${minimum}..${maximum} printable ASCII characters`);
  }
  return value;
}

function printableAscii(value: string, field: string, minimum: number, maximum: number): string {
  return boundedAscii(value, field, minimum, maximum);
}

function timestamp(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value < 0 || !Number.isFinite(new Date(value).getTime())) {
    throw new Error(`${field} must be a non-negative epoch millisecond timestamp`);
  }
  return value;
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}

function required(fields: AdifFields, name: string): string {
  const value = fields[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`ADIF QSO requires ${name}`);
  }
  return value;
}

function optional(
  fields: AdifFields,
  name: string,
  value: string | undefined,
  normalize: (value: string) => string,
): void {
  if (value !== undefined) {
    fields[name] = normalize(value);
  }
}

function cloneRecord(record: QsoLogRecord): QsoLogRecord {
  return { ...record, fields: { ...record.fields } };
}

function isMissing(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "ENOENT";
}
