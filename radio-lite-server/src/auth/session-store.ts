import { createHmac, createHash, randomBytes, timingSafeEqual } from "node:crypto";

import type { PublicUser } from "./user-store.ts";

export type BrowserSession = {
  id: string;
  userId: string;
  authRevision: number;
  createdAtMs: number;
  lastSeenAtMs: number;
  absoluteExpiresAtMs: number;
  inactivityExpiresAtMs: number;
};

export type NewBrowserSession = {
  token: string;
  csrfToken: string;
  session: BrowserSession;
};

export type SessionStoreOptions = {
  now?: () => number;
  tokenFactory?: () => string;
  csrfKey?: Buffer;
  inactivityMs?: number;
  absoluteLifetimeMs?: number;
  touchIntervalMs?: number;
};

type InternalSession = BrowserSession & {
  tokenDigest: string;
};

export class SessionStore {
  readonly #now: () => number;
  readonly #tokenFactory: () => string;
  readonly #csrfKey: Buffer;
  readonly #inactivityMs: number;
  readonly #absoluteLifetimeMs: number;
  readonly #touchIntervalMs: number;
  readonly #sessions = new Map<string, InternalSession>();

  constructor(options: SessionStoreOptions = {}) {
    this.#now = options.now ?? Date.now;
    this.#tokenFactory = options.tokenFactory ?? (() => randomBytes(32).toString("base64url"));
    this.#csrfKey = options.csrfKey ?? randomBytes(32);
    if (this.#csrfKey.length < 32) {
      throw new Error("CSRF key must be at least 32 bytes");
    }
    this.#inactivityMs = positiveInteger(options.inactivityMs ?? 30 * 60_000, "session inactivity");
    this.#absoluteLifetimeMs = positiveInteger(
      options.absoluteLifetimeMs ?? 12 * 60 * 60_000,
      "absolute session lifetime",
    );
    this.#touchIntervalMs = positiveInteger(options.touchIntervalMs ?? 60_000, "session touch interval");
  }

  create(user: PublicUser): NewBrowserSession {
    const now = this.#now();
    const token = this.#newToken();
    const tokenDigest = digestToken(token);
    const session: InternalSession = {
      id: randomBytes(16).toString("base64url"),
      userId: user.id,
      authRevision: user.authRevision,
      createdAtMs: now,
      lastSeenAtMs: now,
      absoluteExpiresAtMs: now + this.#absoluteLifetimeMs,
      inactivityExpiresAtMs: now + this.#inactivityMs,
      tokenDigest,
    };
    this.#sessions.set(tokenDigest, session);
    return {
      token,
      csrfToken: this.csrfToken(token),
      session: publicSession(session),
    };
  }

  resolve(token: string, user: PublicUser | undefined): BrowserSession | null {
    const digest = safeDigestToken(token);
    if (digest === null) {
      return null;
    }
    const session = this.#sessions.get(digest);
    const now = this.#now();
    if (
      session === undefined ||
      user === undefined ||
      !user.enabled ||
      user.authRevision !== session.authRevision ||
      now >= session.absoluteExpiresAtMs ||
      now >= session.inactivityExpiresAtMs
    ) {
      if (session !== undefined) {
        this.#sessions.delete(digest);
      }
      return null;
    }
    if (now - session.lastSeenAtMs >= this.#touchIntervalMs) {
      session.lastSeenAtMs = now;
      session.inactivityExpiresAtMs = Math.min(
        now + this.#inactivityMs,
        session.absoluteExpiresAtMs,
      );
    }
    return publicSession(session);
  }

  validateCsrf(token: string, presented: string): boolean {
    if (typeof presented !== "string" || presented.length > 128) {
      return false;
    }
    const expected = Buffer.from(this.csrfToken(token), "utf8");
    const actual = Buffer.from(presented, "utf8");
    return expected.length === actual.length && timingSafeEqual(expected, actual);
  }

  csrfToken(token: string): string {
    return createHmac("sha256", this.#csrfKey)
      .update("radio-lite-csrf\0", "utf8")
      .update(token, "utf8")
      .digest("base64url");
  }

  candidateUserId(token: string): string | null {
    const digest = safeDigestToken(token);
    return digest === null ? null : (this.#sessions.get(digest)?.userId ?? null);
  }

  revoke(token: string): boolean {
    const digest = safeDigestToken(token);
    return digest === null ? false : this.#sessions.delete(digest);
  }

  revokeUser(userId: string): number {
    let count = 0;
    for (const [digest, session] of this.#sessions) {
      if (session.userId === userId) {
        this.#sessions.delete(digest);
        count += 1;
      }
    }
    return count;
  }

  get size(): number {
    return this.#sessions.size;
  }

  #newToken(): string {
    const token = this.#tokenFactory();
    if (!/^[A-Za-z0-9_-]{32,128}$/u.test(token)) {
      throw new Error("session token factory returned an unsafe or too-short token");
    }
    return token;
  }
}

export function parseCookieHeader(header: string | undefined): Map<string, string> {
  const cookies = new Map<string, string>();
  if (header === undefined || header.length > 8_192) {
    return cookies;
  }
  for (const pair of header.split(";")) {
    const separator = pair.indexOf("=");
    if (separator <= 0) {
      continue;
    }
    const name = pair.slice(0, separator).trim();
    const value = pair.slice(separator + 1).trim();
    if (/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/u.test(name) && !cookies.has(name)) {
      cookies.set(name, value);
    }
  }
  return cookies;
}

function publicSession(session: InternalSession): BrowserSession {
  const { tokenDigest: _tokenDigest, ...safe } = session;
  return { ...safe };
}

function digestToken(token: string): string {
  return createHash("sha256").update("radio-lite-session\0", "utf8").update(token, "utf8").digest("hex");
}

function safeDigestToken(token: string): string | null {
  return typeof token === "string" && /^[A-Za-z0-9_-]{32,128}$/u.test(token)
    ? digestToken(token)
    : null;
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}
