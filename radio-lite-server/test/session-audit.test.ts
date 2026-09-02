import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { AuditLog } from "../src/auth/audit-log.ts";
import { parseCookieHeader, SessionStore } from "../src/auth/session-store.ts";
import type { PublicUser } from "../src/auth/user-store.ts";

function user(): PublicUser {
  return {
    id: "user-1",
    username: "connor",
    role: "admin",
    canTransmit: true,
    enabled: true,
    mustChangePassword: false,
    authRevision: 1,
    createdAtMs: 0,
    updatedAtMs: 0,
    lastLoginAtMs: null,
  };
}

test("browser sessions use opaque cookies, bound CSRF and bounded lifetimes", () => {
  let now = 1_000;
  const sessions = new SessionStore({
    now: () => now,
    tokenFactory: () => "s".repeat(43),
    csrfKey: Buffer.alloc(32, 4),
    inactivityMs: 1_000,
    absoluteLifetimeMs: 3_000,
    touchIntervalMs: 500,
  });
  const created = sessions.create(user());
  assert.equal(created.token, "s".repeat(43));
  assert.equal(sessions.validateCsrf(created.token, created.csrfToken), true);
  assert.equal(sessions.validateCsrf(created.token, "wrong"), false);
  assert.equal(sessions.resolve(created.token, user())?.userId, "user-1");

  now = 1_600;
  assert.equal(sessions.resolve(created.token, user())?.inactivityExpiresAtMs, 2_600);
  now = 2_600;
  assert.equal(sessions.resolve(created.token, user()), null);
  assert.equal(sessions.size, 0);
});

test("auth revision and account disablement revoke otherwise-valid sessions", () => {
  const sessions = new SessionStore({ tokenFactory: () => "a".repeat(43) });
  const account = user();
  const created = sessions.create(account);
  assert.equal(sessions.resolve(created.token, { ...account, authRevision: 2 }), null);

  const second = new SessionStore({ tokenFactory: () => "b".repeat(43) });
  const token = second.create(account).token;
  assert.equal(second.resolve(token, { ...account, enabled: false }), null);
});

test("cookie parsing ignores malformed and duplicate fields", () => {
  const cookies = parseCookieHeader("rr_session=first; broken; rr_session=second; theme=dark");
  assert.equal(cookies.get("rr_session"), "first");
  assert.equal(cookies.get("theme"), "dark");
});

test("audit JSONL serializes concurrent events and rejects secret-bearing metadata", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-audit-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "audit.jsonl");
  const audit = new AuditLog(path);
  await Promise.all([
    audit.append({ occurredAtMs: 1, action: "auth.login", result: "success", actorUserId: "u1" }),
    audit.append({ occurredAtMs: 2, action: "radio.ptt", result: "success", actorUserId: "u1" }),
  ]);
  const lines = (await readFile(path, "utf8")).trim().split(/\r?\n/u)
    .map((line) => JSON.parse(line));
  assert.deepEqual(lines.map((line) => line.action), ["auth.login", "radio.ptt"]);
  assert.deepEqual((await audit.readNewest()).map((event) => event.occurredAtMs), [2, 1]);
  await assert.rejects(
    audit.append({
      occurredAtMs: 3,
      action: "auth.login",
      result: "failure",
      metadata: { access_token: "must-not-log" },
    }),
    /prohibited/u,
  );
});
