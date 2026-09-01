import assert from "node:assert/strict";
import { test } from "node:test";

import type {
  RadioControl,
  RadioControlValue,
  RadioDriver,
  RadioMeterSample,
  RadioState,
} from "../src/rig/radio-driver.ts";
import { RadioTelemetrySampler } from "../src/rig/radio-telemetry.ts";

class MinimalDriver implements RadioDriver {
  async initialize() {}
  async close() {}
  async capabilities() { return { canTransmit: true, supportsInternalTuner: true }; }
  async readState(): Promise<RadioState> {
    return { frequencyHz: 14_074_000, mode: "USB", passbandHz: 3_000, ptt: false };
  }
  async readTelemetry(_mode: "receive" | "transmit"): Promise<RadioMeterSample> { return {}; }
  async readControls(): Promise<RadioControl[]> { return []; }
  async setFrequency(value: number) { return value; }
  async setMode(mode: string, passbandHz = 0) { return { mode, passbandHz }; }
  async setControl(_id: string, _value: RadioControlValue): Promise<RadioControl> {
    throw new Error("control unavailable");
  }
  async invokeAction(_id: string) {}
  async writePtt(_enabled: boolean) {}
  async readPtt() { return false; }
}

test("telemetry sampler exposes explicit transmit activity without changing physical PTT", async () => {
  const sampler = new RadioTelemetrySampler("main", new MinimalDriver());
  const candidate = sampler as unknown as {
    confirmTransmitActivity(active: boolean): void;
    snapshot(): { state: RadioState } | null;
    readState(): Promise<RadioState>;
    close(): Promise<void>;
  };

  assert.equal(typeof candidate.confirmTransmitActivity, "function");
  await candidate.readState();
  candidate.confirmTransmitActivity(true);
  assert.equal(candidate.snapshot()?.state.ptt, false);
  await candidate.close();
});
