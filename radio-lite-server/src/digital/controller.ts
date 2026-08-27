import { randomUUID } from "node:crypto";

import type { PublicUser } from "../auth/user-store.ts";
import type { RadioProfile } from "../config/types.ts";
import type { AdifLogStore, QsoLogRecord } from "../log/adif-log-store.ts";
import type { RadioRuntime } from "../rig/radio-runtime.ts";
import type { DeKeyOutcome } from "../safety/dekey.ts";
import { AutoQsoSession, type AutoQsoSnapshot } from "./auto-qso.ts";
import {
  addDigitalCallFromDecode,
  DigitalCallQueue,
  type AddDigitalCall,
  type DigitalCallQueueEntry,
  type DigitalCallQueueSnapshot,
} from "./call-queue.ts";
import { DigitalDecodeStore } from "./decode-store.ts";
import { UtcSlotScheduler } from "./slot-scheduler.ts";
import { oppositeSlotParity, slotParityAt } from "./slots.ts";
import type {
  DigitalDecodeBatch,
  DigitalDecodeBatchInput,
  DigitalDecodeSnapshot,
} from "./types.ts";
import type {
  DigitalWorker,
  PreparedDigitalTransmission,
} from "./worker.ts";

export type DigitalControlContext = {
  ownerId: string;
  controlToken: string;
  user: PublicUser;
};

export type DigitalControllerEvent =
  | { t: "digital.decode.batch"; radioId: string; batch: DigitalDecodeBatch }
  | { t: "digital.queue"; radioId: string; queue: DigitalCallQueueSnapshot }
  | { t: "digital.qso"; radioId: string; qso: AutoQsoSnapshot }
  | {
      t: "digital.tx.scheduled";
      radioId: string;
      queueEntryId: string;
      slotStartMs: number;
      message: string;
    }
  | {
      t: "digital.tx.started" | "digital.tx.stopped";
      radioId: string;
      queueEntryId: string;
      slotStartMs: number;
    }
  | { t: "digital.log.created"; radioId: string; record: QsoLogRecord }
  | { t: "digital.error"; radioId: string; code: string; message: string };

export type DigitalSlotScheduler = {
  schedule(
    mode: "FT8" | "FT4",
    parity: "even" | "odd",
    callback: (slotStartMs: number) => void | Promise<void>,
  ): number;
  cancel(): void;
};

export type DigitalRadioControllerOptions = {
  profile: RadioProfile;
  runtime: () => Promise<RadioRuntime>;
  worker: DigitalWorker;
  logStore: AdifLogStore;
  decodeStore?: DigitalDecodeStore;
  queue?: DigitalCallQueue;
  scheduler?: DigitalSlotScheduler;
  now?: () => number;
  requestIdFactory?: () => string;
  heartbeatIntervalMs?: number;
  onEvent?: (event: DigitalControllerEvent) => void;
};

type EntryContext = {
  ownerId: string;
  controlToken: string;
  user: PublicUser;
};

type ActiveTransmission = {
  ownerId: string;
  transmitToken: string;
  slotStartMs: number;
  abort: AbortController;
};

export class DigitalRadioController {
  readonly #profile: RadioProfile;
  readonly #runtime: () => Promise<RadioRuntime>;
  readonly #worker: DigitalWorker;
  readonly #logStore: AdifLogStore;
  readonly #decodes: DigitalDecodeStore;
  readonly #queue: DigitalCallQueue;
  readonly #scheduler: DigitalSlotScheduler;
  readonly #now: () => number;
  readonly #requestIdFactory: () => string;
  readonly #heartbeatIntervalMs: number;
  readonly #onEvent: (event: DigitalControllerEvent) => void;
  readonly #contexts = new Map<string, EntryContext>();
  #session: AutoQsoSession | null = null;
  #lastTransmissionSlotMs: number | null = null;
  #preparedGeneration = 0;
  #activeTransmission: ActiveTransmission | null = null;
  #initialized = false;
  #closed = false;
  #workerFaulted = false;
  #dekeyBlocked = false;
  #tail: Promise<void> = Promise.resolve();

