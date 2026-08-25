import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import type { PublicUser } from "../src/auth/user-store.ts";
import type { RadioProfile } from "../src/config/types.ts";
import { DigitalRadioController, type DigitalSlotScheduler } from "../src/digital/controller.ts";
import { DummyDigitalWorker } from "../src/digital/dummy-worker.ts";
import { AdifLogStore } from "../src/log/adif-log-store.ts";
import { RadioRuntime, type RigControl } from "../src/rig/radio-runtime.ts";

test("automatic digital controller uses the interlock and logs one completed FT8 QSO", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-digital-controller-"));
  const log = new AdifLogStore(join(directory, "station-log.adif"), { idFactory: () => "qso_auto_1" });
  await log.load();
  let now = 40_000;
  const rig = new DigitalFakeRig();
  const runtime = new RadioRuntime(profile(), rig, async () => undefined, () => now);
  await runtime.initialize();
  const acquired = await runtime.acquireControl("connection:one", user(), false);
  const scheduler = new ManualSlotScheduler([45_000, 75_000, 105_000]);
  const worker = new DummyDigitalWorker({ playbackDelayMs: 0 });
  const events: string[] = [];
  const controller = new DigitalRadioController({
    profile: profile(),
    runtime: async () => runtime,
    worker,
    logStore: log,
    scheduler,
    now: () => now,
    requestIdFactory: () => "encode_1",
    onEvent: (event) => events.push(event.t),
  });
  context.after(async () => {
    await controller.close();
    await runtime.close();
  });
  await controller.initialize();
  await controller.enqueueManual(
    { ownerId: "connection:one", controlToken: acquired.lease.token, user: user() },
    {
      targetCallsign: "JA1ABC",
      targetGrid: "PM95",
      mode: "FT8",
      audioFrequencyHz: 1_300,
      txParity: "odd",
    },
  );
  assert.equal(controller.qsoSnapshot()?.phase, "calling");

  now = 57_640;
  await scheduler.fire();
  assert.equal(controller.qsoSnapshot()?.phase, "awaiting_report");
  assert.equal(rig.ptt, false);

  await controller.acceptDecoded({
    radioId: "main",
    mode: "FT8",
    slotStartMs: 60_000,
    receivedAtMs: 75_000,
    frames: [{
      message: "BI1XYZ JA1ABC -07",
      snrDb: -12,
      deltaTimeSeconds: 0.1,
      audioFrequencyHz: 1_300,
    }],
  });
  now = 69_000;
  runtime.heartbeatControl("connection:one", acquired.lease.token);
  now = 87_640;
  await scheduler.fire();
  assert.equal(controller.qsoSnapshot()?.phase, "awaiting_final");

  await controller.acceptDecoded({
    radioId: "main",
    mode: "FT8",
    slotStartMs: 90_000,
    receivedAtMs: 105_000,
    frames: [{
      message: "BI1XYZ JA1ABC RR73",
      snrDb: -10,
      deltaTimeSeconds: 0.1,
      audioFrequencyHz: 1_300,
    }],
  });
  now = 98_000;
  runtime.heartbeatControl("connection:one", acquired.lease.token);
  now = 117_640;
  await scheduler.fire();
  assert.equal(controller.qsoSnapshot(), null);
  assert.equal(controller.queueSnapshot().entries.length, 0);
  assert.equal(log.count, 1);
  assert.equal(log.list()[0].source, "FT8_AUTO");
  assert.equal(log.list()[0].call, "JA1ABC");
  assert.deepEqual(rig.pttEvents, [
    false,
    true, false, false,
    true, false, false,
    true, false, false,
  ]);
  assert.equal(events.filter((event) => event === "digital.log.created").length, 1);
});

