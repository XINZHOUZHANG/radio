import assert from "node:assert/strict";
import { test } from "node:test";

import type { RigResponse } from "../src/rig/extended-protocol.ts";
import { HamlibDriver } from "../src/rig/hamlib-driver.ts";
import { HamlibRig } from "../src/rig/hamlib-rig.ts";
import type {
  RadioControl,
  RadioControlValue,
  RadioDriver,
  RadioMeterSample,
  RadioState,
} from "../src/rig/radio-driver.ts";
import {
  RadioTelemetrySampler,
  type RadioTelemetry,
  type RadioTelemetryClock,
} from "../src/rig/radio-telemetry.ts";
import {
  RigReportError,
  RigTelemetryDroppedError,
  type RigRequestOptions,
} from "../src/rig/transport.ts";

test("two subscribers and a legacy state read share one receive sample", async () => {
  const driver = new CountingDriver({
    frequencyHz: 14_074_000,
    mode: "USB",
    passbandHz: 3_000,
    ptt: false,
  });
  const clock = new ManualTelemetryClock();
  const sampler = new RadioTelemetrySampler("main", driver, { clock });
  sampler.start();
  const first: RadioTelemetry[] = [];
  const second: RadioTelemetry[] = [];

  sampler.subscribe((value) => first.push(value));
  sampler.subscribe((value) => second.push(value));
  const legacy = sampler.readState();
  await clock.flush();

  assert.deepEqual(await legacy, {
    frequencyHz: 14_074_000,
    mode: "USB",
    passbandHz: 3_000,
    ptt: false,
  });
  assert.equal(driver.receiveCommandCount, 4);
  assert.deepEqual(first, second);
  assert.equal(first.length, 1);
  await sampler.close();
});

test("an ad-hoc first sample re-arms the periodic receive deadline", async () => {
  const driver = new CountingDriver({
    frequencyHz: 14_074_000,
    mode: "USB",
    passbandHz: 3_000,
    ptt: false,
  });
  const clock = new ManualTelemetryClock();
  const sampler = new RadioTelemetrySampler("main", driver, { clock });
  sampler.start();
  await clock.advanceBy(1_900);

  sampler.subscribe(() => undefined);
  await clock.flush();
  await clock.advanceBy(100);

  assert.equal(driver.readStateCalls, 1);
  await clock.advanceBy(1_900);
  assert.equal(driver.readStateCalls, 2);
  await sampler.close();
});

test("transmit ticks reuse cached tuning state and remain four commands", async () => {
  const driver = new CountingDriver({
    frequencyHz: 7_074_000,
    mode: "PKTUSB",
    passbandHz: 3_000,
    ptt: false,
  });
  const clock = new ManualTelemetryClock();
  const sampler = new RadioTelemetrySampler("main", driver, { clock });
  sampler.start();

  await sampler.readState();
  sampler.confirmPtt(true);
  await clock.advanceBy(1_000);

  assert.equal(driver.readStateCalls, 1);
  assert.equal(driver.receiveCommandCount, 4);
  assert.equal(driver.transmitCommandCount, 4);
  assert.deepEqual(driver.telemetryModes, ["receive", "transmit"]);
  assert.equal(sampler.snapshot()?.state.ptt, true);
  assert.equal(sampler.snapshot()?.meters.strengthDbRelativeS9, undefined);
  assert.equal(sampler.snapshot()?.meters.swr, 1.4);
  await sampler.close();
});

test("a dropped telemetry tick does not stop later sampling", async () => {
  const driver = new CountingDriver({
    frequencyHz: 7_074_000,
    mode: "USB",
    passbandHz: 2_400,
    ptt: false,
  });
  const clock = new ManualTelemetryClock();
  const sampler = new RadioTelemetrySampler("main", driver, { clock });
  const values: RadioTelemetry[] = [];
  sampler.start();
  sampler.subscribe((value) => values.push(value));
  await clock.flush();

  driver.dropNextTick = true;
  await clock.advanceBy(2_000);
  await clock.advanceBy(2_000);

  assert.equal(values.length, 2);
  assert.equal(driver.readStateCalls, 3);
  await sampler.close();
});

