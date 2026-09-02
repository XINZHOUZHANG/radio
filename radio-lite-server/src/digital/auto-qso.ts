import type { NewQso } from "../log/adif-log-store.ts";
import type { DigitalCallQueueEntry } from "./call-queue.ts";
import {
  formatDirectedMessage,
  formatSignalReport,
  normalizeCallsign,
  normalizeGrid,
  parseFtMessage,
} from "./ft-message.ts";
import { isSlotBoundary, slotParityAt } from "./slots.ts";
import type { DigitalDecode, DigitalDecodeBatch } from "./types.ts";

export type AutoQsoPhase =
  | "calling"
  | "awaiting_report"
  | "sending_roger_report"
  | "awaiting_final"
  | "sending_73"
  | "complete"
  | "failed"
  | "stopped";

export type AutoQsoSnapshot = {
  id: string;
  radioId: string;
  queueEntryId: string;
  targetCallsign: string;
  targetGrid: string | null;
  myCallsign: string;
  myGrid: string;
  mode: "FT8" | "FT4";
  dialFrequencyHz: number;
  audioFrequencyHz: number;
  txParity: "even" | "odd";
  phase: AutoQsoPhase;
  outboundMessage: string | null;
  reportSent: string | null;
  reportReceived: string | null;
  callAttempts: number;
  reportAttempts: number;
  finalAttempts: number;
  startedAtMs: number;
  endedAtMs: number | null;
  lastActivityAtMs: number;
  lastInboundMessage: string | null;
  failureReason: string | null;
};

export type AutoQsoOptions = {
  entry: DigitalCallQueueEntry;
  myCallsign: string;
  myGrid: string;
  dialFrequencyHz: number;
  startedAtMs?: number;
  now?: () => number;
  maximumAttemptsPerStage?: number;
};

type SendingPhase = "calling" | "sending_roger_report" | "sending_73";

export class AutoQsoSession {
  readonly #entry: DigitalCallQueueEntry;
  readonly #myCallsign: string;
  readonly #myGrid: string;
  readonly #dialFrequencyHz: number;
  readonly #now: () => number;
  readonly #maximumAttemptsPerStage: number;
  #phase: AutoQsoPhase = "calling";
  #reportSent: string | null = null;
  #reportReceived: string | null = null;
  #callAttempts = 0;
  #reportAttempts = 0;
  #finalAttempts = 0;
  readonly #startedAtMs: number;
  #endedAtMs: number | null = null;
  #lastActivityAtMs: number;
  #lastInboundMessage: string | null = null;
  #failureReason: string | null = null;

