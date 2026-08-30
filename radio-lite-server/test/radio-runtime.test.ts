import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import type { PublicUser } from "../src/auth/user-store.ts";
import { parseRadioProfile } from "../src/config/types.ts";
import { ControlBusyError } from "../src/control/control-lease.ts";
import type { RigResponse } from "../src/rig/extended-protocol.ts";
import { HamlibDriver } from "../src/rig/hamlib-driver.ts";
import { HamlibRig } from "../src/rig/hamlib-rig.ts";
import {
  HardwareTransmitDisabledError,
  ManagedSerialDeviceBusyError,
  RigControlTransmitLockedError,
  RadioRuntime,
  RadioRuntimeCleanupUncertainError,
  RadioRuntimeRegistry,
  RadioRuntimeRegistryClosedError,
  TransmitPermissionError,
} from "../src/rig/radio-runtime.ts";
import type { RadioControl, RadioControlValue, RadioDriver } from "../src/rig/radio-driver.ts";
import { RigReportError } from "../src/rig/transport.ts";

class FakeRig implements RadioDriver {
  frequencyHz = 14_074_000;
  mode = "USB";
  passbandHz = 3_000;
  ptt = false;
  readPttOverride: boolean | null = null;
  tuner = false;
  controls = new Map<string, number>([
    ["level:RFPOWER", 0.5],
    ["level:AF", 0.4],
  ]);
  readonly events: string[] = [];
  readStateCalls = 0;
  readControlsCalls = 0;

  async initialize() {}
  async close() {}
  async capabilities() { return { canTransmit: true, supportsInternalTuner: true }; }
  async readState() { this.readStateCalls += 1; return { frequencyHz: this.frequencyHz, mode: this.mode, passbandHz: this.passbandHz, ptt: this.ptt }; }
  async readTelemetry(_mode: "receive" | "transmit") { return {}; }
  async setFrequency(value: number) { this.frequencyHz = value; this.events.push(`frequency:${value}`); return value; }
  async setMode(value: string, passband = 0) { this.mode = value; this.passbandHz = passband || 2_400; this.events.push(`mode:${value}`); return { mode: this.mode, passbandHz: this.passbandHz }; }
  async setPtt(value: boolean) {
    await this.writePtt(value);
    return this.readPtt();
  }
  async writePtt(value: boolean) { this.ptt = value; this.events.push(`ptt-write:${value}`); }
  async readPtt() {
    const observed = this.readPttOverride ?? this.ptt;
    this.events.push(`ptt-read:${observed}`);
    return observed;
  }
  async supportsInternalTuner() { return true; }
  async startInternalTuner() {
    this.tuner = true;
    this.events.push("tuner:true");
  }
  async writeInternalTuner(value: boolean) {
    this.tuner = value;
    this.events.push(`tuner-write:${value}`);
  }
  async readControls(): Promise<RadioControl[]> {
    this.readControlsCalls += 1;
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
  async setControl(id: string, value: RadioControlValue) {
    if (typeof value !== "number") throw new Error("control value must be numeric");
    const control = (await this.readControls()).find((candidate) => candidate.id === id);
    if (control === undefined) throw new Error("control unavailable");
    this.controls.set(id, value);
    this.events.push(`control:${id}:${value}`);
    return { ...control, value };
  }
  async invokeAction(id: string) {
    if (id !== "action:TUNER") throw new Error("action unavailable");
    await this.startInternalTuner();
  }
}

test("runtime legacy reads and confirmed writes share the telemetry cache and control catalogue", async (context) => {
  const rig = new FakeRig();
  const runtime = new RadioRuntime(profile(true), rig);
  context.after(() => runtime.close());
  await runtime.initialize();
  const operatorUser = user("operator-a", "operator", true);
  const control = await runtime.acquireControl("device-a", operatorUser);

  assert.deepEqual(await runtime.readState(), await runtime.readState());
  assert.equal(rig.readStateCalls, 1);
  assert.deepEqual(await runtime.readControls(), await runtime.readControls());
  assert.equal(rig.readControlsCalls, 1);

  await runtime.setFrequency("device-a", control.lease.token, 7_074_000);
  await runtime.setMode("device-a", control.lease.token, "PKTUSB", 3_000);
  await runtime.setControl("device-a", control.lease.token, "level:AF", 0.25);
  const controlReadsAfterWrite = rig.readControlsCalls;

  assert.deepEqual(runtime.telemetry.snapshot()?.state, {
    frequencyHz: 7_074_000,
    mode: "PKTUSB",
    passbandHz: 3_000,
    ptt: false,
  });
  assert.equal((await runtime.readControls()).find((value) => value.id === "level:AF")?.value, 0.25);
  assert.equal(rig.readStateCalls, 1);
  assert.equal(rig.readControlsCalls, controlReadsAfterWrite);
});

class DeferredControlRig extends FakeRig {
  readonly controlWriteStarted = deferred<void>();
  readonly allowControlWrite = deferred<void>();
  pttWhenControlWritten: boolean | null = null;