  constructor(options: DigitalRadioControllerOptions) {
    this.#profile = options.profile;
    this.#runtime = options.runtime;
    this.#worker = options.worker;
    this.#logStore = options.logStore;
    this.#decodes = options.decodeStore ?? new DigitalDecodeStore();
    this.#queue = options.queue ?? new DigitalCallQueue(options.profile.id, { now: options.now });
    this.#now = options.now ?? Date.now;
    this.#requestIdFactory = options.requestIdFactory ?? (() => `encode_${randomUUID()}`);
    this.#heartbeatIntervalMs = boundedInteger(
      options.heartbeatIntervalMs ?? 2_000,
      "heartbeatIntervalMs",
      250,
      5_000,
    );
    this.#onEvent = options.onEvent ?? (() => undefined);
    this.#scheduler = options.scheduler ?? new UtcSlotScheduler({
      now: this.#now,
      onError: (error) => this.#emitError("slot_callback_failed", error),
    });
  }

  async initialize(): Promise<void> {
    if (this.#initialized) {
      return;
    }
    this.#assertOpen();
    await this.#worker.start({
      decoded: (input) => {
        void this.acceptDecoded(input).catch((error) => this.#emitError("decode_batch_rejected", error));
      },
      fault: (error) => {
        void this.#serialize(() => this.#handleWorkerFault(error));
      },
    });
    this.#initialized = true;
  }

  decodeSnapshot(limit?: number): DigitalDecodeSnapshot {
    return this.#decodes.snapshot(this.#profile.id, limit);
  }

  queueSnapshot(): DigitalCallQueueSnapshot {
    return this.#queue.snapshot();
  }

  qsoSnapshot(): AutoQsoSnapshot | null {
    return this.#session?.snapshot() ?? null;
  }

  enqueueManual(
    context: DigitalControlContext,
    input: Omit<AddDigitalCall, "ownerId">,
  ): Promise<{ entry: DigitalCallQueueEntry; created: boolean }> {
    return this.#serialize(async () => {
      await this.#assertContext(context);
      const added = this.#queue.add({ ...input, ownerId: context.ownerId });
      if (added.created) {
        this.#contexts.set(added.entry.id, cloneContext(context));
        this.#emitQueue();
        await this.#ensureActive();
      }
      return added;
    });
  }

  enqueueDecode(
    context: DigitalControlContext,
    decodeId: string,
  ): Promise<{ entry: DigitalCallQueueEntry; created: boolean }> {
    return this.#serialize(async () => {
      await this.#assertContext(context);
      const batch = this.#decodes.snapshot(this.#profile.id).batches.find(
        (candidate) => candidate.decodes.some((decode) => decode.id === decodeId),
      );
      if (batch === undefined) {
        throw new Error("selected decode is no longer available");
      }
      const added = addDigitalCallFromDecode(
        this.#queue,
        context.ownerId,
        batch,
        decodeId,
        this.#profile.station.callsign,
      );
      if (added.created) {
        this.#contexts.set(added.entry.id, cloneContext(context));
        this.#emitQueue();
        await this.#ensureActive();
      }
      return added;
    });
  }

  skip(context: DigitalControlContext): Promise<DigitalCallQueueEntry | null> {
    return this.#serialize(async () => {
      await this.#assertContext(context);
      await this.#stopCurrentSession("skipped by operator", "keep");
      const next = this.#queue.skipActive();
      this.#emitQueue();
      await this.#activateEntry(next);
      return next;
    });
  }

  remove(context: DigitalControlContext, entryId: string): Promise<DigitalCallQueueEntry | null> {
    return this.#serialize(async () => {
      await this.#assertContext(context);
      const activeId = this.#queue.snapshot().activeId;
      if (activeId === entryId) {
        await this.#stopCurrentSession("removed by operator", "keep");
      }
      const removed = this.#queue.remove(entryId);
      if (removed !== null) {
        this.#contexts.delete(removed.id);
        this.#emitQueue();
      }
      await this.#ensureActive();
      return removed;
    });
  }

  stop(context: DigitalControlContext, requeue = false): Promise<AutoQsoSnapshot | null> {
    return this.#serialize(async () => {
      await this.#assertContext(context);
      const stopped = await this.#stopCurrentSession(
        "stopped by operator",
        requeue ? "requeue" : "remove",
      );
      this.#emitQueue();
      if (!requeue) {
        await this.#ensureActive();
      }
      return stopped;
    });
  }

  acceptDecoded(input: DigitalDecodeBatchInput): Promise<DigitalDecodeBatch> {
    let committed!: DigitalDecodeBatch;
    return this.#serialize(async () => {
      committed = this.#decodes.commit(input);
      this.#onEvent({
        t: "digital.decode.batch",
        radioId: this.#profile.id,
        batch: committed,
      });
      const session = this.#session;
      if (session === null || committed.mode !== session.snapshot().mode) {
        return committed;
      }
      let accepted = false;
      for (const decode of committed.decodes) {
        if (session.ingest(committed, decode)) {
          accepted = true;
          break;
        }
      }
      if (accepted) {
        this.#emitQso();
        await this.#prepareNextTransmission();
        return committed;
      }
      const snapshot = session.snapshot();
      const isReceiveSlot = slotParityAt(committed.mode, committed.slotStartMs)
        === oppositeSlotParity(snapshot.txParity);
      if (
        isReceiveSlot &&
        this.#lastTransmissionSlotMs !== null &&
        committed.slotStartMs > this.#lastTransmissionSlotMs &&
        (snapshot.phase === "awaiting_report" || snapshot.phase === "awaiting_final")
      ) {
        const afterTimeout = session.receiveSlotClosed(committed.receivedAtMs);
        this.#emitQso();
        if (afterTimeout.phase === "failed") {
          await this.#finishFailedSession();
        } else {
          await this.#prepareNextTransmission();
        }
      }
      return committed;
    }).then(() => committed);
  }

  ownerDisconnected(ownerId: string): Promise<void> {
    return this.#ownerEnded(ownerId, false);
  }

  /** Cleanup-only path for a control takeover that already confirmed PTT OFF. */
  ownerStoppedWithProof(ownerId: string): Promise<void> {
    return this.#ownerEnded(ownerId, true);
  }

  #ownerEnded(ownerId: string, pttOffConfirmed: boolean): Promise<void> {
    return this.#serialize(async () => {
      const active = this.#queue.snapshot().entries.find((entry) => entry.status === "active");
      if (active?.ownerId === ownerId) {
        await this.#stopCurrentSession(
          "control connection disconnected",
          "keep",
          pttOffConfirmed,
        );
      }
      for (const removed of this.#queue.clearOwner(ownerId)) {
        this.#contexts.delete(removed.id);
      }
      if (pttOffConfirmed) {
        this.#dekeyBlocked = false;
      }
      this.#emitQueue();
      await this.#ensureActive();
    });
  }

  async close(): Promise<void> {
    if (this.#closed) {
      return;
    }
    this.#closed = true;
    this.#preparedGeneration += 1;
    this.#scheduler.cancel();
    this.#session?.stop(this.#now());
    this.#activeTransmission?.abort.abort();
    await this.#worker.stopTransmission().catch(() => undefined);
    await this.#dekeyActiveTransmission().catch(() => undefined);
    await this.#worker.close();
  }

  async #assertContext(context: DigitalControlContext): Promise<void> {
    this.#assertReady();
    if (!context.user.enabled || !context.user.canTransmit) {
      throw new Error("account is not permitted to run automatic digital transmission");
    }
    if (!this.#profile.hardwareTxEnabled && this.#profile.hamlibModelId !== 1) {
      throw new Error("hardware transmission is disabled for this radio");
    }
    if (this.#profile.station.grid === undefined) {
      throw new Error("station grid is required for automatic FT8/FT4 QSO");
    }
    const runtime = await this.#runtime();
    const lease = runtime.control.assertValid(context.ownerId, context.controlToken);
    if (lease.userId !== context.user.id) {
      throw new Error("control lease belongs to a different account");
    }
  }

  async #ensureActive(): Promise<void> {
    if (this.#session !== null || this.#workerFaulted || this.#dekeyBlocked) {
      return;
    }
    await this.#activateEntry(this.#queue.activateNext());
  }

  async #activateEntry(entry: DigitalCallQueueEntry | null): Promise<void> {
    if (entry === null) {
      return;
    }
    const context = this.#contexts.get(entry.id);
    if (context === undefined) {
      this.#queue.remove(entry.id);
      this.#emitQueue();
      await this.#ensureActive();
      return;
    }
    const runtime = await this.#runtime();
    runtime.control.assertValid(context.ownerId, context.controlToken);
    const rigState = await runtime.readState();
    this.#session = new AutoQsoSession({
      entry,
      myCallsign: this.#profile.station.callsign,
      myGrid: this.#profile.station.grid!,
      dialFrequencyHz: rigState.frequencyHz,
      startedAtMs: this.#now(),
      now: this.#now,
    });
    this.#lastTransmissionSlotMs = null;
    this.#emitQueue();
    this.#emitQso();
    await this.#prepareNextTransmission();
  }

  async #prepareNextTransmission(): Promise<void> {
    const session = this.#session;
    const snapshot = session?.snapshot();
    if (
      session === null ||
      snapshot === undefined ||
      snapshot.outboundMessage === null ||
      this.#dekeyBlocked
    ) {
      return;
    }
    const generation = ++this.#preparedGeneration;
    this.#scheduler.cancel();
    const prepared = await this.#worker.prepare({
      requestId: safeRequestId(this.#requestIdFactory()),
      radioId: this.#profile.id,
      mode: snapshot.mode,
      message: snapshot.outboundMessage,
      audioFrequencyHz: snapshot.audioFrequencyHz,
    });
    validatePrepared(
      prepared,
      snapshot.radioId,
      snapshot.mode,
      snapshot.outboundMessage,
      snapshot.audioFrequencyHz,
    );
    const latest = this.#session?.snapshot();
    if (
      generation !== this.#preparedGeneration ||
      latest?.queueEntryId !== snapshot.queueEntryId ||
      latest.outboundMessage !== snapshot.outboundMessage ||
      this.#dekeyBlocked
    ) {
      return;
    }
    const slotStartMs = this.#scheduler.schedule(
      snapshot.mode,
      snapshot.txParity,
      (slot) => this.#runTransmission(generation, prepared, snapshot.queueEntryId, slot),
    );
    this.#onEvent({
      t: "digital.tx.scheduled",
      radioId: this.#profile.id,
      queueEntryId: snapshot.queueEntryId,
      slotStartMs,
      message: snapshot.outboundMessage,
    });
  }

  async #runTransmission(
    generation: number,
    prepared: PreparedDigitalTransmission,
    queueEntryId: string,
    slotStartMs: number,
  ): Promise<void> {
    const session = this.#session;
    const snapshot = session?.snapshot();
    if (
      session === null ||
      snapshot === undefined ||
      generation !== this.#preparedGeneration ||
      snapshot.queueEntryId !== queueEntryId ||
      snapshot.outboundMessage !== prepared.message ||
      this.#activeTransmission !== null ||
      this.#dekeyBlocked
    ) {
      return;
    }
    const context = this.#contexts.get(queueEntryId);
    if (context === undefined) {
      await this.#serialize(() => this.#finishFailedSession("digital control context was lost"));
      return;
    }
    let transmitToken: string | null = null;
    let heartbeatFailure: unknown = null;
    let heartbeatBusy = false;
    let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
    try {
      const runtime = await this.#runtime();
      const lease = await runtime.startTransmit(
        context.ownerId,
        context.user,
        context.controlToken,
        "digital",
      );
      transmitToken = lease.leaseToken;
      const abort = new AbortController();
      this.#activeTransmission = {
        ownerId: context.ownerId,
        transmitToken,
        slotStartMs,
        abort,
      };
      this.#onEvent({
        t: "digital.tx.started",
        radioId: this.#profile.id,
        queueEntryId,
        slotStartMs,
      });
      heartbeatTimer = setInterval(() => {
        if (heartbeatBusy || this.#activeTransmission?.transmitToken !== transmitToken) {
          return;
        }
        heartbeatBusy = true;
        void runtime.heartbeatTransmit(context.ownerId, context.controlToken, transmitToken!)
          .catch((error) => {
            heartbeatFailure = error;
            abort.abort();
            void this.#worker.stopTransmission().catch(() => undefined);
          })
          .finally(() => { heartbeatBusy = false; });
      }, this.#heartbeatIntervalMs);
      heartbeatTimer.unref();
      await this.#worker.transmit(prepared, abort.signal);
      if (heartbeatFailure !== null) {
        throw heartbeatFailure;
      }
      const dekey = await this.#dekeyActiveTransmission();
      if (dekey?.kind !== "offConfirmed") {
        throw dekeyOutcomeError(dekey);
      }
      this.#lastTransmissionSlotMs = slotStartMs;
      const state = session.recordTransmission(slotStartMs, this.#now());
      this.#emitQso();
      if (state.phase === "complete") {
        const saved = await this.#logStore.append(session.toLogRecord());
        this.#onEvent({
          t: "digital.log.created",
          radioId: this.#profile.id,
          record: saved.record,
        });
        this.#queue.finishActive();
        this.#contexts.delete(queueEntryId);
        this.#session = null;
        this.#lastTransmissionSlotMs = null;
        this.#emitQueue();
        await this.#ensureActive();
      }
    } catch (error) {
      await this.#worker.stopTransmission().catch(() => undefined);
      await this.#dekeyActiveTransmission().catch(() => undefined);
      const latest = this.#session?.snapshot();
      if (
        latest?.queueEntryId === queueEntryId &&
        generation === this.#preparedGeneration &&
        latest.phase !== "stopped"
      ) {
        await this.#serialize(() => this.#finishFailedSession(errorMessage(error)));
      }
    } finally {
      if (heartbeatTimer !== null) {
        clearInterval(heartbeatTimer);
      }
      if (transmitToken !== null && this.#activeTransmission?.transmitToken === transmitToken) {
        await this.#dekeyActiveTransmission().catch(() => undefined);
      }
      this.#onEvent({
        t: "digital.tx.stopped",
        radioId: this.#profile.id,
        queueEntryId,
        slotStartMs,
      });
    }
  }

  async #stopCurrentSession(
    reason: string,
    disposition: "keep" | "requeue" | "remove",
    pttOffConfirmed = false,
  ): Promise<AutoQsoSnapshot | null> {
    const session = this.#session;
    if (session === null) {
      return null;
    }
    this.#preparedGeneration += 1;
    this.#scheduler.cancel();
    this.#activeTransmission?.abort.abort();
    await this.#worker.stopTransmission().catch(() => undefined);
    if (pttOffConfirmed) {
      this.#activeTransmission = null;
    } else {
      await this.#dekeyActiveTransmission().catch(() => undefined);
    }
    const stopped = session.stop(this.#now());
    this.#emitQso();
    const entryId = stopped.queueEntryId;
    this.#session = null;
    this.#lastTransmissionSlotMs = null;
    if (disposition === "requeue") {
      this.#queue.stopActive(true);
    } else if (disposition === "remove") {
      this.#queue.stopActive(false);
      this.#contexts.delete(entryId);
    }
    return stopped;
  }

  async #finishFailedSession(reason?: string): Promise<void> {
    const session = this.#session;
    if (session === null) {
      return;
    }
    if (reason !== undefined && session.snapshot().phase !== "failed") {
      session.workerFailed(reason, this.#now());
    }
    const snapshot = session.snapshot();
    this.#preparedGeneration += 1;
    this.#scheduler.cancel();
    this.#queue.finishActive();
    this.#contexts.delete(snapshot.queueEntryId);
    this.#session = null;
    this.#lastTransmissionSlotMs = null;
    this.#emitQsoSnapshot(snapshot);
    this.#emitQueue();
    this.#emitError("auto_qso_failed", snapshot.failureReason ?? "automatic QSO failed");
    await this.#ensureActive();
  }

  async #handleWorkerFault(error: unknown): Promise<void> {
    if (this.#workerFaulted || this.#closed) {
      return;
    }
    this.#workerFaulted = true;
    this.#preparedGeneration += 1;
    this.#scheduler.cancel();
    this.#activeTransmission?.abort.abort();
    await this.#worker.stopTransmission().catch(() => undefined);
    await this.#dekeyActiveTransmission().catch(() => undefined);
    const session = this.#session;
    if (session !== null) {
      session.workerFailed(errorMessage(error), this.#now());
      this.#emitQso();
      this.#session = null;
      this.#queue.stopActive(true);
      this.#emitQueue();
    }
    this.#emitError("digital_worker_failed", error);
  }

  async #dekeyActiveTransmission(): Promise<DeKeyOutcome | null> {
    const active = this.#activeTransmission;
    if (active === null) {
      return null;
    }
    this.#activeTransmission = null;
    try {
      const runtime = await this.#runtime();
      const outcome = await runtime.stopTransmitOutcome(active.ownerId, active.transmitToken);
      if (outcome.kind !== "offConfirmed") {
        this.#dekeyBlocked = true;
        this.#scheduler.cancel();
        await this.#worker.stopTransmission().catch(() => undefined);
        this.#emitError("digital_ptt_off_failed", dekeyOutcomeError(outcome));
      }
      return outcome;
    } catch (error) {
      this.#dekeyBlocked = true;
      this.#scheduler.cancel();
      await this.#worker.stopTransmission().catch(() => undefined);
      this.#emitError("digital_ptt_off_failed", error);
      throw error;
    }
  }

  #emitQueue(): void {
    this.#onEvent({ t: "digital.queue", radioId: this.#profile.id, queue: this.#queue.snapshot() });
  }

  #emitQso(): void {
    const snapshot = this.#session?.snapshot();
    if (snapshot !== undefined) {
      this.#emitQsoSnapshot(snapshot);
    }
  }

  #emitQsoSnapshot(qso: AutoQsoSnapshot): void {
    this.#onEvent({ t: "digital.qso", radioId: this.#profile.id, qso });
  }

  #emitError(code: string, error: unknown): void {
    this.#onEvent({
      t: "digital.error",
      radioId: this.#profile.id,
      code,
      message: errorMessage(error),
    });
  }

  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }

  #assertReady(): void {
    this.#assertOpen();
    if (!this.#initialized) {
      throw new Error("digital controller is not initialized");
    }
    if (this.#workerFaulted) {
      throw new Error("digital worker is unavailable");
    }
  }

  #assertOpen(): void {
    if (this.#closed) {
      throw new Error("digital controller is closed");
    }
  }
}

