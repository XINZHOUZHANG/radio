import assert from "node:assert/strict";
import { test } from "node:test";

import { BoundedDriverAudioDuplex } from "../src/media/driver-audio.ts";
import { IcomWlanDriver } from "../src/rig/icom-wlan-driver.ts";
import type {
  IcomWlanControlId,
  IcomWlanMeters,
  IcomWlanMode,
  IcomWlanPort,
  IcomWlanPortCapabilities,
} from "../src/rig/icom-wlan-port.ts";

class FakeIcomWlanPort implements IcomWlanPort {
  readonly calls: string[] = [];
  readonly audio = new BoundedDriverAudioDuplex(async (frame) => {
    this.transmittedAudio.push(frame);
  });
  readonly transmittedAudio: Int16Array[] = [];
  frequencyHz = 14_074_000;
  mode: IcomWlanMode = { mode: "USB", dataMode: true };
  ptt = false;
  meters: IcomWlanMeters = {
    strengthDbRelativeS9: -12,
    swr: 1.4,
    alcPercent: 32,
    rfPowerPercent: 48,
    rfPowerWatts: 4.8,
  };
  readonly controlValues = new Map<IcomWlanControlId, boolean | number>([
    ["operation:SPLIT", false],
    ["operation:RIT", 125],
    ["operation:XIT", -250],
  ]);
  readonly #fatalListeners = new Set<(error: Error) => void>();

  async initialize(): Promise<void> {
    this.calls.push("initialize");
  }

  async close(): Promise<void> {
    this.calls.push("close");
    this.audio.close();
  }

  async capabilities(): Promise<IcomWlanPortCapabilities> {
    return {
      model: "IC-705",
      canTransmit: true,
      supportsInternalTuner: true,
      controls: [...this.controlValues.keys()],
    };
  }

  async readFrequency(): Promise<number> {
    this.calls.push("readFrequency");
    return this.frequencyHz;
  }

  async writeFrequency(frequencyHz: number): Promise<void> {
    this.calls.push(`writeFrequency:${frequencyHz}`);
    this.frequencyHz = frequencyHz;
  }

  async readMode(): Promise<IcomWlanMode> {
    this.calls.push("readMode");
    return { ...this.mode };
  }

  async writeMode(mode: IcomWlanMode): Promise<void> {
    this.calls.push(`writeMode:${mode.mode}:${mode.dataMode}`);
    this.mode = { ...mode };
  }

  async readPtt(): Promise<boolean> {
    this.calls.push("readPtt");
    return this.ptt;
  }

  async writePtt(enabled: boolean): Promise<void> {
    this.calls.push(`writePtt:${enabled}`);
    this.ptt = enabled;
  }

  async readMeters(): Promise<IcomWlanMeters> {
    this.calls.push("readMeters");
    return { ...this.meters };
  }

  async readControl(id: IcomWlanControlId): Promise<boolean | number> {
    this.calls.push(`readControl:${id}`);
    const value = this.controlValues.get(id);
    if (value === undefined) throw new Error("control unavailable");
    return value;
  }

  async writeControl(id: IcomWlanControlId, value: boolean | number): Promise<void> {
    this.calls.push(`writeControl:${id}:${value}`);
    this.controlValues.set(id, value);
  }

  async invokeTuner(): Promise<void> {
    this.calls.push("invokeTuner");
  }

  onFatalConnection(listener: (error: Error) => void): () => void {
    this.#fatalListeners.add(listener);
    return () => this.#fatalListeners.delete(listener);
  }

  emitAudio(frame: Int16Array): void {
    this.audio.pushRx(frame);
  }

  emitFatal(): void {
    for (const listener of this.#fatalListeners) listener(new Error("ICOM WLAN connection lost"));
  }
}

test("ICOM driver normalizes state and confirms frequency and mode writes", async () => {
  const port = new FakeIcomWlanPort();
  const driver = new IcomWlanDriver(port);

  assert.deepEqual(await driver.readState(), {
    frequencyHz: 14_074_000,
    mode: "USB-D",
    passbandHz: 0,
    ptt: false,
  });
  assert.equal(await driver.setFrequency(7_074_000), 7_074_000);
  assert.deepEqual(await driver.setMode("LSB"), { mode: "LSB", passbandHz: 0 });
});

test("ICOM driver confirms PTT by read-back and keeps OFF idempotent", async () => {
  const port = new FakeIcomWlanPort();
  const driver = new IcomWlanDriver(port);

  await driver.writePtt(true);
  assert.deepEqual(port.calls.slice(-2), ["writePtt:true", "readPtt"]);
  await driver.writePtt(false);
  await driver.writePtt(false);

  assert.equal(await driver.readPtt(), false);
  assert.equal(port.calls.filter((call) => call === "writePtt:false").length, 2);
});

test("ICOM driver rejects an unconfirmed PTT transition", async () => {
  const port = new FakeIcomWlanPort();
  port.writePtt = async (enabled) => {
    port.calls.push(`writePtt:${enabled}`);
  };
  const driver = new IcomWlanDriver(port);

  await assert.rejects(driver.writePtt(true), /PTT read-back mismatch/u);
});

test("ICOM driver normalizes receive and transmit meters", async () => {
  const port = new FakeIcomWlanPort();
  const driver = new IcomWlanDriver(port);

  assert.deepEqual(await driver.readTelemetry("receive"), {
    strengthDbRelativeS9: -12,
    availableMeters: ["STRENGTH"],
  });
  assert.deepEqual(await driver.readTelemetry("transmit"), {
    ptt: false,
    swr: 1.4,
    alcRatio: 0.32,
    rfPowerRatio: 0.48,
    rfPowerWatts: 4.8,
    availableMeters: ["SWR", "ALC", "RFPOWER_METER", "RFPOWER_METER_WATTS"],
  });
});

test("ICOM driver exposes only documented available controls", async () => {
  const port = new FakeIcomWlanPort();
  port.controlValues.delete("operation:XIT");
  const driver = new IcomWlanDriver(port);

  assert.deepEqual((await driver.readControls()).map((control) => control.id), [
    "operation:SPLIT",
    "operation:RIT",
  ]);
  assert.deepEqual(await driver.setControl("operation:SPLIT", true), {
    id: "operation:SPLIT",
    kind: "operation",
    token: "SPLIT",
    group: "mode",
    access: "read-write",
    presentation: "toggle",
    value: true,
    unit: "boolean",
    transmitLocked: true,
  });
  await assert.rejects(driver.setControl("operation:XIT", 10), /unavailable/u);
});

test("ICOM driver forwards exact audio frames and surfaces fatal disconnect", async () => {
  const port = new FakeIcomWlanPort();
  const driver = new IcomWlanDriver(port);
  const fatal = new Promise<Error>((resolve) => driver.onFatalConnection(resolve));
  const frame = Int16Array.of(100, -100, 200, -200);

  port.emitAudio(frame);
  assert.deepEqual(await driver.audio.read(), frame);
  await driver.audio.write(frame);
  assert.deepEqual(port.transmittedAudio, [frame]);

  port.emitFatal();
  assert.match((await fatal).message, /connection lost/u);
});