  async setControl(id: string, value: RadioControlValue) {
    if (typeof value !== "number") throw new Error("control value must be numeric");
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

class DeferredTelemetryRig extends FakeRig {
  readonly telemetryReadStarted = deferred<void>();
  readonly allowTelemetryRead = deferred<void>();

  override async readState() {
    this.telemetryReadStarted.resolve();
    await this.allowTelemetryRead.promise;
    return super.readState();
  }
}

class FailingDeKeyRig extends FakeRig {
  failDeKey = false;
  failPttRead = false;
  deKeyAttempts = 0;

  async writePtt(value: boolean) {
    if (!value) {
      this.deKeyAttempts += 1;
      if (this.failDeKey) {
        this.events.push("ptt-write:false");
        throw new Error("PTT off failed");
      }
    }
    await super.writePtt(value);
  }

  async readPtt() {
    if (this.failPttRead) {
      this.events.push("ptt-read:error");
      throw new Error("PTT read failed");
    }
    return super.readPtt();
  }
}

class InitializationFailingRig extends FakeRig {
  override async initialize() {
    throw new RigReportError("driver_initialize", -11);
  }
}

class NonHamlibLockedControlRig extends FakeRig {
  setControlCalls = 0;

  override async readControls() {
    return [{
      id: "vendor:TX_LOCKED",
      kind: "level" as const,
      token: "TX_LOCKED",
      value: 1,
      minimum: 0,
      maximum: 1,
      step: 1,
      unit: "boolean" as const,
      transmitLocked: true,
    }];
  }

  override async setControl(id: string, value: RadioControlValue) {
    this.setControlCalls += 1;
    return super.setControl(id, value);
  }
}

class RecordingHamlibRequester {
  readonly commands: string[] = [];
  ptt = false;
  tuner = false;
  pttUnavailable = false;
  vfoOperations = "TUNE TOGGLE";
  writableFunctions = "NB NR TUNER";

  async request(command: string): Promise<RigResponse> {
    this.commands.push(command);
    const name = command.slice(1).split(" ")[0] ?? "unknown";
    if (this.pttUnavailable && (name === "set_ptt" || name === "get_ptt")) {
      throw new RigReportError(name, -11);
    }
    if (name === "set_ptt") {
      this.ptt = command.endsWith(" 1");
      return rigResponse(name);
    }
    if (name === "get_ptt") {
      return rigResponse(name, { PTT: this.ptt ? "1" : "0" });
    }
    if (command === "\\get_level ?") {
      return rigResponse(name, { Level: "STRENGTH SWR ALC RFPOWER_METER_WATTS" });
    }
    if (command === "\\vfo_op ?") {
      return rigResponse(name, { "Mem/VFO Op": this.vfoOperations });
    }
    if (command === "\\vfo_op TUNE") {
      this.tuner = true;
      return rigResponse(name);
    }
    if (command === "\\set_func ?") {
      return rigResponse(name, { Func: this.writableFunctions });
    }
    if (name === "set_func") {
      this.tuner = command.endsWith(" 1");
      return rigResponse(name);
    }
    if (name === "get_func") {
      return rigResponse(name, { TUNER: this.tuner ? "1" : "0" });
    }
    throw new Error(`unexpected test CAT command: ${command}`);
  }

  clear(): void {
    this.commands.length = 0;
  }
}

test("runtime initialization observes PTT without writing OFF", async () => {
  const rig = new FakeRig();
  rig.ptt = true;
  const runtime = new RadioRuntime(profile(true), rig);

  await runtime.initialize();

  assert.equal(rig.ptt, true);
  assert.deepEqual(rig.events, ["ptt-read:true"]);
  assert.equal(runtime.interlock.snapshot().state, "idle");
  await runtime.close();
  assert.deepEqual(rig.events, ["ptt-read:true"]);
});

test("startup observation failure closes dependencies without writing PTT OFF", async () => {
  const rig = new FailingDeKeyRig();
  rig.ptt = true;
  rig.failPttRead = true;
  let dependencyCloseCount = 0;
  const runtime = new RadioRuntime(profile(true), rig, async () => {
    dependencyCloseCount += 1;
  });

  await assert.rejects(runtime.initialize(), /PTT read failed/u);
  await runtime.close();

  assert.equal(dependencyCloseCount, 1);
  assert.equal(rig.ptt, true);
  assert.deepEqual(rig.events, ["ptt-read:error"]);
});

test("receive-only initialization does not swallow a driver initialization failure", async () => {
  const rig = new InitializationFailingRig();
  const runtime = new RadioRuntime(
    { ...profile(false), ptt: { method: "None" } },
    rig,
  );

  await assert.rejects(runtime.initialize(), (error: unknown) =>
    error instanceof RigReportError && error.report === -11 && /driver_initialize/u.test(error.message),
  );
  assert.deepEqual(rig.events, []);
  await runtime.close();
});

test("receive-only PTT None runtime starts without treating display cache as evidence", async () => {
  const requester = new RecordingHamlibRequester();
  requester.pttUnavailable = true;
  const receiveOnlyProfile = {
    ...profile(false),
    ptt: { method: "None" as const },
  };
  const runtime = new RadioRuntime(
    receiveOnlyProfile,
    new HamlibDriver(new HamlibRig(requester, { pttMethod: "None" })),
  );

  await runtime.initialize();

  assert.deepEqual(requester.commands, ["\\get_level ?", "\\get_ptt"]);
  const operator = user("receive-only", "operator", true);
  const control = await runtime.acquireControl("receive-device", operator);
  await assert.rejects(
    runtime.startTransmit("receive-device", operator, control.lease.token, "voice"),
    HardwareTransmitDisabledError,
  );
  await runtime.close();
  assert.deepEqual(requester.commands, ["\\get_level ?", "\\get_ptt"]);
});

test("runtime voice dekey sends one OFF write and one strict PTT read", async () => {
  const rig = new FakeRig();
  const runtime = new RadioRuntime(profile(true), rig);
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const control = await runtime.acquireControl("device-a", operator);
  const transmit = await runtime.startTransmit(
    "device-a",
    operator,
    control.lease.token,
    "voice",
  );
  rig.events.length = 0;

  await runtime.stopTransmit("device-a", transmit.leaseToken);

  assert.deepEqual(rig.events, ["ptt-write:false", "ptt-read:false"]);
  assert.equal(runtime.interlock.snapshot().dekeyRequired, false);
  await runtime.close();
});

test("runtime transmit start retains PTT ON readback", async () => {
  const requester = new RecordingHamlibRequester();
  const runtime = new RadioRuntime(profile(true), new HamlibDriver(new HamlibRig(requester)));
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const control = await runtime.acquireControl("device-a", operator);
  requester.clear();

  const transmit = await runtime.startTransmit(
    "device-a",
    operator,
    control.lease.token,
    "voice",
  );

  assert.deepEqual(requester.commands, ["\\set_ptt 1", "\\get_ptt"]);
  await runtime.stopTransmit("device-a", transmit.leaseToken);
  await runtime.close();
});

test("runtime voice and digital dekey use one OFF write and one strict PTT read", async () => {
  for (const mode of ["voice", "digital"] as const) {
    const requester = new RecordingHamlibRequester();
    const runtime = new RadioRuntime(profile(true), new HamlibDriver(new HamlibRig(requester)));
    await runtime.initialize();
    const operator = user(`operator-${mode}`, "operator", true);
    const control = await runtime.acquireControl(`device-${mode}`, operator);
    const transmit = await runtime.startTransmit(
      `device-${mode}`,
      operator,
      control.lease.token,
      mode,
    );
    requester.clear();

    await runtime.stopTransmit(`device-${mode}`, transmit.leaseToken);

    assert.deepEqual(requester.commands, ["\\set_ptt 0", "\\get_ptt"], mode);
    await runtime.close();
  }
});

test("runtime tuning stop dekeys safely without disabling the persistent tuner switch", async (context) => {
  const requester = new RecordingHamlibRequester();
  const runtime = new RadioRuntime(profile(true), new HamlibDriver(new HamlibRig(requester)));
  context.after(() => runtime.close().catch(() => undefined));
  await runtime.initialize();
  const operator = user("tuner-operator", "operator", true);
  const control = await runtime.acquireControl("device-tuner", operator);
  requester.clear();
  const transmit = await runtime.startTransmit(
    "device-tuner",
    operator,
    control.lease.token,
    "tuning",
  );

  assert.deepEqual(requester.commands, [
    "\\vfo_op ?",
    "\\set_func ?",
    "\\set_func TUNER 1",
    "\\vfo_op TUNE",
  ]);
  requester.clear();

  await runtime.stopTransmit("device-tuner", transmit.leaseToken);

  assert.deepEqual(requester.commands, ["\\set_ptt 0", "\\get_ptt"]);
  assert.equal(requester.tuner, true);
});

test("runtime TUNE-only stop confirms PTT OFF without leaving the safety latch", async (context) => {
  const requester = new RecordingHamlibRequester();
  requester.writableFunctions = "NB NR";
  const runtime = new RadioRuntime(profile(true), new HamlibDriver(new HamlibRig(requester)));
  context.after(() => runtime.close().catch(() => undefined));
  await runtime.initialize();
  const operator = user("tune-only-operator", "operator", true);
  const control = await runtime.acquireControl("tune-only-device", operator);
  requester.clear();
  const transmit = await runtime.startTransmit(
    "tune-only-device",
    operator,
    control.lease.token,
    "tuning",
  );

  assert.deepEqual(requester.commands, ["\\vfo_op ?", "\\set_func ?", "\\vfo_op TUNE"]);
  requester.clear();

  await runtime.stopTransmit("tune-only-device", transmit.leaseToken);

  assert.deepEqual(requester.commands, ["\\set_ptt 0", "\\get_ptt"]);
  assert.equal(runtime.interlock.snapshot().state, "idle");
  assert.equal(runtime.interlock.snapshot().dekeyRequired, false);
});

test("runtime exposes cached internal-tuner capability without steady-state CAT polling", async (context) => {
  const requester = new RecordingHamlibRequester();
  const runtime = new RadioRuntime(profile(true), new HamlibDriver(new HamlibRig(requester)));
  context.after(() => runtime.close().catch(() => undefined));
  await runtime.initialize();
  requester.clear();

  assert.equal(await runtime.supportsInternalTuner(), true);
  assert.equal(await runtime.supportsInternalTuner(), true);

  assert.deepEqual(requester.commands, ["\\vfo_op ?"]);
});

test("runtime rejects unsupported tuning before reserving a transmit activation", async (context) => {
  const requester = new RecordingHamlibRequester();
  requester.vfoOperations = "CPY TOGGLE";
  const runtime = new RadioRuntime(profile(true), new HamlibDriver(new HamlibRig(requester)));
  context.after(() => runtime.close().catch(() => undefined));
  await runtime.initialize();
  const operator = user("unsupported-tuner", "operator", true);
  const control = await runtime.acquireControl("unsupported-device", operator);
  requester.clear();

  await assert.rejects(
    runtime.startTransmit(
      "unsupported-device",
      operator,
      control.lease.token,
      "tuning",
    ),
    /does not support internal tuning/u,
  );

  assert.deepEqual(requester.commands, ["\\vfo_op ?"]);
  assert.equal(runtime.interlock.snapshot().state, "idle");
  assert.equal(runtime.interlock.snapshot().dekeyRequired, false);
});

test("PTT None command cache cannot establish a transmit lease without strict read-back", async (context) => {
  const requester = new RecordingHamlibRequester();
  requester.pttUnavailable = true;
  const runtime = new RadioRuntime(
    profile(true),
    new HamlibDriver(new HamlibRig(requester, { pttMethod: "None" })),
  );
  context.after(() => runtime.close().catch(() => undefined));
  const operator = user("ptt-none-operator", "operator", true);
  const control = await runtime.acquireControl("device-ptt-none", operator);
  await assert.rejects(
    runtime.startTransmit(
      "device-ptt-none",
      operator,
      control.lease.token,
      "voice",
    ),
    /read-back|RPRT -11/u,
  );

  assert.deepEqual(requester.commands, ["\\set_ptt 1", "\\get_ptt", "\\set_ptt 0", "\\get_ptt"]);
  assert.equal(runtime.interlock.snapshot().state, "fault");
  assert.equal(runtime.interlock.snapshot().dekeyRequired, true);
});

test("OFF write followed by ON readback retains the runtime dekey latch", async () => {
  const rig = new FakeRig();
  const runtime = new RadioRuntime(profile(true), rig);
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const control = await runtime.acquireControl("device-a", operator);
  const transmit = await runtime.startTransmit(
    "device-a",
    operator,
    control.lease.token,
    "voice",
  );
  rig.readPttOverride = true;
  rig.events.length = 0;

  try {
    await assert.rejects(
      runtime.stopTransmit("device-a", transmit.leaseToken),
      /read-back.*ON/u,
    );
    assert.deepEqual(rig.events, ["ptt-write:false", "ptt-read:true"]);
    assert.equal(runtime.interlock.snapshot().state, "fault");
    assert.equal(runtime.interlock.snapshot().dekeyRequired, true);
  } finally {
    rig.readPttOverride = false;
    await runtime.close();
  }
});

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

test("force takeover preserves a pre-existing unconfirmed dekey latch", async (context) => {
  const rig = new FakeRig();
  const runtime = new RadioRuntime(profile(true), rig);
  context.after(async () => {
    rig.readPttOverride = false;
    await runtime.close();
  });
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const admin = user("admin", "admin", true);
  const first = await runtime.acquireControl("device-a", operator);
  const tx = await runtime.startTransmit("device-a", operator, first.lease.token, "voice");
  rig.readPttOverride = true;
  assert.deepEqual(await runtime.stopTransmitOutcome("device-a", tx.leaseToken), {
    kind: "recoveryPending",
    generation: 1,
  });

  const takeover = await runtime.acquireControl("device-admin", admin, true);

  assert.equal(takeover.displacedOwnerId, "device-a");
  assert.equal(runtime.interlock.snapshot().dekeyRequired, true);
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

test("tuner is mutually exclusive with voice and disconnect dekeys without bypassing ATU", async (context) => {
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
  assert.equal(rig.tuner, true);
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

test("runtime locks neutral control descriptors and fails closed for unknown controls while transmitting", async (context) => {
  const rig = new NonHamlibLockedControlRig();
  const runtime = new RadioRuntime(profile(true), rig);
  context.after(() => runtime.close());
  await runtime.initialize();
  const operator = user("u1", "operator", true);
  const control = await runtime.acquireControl("device-a", operator);
  const tx = await runtime.startTransmit("device-a", operator, control.lease.token, "voice");

  await assert.rejects(
    runtime.setControl("device-a", control.lease.token, "vendor:TX_LOCKED", 0),
    RigControlTransmitLockedError,
  );
  await assert.rejects(
    runtime.setControl("device-a", control.lease.token, "vendor:UNKNOWN", 0),
    RigControlTransmitLockedError,
  );
  assert.equal(rig.setControlCalls, 0);
  await runtime.stopTransmit("device-a", tx.leaseToken);
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

test("runtime close still cleans dependencies and reports an uncertain de-key", async () => {
  const rig = new FailingDeKeyRig();
  let dependencyCloseCount = 0;
  const runtime = new RadioRuntime(rigProfile(true), rig, async () => {
    dependencyCloseCount += 1;
  });
  await runtime.initialize();
  await runtime.interlock.start("cleanup-test", "voice");
  rig.failDeKey = true;

  await assert.rejects(runtime.close(), RadioRuntimeCleanupUncertainError);
  assert.equal(dependencyCloseCount, 1);
  await assert.rejects(runtime.close(), RadioRuntimeCleanupUncertainError);
  assert.equal(dependencyCloseCount, 1, "idempotent close must preserve the first failure");
});

test("runtime close dekeys before waiting for telemetry and drains it before dependencies", async () => {
  const rig = new DeferredTelemetryRig();
  let dependenciesClosed = false;
  const runtime = new RadioRuntime(profile(true), rig, async () => {
    dependenciesClosed = true;
  });
  await runtime.initialize();
  const stateRead = runtime.readState();
  void stateRead.catch(() => undefined);
  await rig.telemetryReadStarted.promise;
  const operatorUser = user("telemetry-close", "operator", true);
  const control = await runtime.acquireControl("telemetry-close-device", operatorUser);
  await runtime.startTransmit(
    "telemetry-close-device",
    operatorUser,
    control.lease.token,
    "voice",
  );
  rig.events.length = 0;

  const closing = runtime.close();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.deepEqual(rig.events, ["ptt-write:false", "ptt-read:false"]);
  assert.equal(dependenciesClosed, false);
  rig.allowTelemetryRead.resolve();
  await closing;
  assert.equal(dependenciesClosed, true);
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

test("runtime registry refuses a preflight reservation while a serial runtime is initializing", async () => {
  const configuredProfile = managedProfile();
  assert.equal(configuredProfile.connection.kind, "managed-serial");
  if (configuredProfile.connection.kind !== "managed-serial") throw new Error("test profile must be serial");
  const devicePath = configuredProfile.connection.devicePath;
  const runtimeReady = deferred<RadioRuntime>();
  const registry = new RadioRuntimeRegistry(
    () => ({ version: 1, radios: [configuredProfile] }),
    async () => runtimeReady.promise,
  );
  const initializing = registry.get("main");
  const runtime = new RadioRuntime(configuredProfile, new FakeRig());
  await runtime.initialize();

  try {
    assert.throws(
      () => registry.reserveManagedSerialDevice(devicePath),
      ManagedSerialDeviceBusyError,
    );
  } finally {
    runtimeReady.resolve(runtime);
  }

  assert.equal(await initializing, runtime);
  await registry.close();
});

test("runtime registry blocks serial aliases for the lifetime of a preflight reservation", async () => {
  const configuredProfile = managedProfile("/dev/ttyUSB0");
  assert.equal(configuredProfile.connection.kind, "managed-serial");
  let factoryCalls = 0;
  const registry = new RadioRuntimeRegistry(
    () => ({ version: 1, radios: [configuredProfile] }),
    async (runtimeProfile) => {
      factoryCalls += 1;
      const runtime = new RadioRuntime(runtimeProfile, new FakeRig());
      await runtime.initialize();
      return runtime;
    },
    (devicePath) => devicePath === "/dev/serial/by-id/usb-radio"
      ? "/dev/ttyUSB0"
      : devicePath,
  );
  const reservation = registry.reserveManagedSerialDevice("/dev/serial/by-id/usb-radio");

  try {
    assert.throws(() => registry.get("main"), ManagedSerialDeviceBusyError);
    assert.equal(factoryCalls, 0);
  } finally {
    reservation.release();
  }

  await registry.get("main");
  assert.equal(factoryCalls, 1);
  await registry.close();
});

test("runtime registry resolves filesystem aliases to one reservation key", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-runtime-device-alias-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const target = join(directory, "ttyUSB0");
  const alias = join(directory, "radio-by-id");
  await mkdir(target);
  await symlink(target, alias, process.platform === "win32" ? "junction" : "dir");
  const registry = new RadioRuntimeRegistry(() => ({ version: 1, radios: [] }));
  const reservation = registry.reserveManagedSerialDevice(target);

  try {
    assert.throws(
      () => registry.reserveManagedSerialDevice(alias),
      ManagedSerialDeviceBusyError,
    );
  } finally {
    reservation.release();
    await registry.close();
  }
});

test("serial quarantine keeps the reservation's original canonical key across device removal", async () => {
  const stablePath = "/dev/serial/by-id/usb-radio";
  let attached = true;
  const registry = new RadioRuntimeRegistry(
    () => ({ version: 1, radios: [] }),
    undefined,
    (devicePath) => devicePath === stablePath && attached ? "/dev/ttyUSB0" : devicePath,
  );
  const reservation = registry.reserveManagedSerialDevice(stablePath);

  attached = false;
  reservation.quarantine();
  reservation.release();
  attached = true;

  assert.throws(
    () => registry.reserveManagedSerialDevice(stablePath),
    ManagedSerialDeviceBusyError,
  );
  await assert.rejects(registry.close(), RadioRuntimeCleanupUncertainError);
});

test("stale reservation handles cannot release or quarantine a newer generation", async () => {
  const registry = new RadioRuntimeRegistry(() => ({ version: 1, radios: [] }));
  const first = registry.reserveManagedSerialDevice("/dev/ttyUSB0");
  first.release();
  const second = registry.reserveManagedSerialDevice("/dev/ttyUSB0");

  first.quarantine();
  first.release();
  assert.throws(
    () => registry.reserveManagedSerialDevice("/dev/ttyUSB0"),
    ManagedSerialDeviceBusyError,
  );
  second.release();
  const third = registry.reserveManagedSerialDevice("/dev/ttyUSB0");
  third.release();
  await registry.close();
});

test("runtime registry rejects new runtimes and reservations as soon as close starts", async () => {
  const configuredProfile = managedProfile();
  const closeStarted = deferred<void>();
  const allowClose = deferred<void>();
  const registry = new RadioRuntimeRegistry(
    () => ({ version: 1, radios: [configuredProfile] }),
    async (runtimeProfile) => {
      const runtime = new RadioRuntime(runtimeProfile, new FakeRig(), async () => {
        closeStarted.resolve();
        await allowClose.promise;
      });
      await runtime.initialize();
      return runtime;
    },
  );
  await registry.get("main");

  const closing = registry.close();
  await closeStarted.promise;
  assert.throws(() => registry.get("main"), RadioRuntimeRegistryClosedError);
  assert.throws(
    () => registry.reserveManagedSerialDevice("/dev/serial/by-id/usb-radio"),
    RadioRuntimeRegistryClosedError,
  );

  allowClose.resolve();
  await Promise.all([closing, registry.close()]);
});

test("runtime invalidation quarantines a serial device when de-key cannot be confirmed", async () => {
  const configuredProfile = managedProfile("/dev/ttyUSB0");
  const registry = new RadioRuntimeRegistry(
    () => ({ version: 1, radios: [configuredProfile] }),
    async (runtimeProfile) => {
      const rig = new FailingDeKeyRig();
      const runtime = new RadioRuntime(runtimeProfile, rig);
      await runtime.initialize();
      await runtime.interlock.start("cleanup-test", "voice");
      rig.failDeKey = true;
      return runtime;
    },
    (devicePath) => devicePath === "/dev/serial/by-id/usb-radio"
      ? "/dev/ttyUSB0"
      : devicePath,
  );
  await registry.get("main");

  await assert.rejects(registry.invalidate("main"), RadioRuntimeCleanupUncertainError);
  assert.throws(() => registry.get("main"), ManagedSerialDeviceBusyError);
  assert.throws(
    () => registry.reserveManagedSerialDevice("/dev/serial/by-id/usb-radio"),
    ManagedSerialDeviceBusyError,
  );
  await assert.rejects(registry.close(), RadioRuntimeCleanupUncertainError);
});

test("registry shutdown waits for an in-flight invalidation and propagates cleanup uncertainty", async () => {
  const configuredProfile = managedProfile();
  const dependencyCloseStarted = deferred<void>();
  const allowDependencyClose = deferred<void>();
  const registry = new RadioRuntimeRegistry(
    () => ({ version: 1, radios: [configuredProfile] }),
    async (runtimeProfile) => {
      const runtime = new RadioRuntime(runtimeProfile, new FakeRig(), async () => {
        dependencyCloseStarted.resolve();
        await allowDependencyClose.promise;
        throw new Error("managed process exit remained uncertain");
      });
      await runtime.initialize();
      return runtime;
    },
  );
  await registry.get("main");

  const invalidating = registry.invalidate("main");
  const invalidationFailed = assert.rejects(invalidating, RadioRuntimeCleanupUncertainError);
  await dependencyCloseStarted.promise;
  const closing = registry.close();
  let closeSettled = false;
  void closing.then(
    () => { closeSettled = true; },
    () => { closeSettled = true; },
  );
  const closeFailed = assert.rejects(closing, RadioRuntimeCleanupUncertainError);
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(closeSettled, false);

  allowDependencyClose.resolve();
  await Promise.all([invalidationFailed, closeFailed]);
  assert.throws(() => registry.get("main"), RadioRuntimeRegistryClosedError);
  assert.throws(
    () => registry.reserveManagedSerialDevice(configuredProfile.connection.kind === "managed-serial"
      ? configuredProfile.connection.devicePath
      : "/dev/invalid"),
    RadioRuntimeRegistryClosedError,
  );
});

test("queued get becomes device busy when invalidation quarantines the serial path", async () => {
  const configuredProfile = managedProfile();
  const dependencyCloseStarted = deferred<void>();
  const allowDependencyClose = deferred<void>();
  let factoryCalls = 0;
  const registry = new RadioRuntimeRegistry(
    () => ({ version: 1, radios: [configuredProfile] }),
    async (runtimeProfile) => {
      factoryCalls += 1;
      const runtime = new RadioRuntime(runtimeProfile, new FakeRig(), async () => {
        dependencyCloseStarted.resolve();
        await allowDependencyClose.promise;
        throw new Error("managed process exit remained uncertain");
      });
      await runtime.initialize();
      return runtime;
    },
  );
  await registry.get("main");

  const invalidating = registry.invalidate("main");
  const invalidationFailed = assert.rejects(invalidating, RadioRuntimeCleanupUncertainError);
  await dependencyCloseStarted.promise;
  const queuedGetFailed = assert.rejects(
    registry.get("main"),
    ManagedSerialDeviceBusyError,
  );
  allowDependencyClose.resolve();

  await Promise.all([invalidationFailed, queuedGetFailed]);
  assert.equal(factoryCalls, 1, "cleanup failure must not start a replacement runtime");
  await assert.rejects(registry.close(), RadioRuntimeCleanupUncertainError);
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

function rigProfile(hardwareTxEnabled: boolean) {
  return profile(hardwareTxEnabled);
}

function managedProfile(devicePath = "/dev/serial/by-id/usb-Yaesu_FT-710-if00") {
  return parseRadioProfile({
    id: "main",
    name: "FT-710",
    hamlibModelId: 1049,
    connection: {
      kind: "managed-serial",
      devicePath,
      baudRate: 38_400,
    },
    audioInput: { backend: "alsa", id: "hw:1,0" },
    audioOutput: { backend: "alsa", id: "hw:1,0" },
    ptt: { method: "RIG" },
    station: { callsign: "BI1ABC", grid: "OM89" },
    hardwareTxEnabled: false,
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

function rigResponse(
  command: string,
  fields: Readonly<Record<string, string>> = {},
): RigResponse {
  return {
    command,
    fields: new Map(Object.entries(fields)),
    values: [],
    report: 0,
  };
}