function cloneContext(value: DigitalControlContext): EntryContext {
  return { ownerId: value.ownerId, controlToken: value.controlToken, user: { ...value.user } };
}

function safeRequestId(value: string): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{1,128}$/u.test(value)) {
    throw new Error("digital request id is invalid");
  }
  return value;
}

function validatePrepared(
  prepared: PreparedDigitalTransmission,
  radioId: string,
  mode: "FT8" | "FT4",
  message: string,
  audioFrequencyHz: number,
): void {
  if (
    prepared.radioId !== radioId ||
    prepared.mode !== mode ||
    prepared.message !== message ||
    !Number.isSafeInteger(prepared.sampleRate) ||
    prepared.sampleRate < 8_000 ||
    prepared.sampleRate > 96_000 ||
    !Number.isSafeInteger(prepared.durationMs) ||
    prepared.durationMs < 1 ||
    prepared.durationMs > 20_000 ||
    prepared.audioFrequencyHz !== audioFrequencyHz
  ) {
    throw new Error("digital worker returned an invalid prepared transmission");
  }
}

function boundedInteger(value: unknown, field: string, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new Error(`${field} must be in ${minimum}..${maximum}`);
  }
  return value as number;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function dekeyOutcomeError(outcome: Exclude<DeKeyOutcome, { kind: "offConfirmed" }> | null): Error {
  if (outcome === null) {
    return new Error("digital PTT OFF could not be attributed to an active transmission");
  }
  if (outcome.kind === "recoveryPending") {
    return new Error(
      `digital PTT OFF remains unconfirmed; recovery generation ${outcome.generation} is pending`,
    );
  }
  return new Error(
    `digital stop caller is not responsible for PTT state in generation ${outcome.generation}`,
  );
}
