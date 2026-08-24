import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import {
  hashPassword,
  normalizeNewPassword,
  passwordHashNeedsUpgrade,
  verifyPassword,
} from "../src/auth/password.ts";
import { UserStore } from "../src/auth/user-store.ts";

test("stores and verifies an Argon2id PHC hash without plaintext", async () => {
  const password = "Correct horse battery staple 2026";
  const encoded = await hashPassword(password, "connor");

  assert.match(encoded, /^\$argon2id\$v=19\$m=19456,t=2,p=1\$/u);
  assert.equal(encoded.includes(password), false);
  assert.equal(await verifyPassword(password, encoded), true);
  assert.equal(await verifyPassword(`${password}!`, encoded), false);
  assert.equal(passwordHashNeedsUpgrade(encoded), false);
});

test("password policy accepts Unicode and rejects short, common and username-derived values", () => {
  assert.equal(
    normalizeNewPassword("远程电台安全密码，长度足够 2026", "connor"),
    "远程电台安全密码，长度足够 2026",
  );
  assert.throws(() => normalizeNewPassword("too short"), /15\.\.128/u);
  assert.throws(() => normalizeNewPassword("passwordpassword"), /too common/u);
  assert.throws(
    () => normalizeNewPassword("connor-has-a-long-password", "connor"),
    /username/u,
  );
});

test("users.json supports first admin, operators, login and the final-admin invariant", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-users-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "users.json");
  let now = 100;
  let nextId = 0;
  const store = new UserStore(path, {
    now: () => now,
    idFactory: () => `user-${++nextId}`,
  });
  await store.load();

  const admin = await store.initializeAdmin(" Connor ", "Admin radio password 2026!");
  assert.equal(admin.username, "connor");
  assert.equal(admin.role, "admin");
  assert.equal(admin.canTransmit, true);
  await assert.rejects(
    store.initializeAdmin("second", "Another admin password 2026!"),
    /already has/u,
  );

  const operator = await store.create({
    username: "operator.one",
    password: "Operator secure password 2026!",
    role: "operator",
    canTransmit: false,
  });
  assert.equal(operator.canTransmit, false);
  now = 200;
  const login = await store.authenticate("OPERATOR.ONE", "Operator secure password 2026!");
  assert.equal(login?.lastLoginAtMs, 200);
  assert.equal(await store.authenticate("missing", "Some unknown password 2026!"), null);
  assert.equal(await store.authenticate("operator.one", "Wrong operator password 2026!"), null);

  await assert.rejects(store.setAccess(admin.id, { enabled: false }), /final enabled/u);
  const promoted = await store.setAccess(operator.id, { role: "admin" });
  assert.equal(promoted.canTransmit, true);
  const disabled = await store.setAccess(admin.id, { enabled: false });
  assert.equal(disabled.enabled, false);
  assert.equal(await store.authenticate("connor", "Admin radio password 2026!"), null);

  const persisted = await readFile(path, "utf8");
  assert.equal(persisted.includes("Operator secure password 2026!"), false);
  assert.equal(persisted.includes("$argon2id$"), true);
});
