import { randomBytes } from "node:crypto";

export type ControlLease = {
  token: string;
  ownerId: string;
  userId: string;
  acquiredAtMs: number;
  expiresAtMs: number;
};

export type ControlAcquireResult = {
  lease: ControlLease;
  displacedOwnerId: string | null;
};

export type ControlLeaseOptions = {
  now?: () => number;
  leaseDurationMs?: number;
  tokenFactory?: () => string;
};

export class ControlBusyError extends Error {
  readonly ownerId: string;

  constructor(ownerId: string) {
    super("radio control is held by another operator");
    this.ownerId = ownerId;
  }
}

export class InvalidControlLeaseError extends Error {}

export class ControlLeaseManager {
  readonly #now: () => number;
  readonly #leaseDurationMs: number;
  readonly #tokenFactory: () => string;
  #lease: ControlLease | null = null;

  constructor(options: ControlLeaseOptions = {}) {
    this.#now = options.now ?? Date.now;
    this.#leaseDurationMs = positiveInteger(
      options.leaseDurationMs ?? 30_000,
      "control lease duration",
    );
    this.#tokenFactory = options.tokenFactory ?? (() => randomBytes(32).toString("base64url"));
  }

  acquire(
    ownerId: string,
    userId: string,
    options: { administrator: boolean; force?: boolean },
  ): ControlAcquireResult {
    if (!ownerId || !userId) {
      throw new Error("control owner and user are required");
    }
    this.#expireIfNeeded();
    const existing = this.#lease;
    if (existing !== null && existing.ownerId !== ownerId) {
      if (!(options.administrator && options.force === true)) {
        throw new ControlBusyError(existing.ownerId);
      }
    }
    const now = this.#now();
    if (existing?.ownerId === ownerId) {
      existing.expiresAtMs = now + this.#leaseDurationMs;
      return { lease: { ...existing }, displacedOwnerId: null };
    }
    const token = this.#tokenFactory();
    if (!/^[A-Za-z0-9_-]{32,128}$/u.test(token)) {
      throw new Error("control token factory returned an unsafe or too-short token");
    }
    const lease: ControlLease = {
      token,
      ownerId,
      userId,
      acquiredAtMs: now,
      expiresAtMs: now + this.#leaseDurationMs,
    };
    this.#lease = lease;
    return {
      lease: { ...lease },
      displacedOwnerId: existing?.ownerId ?? null,
    };
  }

  heartbeat(ownerId: string, token: string): ControlLease {
    const lease = this.#require(ownerId, token);
    lease.expiresAtMs = this.#now() + this.#leaseDurationMs;
    return { ...lease };
  }

  assertValid(ownerId: string, token: string): ControlLease {
    return { ...this.#require(ownerId, token) };
  }

  release(ownerId: string, token?: string): boolean {
    this.#expireIfNeeded();
    if (
      this.#lease === null ||
      this.#lease.ownerId !== ownerId ||
      (token !== undefined && this.#lease.token !== token)
    ) {
      return false;
    }
    this.#lease = null;
    return true;
  }

  snapshot(): Omit<ControlLease, "token"> | null {
    this.#expireIfNeeded();
    if (this.#lease === null) {
      return null;
    }
    const { token: _token, ...safe } = this.#lease;
    return { ...safe };
  }

  #require(ownerId: string, token: string): ControlLease {
    this.#expireIfNeeded();
    if (this.#lease === null || this.#lease.ownerId !== ownerId || this.#lease.token !== token) {
      throw new InvalidControlLeaseError("invalid or expired radio control lease");
    }
    return this.#lease;
  }

  #expireIfNeeded(): void {
    if (this.#lease !== null && this.#now() >= this.#lease.expiresAtMs) {
      this.#lease = null;
    }
  }
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}
