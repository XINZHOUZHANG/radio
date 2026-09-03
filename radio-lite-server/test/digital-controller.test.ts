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
import { RadioRuntime } from "../src/rig/radio-runtime.ts";
import type { RadioControlValue, RadioDriver } from "../src/rig/radio-driver.ts";
import { InvalidLeaseError } from "../src/safety/transmit-interlock.ts";

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
  const watchdog = new ManualWatchdogTimer();
  const worker = new DummyDigitalWorker({ playbackDelayMs: 0 });
  const events: string[] = [];
  const controller = new DigitalRadioController({
    profile: profile(),
    runtime: async () => runtime,
    worker,
    logStore: log,
    scheduler,
    scheduleTimeout: (callback, delayMs) => watchdog.schedule(callback, delayMs),
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
  assert.equal(watchdog.armed, true);

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
  assert.equal(watchdog.armed, false, "an accepted decode must cancel the receive watchdog");
  now = 69_000;
  runtime.heartbeatControl("connection:one", acquired.lease.token);
  now = 87_640;
  await scheduler.fire();
  assert.equal(controller.qsoSnapshot()?.phase, "awaiting_final");
  assert.equal(watchdog.armed, true);

  worker.beginDecode({ mode: "FT8", slotStartMs: 90_000 });
  now = 105_500;
  await watchdog.fire();
  assert.equal(controller.qsoSnapshot()?.phase, "awaiting_final");
  assert.equal(controller.qsoSnapshot()?.reportAttempts, 1);
  assert.equal(watchdog.armed, true, "watchdog remains only as a worker-loss fallback");

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
  worker.finishDecode({ mode: "FT8", slotStartMs: 90_000 });
  assert.equal(watchdog.armed, false, "a final decode must cancel the receive watchdog");
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
    true, false,
    true, false,
    true, false,
  ]);
  assert.equal(events.filter((event) => event === "digital.log.created").length, 1);
});

test("receive-slot watchdog retries when capture produces no decode batch", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-digital-watchdog-"));
  const log = new AdifLogStore(join(directory, "station-log.adif"));
  await log.load();
  let now = 40_000;
  const rig = new DigitalFakeRig();
  const runtime = new RadioRuntime(profile(), rig, async () => undefined, () => now);
  await runtime.initialize();
  const account = user();
  const acquired = await runtime.acquireControl("connection:one", account, false);
  const scheduler = new ManualSlotScheduler([45_000, 105_000]);
  const watchdog = new ManualWatchdogTimer();
  const controller = new DigitalRadioController({
    profile: profile(),
    runtime: async () => runtime,
    worker: new DummyDigitalWorker({ playbackDelayMs: 0 }),
    logStore: log,
    scheduler,
    scheduleTimeout: (callback, delayMs) => watchdog.schedule(callback, delayMs),
    now: () => now,
  });
  context.after(async () => {
    await controller.close();
    await runtime.close();
  });
  await controller.initialize();
  await controller.enqueueManual(
    { ownerId: "connection:one", controlToken: acquired.lease.token, user: account },
    {
      targetCallsign: "JA1ABC",
      mode: "FT8",
      audioFrequencyHz: 1_300,
      txParity: "odd",
    },
  );

  now = 57_640;
  await scheduler.fire();
  assert.equal(controller.qsoSnapshot()?.phase, "awaiting_report");
  assert.equal(watchdog.delayMs, 17_860, "watchdog must wait through the receive slot and grace");

  now = 75_500;
  await watchdog.fire();
  assert.equal(controller.qsoSnapshot()?.phase, "calling");
  assert.equal(controller.qsoSnapshot()?.callAttempts, 1);
  assert.equal(scheduler.armedSlotStartMs, 105_000, "fallback retry uses the next TX-parity slot");
});

