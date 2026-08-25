import assert from "node:assert/strict";
import { test } from "node:test";

import type { PublicUser } from "../src/auth/user-store.ts";
import { parseRadioProfile } from "../src/config/types.ts";
import { ControlBusyError } from "../src/control/control-lease.ts";
import {
  HardwareTransmitDisabledError,
  RigControlTransmitLockedError,
  RadioRuntime,
  RadioRuntimeRegistry,
  TransmitPermissionError,
  type RigControl,
} from "../src/rig/radio-runtime.ts";

class FakeRig implements RigControl {
  frequencyHz = 14_074_000;
  mode = "USB";
  passbandHz = 3_000;
  ptt = false;
  tuner = false;
  controls = new Map<string, number>([
    ["level:RFPOWER", 0.5],
    ["level:AF", 0.4],
  ]);
  readonly events: string[] = [];

  async readState() { return { frequencyHz: this.frequencyHz, mode: this.mode, passbandHz: this.passbandHz, ptt: this.ptt }; }
  async setFrequency(value: number) { this.frequencyHz = value; this.events.push(`frequency:${value}`); return value; }
  async setMode(value: string, passband = 0) { this.mode = value; this.passbandHz = passband || 2_400; this.events.push(`mode:${value}`); return { mode: this.mode, passbandHz: this.passbandHz }; }
  async setPtt(value: boolean) { this.ptt = value; this.events.push(`ptt:${value}`); return value; }
  async setInternalTuner(value: boolean) { this.tuner = value; this.events.push(`tuner:${value}`); return value; }
  async readControls() {
    return [...this.controls].map(([id, value]) => ({
      id,
      kind: "level" as const,
      token: id.split(":")[1]!,
      value,
      minimum: 0,
      maximum: 1,
      step: 0.01,
      unit: "ratio" as const,
      transmitLocked: id === "level:RFPOWER",
    }));
  }
  async setControl(id: string, value: number) {
    const control = (await this.readControls()).find((candidate) => candidate.id === id);
    if (control === undefined) throw new Error("control unavailable");
    this.controls.set(id, value);
    this.events.push(`control:${id}:${value}`);
    return { ...control, value };
  }
}

class DeferredControlRig extends FakeRig {
  readonly controlWriteStarted = deferred<void>();
  readonly allowControlWrite = deferred<void>();
  pttWhenControlWritten: boolean | null = null;

