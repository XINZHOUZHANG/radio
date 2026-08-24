import { randomBytes } from "node:crypto";

export type TransmitMode = "voice" | "digital" | "tuning";
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
};

export type TransmitDriver = {
  activate(mode: TransmitMode): Promise<void>;
  deactivate(mode: TransmitMode): Promise<void>;
  emergencyOff(): Promise<void>;
};

export type TransmitInterlockOptions = {
  heartbeatTimeoutMs?: number;
  hardLimitsMs?: Partial<Record<TransmitMode, number>>;
  now?: () => number;
  tokenFactory?: () => string;
};

export class InterlockConflictError extends Error {}
export class InvalidLeaseError extends Error {}

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
    };
  }

  async startupSafe(): Promise<void> {
    return this.#serialize(async () => {
      try {
        await this.#driver.emergencyOff();
        this.#state = "idle";
        this.#lease = null;
        this.#faultReason = null;
      } catch (error) {
        this.#state = "fault";
        this.#lease = null;
        this.#faultReason = `startup PTT OFF failed: ${errorMessage(error)}`;
        throw error;
      }
    });
  }

  async start(ownerId: string, mode: TransmitMode): Promise<TransmitLease> {
    if (!ownerId) {
      throw new Error("transmit owner is required");
    }
    return this.#serialize(async () => {
      if (this.#state !== "idle") {
        throw new InterlockConflictError(`cannot start ${mode} while state is ${this.#state}`);
      }
      const now = this.#now();
      try {
        await this.#driver.activate(mode);
      } catch (error) {
        await this.#emergencyAfterFailure(`failed to start ${mode}: ${errorMessage(error)}`);
        throw error;
      }
      const lease: TransmitLease = {
        leaseToken: this.#tokenFactory(),
        ownerId,
        mode,
        startedAtMs: now,
        heartbeatDeadlineMs: now + this.#heartbeatTimeoutMs,
        hardDeadlineMs: now + this.#hardLimitsMs[mode],
      };
      this.#state = mode;
      this.#lease = lease;
      this.#faultReason = null;
      return { ...lease };
    });
  }

  async heartbeat(ownerId: string, leaseToken: string): Promise<TransmitLease> {
    return this.#serialize(async () => {
      const lease = this.#requireLease(ownerId, leaseToken);
      const now = this.#now();
      if (now >= lease.heartbeatDeadlineMs || now >= lease.hardDeadlineMs) {
        await this.#stopActive("heartbeat arrived after transmit deadline");
        throw new InvalidLeaseError("transmit lease has expired");
      }
      lease.heartbeatDeadlineMs = Math.min(
        now + this.#heartbeatTimeoutMs,
        lease.hardDeadlineMs,
      );
      return { ...lease };
    });
  }

  async stop(ownerId: string, leaseToken: string): Promise<void> {
    return this.#serialize(async () => {
      this.#requireLease(ownerId, leaseToken);
      await this.#stopActive("released by owner");
    });
  }

  async ownerDisconnected(ownerId: string): Promise<boolean> {
    return this.#serialize(async () => {
      if (this.#lease?.ownerId !== ownerId) {
        return false;
      }
      await this.#stopActive("owner disconnected");
      return true;
    });
  }

  async checkDeadlines(): Promise<"heartbeat_timeout" | "hard_limit" | null> {
    return this.#serialize(async () => {
      const lease = this.#lease;
      if (lease === null) {
        return null;
      }
      const now = this.#now();
      if (now >= lease.hardDeadlineMs) {
        await this.#stopActive("continuous transmit hard limit reached");
        return "hard_limit";
      }
      if (now >= lease.heartbeatDeadlineMs) {
        await this.#stopActive("transmit heartbeat timed out");
        return "heartbeat_timeout";
      }
      return null;
    });
  }

  async trip(reason: string): Promise<void> {
    if (!reason.trim()) {
      throw new Error("fault reason is required");
    }
    return this.#serialize(async () => {
      const activeMode = this.#lease?.mode;
      try {
        if (activeMode !== undefined) {
          await this.#driver.deactivate(activeMode);
        }
        await this.#driver.emergencyOff();
      } finally {
        this.#lease = null;
        this.#state = "fault";
        this.#faultReason = reason;
      }
    });
  }

  async clearFault(): Promise<void> {
    return this.#serialize(async () => {
      if (this.#state !== "fault") {
        return;
      }
      await this.#driver.emergencyOff();
      this.#state = "idle";
      this.#faultReason = null;
    });
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

  async #stopActive(reason: string): Promise<void> {
    const lease = this.#lease;
    if (lease === null) {
      return;
    }
    try {
      await this.#driver.deactivate(lease.mode);
      await this.#driver.emergencyOff();
      this.#state = "idle";
      this.#lease = null;
      this.#faultReason = null;
    } catch (error) {
      await this.#emergencyAfterFailure(`${reason}; PTT OFF failed: ${errorMessage(error)}`);
      throw error;
    }
  }

  async #emergencyAfterFailure(reason: string): Promise<void> {
    try {
      await this.#driver.emergencyOff();
    } catch (emergencyError) {
      reason = `${reason}; emergency PTT OFF failed: ${errorMessage(emergencyError)}`;
    }
    this.#state = "fault";
    this.#lease = null;
    this.#faultReason = reason;
  }

  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

function positiveDuration(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