test("an empty receive batch cancels the watchdog before scheduling the adjacent retry", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-digital-empty-batch-"));
  const log = new AdifLogStore(join(directory, "station-log.adif"));
  await log.load();
  let now = 40_000;
  const rig = new DigitalFakeRig();
  const runtime = new RadioRuntime(profile(), rig, async () => undefined, () => now);
  await runtime.initialize();
  const account = user();
  const acquired = await runtime.acquireControl("connection:one", account, false);
  const scheduler = new ManualSlotScheduler([45_000, 75_000]);
  const watchdog = new ManualWatchdogTimer();
  const controller = new DigitalRadioController({
    profile: profile(),
    runtime: async () => runtime,
    worker: new DummyDigitalWorker({ playbackDelayMs: 0 }),
    logStore: log,
    scheduler,
    scheduleTimeout: (callback, delayMs) => watchdog.schedule(callback, delayMs),
    now: () => now,
  });
  context.after(async () => {
    await controller.close();
    await runtime.close();
  });
  await controller.initialize();
  await controller.enqueueManual(
    { ownerId: "connection:one", controlToken: acquired.lease.token, user: account },
    {
      targetCallsign: "JA1ABC",
      mode: "FT8",
      audioFrequencyHz: 1_300,
      txParity: "odd",
    },
  );

  now = 57_640;
  await scheduler.fire();
  assert.equal(watchdog.armed, true);
  now = 73_700;
  await controller.acceptDecoded({
    radioId: "main",
    mode: "FT8",
    slotStartMs: 60_000,
    receivedAtMs: 75_000,
    frames: [],
  });

  assert.equal(watchdog.armed, false);
  assert.equal(controller.qsoSnapshot()?.phase, "calling");
  assert.equal(scheduler.armedSlotStartMs, 75_000);
  await assert.rejects(watchdog.fire(), /no armed watchdog/u);
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

test("digital worker failure during playback immediately de-keys and requeues the call", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-digital-fault-"));
  const log = new AdifLogStore(join(directory, "station-log.adif"));
  await log.load();
  let now = 40_000;
  const rig = new DigitalFakeRig();
  const runtime = new RadioRuntime(profile(), rig, async () => undefined, () => now);
  await runtime.initialize();
  const account = user();
  const acquired = await runtime.acquireControl("connection:one", account, false);
  const scheduler = new ManualSlotScheduler([45_000]);
  const worker = new DummyDigitalWorker({ playbackDelayMs: 60_000 });
  const errors: string[] = [];
  const controller = new DigitalRadioController({
    profile: profile(),
    runtime: async () => runtime,
    worker,
    logStore: log,
    scheduler,
    now: () => now,
    onEvent: (event) => {
      if (event.t === "digital.error") errors.push(event.code);
    },
  });
  context.after(async () => {
    await controller.close();
    await runtime.close();
  });
  await controller.initialize();
  await controller.enqueueManual(
    { ownerId: "connection:one", controlToken: acquired.lease.token, user: account },
    {
      targetCallsign: "JA1ABC",
      mode: "FT8",
      audioFrequencyHz: 1_300,
      txParity: "odd",
    },
  );

  now = 45_000;
  const firing = scheduler.fire();
  await waitFor(() => rig.ptt);
  worker.injectFault(new Error("native DSP exited"));
  await firing;
  await waitFor(() => !rig.ptt);
  await waitFor(() => controller.qsoSnapshot() === null);

  assert.equal(rig.ptt, false);
  assert.equal(controller.qsoSnapshot(), null);
  assert.equal(controller.queueSnapshot().entries[0]?.status, "queued");
  assert.ok(errors.includes("digital_worker_failed"));
});

