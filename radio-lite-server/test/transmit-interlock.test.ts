import assert from "node:assert/strict";
import { test } from "node:test";

import {
  InterlockConflictError,
  InvalidLeaseError,
  TransmitInterlock,
  type TransmitDriver,
  type TransmitMode,
} from "../src/safety/transmit-interlock.ts";

class RecordingDriver implements TransmitDriver {
  readonly events: string[] = [];
  failDeactivate = false;

  async activate(mode: TransmitMode): Promise<void> {
    this.events.push(`on:${mode}`);
  }

  async deactivate(mode: TransmitMode): Promise<void> {
    this.events.push(`off:${mode}`);
    if (this.failDeactivate) {
      throw new Error("CAT unavailable");
    }
  }

  async emergencyOff(): Promise<void> {
    this.events.push("emergency-off");
  }
}

test("voice, digital and tuner transmission are mutually exclusive", async () => {
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, { tokenFactory: () => "lease-a" });
  await interlock.startupSafe();
  const lease = await interlock.start("user-a", "voice");

  await assert.rejects(
    interlock.start("user-b", "digital"),
    InterlockConflictError,
  );
  await assert.rejects(interlock.stop("user-b", lease.leaseToken), InvalidLeaseError);
  await interlock.stop("user-a", lease.leaseToken);
  assert.equal(interlock.snapshot().state, "idle");
  assert.deepEqual(driver.events, [
    "emergency-off",
    "on:voice",
    "off:voice",
    "emergency-off",
  ]);
});

test("heartbeat extends only to the hard limit and timeout forces PTT off", async () => {
  let now = 1_000;
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, {
    now: () => now,
    tokenFactory: () => "lease-b",
    heartbeatTimeoutMs: 8_000,
    hardLimitsMs: { voice: 20_000 },
  });
  const lease = await interlock.start("user-a", "voice");
  now = 7_000;
  const renewed = await interlock.heartbeat("user-a", lease.leaseToken);
  assert.equal(renewed.heartbeatDeadlineMs, 15_000);
  now = 15_000;
  assert.equal(await interlock.checkDeadlines(), "heartbeat_timeout");
  assert.equal(interlock.snapshot().state, "idle");
  assert.deepEqual(driver.events, ["on:voice", "off:voice", "emergency-off"]);
});

test("disconnect revokes only the matching owner's active transmission", async () => {
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, { tokenFactory: () => "lease-c" });
  await interlock.start("device-a", "tuning");

  assert.equal(await interlock.ownerDisconnected("device-b"), false);
  assert.equal(interlock.snapshot().state, "tuning");
  assert.equal(await interlock.ownerDisconnected("device-a"), true);
  assert.equal(interlock.snapshot().state, "idle");
});

test("a failed normal de-key attempts emergency off and latches fault", async () => {
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, { tokenFactory: () => "lease-d" });
  const lease = await interlock.start("device-a", "digital");
  driver.failDeactivate = true;

  await assert.rejects(interlock.stop("device-a", lease.leaseToken), /CAT unavailable/u);
  assert.equal(interlock.snapshot().state, "fault");
  assert.match(interlock.snapshot().faultReason ?? "", /PTT OFF failed/u);
  assert.deepEqual(driver.events, ["on:digital", "off:digital", "emergency-off"]);
});

test("hard deadline wins even when heartbeats keep arriving", async () => {
  let now = 0;
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, {
    now: () => now,
    tokenFactory: () => "lease-e",
    heartbeatTimeoutMs: 8_000,
    hardLimitsMs: { tuning: 10_000 },
  });
  const lease = await interlock.start("device-a", "tuning");
  now = 6_000;
  const renewed = await interlock.heartbeat("device-a", lease.leaseToken);
  assert.equal(renewed.heartbeatDeadlineMs, 10_000);
  now = 10_000;
  assert.equal(await interlock.checkDeadlines(), "hard_limit");
  assert.equal(interlock.snapshot().state, "idle");
});
