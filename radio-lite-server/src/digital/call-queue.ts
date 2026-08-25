import { randomUUID } from "node:crypto";

import { normalizeCallsign, normalizeGrid, parseFtMessage } from "./ft-message.ts";
import { oppositeSlotParity, slotParityAt } from "./slots.ts";
import type {
  DigitalDecodeBatch,
  DigitalMode,
  SlotParity,
} from "./types.ts";

export type DigitalCallQueueEntryStatus = "queued" | "active";

export type DigitalCallQueueEntry = {
  id: string;
  radioId: string;
  ownerId: string;
  targetCallsign: string;
  targetGrid: string | null;
  mode: DigitalMode;
  audioFrequencyHz: number;
  txParity: SlotParity;
  sourceDecodeId: string | null;
  enqueuedAtMs: number;
  status: DigitalCallQueueEntryStatus;
};

export type AddDigitalCall = {
  ownerId: string;
  targetCallsign: string;
  targetGrid?: string;
  mode: DigitalMode;
  audioFrequencyHz: number;
  txParity: SlotParity;
  sourceDecodeId?: string;
};

export type DigitalCallQueueSnapshot = {
  radioId: string;
  revision: number;
  activeId: string | null;
  entries: DigitalCallQueueEntry[];
};

export type DigitalCallQueueOptions = {
  now?: () => number;
  idFactory?: () => string;
  maximumEntries?: number;
};

export class DigitalCallQueue {
  readonly #radioId: string;
  readonly #now: () => number;
  readonly #idFactory: () => string;
  readonly #maximumEntries: number;
  #entries: DigitalCallQueueEntry[] = [];
  #revision = 0;

  constructor(radioId: string, options: DigitalCallQueueOptions = {}) {
    this.#radioId = identifier(radioId, "radioId", 32);
    this.#now = options.now ?? Date.now;
    this.#idFactory = options.idFactory ?? (() => `call_${randomUUID()}`);
    this.#maximumEntries = integer(options.maximumEntries ?? 64, "maximumEntries", 1, 256);
  }

  add(input: AddDigitalCall): { entry: DigitalCallQueueEntry; created: boolean } {
    const ownerId = oneLine(input.ownerId, "ownerId", 128);
    const targetCallsign = normalizeCallsign(input.targetCallsign);
    const targetGrid = input.targetGrid === undefined ? null : normalizeGrid(input.targetGrid);
    const audioFrequencyHz = finite(input.audioFrequencyHz, "audioFrequencyHz", 200, 5_000);
    const txParity = parity(input.txParity);
    const sourceDecodeId = input.sourceDecodeId === undefined
      ? null
      : identifier(input.sourceDecodeId, "sourceDecodeId", 128);
    const duplicate = this.#entries.find(
      (entry) => entry.ownerId === ownerId && entry.mode === input.mode && entry.targetCallsign === targetCallsign,
    );
    if (duplicate !== undefined) {
      return { entry: cloneEntry(duplicate), created: false };
    }
    if (this.#entries.length >= this.#maximumEntries) {
      throw new Error("digital call queue is full");
    }
    const entry: DigitalCallQueueEntry = {
      id: identifier(this.#idFactory(), "queue entry id", 128),
      radioId: this.#radioId,
      ownerId,
      targetCallsign,
      targetGrid,
      mode: input.mode,
      audioFrequencyHz,
      txParity,
      sourceDecodeId,
      enqueuedAtMs: timestamp(this.#now(), "queue timestamp"),
      status: "queued",
    };
    if (this.#entries.some((candidate) => candidate.id === entry.id)) {
      throw new Error("queue entry id is duplicated");
    }
    this.#entries.push(entry);
    this.#revision += 1;
    return { entry: cloneEntry(entry), created: true };
  }

  activateNext(): DigitalCallQueueEntry | null {
    const active = this.#active();
    if (active !== undefined) {
      return cloneEntry(active);
    }
    const next = this.#entries.find((entry) => entry.status === "queued");
    if (next === undefined) {
      return null;
    }
    next.status = "active";
    this.#revision += 1;
    return cloneEntry(next);
  }

  skipActive(): DigitalCallQueueEntry | null {
    const index = this.#entries.findIndex((entry) => entry.status === "active");
    if (index < 0) {
      return this.activateNext();
    }
    const [skipped] = this.#entries.splice(index, 1);
    skipped.status = "queued";
    this.#entries.push(skipped);
    const next = this.#entries.find((entry) => entry.status === "queued");
    if (next !== undefined) {
      next.status = "active";
    }
    this.#revision += 1;
    return next === undefined ? null : cloneEntry(next);
  }

  stopActive(requeue = true): DigitalCallQueueEntry | null {
    const active = this.#active();
    if (active === undefined) {
      return null;
    }
    if (requeue) {
      active.status = "queued";
    } else {
      this.#entries = this.#entries.filter((entry) => entry.id !== active.id);
    }
    this.#revision += 1;
    return cloneEntry(active);
  }

  finishActive(): DigitalCallQueueEntry | null {
    const active = this.#active();
    if (active === undefined) {
      return null;
    }
    this.#entries = this.#entries.filter((entry) => entry.id !== active.id);
    this.#revision += 1;
    return cloneEntry(active);
  }

  remove(entryId: string): DigitalCallQueueEntry | null {
    const normalizedId = identifier(entryId, "entryId", 128);
    const index = this.#entries.findIndex((entry) => entry.id === normalizedId);
    if (index < 0) {
      return null;
    }
    const [removed] = this.#entries.splice(index, 1);
    this.#revision += 1;
    return cloneEntry(removed);
  }

  clearOwner(ownerId: string): DigitalCallQueueEntry[] {
    const normalizedOwnerId = oneLine(ownerId, "ownerId", 128);
    const removed = this.#entries.filter((entry) => entry.ownerId === normalizedOwnerId);
    if (removed.length > 0) {
      this.#entries = this.#entries.filter((entry) => entry.ownerId !== normalizedOwnerId);
      this.#revision += 1;
    }
    return removed.map(cloneEntry);
  }

  snapshot(): DigitalCallQueueSnapshot {
    return {
      radioId: this.#radioId,
      revision: this.#revision,
      activeId: this.#active()?.id ?? null,
      entries: this.#entries.map(cloneEntry),
    };
  }

  #active(): DigitalCallQueueEntry | undefined {
    return this.#entries.find((entry) => entry.status === "active");
  }
}