test("confirmed upstream digital stop cleans local state without a second dekey", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-digital-confirmed-stop-"));
  const log = new AdifLogStore(join(directory, "station-log.adif"));
  await log.load();
  let now = 40_000;
  const rig = new DigitalFakeRig();
  const runtime = new RadioRuntime(profile(), rig, async () => undefined, () => now);
  await runtime.initialize();
  const account = user();
  const acquired = await runtime.acquireControl("connection:one", account, false);
  const scheduler = new ManualSlotScheduler([45_000]);
  const worker = new TrackingDummyDigitalWorker({ playbackDelayMs: 60_000 });
  const errors: string[] = [];
  const controller = new DigitalRadioController({
    profile: profile(),
    runtime: async () => runtime,
    worker,
    logStore: log,
    scheduler,
    now: () => now,
    onEvent: (event) => {
      if (event.t === "digital.error") errors.push(event.code);
    },
  });
  context.after(async () => {
    await controller.close();
    await runtime.close();
  });
  await controller.initialize();
  await controller.enqueueManual(
    { ownerId: "connection:one", controlToken: acquired.lease.token, user: account },
    {
      targetCallsign: "JA1ABC",
      mode: "FT8",
      audioFrequencyHz: 1_300,
      txParity: "odd",
    },
  );
  let duplicateStops = 0;
  runtime.stopTransmitOutcome = async () => {
    duplicateStops += 1;
    throw new Error("duplicate dekey should not run");
  };

  now = 45_000;
  const firing = scheduler.fire();
  await waitFor(() => rig.ptt);
  assert.equal(await runtime.interlock.ownerDisconnected("connection:one"), true);
  await controller.ownerStoppedWithProof("connection:one");
  await firing;

  assert.equal(rig.ptt, false);
  assert.equal(duplicateStops, 0);
  assert.equal(controller.qsoSnapshot(), null);
  assert.equal(controller.queueSnapshot().entries.length, 0);
  assert.equal(errors.includes("digital_ptt_off_failed"), false);
});

test("digital stop reports unconfirmed dekey rather than swallowing InvalidLease", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-digital-invalid-lease-"));
  const log = new AdifLogStore(join(directory, "station-log.adif"));
  await log.load();
  let now = 40_000;
  const rig = new DigitalFakeRig();
  const runtime = new RadioRuntime(profile(), rig, async () => undefined, () => now);
  await runtime.initialize();
  const account = user();
  const acquired = await runtime.acquireControl("connection:one", account, false);
  const scheduler = new ManualSlotScheduler([45_000]);
  const worker = new TrackingDummyDigitalWorker({ playbackDelayMs: 60_000 });
  const errors: Array<{ code: string; message: string }> = [];
  const controller = new DigitalRadioController({
    profile: profile(),
    runtime: async () => runtime,
    worker,
    logStore: log,
    scheduler,
    now: () => now,
    onEvent: (event) => {
      if (event.t === "digital.error") errors.push({ code: event.code, message: event.message });
    },
  });
  context.after(async () => {
    await controller.close();
    await runtime.close();
  });
  await controller.initialize();
  await controller.enqueueManual(
    { ownerId: "connection:one", controlToken: acquired.lease.token, user: account },
    {
      targetCallsign: "JA1ABC",
      mode: "FT8",
      audioFrequencyHz: 1_300,
      txParity: "odd",
    },
  );

  runtime.stopTransmitOutcome = async () => {
    throw new InvalidLeaseError("transmit lease expired before the caller stopped it");
  };
  now = 45_000;
  const firing = scheduler.fire();
  await waitFor(() => rig.ptt);
  worker.injectFault(new Error("force automatic stop"));
  await firing;
  await waitFor(() => errors.some((event) => event.code === "digital_ptt_off_failed"));

  assert.equal(rig.ptt, true, "an expired caller token is not evidence that physical PTT is off");
  assert.equal(worker.stopCount > 0, true);
  assert.match(
    errors.find((event) => event.code === "digital_ptt_off_failed")?.message ?? "",
    /expired before the caller stopped/u,
  );
});

