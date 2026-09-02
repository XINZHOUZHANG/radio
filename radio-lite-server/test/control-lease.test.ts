import assert from "node:assert/strict";
import { test } from "node:test";

import {
  ControlBusyError,
  ControlLeaseManager,
  InvalidControlLeaseError,
} from "../src/control/control-lease.ts";

test("one radio has one renewable controller and ordinary users cannot take it", () => {
  let now = 1_000;
  let number = 0;
  const control = new ControlLeaseManager({
    now: () => now,
    leaseDurationMs: 30_000,
    tokenFactory: () => `lease_${String(++number).padStart(40, "0")}`,
  });
  const first = control.acquire("device-a", "user-a", { administrator: false });
  assert.equal(first.displacedOwnerId, null);
  assert.throws(
    () => control.acquire("device-b", "user-b", { administrator: false }),
    ControlBusyError,
  );
  now = 20_000;
  assert.equal(control.heartbeat("device-a", first.lease.token).expiresAtMs, 50_000);
  assert.equal(control.snapshot()?.ownerId, "device-a");
});

test("administrator force takeover reports displaced owner and invalidates old token", () => {
  let number = 0;
  const control = new ControlLeaseManager({
    tokenFactory: () => `lease_${String(++number).padStart(40, "0")}`,
  });
  const first = control.acquire("device-a", "user-a", { administrator: false });
  const takeover = control.acquire("device-admin", "admin", {
    administrator: true,
    force: true,
  });
  assert.equal(takeover.displacedOwnerId, "device-a");
  assert.throws(
    () => control.assertValid("device-a", first.lease.token),
    InvalidControlLeaseError,
  );
  assert.equal(control.assertValid("device-admin", takeover.lease.token).userId, "admin");
});

test("lease expiration and disconnect release allow the next controller", () => {
  let now = 0;
  let number = 0;
  const control = new ControlLeaseManager({
    now: () => now,
    leaseDurationMs: 100,
    tokenFactory: () => `lease_${String(++number).padStart(40, "0")}`,
  });
  const first = control.acquire("a", "u1", { administrator: false });
  assert.equal(control.release("wrong"), false);
  assert.equal(control.release("a", first.lease.token), true);
  control.acquire("b", "u2", { administrator: false });
  now = 100;
  assert.equal(control.snapshot(), null);
  assert.equal(control.acquire("c", "u3", { administrator: false }).lease.ownerId, "c");
});
