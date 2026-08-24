import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import {
  DeviceStore,
  RefreshTokenReuseError,
} from "../src/auth/device-store.ts";
import { PairingService } from "../src/auth/pairing-service.ts";
import {
  CodeRateLimitError,
  InvalidOrExpiredCodeError,
  SixDigitCodeVault,
} from "../src/auth/six-digit-codes.ts";

test("six-digit codes preserve leading zeroes, expire and are single-use", () => {
  let now = 1_000;
  const codes = new SixDigitCodeVault({
    now: () => now,
    codeFactory: () => 42,
    hmacKey: Buffer.alloc(32, 7),
  });
  const issued = codes.issue("user-1", "device_pairing", 120_000);
  assert.equal(issued.code, "000042");
  assert.equal(issued.expiresAtMs, 121_000);
  assert.equal(codes.redeem("000042", "device_pairing", "source-a"), "user-1");
  assert.throws(
    () => codes.redeem("000042", "device_pairing", "source-a"),
    InvalidOrExpiredCodeError,
  );

  codes.issue("user-2", "device_pairing", 120_000);
  now = 121_000;
  assert.throws(
    () => codes.redeem("000042", "device_pairing", "source-b"),
    InvalidOrExpiredCodeError,
  );
});

test("repeated invalid code guesses are source-rate-limited", () => {
  const codes = new SixDigitCodeVault({
    codeFactory: () => 123456,
    hmacKey: Buffer.alloc(32, 8),
    maxFailures: 2,
  });
  codes.issue("user-1", "device_pairing", 120_000);
  assert.throws(
    () => codes.redeem("000000", "device_pairing", "source-a"),
    InvalidOrExpiredCodeError,
  );
  assert.throws(
    () => codes.redeem("000001", "device_pairing", "source-a"),
    InvalidOrExpiredCodeError,
  );
  assert.throws(
    () => codes.redeem("123456", "device_pairing", "source-a"),
    CodeRateLimitError,
  );
  assert.equal(codes.redeem("123456", "device_pairing", "source-b"), "user-1");
});

test("pairing persists only token digests, rotates refresh and revokes on reuse", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-devices-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "devices.json");
  let now = 10_000;
  let tokenNumber = 0;
  const devices = new DeviceStore(path, {
    now: () => now,
    idFactory: () => "device-1",
    tokenFactory: () => `token_${String(++tokenNumber).padStart(40, "0")}`,
    accessLifetimeMs: 1_000,
    refreshLifetimeMs: 10_000,
  });
  await devices.load();
  const codes = new SixDigitCodeVault({
    now: () => now,
    codeFactory: () => 654321,
    hmacKey: Buffer.alloc(32, 9),
  });
  const pairing = new PairingService(codes, devices);
  assert.equal(pairing.issueForUser("user-1").code, "654321");

  const initial = await pairing.redeem("654321", "Connor's iPhone", "100.64.0.2");
  assert.equal(devices.verifyAccess(initial.deviceId, initial.accessToken)?.userId, "user-1");
  await assert.rejects(
    pairing.redeem("654321", "Second phone", "100.64.0.2"),
    InvalidOrExpiredCodeError,
  );
  const file = await readFile(path, "utf8");
  assert.equal(file.includes(initial.accessToken), false);
  assert.equal(file.includes(initial.refreshToken), false);

  now = 10_500;
  const rotated = await devices.refresh(initial.deviceId, initial.refreshToken);
  assert.equal(devices.verifyAccess(initial.deviceId, initial.accessToken), null);
  assert.equal(devices.verifyAccess(rotated.deviceId, rotated.accessToken)?.id, "device-1");

  await assert.rejects(
    devices.refresh(initial.deviceId, initial.refreshToken),
    RefreshTokenReuseError,
  );
  assert.equal(devices.verifyAccess(rotated.deviceId, rotated.accessToken), null);
  assert.notEqual(devices.list()[0].revokedAtMs, null);
});