test("controller skip, remove and stop cancel prepared slots without keying the radio", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-digital-queue-"));
  const log = new AdifLogStore(join(directory, "station-log.adif"));
  await log.load();
  const rig = new DigitalFakeRig();
  const runtime = new RadioRuntime(profile(), rig);
  await runtime.initialize();
  const account = user();
  const acquired = await runtime.acquireControl("connection:one", account, false);
  const scheduler = new ManualSlotScheduler([45_000, 75_000, 105_000]);
  const controller = new DigitalRadioController({
    profile: profile(),
    runtime: async () => runtime,
    worker: new DummyDigitalWorker({ playbackDelayMs: 0 }),
    logStore: log,
    scheduler,
    now: () => 40_000,
  });
  context.after(async () => {
    await controller.close();
    await runtime.close();
  });
  await controller.initialize();
  const control = {
    ownerId: "connection:one",
    controlToken: acquired.lease.token,
    user: account,
  };
  await controller.enqueueManual(control, {
    targetCallsign: "JA1ABC",
    mode: "FT8",
    audioFrequencyHz: 1_000,
    txParity: "odd",
  });
  await controller.enqueueManual(control, {
    targetCallsign: "JA2XYZ",
    mode: "FT8",
    audioFrequencyHz: 1_500,
    txParity: "odd",
  });

  assert.equal((await controller.skip(control))?.targetCallsign, "JA2XYZ");
  assert.equal(controller.qsoSnapshot()?.targetCallsign, "JA2XYZ");
  const activeId = controller.queueSnapshot().activeId!;
  assert.equal((await controller.remove(control, activeId))?.targetCallsign, "JA2XYZ");
  assert.equal(controller.qsoSnapshot()?.targetCallsign, "JA1ABC");
  await controller.stop(control, false);
  assert.equal(controller.qsoSnapshot(), null);
  assert.equal(controller.queueSnapshot().entries.length, 0);
  assert.equal(rig.pttEvents.includes(true), false);
});

class ManualSlotScheduler implements DigitalSlotScheduler {
  readonly #slots: number[];
  #callback: ((slotStartMs: number) => void | Promise<void>) | null = null;
  #slotStartMs: number | null = null;

  constructor(slots: number[]) {
    this.#slots = [...slots];
  }

  schedule(
    _mode: "FT8" | "FT4",
    _parity: "even" | "odd",
    callback: (slotStartMs: number) => void | Promise<void>,
  ): number {
    const slot = this.#slots.shift();
    if (slot === undefined) {
      throw new Error("test scheduler ran out of slots");
    }
    this.#callback = callback;
    this.#slotStartMs = slot;
    return slot;
  }

  cancel(): void {
    this.#callback = null;
    this.#slotStartMs = null;
  }

  async fire(): Promise<void> {
    const callback = this.#callback;
    const slot = this.#slotStartMs;
    this.#callback = null;
    this.#slotStartMs = null;
    if (callback === null || slot === null) {
      throw new Error("test scheduler has no armed slot");
    }
    await callback(slot);
  }
}

class DigitalFakeRig implements RigControl {
  frequencyHz = 14_074_000;
  mode = "USB";
  passbandHz = 3_000;
  ptt = false;
  readonly pttEvents: boolean[] = [];

  async readState() {
    return {
      frequencyHz: this.frequencyHz,
      mode: this.mode,
      passbandHz: this.passbandHz,
      ptt: this.ptt,
    };
  }
  async setFrequency(value: number) { this.frequencyHz = value; return value; }
  async setMode(value: string, passband = 0) {
    this.mode = value;
    this.passbandHz = passband || 2_400;
    return { mode: this.mode, passbandHz: this.passbandHz };
  }
  async setPtt(value: boolean) {
    this.ptt = value;
    this.pttEvents.push(value);
    return value;
  }
  async setInternalTuner(_value: boolean) { return true; }
}

function profile(): RadioProfile {
  return {
    id: "main",
    name: "Dummy",
    hamlibModelId: 1,
    connection: { kind: "hamlib-dummy" },
    audioInput: { backend: "alsa", id: "dummy-in" },
    audioOutput: { backend: "alsa", id: "dummy-out" },
    station: { callsign: "BI1XYZ", grid: "OM89" },
    hardwareTxEnabled: false,
  };
}

function user(): PublicUser {
  return {
    id: "user-1",
    username: "operator",
    role: "operator",
    canTransmit: true,
    enabled: true,
    mustChangePassword: false,
    authRevision: 1,
    createdAtMs: 0,
    updatedAtMs: 0,
    lastLoginAtMs: null,
  };
}
