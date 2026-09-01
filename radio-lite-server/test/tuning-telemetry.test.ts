import assert from "node:assert/strict";
import { test } from "node:test";

import type { PublicUser } from "../src/auth/user-store.ts";
import { parseRadioProfile } from "../src/config/types.ts";
import type {
  RadioControl,
  RadioControlValue,
  RadioDriver,
  RadioMeterSample,
  RadioState,
} from "../src/rig/radio-driver.ts";
import { RadioRuntime } from "../src/rig/radio-runtime.ts";
import {
  RadioTelemetrySampler,
  type RadioTelemetryClock,
} from "../src/rig/radio-telemetry.ts";

class TuningMeterDriver implements RadioDriver {
  readonly state: RadioState = {
    frequencyHz: 14_074_000,
    mode: "USB",
    passbandHz: 3_000,
    ptt: false,
  };
  readonly telemetryModes: Array<"receive" | "transmit"> = [];
  readonly events: string[] = [];
  tunerEnabled = false;

  async initialize() {}
  async close() {}
  async capabilities() { return { canTransmit: true, supportsInternalTuner: true }; }
  async readState() { return { ...this.state }; }
  async readTelemetry(mode: "receive" | "transmit"): Promise<RadioMeterSample> {
    this.telemetryModes.push(mode);
    if (mode === "receive") {
      return {
        strengthDbRelativeS9: -12,
        availableMeters: ["STRENGTH", "SWR", "ALC", "RFPOWER_METER_WATTS"],
      };
    }
    return {
      ptt: false,
      swr: 1.3,
      alcRatio: 0.18,
      rfPowerWatts: 9.5,
      availableMeters: ["STRENGTH", "SWR", "ALC", "RFPOWER_METER_WATTS"],
    };
  }
  async readControls(): Promise<RadioControl[]> {
    return [{
      id: "function:TUNER",
      kind: "function",
      token: "TUNER",
      group: "rf",
      access: "read-write",
      presentation: "toggle",
      value: this.tunerEnabled,
      minimum: 0,
      maximum: 1,
      step: 1,
      unit: "boolean",
      transmitLocked: true,
    }, {
      id: "action:TUNER",
      kind: "action",
      token: "TUNER",
      group: "rf",
      access: "action",
      presentation: "button",
      value: null,
      transmitLocked: true,
    }];
  }
  async setFrequency(frequencyHz: number) { this.state.frequencyHz = frequencyHz; return frequencyHz; }
  async setMode(mode: string, passbandHz = 0) {
    this.state.mode = mode;
    this.state.passbandHz = passbandHz;
    return { mode, passbandHz };
  }
  async setControl(id: string, value: RadioControlValue): Promise<RadioControl> {
    if (id !== "function:TUNER" || typeof value !== "boolean") {
      throw new Error("control unavailable");
    }
    this.tunerEnabled = value;
    return (await this.readControls())[0]!;
  }
  async invokeAction(id: string) {
    if (id !== "action:TUNER") throw new Error("action unavailable");
    this.tunerEnabled = true;
    this.events.push("tune");
  }
  async writePtt(enabled: boolean) {
    this.state.ptt = enabled;
    this.events.push(`ptt-write:${enabled}`);
  }
  async readPtt() {
    this.events.push(`ptt-read:${this.state.ptt}`);
    return this.state.ptt;
  }
}

test("explicit tuning activity samples transmit meters without falsifying physical PTT", async () => {
  const driver = new TuningMeterDriver();
  const clock = new ManualClock();
  const sampler = new RadioTelemetrySampler("main", driver, { clock });
  sampler.start();
  await sampler.readState();

  sampler.confirmTransmitActivity(true);
  await clock.advanceBy(1_000);

  assert.deepEqual(driver.telemetryModes, ["receive", "transmit"]);
  assert.equal(sampler.snapshot()?.state.ptt, false);
  assert.equal(sampler.snapshot()?.meters.rfPowerWatts, 9.5);
  assert.equal(sampler.snapshot()?.meters.alcRatio, 0.18);

  sampler.confirmTransmitActivity(false);
  await clock.advanceBy(2_000);

  assert.deepEqual(driver.telemetryModes, ["receive", "transmit", "receive"]);
  assert.equal(sampler.snapshot()?.meters.rfPowerWatts, undefined);
  await sampler.close();
});