export function addDigitalCallFromDecode(
  queue: DigitalCallQueue,
  ownerId: string,
  batch: DigitalDecodeBatch,
  decodeId: string,
  stationCallsign: string,
): { entry: DigitalCallQueueEntry; created: boolean } {
  const decoded = batch.decodes.find((candidate) => candidate.id === decodeId);
  if (decoded === undefined) {
    throw new Error("selected decode does not exist in the batch");
  }
  const parsed = parseFtMessage(decoded.message);
  const myCallsign = normalizeCallsign(stationCallsign);
  let targetCallsign: string;
  let targetGrid: string | undefined;
  if (parsed.kind === "cq") {
    targetCallsign = parsed.senderCallsign;
    targetGrid = parsed.grid ?? undefined;
  } else if (
    parsed.kind !== "free_text" &&
    parsed.recipientCallsign === myCallsign &&
    parsed.senderCallsign !== myCallsign
  ) {
    targetCallsign = parsed.senderCallsign;
    targetGrid = parsed.kind === "grid" ? parsed.grid : undefined;
  } else {
    throw new Error("selected decode is not a CQ or a call directed to this station");
  }
  return queue.add({
    ownerId,
    targetCallsign,
    targetGrid,
    mode: batch.mode,
    audioFrequencyHz: decoded.audioFrequencyHz,
    txParity: oppositeSlotParity(slotParityAt(batch.mode, batch.slotStartMs)),
    sourceDecodeId: decoded.id,
  });
}

function cloneEntry(entry: DigitalCallQueueEntry): DigitalCallQueueEntry {
  return { ...entry };
}

function parity(value: unknown): SlotParity {
  if (value !== "even" && value !== "odd") {
    throw new Error("txParity must be even or odd");
  }
  return value;
}

function identifier(value: string, field: string, maximum: number): string {
  const normalized = oneLine(value, field, maximum);
  if (!/^[A-Za-z0-9_-]+$/u.test(normalized)) {
    throw new Error(`${field} contains invalid characters`);
  }
  return normalized;
}

function oneLine(value: string, field: string, maximum: number): string {
  if (typeof value !== "string") {
    throw new Error(`${field} must be text`);
  }
  const normalized = value.trim();
  if (normalized.length < 1 || normalized.length > maximum || /[\0\r\n]/u.test(normalized)) {
    throw new Error(`${field} must be 1..${maximum} characters on one line`);
  }
  return normalized;
}

function finite(value: unknown, field: string, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new Error(`${field} must be in ${minimum}..${maximum}`);
  }
  return value;
}

function integer(value: unknown, field: string, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new Error(`${field} must be in ${minimum}..${maximum}`);
  }
  return value as number;
}

function timestamp(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error(`${field} must be a non-negative epoch millisecond integer`);
  }
  return value as number;
}
