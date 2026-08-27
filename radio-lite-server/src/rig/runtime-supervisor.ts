import { randomUUID } from "node:crypto";

import type { DeKeyOutcome, DeKeyTransport } from "../safety/dekey.ts";
import {
  type SafetyOwnerCursor,
  SafetyEventHub,
} from "../safety/safety-event-hub.ts";
import {
  type InterlockSnapshot,
  TransmitInterlock,
  type TransmitLease,
  type TransmitMode,
} from "../safety/transmit-interlock.ts";
import type { ManagedRigctldExit } from "./managed-process.ts";

export type { ManagedRigctldExit } from "./managed-process.ts";

export type TransmitStartReservation = Readonly<{
  radioId: string;
  ownerId: string;
  userId: string;
  mode: TransmitMode;
  controlLeaseRevision: number;
  profileRevision: number;
}>;

export type TransmitStartPermit = Readonly<TransmitStartReservation & {
  admissionGeneration: number;
  permitId: string;
}>;

export class RigRuntimeSupervisorCleanupUncertainError extends Error {}

export interface RigRuntimeSupervisorContract {
  startupObserve(): Promise<void>;
  snapshot(): InterlockSnapshot;
  reserveTransmitStart(input: TransmitStartReservation): Promise<TransmitStartPermit>;
  commitTransmitStart(
    permit: TransmitStartPermit,
    revalidate: () => void | Promise<void>,
  ): Promise<TransmitLease>;
  abandonTransmitStart(permit: TransmitStartPermit, reason: string): void;
  invalidateTransmitStarts(reason: string): void;
  heartbeat(ownerId: string, token: string): Promise<TransmitLease>;
  checkDeadlines(): Promise<"heartbeat_timeout" | "hard_limit" | null>;
  stop(ownerId: string, token: string, reason: string): Promise<DeKeyOutcome>;
  ownerDisconnected(ownerId: string, reason: string): Promise<DeKeyOutcome>;
  emergencyStop(reason: string): Promise<DeKeyOutcome>;
  notifyManagedExit(exit: ManagedRigctldExit): Promise<void>;
  close(): Promise<void>;
}

export type RigRuntimeSupervisorOptions = {
  radioId: string;
  interlock: TransmitInterlock;
  safetyEvents: SafetyEventHub;
  recoveryTransport: (generation: number) => DeKeyTransport;
  startManaged?: () => Promise<void>;
  restartManaged?: (recoveryGeneration: number, exit: ManagedRigctldExit) => Promise<void>;
  closeManaged?: () => Promise<void>;
  now?: () => number;
  permitIdFactory?: () => string;
  schedule?: (callback: () => void, delayMs: number) => ReturnType<typeof setTimeout>;
  cancelScheduled?: (handle: ReturnType<typeof setTimeout>) => void;
  maximumBackoffMs?: number;
  escalationAfterMs?: number;
};