test("unsubscribing one listener leaves the other listener active", async () => {
  const driver = new CountingDriver({
    frequencyHz: 14_074_000,
    mode: "USB",
    passbandHz: 3_000,
    ptt: false,
  });
  const clock = new ManualTelemetryClock();
  const sampler = new RadioTelemetrySampler("main", driver, { clock });
  const first: RadioTelemetry[] = [];
  const second: RadioTelemetry[] = [];
  sampler.start();
  const unsubscribeFirst = sampler.subscribe((value) => first.push(value));
  sampler.subscribe((value) => second.push(value));
  await clock.flush();

  unsubscribeFirst();
  await clock.advanceBy(2_000);

  assert.equal(first.length, 1);
  assert.equal(second.length, 2);
  await sampler.close();
});

test("a concurrent confirmed write does not erase other freshly sampled state", async () => {
  const driver = new DeferredStateDriver({
    frequencyHz: 14_074_000,
    mode: "USB",
    passbandHz: 3_000,
    ptt: false,
  });
  const clock = new ManualTelemetryClock();
  const sampler = new RadioTelemetrySampler("main", driver, { clock });
  sampler.start();
  await sampler.readState();
  driver.state.mode = "FM";
  driver.state.passbandHz = 12_000;
  driver.blockNextRead = true;

  const ticking = clock.advanceBy(2_000);
  await driver.readStarted.promise;
  sampler.confirmFrequency(7_074_000);
  driver.allowRead.resolve();
  await ticking;

  assert.deepEqual(sampler.snapshot()?.state, {
    frequencyHz: 7_074_000,
    mode: "FM",
    passbandHz: 12_000,
    ptt: false,
  });
  await sampler.close();
});

test("transmit telemetry uses telemetry PTT and one discovered actual-power token", async () => {
  const requester = new MeterRequester();
  const transportModes: string[] = [];
  const driver = new HamlibDriver(new HamlibRig(requester), {
    onTransportMode: (mode) => transportModes.push(mode),
  });
  await driver.initialize();
  assert.deepEqual(requester.requests.map((value) => value.command), ["\\get_level ?"]);
  requester.requests.length = 0;

  const sample = await driver.readTelemetry("transmit");

  assert.deepEqual(requester.requests.map((value) => value.command), [
    "\\get_ptt",
    "\\get_level SWR",
    "\\get_level ALC",
    "\\get_level RFPOWER_METER_WATTS",
  ]);
  assert.equal(requester.requests.find((value) => value.command === "\\get_ptt")?.options?.source, "telemetry");
  assert.equal(requester.requests.filter((value) => value.options?.priority === "safety").length, 0);
  assert.equal(requester.requests.some((value) => value.command === "\\get_level RFPOWER"), false);
  assert.deepEqual(transportModes, ["transmit"]);
  assert.deepEqual(sample, {
    ptt: true,
    swr: 1.4,
    alcRatio: 0.2,
    rfPowerWatts: 37,
    availableMeters: ["STRENGTH", "SWR", "ALC", "RFPOWER_METER_WATTS"],
  });
});

test("receive state telemetry raises the CAT budget when external PTT is observed", async () => {
  const requester = new MeterRequester();
  const transportModes: string[] = [];
  const driver = new HamlibDriver(new HamlibRig(requester), {
    onTransportMode: (mode) => transportModes.push(mode),
  });

  const state = await driver.readState({ source: "telemetry" });

  assert.equal(state.ptt, true);
  assert.deepEqual(transportModes, ["transmit"]);
});

test("RPRT -11 disables only the affected meter and falls back on a later tick", async () => {
  const requester = new MeterRequester();
  requester.unavailableOnce.add("RFPOWER_METER_WATTS");
  const driver = new HamlibDriver(new HamlibRig(requester));
  await driver.initialize();
  requester.requests.length = 0;

  const first = await driver.readTelemetry("transmit");
  const second = await driver.readTelemetry("transmit");

  assert.equal(first.rfPowerWatts, undefined);
  assert.equal(first.swr, 1.4);
  assert.equal(first.alcRatio, 0.2);
  assert.equal(second.rfPowerRatio, 0.5);
  assert.deepEqual(requester.requests.map((value) => value.command), [
    "\\get_ptt",
    "\\get_level SWR",
    "\\get_level ALC",
    "\\get_level RFPOWER_METER_WATTS",
    "\\get_ptt",
    "\\get_level SWR",
    "\\get_level ALC",
    "\\get_level RFPOWER_METER",
  ]);
});

