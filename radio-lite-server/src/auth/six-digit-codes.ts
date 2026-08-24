import { createHmac, randomBytes, randomInt, timingSafeEqual } from "node:crypto";

export type CodePurpose = "initial_setup" | "device_pairing";

export type IssuedCode = {
  code: string;
  expiresAtMs: number;
};

type CodeRecord = {
  digest: Buffer;
  purpose: CodePurpose;
  subjectId: string;
  expiresAtMs: number;
};

type FailureBucket = {
  failures: number;
  windowStartedAtMs: number;
  blockedUntilMs: number;
};

export type SixDigitCodeVaultOptions = {
  now?: () => number;
  codeFactory?: () => number;
  hmacKey?: Buffer;
  maxFailures?: number;
  failureWindowMs?: number;
  blockMs?: number;
};

export class InvalidOrExpiredCodeError extends Error {}

export class CodeRateLimitError extends Error {
  readonly retryAfterMs: number;

  constructor(retryAfterMs: number) {
    super("too many invalid code attempts");
    this.retryAfterMs = retryAfterMs;
  }
}

export class SixDigitCodeVault {
  readonly #now: () => number;
  readonly #codeFactory: () => number;
  readonly #hmacKey: Buffer;
  readonly #maxFailures: number;
  readonly #failureWindowMs: number;
  readonly #blockMs: number;
  readonly #records = new Map<string, CodeRecord>();
  readonly #failures = new Map<string, FailureBucket>();

  constructor(options: SixDigitCodeVaultOptions = {}) {
    this.#now = options.now ?? Date.now;
    this.#codeFactory = options.codeFactory ?? (() => randomInt(0, 1_000_000));
    this.#hmacKey = options.hmacKey ?? randomBytes(32);
    if (this.#hmacKey.length < 32) {
      throw new Error("six-digit code HMAC key must be at least 32 bytes");
    }
    this.#maxFailures = positiveInteger(options.maxFailures ?? 5, "max failures");
    this.#failureWindowMs = positiveInteger(
      options.failureWindowMs ?? 5 * 60_000,
      "failure window",
    );
    this.#blockMs = positiveInteger(options.blockMs ?? 15 * 60_000, "block duration");
  }

  issue(subjectId: string, purpose: CodePurpose, ttlMs: number): IssuedCode {
    if (!subjectId.trim()) {
      throw new Error("code subject is required");
    }
    positiveInteger(ttlMs, "code lifetime");
    this.#discardExpired();
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const numeric = this.#codeFactory();
      if (!Number.isSafeInteger(numeric) || numeric < 0 || numeric > 999_999) {
        throw new Error("code factory must return an integer in 0..999999");
      }
      const code = String(numeric).padStart(6, "0");
      const digest = this.#digest(code, purpose);
      const key = digest.toString("hex");
      if (this.#records.has(key)) {
        continue;
      }
      const expiresAtMs = this.#now() + ttlMs;
      this.#records.set(key, { digest, purpose, subjectId, expiresAtMs });
      return { code, expiresAtMs };
    }
    throw new Error("unable to allocate a unique six-digit code");
  }

  redeem(code: string, purpose: CodePurpose, sourceKey: string): string {
    if (!sourceKey.trim()) {
      throw new Error("code attempt source is required");
    }
    const now = this.#now();
    this.#discardExpired();
    const bucket = this.#activeBucket(sourceKey, now);
    if (bucket.blockedUntilMs > now) {
      throw new CodeRateLimitError(bucket.blockedUntilMs - now);
    }
    const digest = /^\d{6}$/u.test(code) ? this.#digest(code, purpose) : null;
    let matchedKey: string | null = null;
    let matched: CodeRecord | null = null;
    if (digest !== null) {
      for (const [key, record] of this.#records) {
        if (
          record.purpose === purpose &&
          record.digest.length === digest.length &&
          timingSafeEqual(record.digest, digest)
        ) {
          matchedKey = key;
          matched = record;
          break;
        }
      }
    }
    if (matched === null || matchedKey === null || matched.expiresAtMs <= now) {
      this.#recordFailure(sourceKey, bucket, now);
      throw new InvalidOrExpiredCodeError("invalid or expired six-digit code");
    }
    this.#records.delete(matchedKey);
    this.#failures.delete(sourceKey);
    return matched.subjectId;
  }

  invalidateSubject(subjectId: string, purpose?: CodePurpose): number {
    let removed = 0;
    for (const [key, record] of this.#records) {
      if (record.subjectId === subjectId && (purpose === undefined || record.purpose === purpose)) {
        this.#records.delete(key);
        removed += 1;
      }
    }
    return removed;
  }

  get activeCount(): number {
    this.#discardExpired();
    return this.#records.size;
  }

  #digest(code: string, purpose: CodePurpose): Buffer {
    return createHmac("sha256", this.#hmacKey)
      .update("radio-lite-code\0", "utf8")
      .update(purpose, "utf8")
      .update("\0", "utf8")
      .update(code, "ascii")
      .digest();
  }

  #activeBucket(sourceKey: string, now: number): FailureBucket {
    const existing = this.#failures.get(sourceKey);
    if (existing === undefined || now - existing.windowStartedAtMs >= this.#failureWindowMs) {
      const fresh = { failures: 0, windowStartedAtMs: now, blockedUntilMs: 0 };
      this.#failures.set(sourceKey, fresh);
      return fresh;
    }
    return existing;
  }

  #recordFailure(sourceKey: string, bucket: FailureBucket, now: number): void {
    bucket.failures += 1;
    if (bucket.failures >= this.#maxFailures) {
      bucket.blockedUntilMs = now + this.#blockMs;
    }
    this.#failures.set(sourceKey, bucket);
  }

  #discardExpired(): void {
    const now = this.#now();
    for (const [key, record] of this.#records) {
      if (record.expiresAtMs <= now) {
        this.#records.delete(key);
      }
    }
  }
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}