export class RigRuntimeSupervisor implements RigRuntimeSupervisorContract {
  readonly #radioId: string;
  readonly #interlock: TransmitInterlock;
  readonly #safetyEvents: SafetyEventHub;
  readonly #recoveryTransport: (generation: number) => DeKeyTransport;
  readonly #startManaged: () => Promise<void>;
  readonly #restartManaged: (
    recoveryGeneration: number,
    exit: ManagedRigctldExit,
  ) => Promise<void>;
  readonly #closeManaged: () => Promise<void>;
  readonly #now: () => number;
  readonly #permitIdFactory: () => string;
  readonly #schedule: (
    callback: () => void,
    delayMs: number,
  ) => ReturnType<typeof setTimeout>;
  readonly #cancelScheduled: (handle: ReturnType<typeof setTimeout>) => void;
  readonly #maximumBackoffMs: number;
  readonly #escalationAfterMs: number;

  #admissionGeneration = 1;
  #pendingPermit: TransmitStartPermit | null = null;
  #activeCommitPermit: TransmitStartPermit | null = null;
  #activeCommitActivationStarted = false;
  #commitPromise: Promise<TransmitLease> | null = null;
  #recoveryGeneration = 0;
  #recoveryAttempt: { generation: number; promise: Promise<void> } | null = null;
  #recoveryTimer: ReturnType<typeof setTimeout> | null = null;
  #escalationTimer: ReturnType<typeof setTimeout> | null = null;
  #retryDelayMs = 100;
  #transmitCursor: SafetyOwnerCursor | null = null;
  #transmitAlert: "active" | "dekey_required" | "dekey_escalated" | null = null;
  #escalated = false;
  #lastExit: ManagedRigctldExit | null = null;
  #linkUnavailable = false;
  #lastInvalidatedCommitOutcome: DeKeyOutcome | null = null;
  #handledProcessGenerations = new Map<number, Promise<void>>();
  #latestProcessGeneration = 0;
  #closed = false;
  #closePromise: Promise<void> | null = null;
  #startupPromise: Promise<void> | null = null;
  #startupInFlight: Promise<void> | null = null;

  constructor(options: RigRuntimeSupervisorOptions) {
    if (!options.radioId) throw new Error("radioId is required");
    this.#radioId = options.radioId;
    this.#interlock = options.interlock;
    this.#safetyEvents = options.safetyEvents;
    this.#recoveryTransport = options.recoveryTransport;
    this.#startManaged = options.startManaged ?? (async () => undefined);
    this.#restartManaged = options.restartManaged ?? (async () => undefined);
    this.#closeManaged = options.closeManaged ?? (async () => undefined);
    this.#now = options.now ?? Date.now;
    this.#permitIdFactory = options.permitIdFactory ?? randomUUID;
    this.#schedule = options.schedule ?? ((callback, delayMs) => setTimeout(callback, delayMs));
    this.#cancelScheduled = options.cancelScheduled ?? clearTimeout;
    this.#maximumBackoffMs = positiveInteger(options.maximumBackoffMs ?? 2_000, "maximumBackoffMs");
    this.#escalationAfterMs = positiveInteger(options.escalationAfterMs ?? 30_000, "escalationAfterMs");
  }

  get recoveryGeneration(): number { return this.#recoveryGeneration; }
  get hasScheduledRecovery(): boolean { return this.#recoveryTimer !== null; }

  snapshot(): InterlockSnapshot { return this.#interlock.snapshot(); }

  startupObserve(): Promise<void> {
    this.#assertOpen();
    if (this.#startupPromise === null) {
      const work = (async () => {
        await this.#startManaged();
        this.#assertOpen();
        await this.#interlock.startupObserve();
        this.#assertOpen();
      })();
      this.#startupPromise = work;
      this.#startupInFlight = work;
      const clear = () => {
        if (this.#startupInFlight === work) this.#startupInFlight = null;
      };
      void work.then(clear, clear);
    }
    return this.#startupPromise;
  }

  async reserveTransmitStart(
    input: TransmitStartReservation,
  ): Promise<TransmitStartPermit> {
    this.#assertOpen();
    if (input.radioId !== this.#radioId) throw new Error("transmit reservation radio mismatch");
    const snapshot = this.#interlock.snapshot();
    if (this.#linkUnavailable) {
      throw new Error("managed link is unavailable");
    }
    if (
      snapshot.state !== "idle" ||
      snapshot.lease !== null ||
      snapshot.dekeyRequired ||
      this.#transmitCursor !== null
    ) {
      throw new Error(
        `transmit_start_busy: cannot start ${input.mode} while state is ${snapshot.state}`,
      );
    }
    if (this.#pendingPermit !== null || this.#commitPromise !== null) {
      throw new Error("transmit_start_busy");
    }
    const permit: TransmitStartPermit = Object.freeze({
      ...input,
      admissionGeneration: this.#admissionGeneration,
      permitId: this.#permitIdFactory(),
    });
    this.#pendingPermit = permit;
    return permit;
  }

  commitTransmitStart(
    permit: TransmitStartPermit,
    revalidate: () => void | Promise<void>,
  ): Promise<TransmitLease> {
    this.#assertOpen();
    if (this.#commitPromise !== null) return Promise.reject(new Error("transmit_start_busy"));
    this.#activeCommitPermit = permit;
    this.#activeCommitActivationStarted = false;
    const work = this.#commit(permit, revalidate);
    this.#commitPromise = work;
    void work.then(
      () => {
        if (this.#commitPromise === work) this.#commitPromise = null;
        if (this.#activeCommitPermit === permit) this.#activeCommitPermit = null;
        this.#activeCommitActivationStarted = false;
      },
      () => {
        if (this.#commitPromise === work) this.#commitPromise = null;
        if (this.#activeCommitPermit === permit) this.#activeCommitPermit = null;
        this.#activeCommitActivationStarted = false;
      },
    );
    return work;
  }

  abandonTransmitStart(permit: TransmitStartPermit, _reason: string): void {
    if (this.#samePermit(permit)) this.#pendingPermit = null;
  }

  invalidateTransmitStarts(reason: string): void {
    this.#admissionGeneration += 1;
    this.#pendingPermit = null;
    const activation = this.#activeCommitPermit;
    if (
      activation !== null &&
      this.#activeCommitActivationStarted &&
      this.#interlock.requireDeKey(reason, activation.mode)
    ) {
      this.#ensureRecovery(reason, false);
    }
  }

  async heartbeat(ownerId: string, token: string): Promise<TransmitLease> {
    const before = this.#interlock.snapshot().lease;
    const exactLease = before?.ownerId === ownerId && before.leaseToken === token;
    try {
      return await this.#interlock.heartbeat(ownerId, token);
    } catch (error) {
      const snapshot = this.#interlock.snapshot();
      if (snapshot.dekeyRequired) {
        this.#ensureRecovery("transmit heartbeat failed", false);
      } else if (exactLease && snapshot.lease === null) {
        // An exact active lease can disappear through heartbeat() only after
        // that method's own OFF write and real OFF read-back succeeded.
        this.#clearTransmitAlert(this.#recoveryGeneration);
      }
      throw error;
    }
  }

  async checkDeadlines(): Promise<"heartbeat_timeout" | "hard_limit" | null> {
    try {
      const result = await this.#interlock.checkDeadlines();
      if (result !== null) {
        this.#clearTransmitAlert(this.#recoveryGeneration);
      }
      return result;
    } catch (error) {
      if (this.#interlock.snapshot().dekeyRequired) {
        this.#ensureRecovery("transmit deadline de-key failed", false);
      }
      throw error;
    }
  }

  async stop(ownerId: string, token: string, _reason: string): Promise<DeKeyOutcome> {
    this.invalidateTransmitStarts("stop");
    const outcome = await this.#interlock.stopOutcome(ownerId, token);
    await this.#consumeDeKeyOutcome(outcome);
    return outcome;
  }

  async ownerDisconnected(ownerId: string, reason: string): Promise<DeKeyOutcome> {
    const initial = this.#interlock.snapshot();
    const ownsLease = initial.lease?.ownerId === ownerId;
    const ownsPending = this.#pendingPermit?.ownerId === ownerId;
    const ownsCommit = this.#activeCommitPermit?.ownerId === ownerId;
    if (!ownsLease && !ownsPending && !ownsCommit) {
      if (initial.dekeyRequired) {
        this.#ensureRecovery(reason, false);
        return { kind: "recoveryPending", generation: this.#recoveryGeneration };
      }
      return { kind: "notResponsible", generation: this.#recoveryGeneration };
    }

    this.#lastInvalidatedCommitOutcome = null;
    this.invalidateTransmitStarts(reason);
    if (ownsCommit && this.#activeCommitActivationStarted) {
      const generation = this.#recoveryGeneration;
      await this.#attemptRecovery(generation);
      if (generation !== this.#recoveryGeneration) {
        return this.#interlock.snapshot().dekeyRequired
          ? { kind: "recoveryPending", generation: this.#recoveryGeneration }
          : { kind: "notResponsible", generation: this.#recoveryGeneration };
      }
      if (!this.#interlock.snapshot().dekeyRequired) {
        return { kind: "offConfirmed", generation };
      }
      return { kind: "recoveryPending", generation };
    }
    if (ownsCommit) {
      return { kind: "notResponsible", generation: this.#recoveryGeneration };
    }

    const lease = this.#interlock.snapshot().lease;
    if (lease?.ownerId === ownerId) {
      return this.stop(ownerId, lease.leaseToken, reason);
    }
    if (this.#interlock.snapshot().dekeyRequired) {
      this.#ensureRecovery(reason, false);
      return { kind: "recoveryPending", generation: this.#recoveryGeneration };
    }
    return { kind: "notResponsible", generation: this.#recoveryGeneration };
  }

  async emergencyStop(reason: string): Promise<DeKeyOutcome> {
    this.#lastInvalidatedCommitOutcome = null;
    const activationStarted = this.#activeCommitPermit !== null &&
      this.#activeCommitActivationStarted;
    this.invalidateTransmitStarts(reason);
    if (activationStarted) {
      const generation = this.#recoveryGeneration;
      await this.#attemptRecovery(generation);
      if (generation !== this.#recoveryGeneration) {
        return this.#interlock.snapshot().dekeyRequired
          ? { kind: "recoveryPending", generation: this.#recoveryGeneration }
          : { kind: "notResponsible", generation: this.#recoveryGeneration };
      }
      return this.#interlock.snapshot().dekeyRequired
        ? { kind: "recoveryPending", generation }
        : { kind: "offConfirmed", generation };
    }
    if (this.#commitPromise !== null) {
      return { kind: "notResponsible", generation: this.#recoveryGeneration };
    }
    const lease = this.#interlock.snapshot().lease;
    if (lease !== null) return this.stop(lease.ownerId, lease.leaseToken, reason);
    if (this.#interlock.snapshot().dekeyRequired) {
      this.#ensureRecovery(reason, false);
      return { kind: "recoveryPending", generation: this.#recoveryGeneration };
    }
    return { kind: "notResponsible", generation: this.#recoveryGeneration };
  }

  notifyManagedExit(exit: ManagedRigctldExit): Promise<void> {
    if (this.#closed) return Promise.resolve();
    const existing = this.#handledProcessGenerations.get(exit.generation);
    if (existing !== undefined) return existing;
    if (exit.generation < this.#latestProcessGeneration) return Promise.resolve();
    this.#latestProcessGeneration = exit.generation;
    const handling = this.#handleManagedExit(exit);
    this.#handledProcessGenerations.set(exit.generation, handling);
    return handling;
  }

  runDueRecovery(): Promise<void> {
    this.#clearRecoveryTimer();
    this.#clearEscalationTimer();
    if (
      this.#closed ||
      (!this.#linkUnavailable && !this.#interlock.snapshot().dekeyRequired)
    ) return Promise.resolve();
    return this.#attemptRecovery(this.#recoveryGeneration);
  }

  async close(): Promise<void> {
    if (this.#closePromise !== null) return this.#closePromise;
    this.invalidateTransmitStarts("close");
    this.#closed = true;
    this.#clearRecoveryTimer();
    this.#clearEscalationTimer();
    // Retain the recovery that was active at the shutdown boundary. Its
    // finally handler may clear #recoveryAttempt while the first managed close
    // is still pending, but it may also have created a late child by then.
    const recoveryAtClose = this.#recoveryAttempt?.promise;
    const startupAtClose = this.#startupInFlight;
    const closing = (async () => {
      const failures: unknown[] = [];
      const lease = this.#interlock.snapshot().lease;
      if (lease !== null) {
        try {
          const outcome = await this.#interlock.stopOutcome(lease.ownerId, lease.leaseToken);
          if (outcome.kind === "offConfirmed") {
            await this.#consumeDeKeyOutcome(outcome);
          } else {
            failures.push(new Error("PTT OFF remains unconfirmed"));
          }
        } catch (error) {
          failures.push(error);
        }
      } else if (this.#interlock.snapshot().dekeyRequired) {
        try {
          const attempt = await this.#interlock.attemptDeKey(
            this.#recoveryTransport(this.#recoveryGeneration),
            this.#recoveryGeneration,
          );
          if (attempt.confirmed) {
            this.#clearTransmitAlert(attempt.generation);
          } else {
            failures.push(new Error(attempt.reason));
          }
        } catch (error) {
          failures.push(error);
        }
      }
      try {
        await this.#closeManaged();
      } catch (error) {
        failures.push(error);
      }
      if (recoveryAtClose !== undefined) {
        await recoveryAtClose.catch((error) => { failures.push(error); });
      }
      if (startupAtClose !== null) {
        // Shutdown intentionally invalidates startup after startManaged settles.
        // Its caller still observes that rejection; cleanup relies on the final
        // close below instead of treating cancellation as cleanup uncertainty.
        await startupAtClose.catch(() => undefined);
      }
      if (recoveryAtClose !== undefined || startupAtClose !== null) {
        try {
          // A startup or restart callback may have crossed the first close
          // boundary. Close again after both settle so no late child survives.
          await this.#closeManaged();
        } catch (error) {
          failures.push(error);
        }
      }
      await Promise.resolve();
      if (this.#commitPromise !== null) {
        failures.push(new Error("transmit activation did not settle during shutdown"));
      }
      if (this.#interlock.snapshot().dekeyRequired) {
        failures.push(new Error("PTT OFF remains unconfirmed after dependency shutdown"));
      }
      if (failures.length > 0) {
        throw new RigRuntimeSupervisorCleanupUncertainError(
          "runtime supervisor could not confirm cleanup",
          { cause: new AggregateError(failures) },
        );
      }
    })();
    this.#closePromise = closing;
    return closing;
  }

  async #commit(
    permit: TransmitStartPermit,
    revalidate: () => void | Promise<void>,
  ): Promise<TransmitLease> {
    this.#assertPermit(permit);
    try {
      await revalidate();
    } catch (error) {
      if (this.#samePermit(permit)) this.#pendingPermit = null;
      throw error;
    }
    this.#assertPermit(permit);
    // From this point onward a synchronous SafetyEventHub subscriber can
    // re-enter emergencyStop/ownerDisconnected while the active event is being
    // published. Establish OFF responsibility before that callback boundary,
    // then re-check the exact permit after publishing before CAT may write ON.
    this.#activeCommitActivationStarted = true;
    try {
      this.#beginTransmitSafetyEpisode();
      this.#assertPermit(permit);
      this.#pendingPermit = null;
      const lease = await this.#interlock.start(permit.ownerId, permit.mode);
      if (!this.#permitGenerationCurrent(permit)) {
        const outcome = await this.#interlock.stopOutcome(lease.ownerId, lease.leaseToken);
        this.#lastInvalidatedCommitOutcome = outcome;
        await this.#consumeDeKeyOutcome(outcome);
        throw new Error("transmit_start_invalidated");
      }
      return lease;
    } catch (error) {
      if (this.#samePermit(permit)) this.#pendingPermit = null;
      const snapshot = this.#interlock.snapshot();
      if (snapshot.dekeyRequired) {
        this.#ensureRecovery("transmit activation failed", false);
      } else if (snapshot.lease === null) {
        this.#clearTransmitAlert(this.#recoveryGeneration);
      }
      if (!this.#permitGenerationCurrent(permit)) {
        throw new Error("transmit_start_invalidated", { cause: error });
      }
      throw error;
    }
  }

  async #handleManagedExit(exit: ManagedRigctldExit): Promise<void> {
    this.invalidateTransmitStarts("managed_rigctld_exit");
    this.#lastExit = exit;
    this.#linkUnavailable = true;
    const snapshot = this.#interlock.snapshot();
    if (snapshot.lease !== null) {
      // Begin the latch immediately but never await dead-link I/O before restart.
      const evidenceGeneration = this.#recoveryGeneration;
      let tripState: "pending" | "offConfirmed" | "failed" = "pending";
      let exitHandlingComplete = false;
      const trip = this.#interlock.trip("managed rigctld exited");
      void trip.then(
        () => {
          tripState = "offConfirmed";
          if (exitHandlingComplete && !this.#closed) {
            this.#clearTransmitAlert(evidenceGeneration);
          }
        },
        () => {
          tripState = "failed";
          if (
            exitHandlingComplete &&
            !this.#closed &&
            this.#interlock.snapshot().dekeyRequired
          ) {
            this.#ensureRecovery("managed rigctld exited", false);
          }
        },
      );
      const observed = await this.#waitForManagedExitDeKey(() => tripState);
      if (observed === "offConfirmed") {
        this.#clearTransmitAlert(evidenceGeneration);
      }
      exitHandlingComplete = true;
    }
    if (this.#interlock.snapshot().dekeyRequired) {
      this.#ensureRecovery("managed rigctld exited", true);
    } else {
      this.#advanceRecoveryGeneration();
      this.#scheduleRecovery(0);
    }
    void this.#attemptRecovery(this.#recoveryGeneration);
  }

  #beginTransmitSafetyEpisode(): void {
    const version = this.#safetyEvents.ownerVersion(this.#radioId, "transmit");
    let cursor = this.#safetyEvents.beginOwnerGeneration(this.#radioId, "transmit", version);
    if (cursor === null) throw new Error("transmit_safety_generation_conflict");
    // Idle managed-link recovery can advance the interlock generation without an
    // active Hub alert. Catch the Hub owner generation up before publishing so
    // later OFF evidence has one exact generation in both state machines.
    while (cursor.generation <= this.#recoveryGeneration) {
      cursor = this.#safetyEvents.beginOwnerGeneration(this.#radioId, "transmit", cursor);
      if (cursor === null) throw new Error("transmit_safety_generation_conflict");
    }
    this.#recoveryGeneration = cursor.generation;
    this.#interlock.advanceRecoveryGeneration(this.#recoveryGeneration);
    const mutation = this.#safetyEvents.publish(cursor, {
      kind: "active",
      startedAtMs: this.#now(),
      source: "software",
    });
    if (mutation === null) throw new Error("transmit_safety_publish_conflict");
    this.#transmitCursor = mutation.cursor;
    this.#transmitAlert = "active";
    this.#escalated = false;
  }

  async #consumeDeKeyOutcome(outcome: DeKeyOutcome): Promise<void> {
    if (outcome.kind === "offConfirmed") {
      this.#clearRecoveryTimer();
      this.#clearTransmitAlert(outcome.generation);
      return;
    }
    if (this.#interlock.snapshot().dekeyRequired) {
      this.#ensureRecovery("PTT OFF unconfirmed", false);
    }
  }

  #ensureRecovery(_reason: string, advanceGeneration: boolean): void {
    if (!this.#interlock.snapshot().dekeyRequired || this.#closed) return;
    if (advanceGeneration) {
      this.#advanceRecoveryGeneration();
      this.#retryDelayMs = 100;
    }
    this.#publishDeKeyRequired();
    this.#scheduleEscalation();
    this.#scheduleRecovery(0);
  }

  #publishDeKeyRequired(): void {
    if (this.#transmitCursor === null || this.#transmitAlert === "dekey_escalated") return;
    if (this.#transmitAlert === "dekey_required") return;
    const startedAtMs = this.#interlock.snapshot().dekeyStartedAtMs ?? this.#now();
    const mutation = this.#safetyEvents.publish(this.#transmitCursor, {
      kind: "dekey_required",
      startedAtMs,
      source: "software",
    });
    if (mutation !== null) {
      this.#transmitCursor = mutation.cursor;
      this.#transmitAlert = "dekey_required";
    }
  }

  #publishEscalationIfDue(): void {
    if (this.#escalated || this.#transmitCursor === null) return;
    const started = this.#interlock.snapshot().dekeyStartedAtMs;
    if (started === null || this.#now() - started < this.#escalationAfterMs) return;
    const mutation = this.#safetyEvents.publish(this.#transmitCursor, {
      kind: "dekey_escalated",
      startedAtMs: started,
      source: "software",
    });
    if (mutation !== null) {
      this.#transmitCursor = mutation.cursor;
      this.#transmitAlert = "dekey_escalated";
      this.#escalated = true;
      this.#clearEscalationTimer();
    }
  }

  #clearTransmitAlert(evidenceGeneration: number): void {
    const cursor = this.#transmitCursor;
    if (cursor === null) return;
    if (cursor.generation !== evidenceGeneration) return;
    const mutation = this.#safetyEvents.clear(cursor, this.#now(), {
      kind: "ptt_off_confirmed",
      generation: evidenceGeneration,
    });
    if (mutation === null) return;
    this.#transmitCursor = mutation.cursor;
    this.#transmitCursor = null;
    this.#transmitAlert = null;
    this.#escalated = false;
    this.#clearEscalationTimer();
  }

  #attemptRecovery(generation: number): Promise<void> {
    if (this.#closed || generation !== this.#recoveryGeneration) return Promise.resolve();
    this.#publishEscalationIfDue();
    const active = this.#recoveryAttempt;
    if (active?.generation === generation) return active.promise;
    const work = (async () => {
      try {
        await this.#restartManaged(generation, this.#lastExit ?? syntheticExit());
        if (this.#closed || generation !== this.#recoveryGeneration) return;
        this.#linkUnavailable = false;
      } catch {
        if (!this.#closed && generation === this.#recoveryGeneration) {
          this.#linkUnavailable = true;
          this.#scheduleNextRetry();
        }
        return;
      }
      if (!this.#interlock.snapshot().dekeyRequired) {
        this.#retryDelayMs = 100;
        this.#clearRecoveryTimer();
        return;
      }
      let confirmed = false;
      try {
        const attempt = await this.#interlock.attemptDeKey(
          this.#recoveryTransport(generation),
          generation,
        );
        confirmed = attempt.confirmed && attempt.generation === generation;
      } catch {
        confirmed = false;
      }
      if (this.#closed || generation !== this.#recoveryGeneration) return;
      if (confirmed && !this.#interlock.snapshot().dekeyRequired) {
        this.#retryDelayMs = 100;
        this.#clearRecoveryTimer();
        this.#clearTransmitAlert(generation);
        return;
      }
      this.#publishEscalationIfDue();
      this.#scheduleNextRetry();
    })();
    let entry!: { generation: number; promise: Promise<void> };
    const promise = work.finally(() => {
      if (this.#recoveryAttempt === entry) this.#recoveryAttempt = null;
    });
    entry = { generation, promise };
    this.#recoveryAttempt = entry;
    return promise;
  }

  #scheduleRecovery(delayMs: number): void {
    if (
      this.#closed ||
      this.#recoveryTimer !== null ||
      (!this.#linkUnavailable && !this.#interlock.snapshot().dekeyRequired)
    ) return;
    const generation = this.#recoveryGeneration;
    const handle = this.#schedule(() => {
      if (this.#recoveryTimer === handle) this.#recoveryTimer = null;
      void this.#attemptRecovery(generation);
    }, delayMs);
    this.#recoveryTimer = handle;
  }

  #clearRecoveryTimer(): void {
    if (this.#recoveryTimer === null) return;
    this.#cancelScheduled(this.#recoveryTimer);
    this.#recoveryTimer = null;
  }

  #scheduleEscalation(): void {
    if (this.#closed || this.#escalated || this.#escalationTimer !== null) return;
    const startedAtMs = this.#interlock.snapshot().dekeyStartedAtMs;
    if (startedAtMs === null) return;
    const delayMs = Math.max(0, startedAtMs + this.#escalationAfterMs - this.#now());
    const handle = this.#schedule(() => {
      if (this.#escalationTimer === handle) this.#escalationTimer = null;
      this.#publishEscalationIfDue();
    }, delayMs);
    this.#escalationTimer = handle;
  }

  #clearEscalationTimer(): void {
    if (this.#escalationTimer === null) return;
    this.#cancelScheduled(this.#escalationTimer);
    this.#escalationTimer = null;
  }

  #scheduleNextRetry(): void {
    this.#scheduleRecovery(this.#retryDelayMs);
    this.#retryDelayMs = Math.min(this.#maximumBackoffMs, this.#retryDelayMs * 2);
  }

  #advanceRecoveryGeneration(): void {
    // A timer captures the generation at scheduling time. Never let an old
    // timer occupy the single timer slot and suppress the new generation's retry.
    this.#clearRecoveryTimer();
    const cursor = this.#transmitCursor;
    if (cursor !== null) {
      const next = this.#safetyEvents.beginOwnerGeneration(
        this.#radioId,
        "transmit",
        cursor,
      );
      if (next === null) throw new Error("transmit_safety_generation_conflict");
      this.#transmitCursor = next;
      this.#recoveryGeneration = next.generation;
    } else {
      this.#recoveryGeneration += 1;
    }
    this.#interlock.advanceRecoveryGeneration(this.#recoveryGeneration);
  }

  async #waitForManagedExitDeKey(
    tripState: () => "pending" | "offConfirmed" | "failed",
  ): Promise<"latched" | "offConfirmed" | "pending"> {
    for (let attempt = 0; attempt < 100; attempt += 1) {
      if (this.#interlock.snapshot().dekeyRequired) return "latched";
      if (tripState() === "offConfirmed") return "offConfirmed";
      await new Promise<void>((resolve) => setImmediate(resolve));
    }
    return "pending";
  }

  #assertPermit(permit: TransmitStartPermit): void {
    if (!this.#samePermit(permit) || !this.#permitGenerationCurrent(permit)) {
      throw new Error("transmit_start_invalidated");
    }
  }

  #samePermit(permit: TransmitStartPermit): boolean {
    return this.#pendingPermit?.permitId === permit.permitId;
  }

  #permitGenerationCurrent(permit: TransmitStartPermit): boolean {
    return !this.#closed && permit.admissionGeneration === this.#admissionGeneration;
  }

  #assertOpen(): void {
    if (this.#closed) throw new Error("runtime_supervisor_closed");
  }
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value < 1) throw new Error(`${field} must be positive`);
  return value;
}

function syntheticExit(): ManagedRigctldExit {
  return {
    generation: 0,
    exitCode: null,
    signalCode: null,
    stderr: "recovery requested without a managed child exit",
  };
}
