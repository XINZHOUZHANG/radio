import { randomBytes } from "node:crypto";

import type {
  DeKeyAttempt,
  DeKeyMode,
  DeKeyOutcome,
  DeKeyTransport,
} from "./dekey.ts";

export type TransmitMode = DeKeyMode;
export type InterlockState = "idle" | TransmitMode | "fault";

export type TransmitLease = {
  leaseToken: string;
  ownerId: string;
  mode: TransmitMode;
  startedAtMs: number;
  heartbeatDeadlineMs: number;
  hardDeadlineMs: number;
};

export type InterlockSnapshot = {
  state: InterlockState;
  lease: TransmitLease | null;
  faultReason: string | null;
  dekeyRequired: boolean;
  dekeyStartedAtMs: number | null;
};

export type TransmitDriver = DeKeyTransport & {
  activate(mode: TransmitMode): Promise<void>;
};

export type TransmitInterlockOptions = {
  heartbeatTimeoutMs?: number;
  hardLimitsMs?: Partial<Record<TransmitMode, number>>;
  now?: () => number;
  tokenFactory?: () => string;
};

export class InterlockConflictError extends Error {}
export class InvalidLeaseError extends Error {}
export class DeKeyUnconfirmedError extends Error {
  readonly attempt: DeKeyAttempt;

  constructor(
    attempt: DeKeyAttempt & { confirmed: false },
    options: { cause?: unknown } = {},
  ) {
    super(attempt.reason, options.cause === undefined ? undefined : { cause: options.cause });
    this.attempt = attempt;
  }
}

const DEFAULT_LIMITS: Record<TransmitMode, number> = {
  voice: 180_000,
  digital: 30_000,
  tuning: 30_000,
};

