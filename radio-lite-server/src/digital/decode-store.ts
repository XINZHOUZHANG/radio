import { createHash } from "node:crypto";

import { isSlotBoundary, slotDurationMs } from "./slots.ts";
import type {
  DigitalDecode,
  DigitalDecodeBatch,
  DigitalDecodeBatchInput,
  DigitalDecodeSnapshot,
  RawDigitalDecode,
} from "./types.ts";

export type DigitalDecodeStoreOptions = {
  historySlots?: number;
};

type RadioHistory = {
  revision: number;
  batches: DigitalDecodeBatch[];
  decodeById: Map<string, DigitalDecode>;
};

export class DigitalDecodeStore {
  readonly #historySlots: number;
  readonly #radios = new Map<string, RadioHistory>();

  constructor(options: DigitalDecodeStoreOptions = {}) {
    this.#historySlots = boundedInteger(options.historySlots ?? 16, "historySlots", 1, 256);
  }

  commit(input: DigitalDecodeBatchInput): DigitalDecodeBatch {
    const radioId = identifier(input.radioId, "radioId", 32);
    const slotStartMs = timestamp(input.slotStartMs, "slotStartMs");
    const receivedAtMs = timestamp(input.receivedAtMs, "receivedAtMs");
    if (!isSlotBoundary(input.mode, slotStartMs)) {
      throw new Error("slotStartMs is not aligned to the selected digital mode");
    }
    const slotEndMs = slotStartMs + slotDurationMs(input.mode);
    if (receivedAtMs < slotEndMs) {
      throw new Error("a decode batch cannot be committed before its UTC slot ends");
    }
    if (!Array.isArray(input.frames) || input.frames.length > 4_096) {
      throw new Error("decode batch must contain at most 4096 frames");
    }
    const deduplicated = new Map<string, DigitalDecode>();
    for (const frame of input.frames) {
      const decoded = normalizeDecode(radioId, input.mode, slotStartMs, frame);
      const existing = deduplicated.get(decoded.id);
      if (existing === undefined || isBetterDecode(decoded, existing)) {
        deduplicated.set(decoded.id, decoded);
      }
    }
    const decodes = [...deduplicated.values()].sort(
      (left, right) =>
        left.audioFrequencyHz - right.audioFrequencyHz || left.id.localeCompare(right.id),
    );
    const history = this.#history(radioId);
    const existing = history.batches.find(
      (batch) => batch.mode === input.mode && batch.slotStartMs === slotStartMs,
    );
    if (existing !== undefined) {
      if (!sameDecodes(existing.decodes, decodes)) {
        throw new Error("decode slot was already committed with different results");
      }
      return cloneBatch(existing);
    }
    history.revision += 1;
    const batch: DigitalDecodeBatch = {
      radioId,
      mode: input.mode,
      slotStartMs,
      slotEndMs,
      receivedAtMs,
      revision: history.revision,
      decodes,
    };
    history.batches.push(batch);
    history.batches.sort(
      (left, right) => left.slotStartMs - right.slotStartMs || left.mode.localeCompare(right.mode),
    );
    while (history.batches.length > this.#historySlots) {
      history.batches.shift();
    }
    rebuildDecodeIndex(history);
    return cloneBatch(batch);
  }

  snapshot(radioId: string, limit = this.#historySlots): DigitalDecodeSnapshot {
    const normalizedRadioId = identifier(radioId, "radioId", 32);
    const boundedLimit = boundedInteger(limit, "limit", 1, this.#historySlots);
    const history = this.#radios.get(normalizedRadioId);
    if (history === undefined) {
      return { radioId: normalizedRadioId, revision: 0, batches: [] };
    }
    return {
      radioId: normalizedRadioId,
      revision: history.revision,
      batches: history.batches.slice(-boundedLimit).reverse().map(cloneBatch),
    };
  }

  decode(radioId: string, decodeId: string): DigitalDecode | null {
    const history = this.#radios.get(identifier(radioId, "radioId", 32));
    const decoded = history?.decodeById.get(identifier(decodeId, "decodeId", 128));
    return decoded === undefined ? null : { ...decoded };
  }

  #history(radioId: string): RadioHistory {
    const existing = this.#radios.get(radioId);
    if (existing !== undefined) {
      return existing;
    }
    const created: RadioHistory = { revision: 0, batches: [], decodeById: new Map() };
    this.#radios.set(radioId, created);
    return created;
  }
}

function normalizeDecode(
  radioId: string,
  mode: string,
  slotStartMs: number,
  value: RawDigitalDecode,
): DigitalDecode {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("decode frame must be an object");
  }
  const message = text(value.message, "decode message", 1, 64)
    .toUpperCase()
    .replace(/\s+/gu, " ");
  const snrDb = finiteRange(value.snrDb, "snrDb", -60, 50);
  const deltaTimeSeconds = finiteRange(value.deltaTimeSeconds, "deltaTimeSeconds", -10, 10);
  const audioFrequencyHz = finiteRange(value.audioFrequencyHz, "audioFrequencyHz", 0, 6_000);
  const confidence = value.confidence === undefined
    ? 1
    : finiteRange(value.confidence, "confidence", 0, 1);
  const frequencyKey = Math.round(audioFrequencyHz);
  const id = `decode_${createHash("sha256")
    .update([radioId, mode, String(slotStartMs), message, String(frequencyKey)].join("\0"))
    .digest("base64url")
    .slice(0, 24)}`;
  return { id, message, snrDb, deltaTimeSeconds, audioFrequencyHz, confidence };
}

function isBetterDecode(candidate: DigitalDecode, existing: DigitalDecode): boolean {
  return candidate.confidence > existing.confidence || (
    candidate.confidence === existing.confidence && candidate.snrDb > existing.snrDb
  );
}

function sameDecodes(left: readonly DigitalDecode[], right: readonly DigitalDecode[]): boolean {
  return left.length === right.length && left.every((value, index) =>
    JSON.stringify(value) === JSON.stringify(right[index]),
  );
}

function rebuildDecodeIndex(history: RadioHistory): void {
  history.decodeById.clear();
  for (const batch of history.batches) {
    for (const decoded of batch.decodes) {
      history.decodeById.set(decoded.id, decoded);
    }
  }
}

function cloneBatch(value: DigitalDecodeBatch): DigitalDecodeBatch {
  return { ...value, decodes: value.decodes.map((decoded) => ({ ...decoded })) };
}

function identifier(value: string, field: string, maximum: number): string {
  const normalized = text(value, field, 1, maximum);
  if (!/^[A-Za-z0-9_-]+$/u.test(normalized)) {
    throw new Error(`${field} contains invalid characters`);
  }
  return normalized;
}

function text(value: unknown, field: string, minimum: number, maximum: number): string {
  if (typeof value !== "string") {
    throw new Error(`${field} must be text`);
  }
  const normalized = value.trim();
  if (normalized.length < minimum || normalized.length > maximum || /[\0\r\n]/u.test(normalized)) {
    throw new Error(`${field} length must be ${minimum}..${maximum}`);
  }
  return normalized;
}

function finiteRange(value: unknown, field: string, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new Error(`${field} must be in ${minimum}..${maximum}`);
  }
  return value;
}

function timestamp(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error(`${field} must be a non-negative epoch millisecond integer`);
  }
  return value as number;
}

function boundedInteger(
  value: unknown,
  field: string,
  minimum: number,
  maximum: number,
): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new Error(`${field} must be in ${minimum}..${maximum}`);
  }
  return value as number;
}