test("digital recoveryPending stop cannot record transmission or schedule another automatic QSO", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-digital-pending-dekey-"));
  const log = new AdifLogStore(join(directory, "station-log.adif"));
  await log.load();
  let now = 40_000;
  const rig = new DigitalFakeRig();
  const runtime = new RadioRuntime(profile(), rig, async () => undefined, () => now);
  await runtime.initialize();
  const account = user();
  const acquired = await runtime.acquireControl("connection:one", account, false);
  const scheduler = new ManualSlotScheduler([45_000, 75_000]);
  const worker = new TrackingDummyDigitalWorker({ playbackDelayMs: 0 });
  const errors: string[] = [];
  const controller = new DigitalRadioController({
    profile: profile(),
    runtime: async () => runtime,
    worker,
    logStore: log,
    scheduler,
    now: () => now,
    onEvent: (event) => {
      if (event.t === "digital.error") errors.push(event.code);
    },
  });
  context.after(async () => {
    await controller.close();
    await runtime.close();
  });
  await controller.initialize();
  await controller.enqueueManual(
    { ownerId: "connection:one", controlToken: acquired.lease.token, user: account },
    {
      targetCallsign: "JA1ABC",
      mode: "FT8",
      audioFrequencyHz: 1_300,
      txParity: "odd",
    },
  );
  await controller.enqueueManual(
    { ownerId: "connection:one", controlToken: acquired.lease.token, user: account },
    {
      targetCallsign: "JA2XYZ",
      mode: "FT8",
      audioFrequencyHz: 1_500,
      txParity: "odd",
    },
  );
  runtime.stopTransmitOutcome = async () => ({ kind: "recoveryPending", generation: 9 });

  now = 45_000;
  await scheduler.fire();

  assert.equal(rig.ptt, true, "pending recovery is not physical PTT OFF evidence");
  assert.equal(controller.qsoSnapshot(), null, "automatic QSO is terminated after unconfirmed OFF");
  assert.equal(controller.queueSnapshot().entries.length, 1);
  assert.equal(controller.queueSnapshot().entries[0]?.status, "queued");
  assert.equal(log.count, 0, "an unconfirmed stop cannot be recorded as a completed transmission");
  assert.equal(worker.stopCount > 0, true);
  assert.ok(errors.includes("digital_ptt_off_failed"));
  assert.ok(errors.includes("auto_qso_failed"));
  await assert.rejects(scheduler.fire(), /no armed slot/u);
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

  get armedSlotStartMs(): number | null {
    return this.#slotStartMs;
  }
}

class ManualWatchdogTimer {
  #callback: (() => void | Promise<void>) | null = null;
  delayMs: number | null = null;

  schedule(callback: () => void | Promise<void>, delayMs: number): () => void {
    if (this.#callback !== null) {
      throw new Error("test watchdog is already armed");
    }
    this.#callback = callback;
    this.delayMs = delayMs;
    return () => {
      if (this.#callback === callback) {
        this.#callback = null;
        this.delayMs = null;
      }
    };
  }

  async fire(): Promise<void> {
    const callback = this.#callback;
    this.#callback = null;
    this.delayMs = null;
    if (callback === null) {
      throw new Error("test watchdog has no armed watchdog");
    }
    await callback();
  }

  get armed(): boolean {
    return this.#callback !== null;
  }
}

class DigitalFakeRig implements RadioDriver {
  frequencyHz = 14_074_000;
  mode = "USB";
  passbandHz = 3_000;
  ptt = false;
  readonly pttEvents: boolean[] = [];

  async initialize() {}
  async close() {}
  async capabilities() { return { canTransmit: true, supportsInternalTuner: true }; }
  async readState() {
    return {
      frequencyHz: this.frequencyHz,
      mode: this.mode,
      passbandHz: this.passbandHz,
      ptt: this.ptt,
    };
  }
  async readTelemetry(_mode: "receive" | "transmit") { return {}; }
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
  async writePtt(value: boolean) {
    this.ptt = value;
    this.pttEvents.push(value);
  }
  async readPtt() { return this.ptt; }
  async supportsInternalTuner() { return true; }
  async startInternalTuner() {}
  async writeInternalTuner(_value: boolean) {}
  async readControls() { return []; }
  async setControl(_id: string, _value: RadioControlValue): Promise<never> {
    throw new Error("digital controller test rig has no adjustable controls");
  }
  async invokeAction(id: string) {
    if (id !== "action:TUNER") throw new Error("action unavailable");
    await this.startInternalTuner();
  }
}

class TrackingDummyDigitalWorker extends DummyDigitalWorker {
  stopCount = 0;

  override async stopTransmission(): Promise<void> {
    this.stopCount += 1;
    await super.stopTransmission();
  }
}

function profile(): RadioProfile {
  return {
    id: "main",
    name: "Dummy",
    hamlibModelId: 1,
    connection: { kind: "hamlib-dummy" },
    audioInput: { backend: "alsa", id: "dummy-in" },
    audioOutput: { backend: "alsa", id: "dummy-out" },
    ptt: { method: "None" },
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

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
  throw new Error("condition did not become true");
}