  async setControl(id: string, value: number) {
    const control = (await this.readControls()).find((candidate) => candidate.id === id);
    if (control === undefined) throw new Error("control unavailable");
    this.controlWriteStarted.resolve();
    await this.allowControlWrite.promise;
    this.pttWhenControlWritten = this.ptt;
    this.controls.set(id, value);
    this.events.push(`control:${id}:${value}`);
    return { ...control, value };
  }
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

test("runtime locks transmit-sensitive Hamlib adjustments only while transmitting", async (context) => {
  const rig = new FakeRig();
  const runtime = new RadioRuntime(profile(true), rig);
  context.after(() => runtime.close());
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const control = await runtime.acquireControl("device-a", operator);

  const tx = await runtime.startTransmit("device-a", operator, control.lease.token, "voice");
  await assert.rejects(
    runtime.setControl("device-a", control.lease.token, "level:RFPOWER", 0.25),
    RigControlTransmitLockedError,
  );
  const audioGain = await runtime.setControl(
    "device-a",
    control.lease.token,
    "level:AF",
    0.65,
  );
  assert.equal(audioGain.value, 0.65);
  await runtime.stopTransmit("device-a", tx.leaseToken);
  const power = await runtime.setControl(
    "device-a",
    control.lease.token,
    "level:RFPOWER",
    0.25,
  );
  assert.equal(power.value, 0.25);
});

test("runtime does not key PTT while a transmit-sensitive control write is pending", async (context) => {
  const rig = new DeferredControlRig();
  const runtime = new RadioRuntime(profile(true), rig);
  context.after(() => runtime.close());
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const control = await runtime.acquireControl("device-a", operator);

  const updating = runtime.setControl(
    "device-a",
    control.lease.token,
    "level:RFPOWER",
    0.25,
  );
  await rig.controlWriteStarted.promise;
  const starting = runtime.startTransmit("device-a", operator, control.lease.token, "voice");
  await new Promise<void>((resolve) => setImmediate(resolve));
  const pttWhileControlWriteWasBlocked = rig.ptt;

  rig.allowControlWrite.resolve();
  await updating;
  const tx = await starting;
  try {
    assert.equal(pttWhileControlWriteWasBlocked, false);
    assert.equal(rig.pttWhenControlWritten, false);
    assert.equal(rig.ptt, true);
  } finally {
    await runtime.stopTransmit("device-a", tx.leaseToken);
  }
});

test("runtime de-keys immediately when an allowed control write is stalled", async (context) => {
  const rig = new DeferredControlRig();
  const runtime = new RadioRuntime(profile(true), rig);
  context.after(() => runtime.close());
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const control = await runtime.acquireControl("device-a", operator);
  const tx = await runtime.startTransmit("device-a", operator, control.lease.token, "voice");

  const updating = runtime.setControl(
    "device-a",
    control.lease.token,
    "level:AF",
    0.65,
  );
  await rig.controlWriteStarted.promise;
  const stopping = runtime.stopTransmit("device-a", tx.leaseToken);
  await new Promise<void>((resolve) => setImmediate(resolve));
  const pttAfterStopRequested = rig.ptt;

  rig.allowControlWrite.resolve();
  await Promise.all([updating, stopping]);
  assert.equal(pttAfterStopRequested, false);
  assert.equal(rig.ptt, false);
});

test("runtime registry waits for invalidated resources to close before creating a replacement", async (context) => {
  const configuredProfile = profile(false);
  const closeStarted = deferred();
  const allowClose = deferred();
  let factoryCalls = 0;
  const registry = new RadioRuntimeRegistry(
    () => ({ version: 1, radios: [configuredProfile] }),
    async (runtimeProfile) => {
      factoryCalls += 1;
      const generation = factoryCalls;
      const runtime = new RadioRuntime(runtimeProfile, new FakeRig(), async () => {
        if (generation === 1) {
          closeStarted.resolve();
          await allowClose.promise;
        }
      });
      await runtime.initialize();
      return runtime;
    },
  );
  context.after(() => registry.close());

  const original = await registry.get("main");
  const invalidating = registry.invalidate("main");
  await closeStarted.promise;
  const replacementPromise = registry.get("main");

  try {
    assert.equal(factoryCalls, 1, "replacement factory must wait for the old close");
  } finally {
    allowClose.resolve();
    await invalidating;
  }

  const replacement = await replacementPromise;
  assert.notEqual(replacement, original);
  assert.equal(factoryCalls, 2);
});

test("failed stale runtime initialization cannot evict or leak its replacement", async () => {
  const configuredProfile = profile(false);
  const failFirstInitialization = deferred<never>();
  const closed: number[] = [];
  let factoryCalls = 0;
  const registry = new RadioRuntimeRegistry(
    () => ({ version: 1, radios: [configuredProfile] }),
    async (runtimeProfile) => {
      factoryCalls += 1;
      const generation = factoryCalls;
      if (generation === 1) {
        return failFirstInitialization.promise;
      }
      const runtime = new RadioRuntime(runtimeProfile, new FakeRig(), async () => {
        closed.push(generation);
      });
      await runtime.initialize();
      return runtime;
    },
  );

  void registry.get("main").catch(() => undefined);
  const invalidating = registry.invalidate("main");
  const replacementPromise = registry.get("main");
  failFirstInitialization.reject(new Error("old runtime initialization failed"));
  await invalidating;

  const replacement = await replacementPromise;
  assert.equal(await registry.get("main"), replacement);
  assert.equal(factoryCalls, 2);
  await registry.close();
  assert.deepEqual(closed, [2]);
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

function deferred<T = void>(): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(error: unknown): void;
} {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}