export class TransmitInterlock {
  readonly #driver: TransmitDriver;
  readonly #heartbeatTimeoutMs: number;
  readonly #hardLimitsMs: Record<TransmitMode, number>;
  readonly #now: () => number;
  readonly #tokenFactory: () => string;
  #state: InterlockState = "idle";
  #lease: TransmitLease | null = null;
  #faultReason: string | null = null;
  #dekeyRequired = false;
  #dekeyStartedAtMs: number | null = null;
  #dekeyMode: TransmitMode | null = null;
  #latchEpisode = 0;
  #latchRevision = 0;
  #recoveryGeneration = 0;
  #inFlightRecovery: {
    episode: number;
    generation: number;
    promise: Promise<DeKeyAttempt>;
  } | null = null;
  #activation: ActivationRef | null = null;
  #tail: Promise<void> = Promise.resolve();

  constructor(driver: TransmitDriver, options: TransmitInterlockOptions = {}) {
    this.#driver = driver;
    this.#heartbeatTimeoutMs = positiveDuration(
      options.heartbeatTimeoutMs ?? 8_000,
      "heartbeat timeout",
    );
    this.#hardLimitsMs = {
      voice: positiveDuration(options.hardLimitsMs?.voice ?? DEFAULT_LIMITS.voice, "voice limit"),
      digital: positiveDuration(options.hardLimitsMs?.digital ?? DEFAULT_LIMITS.digital, "digital limit"),
      tuning: positiveDuration(options.hardLimitsMs?.tuning ?? DEFAULT_LIMITS.tuning, "tuning limit"),
    };
    this.#now = options.now ?? Date.now;
    this.#tokenFactory = options.tokenFactory ?? (() => randomBytes(32).toString("base64url"));
  }

  snapshot(): InterlockSnapshot {
    return {
      state: this.#state,
      lease: this.#lease === null ? null : { ...this.#lease },
      faultReason: this.#faultReason,
      dekeyRequired: this.#dekeyRequired,
      dekeyStartedAtMs: this.#dekeyStartedAtMs,
    };
  }

  async startupObserve(): Promise<void> {
    const observed = await this.#driver.readPtt();
    if (typeof observed !== "boolean") {
      throw new Error("PTT read-back is malformed");
    }
  }

  advanceRecoveryGeneration(generation: number): "advanced" | "current" | "stale" {
    validateGeneration(generation);
    if (generation < this.#recoveryGeneration) {
      return "stale";
    }
    if (generation === this.#recoveryGeneration) {
      return "current";
    }
    this.#recoveryGeneration = generation;
    if (this.#dekeyRequired) {
      this.#latchRevision += 1;
    }
    return "advanced";
  }

  /**
   * Synchronously claim software responsibility for PTT OFF.
   *
   * This intentionally bypasses the async state tail: a CAT activation may be
   * stuck while the managed link has already failed. The new latch invalidates
   * that activation and lets a replacement transport perform OFF/read-back.
   */
  requireDeKey(reason: string, mode: TransmitMode | null = null): boolean {
    if (!reason.trim()) {
      throw new Error("fault reason is required");
    }
    const activeMode = this.#lease?.mode
      ?? this.#activation?.mode
      ?? this.#dekeyMode
      ?? mode;
    if (activeMode === null && !this.#dekeyRequired) {
      return false;
    }
    this.#beginDeKey(reason, activeMode);
    return true;
  }

  async start(ownerId: string, mode: TransmitMode): Promise<TransmitLease> {
    if (!ownerId) {
      throw new Error("transmit owner is required");
    }
    const activation = await this.#serialize(async () => {
      if (this.#state !== "idle" || this.#dekeyRequired || this.#activation !== null) {
        throw new InterlockConflictError(`cannot start ${mode} while state is ${this.#state}`);
      }
      const now = this.#now();
      const leaseToken = this.#tokenFactory();
      const prepared: ActivationRef = {
        lease: {
          leaseToken,
          ownerId,
          mode,
          startedAtMs: now,
          heartbeatDeadlineMs: now + this.#heartbeatTimeoutMs,
          hardDeadlineMs: now + this.#hardLimitsMs[mode],
        },
        mode,
        cancelled: false,
      };
      this.#activation = prepared;
      return prepared;
    });

    let activationError: unknown = null;
    try {
      await this.#driver.activate(mode);
    } catch (error) {
      activationError = error;
    }

    const outcome = await this.#serialize(async () => {
      const activationCurrent = this.#activation === activation;
      const activationCancelled = activation.cancelled;
      if (activationCurrent) {
        this.#activation = null;
      }
      if (
        !activationCurrent ||
        activationCancelled ||
        this.#dekeyRequired ||
        this.#state !== "idle"
      ) {
        return {
          kind: "activation_cancelled" as const,
          error: activationError,
          attempt: this.#beginDeKey(
            "transmit activation completed after it was cancelled",
            mode,
          ),
        };
      }
      if (activationError !== null) {
        return {
          kind: "activation_failed" as const,
          error: activationError,
          attempt: this.#beginDeKey(
            `failed to start ${mode}: ${errorMessage(activationError)}`,
            mode,
          ),
        };
      }
      const lease = activation.lease;
      this.#state = mode;
      this.#lease = lease;
      this.#faultReason = null;
      return { kind: "started" as const, lease: { ...lease } };
    });
    if (outcome.kind === "started") {
      return outcome.lease;
    }
    const recovery = await this.#completeDeKey(outcome.attempt, this.#driver);
    if (!recovery.confirmed) {
      throw new DeKeyUnconfirmedError(recovery, { cause: outcome.error });
    }
    if (outcome.kind === "activation_failed") {
      throw outcome.error;
    }
    throw new InterlockConflictError("transmit activation was cancelled");
  }

  async heartbeat(ownerId: string, leaseToken: string): Promise<TransmitLease> {
    const outcome = await this.#serialize(async () => {
      const lease = this.#requireLease(ownerId, leaseToken);
      const now = this.#now();
      if (now >= lease.heartbeatDeadlineMs || now >= lease.hardDeadlineMs) {
        return {
          kind: "expired" as const,
          attempt: this.#beginDeKey("heartbeat arrived after transmit deadline", lease.mode),
        };
      }
      lease.heartbeatDeadlineMs = Math.min(
        now + this.#heartbeatTimeoutMs,
        lease.hardDeadlineMs,
      );
      return { kind: "renewed" as const, lease: { ...lease } };
    });
    if (outcome.kind === "renewed") {
      return outcome.lease;
    }
    const recovery = await this.#completeDeKey(outcome.attempt, this.#driver);
    if (!recovery.confirmed) {
      throw new DeKeyUnconfirmedError(recovery);
    }
    throw new InvalidLeaseError("transmit lease has expired");
  }

  async stop(ownerId: string, leaseToken: string): Promise<void> {
    const attempt = await this.#serialize(async () => {
      const lease = this.#requireLease(ownerId, leaseToken);
      return this.#beginDeKey("released by owner", lease.mode);
    });
    const recovery = await this.#completeDeKey(attempt, this.#driver);
    if (!recovery.confirmed) {
      throw new DeKeyUnconfirmedError(recovery);
    }
  }

  /**
   * Outcome-bearing stop adapter for automatic media and digital cleanup.
   *
   * A stale caller token is not physical OFF evidence. If another stop already
   * owns an unresolved de-key episode, report that recovery as pending. If no
   * latch remains, the caller is no longer responsible for the current radio
   * state (for example, a concurrent stop already confirmed OFF).
   */
  async stopOutcome(ownerId: string, leaseToken: string): Promise<DeKeyOutcome> {
    const prepared = await this.#serialize(async () => {
      const lease = this.#lease;
      if (
        lease === null ||
        lease.ownerId !== ownerId ||
        lease.leaseToken !== leaseToken
      ) {
        return {
          kind: "existing" as const,
          outcome: {
            kind: this.#dekeyRequired ? "recoveryPending" : "notResponsible",
            generation: this.#recoveryGeneration,
          } satisfies DeKeyOutcome,
        };
      }
      return {
        kind: "attempt" as const,
        attempt: this.#beginDeKey("released by owner", lease.mode),
      };
    });
    if (prepared.kind === "existing") {
      return prepared.outcome;
    }
    const recovery = await this.#completeDeKey(prepared.attempt, this.#driver);
    return recovery.confirmed
      ? { kind: "offConfirmed", generation: recovery.generation }
      : { kind: "recoveryPending", generation: recovery.generation };
  }

  async ownerDisconnected(ownerId: string): Promise<boolean> {
    const attempt = await this.#serialize(async () => {
      if (this.#lease?.ownerId !== ownerId) {
        return null;
      }
      return this.#beginDeKey("owner disconnected", this.#lease.mode);
    });
    if (attempt === null) {
      return false;
    }
    const recovery = await this.#completeDeKey(attempt, this.#driver);
    if (!recovery.confirmed) {
      throw new DeKeyUnconfirmedError(recovery);
    }
    return true;
  }

  async checkDeadlines(): Promise<"heartbeat_timeout" | "hard_limit" | null> {
    const deadline = await this.#serialize(async () => {
      const lease = this.#lease;
      if (lease === null) {
        return null;
      }
      const now = this.#now();
      if (now >= lease.hardDeadlineMs) {
        return {
          kind: "hard_limit" as const,
          attempt: this.#beginDeKey("continuous transmit hard limit reached", lease.mode),
        };
      }
      if (now >= lease.heartbeatDeadlineMs) {
        return {
          kind: "heartbeat_timeout" as const,
          attempt: this.#beginDeKey("transmit heartbeat timed out", lease.mode),
        };
      }
      return null;
    });
    if (deadline === null) {
      return null;
    }
    const recovery = await this.#completeDeKey(deadline.attempt, this.#driver);
    if (!recovery.confirmed) {
      throw new DeKeyUnconfirmedError(recovery);
    }
    return deadline.kind;
  }

  async trip(reason: string): Promise<void> {
    if (!reason.trim()) {
      throw new Error("fault reason is required");
    }
    const attempt = await this.#serialize(async () => {
      const activeMode = this.#lease?.mode ?? this.#activation?.mode ?? this.#dekeyMode;
      if (activeMode === null && !this.#dekeyRequired) {
        this.#state = "fault";
        this.#faultReason = reason;
        return null;
      }
      return this.#beginDeKey(reason, activeMode);
    });
    if (attempt === null) {
      return;
    }
    const recovery = await this.#completeDeKey(attempt, this.#driver);
    if (!recovery.confirmed) {
      throw new DeKeyUnconfirmedError(recovery);
    }
  }

  async clearFault(): Promise<void> {
    return this.#serialize(async () => {
      if (this.#state !== "fault") {
        return;
      }
      if (this.#dekeyRequired) {
        return;
      }
      this.#state = "idle";
      this.#faultReason = null;
    });
  }

  attemptDeKey(
    transport: DeKeyTransport,
    generation: number,
  ): Promise<DeKeyAttempt> {
    try {
      validateGeneration(generation);
    } catch (error) {
      return Promise.reject(error);
    }
    const generationState = this.advanceRecoveryGeneration(generation);
    if (generationState === "stale") {
      return Promise.resolve({
        confirmed: false,
        generation,
        reason: "recovery generation is stale",
      });
    }
    if (!this.#dekeyRequired) {
      return Promise.resolve({
        confirmed: false,
        generation,
        reason: "de-key is not required",
      });
    }
    const episode = this.#latchEpisode;
    const inFlight = this.#inFlightRecovery;
    if (
      inFlight !== null &&
      inFlight.episode === episode &&
      inFlight.generation === generation
    ) {
      return inFlight.promise;
    }

    const promise = this.#runRecoveryAttempt(transport, generation);
    const entry = { episode, generation, promise };
    this.#inFlightRecovery = entry;
    const clear = () => {
      if (this.#inFlightRecovery === entry) {
        this.#inFlightRecovery = null;
      }
    };
    void promise.then(clear, clear);
    return promise;
  }

  async #runRecoveryAttempt(
    transport: DeKeyTransport,
    generation: number,
  ): Promise<DeKeyAttempt> {
    const prepared = await this.#serialize(async () => {
      if (!this.#dekeyRequired) {
        return null;
      }
      if (generation !== this.#recoveryGeneration) {
        return "stale" as const;
      }
      this.#latchRevision += 1;
      return this.#attemptRef(this.#faultReason ?? "PTT OFF unconfirmed");
    });
    if (prepared === null) {
      return { confirmed: false, generation, reason: "de-key is not required" };
    }
    if (prepared === "stale") {
      return { confirmed: false, generation, reason: "recovery generation is stale" };
    }
    return this.#completeDeKey(prepared, transport);
  }

  #requireLease(ownerId: string, leaseToken: string): TransmitLease {
    if (
      this.#lease === null ||
      this.#lease.ownerId !== ownerId ||
      this.#lease.leaseToken !== leaseToken
    ) {
      throw new InvalidLeaseError("invalid transmit lease");
    }
    return this.#lease;
  }

  async #completeDeKey(
    attempt: DeKeyAttemptRef,
    transport: DeKeyTransport,
  ): Promise<DeKeyAttempt> {
    const io = await executeDeKey(transport, attempt.mode);
    return this.#serialize(async () => this.#finalizeDeKey(attempt, io));
  }

  #beginDeKey(reason: string, mode: TransmitMode | null): DeKeyAttemptRef {
    if (!this.#dekeyRequired) {
      this.#dekeyRequired = true;
      this.#dekeyStartedAtMs = this.#now();
      this.#dekeyMode = mode;
      this.#latchEpisode += 1;
    } else if (this.#dekeyMode === null && mode !== null) {
      this.#dekeyMode = mode;
    }
    this.#state = "fault";
    if (this.#activation !== null) {
      this.#activation.cancelled = true;
    }
    this.#lease = null;
    this.#faultReason = `${reason}; PTT OFF unconfirmed`;
    this.#latchRevision += 1;
    return this.#attemptRef(reason);
  }

  #attemptRef(reason: string): DeKeyAttemptRef {
    return {
      episode: this.#latchEpisode,
      revision: this.#latchRevision,
      generation: this.#recoveryGeneration,
      mode: this.#dekeyMode,
      reason,
    };
  }

  #finalizeDeKey(ref: DeKeyAttemptRef, io: DeKeyIoResult): DeKeyAttempt {
    if (!this.#dekeyRequired || ref.episode !== this.#latchEpisode) {
      return {
        confirmed: false,
        generation: ref.generation,
        reason: "de-key episode was superseded",
      };
    }
    if (
      ref.revision !== this.#latchRevision ||
      ref.generation !== this.#recoveryGeneration
    ) {
      return {
        confirmed: false,
        generation: ref.generation,
        reason: "recovery generation is stale",
      };
    }

    const failureReason = deKeyFailureReason(io);
    if (failureReason !== null) {
      if (io.failures.length > 0) {
        this.#faultReason = `${baseDeKeyReason(ref.reason)}; PTT OFF failed: ${failureReason}`;
      }
      return {
        confirmed: false,
        generation: ref.generation,
        reason: failureReason,
      };
    }

    if (this.#activation?.cancelled === true) {
      return {
        confirmed: false,
        generation: ref.generation,
        reason: "transmit activation cancellation is still pending",
      };
    }

    this.#state = "idle";
    this.#lease = null;
    this.#faultReason = null;
    this.#dekeyRequired = false;
    this.#dekeyStartedAtMs = null;
    this.#dekeyMode = null;
    this.#latchRevision += 1;
    return { confirmed: true, generation: ref.generation };
  }

  #serialize<T>(operation: () => T | Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