  constructor(options: AutoQsoOptions) {
    if (options.entry.status !== "active") {
      throw new Error("automatic QSO requires an active call queue entry");
    }
    this.#entry = { ...options.entry };
    this.#myCallsign = normalizeCallsign(options.myCallsign);
    this.#myGrid = normalizeGrid(options.myGrid).slice(0, 4);
    this.#dialFrequencyHz = positiveInteger(options.dialFrequencyHz, "dialFrequencyHz");
    this.#now = options.now ?? Date.now;
    this.#maximumAttemptsPerStage = integer(
      options.maximumAttemptsPerStage ?? 3,
      "maximumAttemptsPerStage",
      1,
      10,
    );
    this.#startedAtMs = timestamp(options.startedAtMs ?? this.#now(), "startedAtMs");
    this.#lastActivityAtMs = this.#startedAtMs;
  }

  snapshot(): AutoQsoSnapshot {
    return {
      id: `auto_${this.#entry.id}`,
      radioId: this.#entry.radioId,
      queueEntryId: this.#entry.id,
      targetCallsign: this.#entry.targetCallsign,
      targetGrid: this.#entry.targetGrid,
      myCallsign: this.#myCallsign,
      myGrid: this.#myGrid,
      mode: this.#entry.mode,
      dialFrequencyHz: this.#dialFrequencyHz,
      audioFrequencyHz: this.#entry.audioFrequencyHz,
      txParity: this.#entry.txParity,
      phase: this.#phase,
      outboundMessage: this.#outboundMessage(),
      reportSent: this.#reportSent,
      reportReceived: this.#reportReceived,
      callAttempts: this.#callAttempts,
      reportAttempts: this.#reportAttempts,
      finalAttempts: this.#finalAttempts,
      startedAtMs: this.#startedAtMs,
      endedAtMs: this.#endedAtMs,
      lastActivityAtMs: this.#lastActivityAtMs,
      lastInboundMessage: this.#lastInboundMessage,
      failureReason: this.#failureReason,
    };
  }

  recordTransmission(slotStartMs: number, endedAtMs: number): AutoQsoSnapshot {
    const sendingPhase = this.#sendingPhase();
    const normalizedSlotStart = timestamp(slotStartMs, "slotStartMs");
    const normalizedEndedAt = timestamp(endedAtMs, "endedAtMs");
    if (!isSlotBoundary(this.#entry.mode, normalizedSlotStart)) {
      throw new Error("digital transmission is not aligned to a UTC slot boundary");
    }
    if (slotParityAt(this.#entry.mode, normalizedSlotStart) !== this.#entry.txParity) {
      throw new Error("digital transmission used the wrong UTC slot parity");
    }
    if (normalizedEndedAt < normalizedSlotStart) {
      throw new Error("digital transmission end precedes its slot start");
    }
    if (sendingPhase === "calling") {
      this.#callAttempts += 1;
      this.#phase = "awaiting_report";
    } else if (sendingPhase === "sending_roger_report") {
      this.#reportAttempts += 1;
      this.#phase = "awaiting_final";
    } else {
      this.#finalAttempts += 1;
      this.#phase = "complete";
      this.#endedAtMs = normalizedEndedAt;
    }
    this.#lastActivityAtMs = normalizedEndedAt;
    return this.snapshot();
  }

  ingest(batch: DigitalDecodeBatch, decode: DigitalDecode): boolean {
    if (
      batch.radioId !== this.#entry.radioId ||
      batch.mode !== this.#entry.mode ||
      !batch.decodes.some((candidate) => candidate.id === decode.id)
    ) {
      throw new Error("decode does not belong to this automatic QSO radio and batch");
    }
    if (this.#phase !== "awaiting_report" && this.#phase !== "awaiting_final") {
      return false;
    }
    const parsed = parseFtMessage(decode.message);
    if (
      parsed.kind === "cq" ||
      parsed.kind === "free_text" ||
      parsed.senderCallsign !== this.#entry.targetCallsign ||
      parsed.recipientCallsign !== this.#myCallsign
    ) {
      return false;
    }
    if (this.#phase === "awaiting_report" && parsed.kind === "report") {
      this.#reportReceived = formatSignalReport(parsed.report);
      this.#reportSent = formatSignalReport(decode.snrDb);
      this.#phase = "sending_roger_report";
      this.#acceptInbound(parsed.text, batch.receivedAtMs);
      return true;
    }
    if (this.#phase === "awaiting_final") {
      if (parsed.kind === "rrr" || parsed.kind === "rr73" || parsed.kind === "73") {
        this.#phase = "sending_73";
        this.#acceptInbound(parsed.text, batch.receivedAtMs);
        return true;
      }
      if (parsed.kind === "report") {
        this.#reportReceived = formatSignalReport(parsed.report);
        this.#phase = "sending_roger_report";
        this.#acceptInbound(parsed.text, batch.receivedAtMs);
        return true;
      }
    }
    return false;
  }

  receiveSlotClosed(atMs: number): AutoQsoSnapshot {
    const normalizedAt = timestamp(atMs, "atMs");
    if (this.#phase === "awaiting_report") {
      if (this.#callAttempts >= this.#maximumAttemptsPerStage) {
        this.#fail("no signal report received before retry limit", normalizedAt);
      } else {
        this.#phase = "calling";
      }
    } else if (this.#phase === "awaiting_final") {
      if (this.#reportAttempts >= this.#maximumAttemptsPerStage) {
        this.#fail("no RR73/73 received before retry limit", normalizedAt);
      } else {
        this.#phase = "sending_roger_report";
      }
    }
    this.#lastActivityAtMs = normalizedAt;
    return this.snapshot();
  }

  stop(atMs = this.#now()): AutoQsoSnapshot {
    if (this.#terminal()) {
      return this.snapshot();
    }
    const normalizedAt = timestamp(atMs, "atMs");
    this.#phase = "stopped";
    this.#endedAtMs = normalizedAt;
    this.#lastActivityAtMs = normalizedAt;
    return this.snapshot();
  }

  workerFailed(reason: string, atMs = this.#now()): AutoQsoSnapshot {
    if (this.#terminal()) {
      return this.snapshot();
    }
    this.#fail(oneLine(reason, "worker failure reason", 256), timestamp(atMs, "atMs"));
    return this.snapshot();
  }

  toLogRecord(): NewQso {
    if (this.#phase !== "complete" || this.#endedAtMs === null) {
      throw new Error("only a completed automatic QSO can be logged");
    }
    return {
      radioId: this.#entry.radioId,
      source: this.#entry.mode === "FT8" ? "FT8_AUTO" : "FT4_AUTO",
      call: this.#entry.targetCallsign,
      startedAtMs: this.#startedAtMs,
      endedAtMs: this.#endedAtMs,
      frequencyHz: this.#dialFrequencyHz,
      mode: this.#entry.mode,
      rstSent: this.#reportSent ?? undefined,
      rstReceived: this.#reportReceived ?? undefined,
      grid: this.#entry.targetGrid ?? undefined,
      myCall: this.#myCallsign,
      myGrid: this.#myGrid,
    };
  }

  #outboundMessage(): string | null {
    if (this.#phase === "calling") {
      return formatDirectedMessage(
        this.#entry.targetCallsign,
        this.#myCallsign,
        this.#myGrid,
      );
    }
    if (this.#phase === "sending_roger_report") {
      if (this.#reportSent === null) {
        throw new Error("automatic QSO cannot send a report before measuring the target");
      }
      return formatDirectedMessage(
        this.#entry.targetCallsign,
        this.#myCallsign,
        `R${this.#reportSent}`,
      );
    }
    if (this.#phase === "sending_73") {
      return formatDirectedMessage(this.#entry.targetCallsign, this.#myCallsign, "73");
    }
    return null;
  }

  #sendingPhase(): SendingPhase {
    if (
      this.#phase !== "calling" &&
      this.#phase !== "sending_roger_report" &&
      this.#phase !== "sending_73"
    ) {
      throw new Error(`automatic QSO is not ready to transmit while phase is ${this.#phase}`);
    }
    return this.#phase;
  }

  #acceptInbound(message: string, atMs: number): void {
    this.#lastInboundMessage = message;
    this.#lastActivityAtMs = atMs;
  }

  #fail(reason: string, atMs: number): void {
    this.#phase = "failed";
    this.#failureReason = reason;
    this.#endedAtMs = atMs;
    this.#lastActivityAtMs = atMs;
  }

  #terminal(): boolean {
    return this.#phase === "complete" || this.#phase === "failed" || this.#phase === "stopped";
  }
}

function positiveInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value as number;
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