class CountingDriver implements RadioDriver {
  readonly telemetryModes: Array<"receive" | "transmit"> = [];
  readStateCalls = 0;
  receiveCommandCount = 0;
  transmitCommandCount = 0;
  dropNextTick = false;

  readonly state: RadioState;

  constructor(state: RadioState) {
    this.state = state;
  }

  async initialize() {}
  async close() {}
  async capabilities() { return { canTransmit: true, supportsInternalTuner: true }; }
  async readState() {
    this.readStateCalls += 1;
    this.receiveCommandCount += 3;
    return { ...this.state };
  }
  async readTelemetry(mode: "receive" | "transmit"): Promise<RadioMeterSample> {
    this.telemetryModes.push(mode);
    if (this.dropNextTick) {
      this.dropNextTick = false;
      throw new RigTelemetryDroppedError("rig_telemetry_dropped");
    }
    if (mode === "receive") {
      this.receiveCommandCount += 1;
      return {
        strengthDbRelativeS9: -7,
        availableMeters: ["STRENGTH", "SWR", "ALC", "RFPOWER_METER_WATTS"],
      };
    }
    this.transmitCommandCount += 4;
    return {
      ptt: true,
      swr: 1.4,
      alcRatio: 0.2,
      rfPowerWatts: 37,
      availableMeters: ["STRENGTH", "SWR", "ALC", "RFPOWER_METER_WATTS"],
    };
  }
  async readControls(): Promise<RadioControl[]> { return []; }
  async setFrequency(value: number) { this.state.frequencyHz = value; return value; }
  async setMode(mode: string, passbandHz = 0) {
    this.state.mode = mode;
    this.state.passbandHz = passbandHz;
    return { mode, passbandHz };
  }
  async setControl(_id: string, _value: RadioControlValue): Promise<RadioControl> {
    throw new Error("control unavailable");
  }
  async invokeAction(_id: string) { throw new Error("action unavailable"); }
  async writePtt(value: boolean) { this.state.ptt = value; }
  async readPtt() { return this.state.ptt; }
}

class DeferredStateDriver extends CountingDriver {
  readonly readStarted = deferred<void>();
  readonly allowRead = deferred<void>();
  blockNextRead = false;

  override async readState() {
    if (this.blockNextRead) {
      this.blockNextRead = false;
      this.readStarted.resolve();
      await this.allowRead.promise;
    }
    return super.readState();
  }
}

type Timer = { atMs: number; callback: () => void; active: boolean };

class ManualTelemetryClock implements RadioTelemetryClock {
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

  async flush(): Promise<void> {
    await Promise.resolve();
    await Promise.resolve();
    await new Promise<void>((resolve) => setImmediate(resolve));
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
      await this.flush();
    }
    this.nowMs = target;
    await this.flush();
  }
}

class MeterRequester {
  readonly requests: Array<{ command: string; options?: RigRequestOptions }> = [];
  readonly unavailableOnce = new Set<string>();

  async request(command: string, options?: RigRequestOptions): Promise<RigResponse> {
    this.requests.push({ command, options });
    if (command === "\\get_level ?") {
      return response("get_level", {
        Level: "STRENGTH SWR ALC RFPOWER RFPOWER_METER_WATTS RFPOWER_METER",
      });
    }
    if (command === "\\get_freq") return response("get_freq", { Frequency: "14074000" });
    if (command === "\\get_mode") {
      return response("get_mode", { Mode: "USB", Passband: "3000" });
    }
    if (command === "\\get_ptt") return response("get_ptt", { PTT: "1" });
    const token = command.match(/^\\get_level (.+)$/u)?.[1];
    if (token !== undefined && this.unavailableOnce.delete(token)) {
      throw new RigReportError("get_level", -11);
    }
    if (token === "STRENGTH") return response("get_level", {}, ["-7"]);
    if (token === "SWR") return response("get_level", {}, ["1.4"]);
    if (token === "ALC") return response("get_level", {}, ["0.2"]);
    if (token === "RFPOWER_METER_WATTS") return response("get_level", {}, ["37"]);
    if (token === "RFPOWER_METER") return response("get_level", {}, ["0.5"]);
    throw new Error(`unexpected CAT command: ${command}`);
  }
}

function response(
  command: string,
  fields: Record<string, string> = {},
  values: string[] = [],
): RigResponse {
  return {
    command,
    fields: new Map(Object.entries(fields)),
    values,
    report: 0,
  };
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
} {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}