type DeKeyAttemptRef = {
  episode: number;
  revision: number;
  generation: number;
  mode: TransmitMode | null;
  reason: string;
};

type ActivationRef = {
  lease: TransmitLease;
  mode: TransmitMode;
  cancelled: boolean;
};

type DeKeyStepFailure = {
  step: "deactivate" | "off-write" | "read-back";
  message: string;
};

type DeKeyIoResult = {
  failures: DeKeyStepFailure[];
  ptt: boolean | null;
};

async function executeDeKey(
  transport: DeKeyTransport,
  mode: TransmitMode | null,
): Promise<DeKeyIoResult> {
  const failures: DeKeyStepFailure[] = [];
  if (mode !== null) {
    try {
      await transport.deactivate(mode);
    } catch (error) {
      failures.push({ step: "deactivate", message: errorMessage(error) });
    }
  }
  try {
    await transport.emergencyOff();
  } catch (error) {
    failures.push({ step: "off-write", message: errorMessage(error) });
  }

  let ptt: boolean | null = null;
  try {
    const observed = await transport.readPtt();
    if (typeof observed !== "boolean") {
      throw new Error("PTT read-back is malformed");
    }
    ptt = observed;
  } catch (error) {
    failures.push({ step: "read-back", message: errorMessage(error) });
  }
  return { failures, ptt };
}

function deKeyFailureReason(io: DeKeyIoResult): string | null {
  if (io.failures.length > 0) {
    return io.failures.map(({ step, message }) => `${step}: ${message}`).join("; ");
  }
  if (io.ptt !== false) {
    return "PTT OFF read-back remained ON";
  }
  return null;
}

function baseDeKeyReason(reason: string): string {
  return reason.replace(/; PTT OFF (?:failed|unconfirmed).*$/u, "");
}

function positiveDuration(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}

function validateGeneration(value: number): void {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error("recovery generation must be a positive safe integer");
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