test("runtime tuning lease activates transmit meters and confirmed stop restores receive sampling", async (context) => {
  const driver = new TuningMeterDriver();
  const clock = new ManualClock();
  const runtime = new RadioRuntime(profile(), driver, undefined, clock.now, {
    telemetryClock: clock,
  });
  context.after(() => runtime.close());
  await runtime.initialize();
  const operator = user();
  const control = await runtime.acquireControl("device-a", operator);

  const transmit = await runtime.startTransmit(
    "device-a",
    operator,
    control.lease.token,
    "tuning",
  );
  await clock.advanceBy(1_000);

  assert.deepEqual(driver.telemetryModes, ["receive", "transmit"]);
  assert.equal(runtime.telemetry.snapshot()?.state.ptt, false);
  assert.equal(runtime.telemetry.snapshot()?.meters.rfPowerWatts, 9.5);
  assert.equal(runtime.telemetry.snapshot()?.meters.swr, 1.3);

  await runtime.stopTransmit("device-a", transmit.leaseToken);
  await clock.advanceBy(2_000);

  assert.deepEqual(driver.telemetryModes, ["receive", "transmit", "receive"]);
  assert.equal(runtime.telemetry.snapshot()?.meters.alcRatio, undefined);
});

test("successful tuner action updates the cached persistent tuner switch", async (context) => {
  const driver = new TuningMeterDriver();
  const runtime = new RadioRuntime(profile(), driver);
  context.after(() => runtime.close());
  await runtime.initialize();
  const operator = user();
  const control = await runtime.acquireControl("device-a", operator);

  assert.equal(
    (await runtime.readControls()).find(({ id }) => id === "function:TUNER")?.value,
    false,
  );
  const transmit = await runtime.invokeAction(
    "device-a",
    operator,
    control.lease.token,
    "action:TUNER",
  );

  assert.equal(driver.tunerEnabled, true);
  assert.equal(
    (await runtime.readControls()).find(({ id }) => id === "function:TUNER")?.value,
    true,
  );
  await runtime.stopTransmit("device-a", transmit.leaseToken);
});

function profile() {
  return parseRadioProfile({
    id: "main",
    name: "Test radio",
    hamlibModelId: 1049,
    connection: { kind: "network-rigctld", host: "127.0.0.1", port: 4532 },
    audioInput: { backend: "alsa", id: "hw:1,0" },
    audioOutput: { backend: "alsa", id: "hw:1,0" },
    station: { callsign: "BI1ABC", grid: "OM89" },
    hardwareTxEnabled: true,
  });
}

function user(): PublicUser {
  return {
    id: "operator-a",
    username: "operator-a",
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

type Timer = { atMs: number; callback: () => void; active: boolean };

class ManualClock implements RadioTelemetryClock {
  nowMs = 10_000;
  readonly timers: Timer[] = [];
  now = () => this.nowMs;

  setTimeout(callback: () => void, delayMs: number): Timer {
    const timer = { atMs: this.nowMs + delayMs, callback, active: true };
    this.timers.push(timer);
    return timer;
  }

  clearTimeout(timer: unknown): void {
    (timer as Timer).active = false;
  }

  async advanceBy(milliseconds: number): Promise<void> {
    const target = this.nowMs + milliseconds;
    while (true) {
      const next = this.timers
        .filter((timer) => timer.active && timer.atMs <= target)
        .sort((left, right) => left.atMs - right.atMs)[0];
      if (next === undefined) break;
      this.nowMs = next.atMs;
      next.active = false;
      next.callback();
      await new Promise<void>((resolve) => setImmediate(resolve));
    }
    this.nowMs = target;
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
}
