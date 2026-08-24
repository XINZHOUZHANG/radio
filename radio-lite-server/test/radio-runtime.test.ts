import assert from "node:assert/strict";
import { test } from "node:test";

import type { PublicUser } from "../src/auth/user-store.ts";
import { parseRadioProfile } from "../src/config/types.ts";
import { ControlBusyError } from "../src/control/control-lease.ts";
import {
  HardwareTransmitDisabledError,
  RadioRuntime,
  TransmitPermissionError,
  type RigControl,
} from "../src/rig/radio-runtime.ts";

class FakeRig implements RigControl {
  frequencyHz = 14_074_000;
  mode = "USB";
  passbandHz = 3_000;
  ptt = false;
  tuner = false;
  readonly events: string[] = [];

  async readState() { return { frequencyHz: this.frequencyHz, mode: this.mode, passbandHz: this.passbandHz, ptt: this.ptt }; }
  async setFrequency(value: number) { this.frequencyHz = value; this.events.push(`frequency:${value}`); return value; }
  async setMode(value: string, passband = 0) { this.mode = value; this.passbandHz = passband || 2_400; this.events.push(`mode:${value}`); return { mode: this.mode, passbandHz: this.passbandHz }; }
  async setPtt(value: boolean) { this.ptt = value; this.events.push(`ptt:${value}`); return value; }
  async setInternalTuner(value: boolean) { this.tuner = value; this.events.push(`tuner:${value}`); return value; }
}

test("runtime requires one control lease for writes and force takeover de-keys old owner", async (context) => {
  const rig = new FakeRig();
  const runtime = new RadioRuntime(profile(true), rig);
  context.after(() => runtime.close());
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const admin = user("admin", "admin", true);
  const first = await runtime.acquireControl("device-a", operator);
  await assert.rejects(runtime.acquireControl("device-b", operator), ControlBusyError);
  const tx = await runtime.startTransmit("device-a", operator, first.lease.token, "voice");
  assert.equal(rig.ptt, true);

  const takeover = await runtime.acquireControl("device-admin", admin, true);
  assert.equal(takeover.displacedOwnerId, "device-a");
  assert.equal(rig.ptt, false);
  await assert.rejects(runtime.stopTransmit("device-a", tx.leaseToken));
});

test("runtime enforces account permission and explicit hardware TX switch", async (context) => {
  const rig = new FakeRig();
  const runtime = new RadioRuntime(profile(false), rig);
  context.after(() => runtime.close());
  await runtime.initialize();
  const receiveOnly = user("rx", "operator", false);
  const lease = await runtime.acquireControl("rx-device", receiveOnly);
  await assert.rejects(
    runtime.startTransmit("rx-device", receiveOnly, lease.lease.token, "voice"),
    TransmitPermissionError,
  );
  const allowedUser = user("admin", "admin", true);
  const forced = await runtime.acquireControl("tx-device", allowedUser, true);
  await assert.rejects(
    runtime.startTransmit("tx-device", allowedUser, forced.lease.token, "voice"),
    HardwareTransmitDisabledError,
  );
  assert.equal(rig.ptt, false);
});

test("tuner is mutually exclusive with voice and disconnect releases both TX and control", async (context) => {
  const rig = new FakeRig();
  const runtime = new RadioRuntime(profile(true), rig);
  context.after(() => runtime.close());
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const control = await runtime.acquireControl("device-a", operator);
  await runtime.startTransmit("device-a", operator, control.lease.token, "tuning");
  assert.equal(rig.tuner, true);
  await assert.rejects(
    runtime.startTransmit("device-a", operator, control.lease.token, "voice"),
    /cannot start/u,
  );
  await runtime.ownerDisconnected("device-a");
  assert.equal(rig.tuner, false);
  assert.equal(rig.ptt, false);
  assert.equal(runtime.control.snapshot(), null);
});

function profile(hardwareTxEnabled: boolean) {
  return parseRadioProfile({
    id: "main",
    name: "FT-710",
    hamlibModelId: 1049,
    connection: { kind: "network-rigctld", host: "127.0.0.1", port: 4532 },
    audioInput: { backend: "alsa", id: "hw:1,0" },
    audioOutput: { backend: "alsa", id: "hw:1,0" },
    station: { callsign: "BI1ABC", grid: "OM89" },
    hardwareTxEnabled,
  });
}

function user(id: string, role: "admin" | "operator", canTransmit: boolean): PublicUser {
  return {
    id,
    username: id,
    role,
    canTransmit,
    enabled: true,
    mustChangePassword: false,
    authRevision: 1,
    createdAtMs: 0,
    updatedAtMs: 0,
    lastLoginAtMs: null,
  };
}
