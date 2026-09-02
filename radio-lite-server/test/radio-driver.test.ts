import assert from "node:assert/strict";
import { test } from "node:test";

import { HamlibDriver } from "../src/rig/hamlib-driver.ts";
import { HamlibRig, type RigRequester } from "../src/rig/hamlib-rig.ts";
import type {
  RadioCapabilities,
  RadioControl,
  RadioControlValue,
  RadioDriver,
  RadioMeterSample,
  RadioModeState,
  RadioReadOptions,
  RadioState,
} from "../src/rig/radio-driver.ts";
import { RadioRuntime } from "../src/rig/radio-runtime.ts";
import type { RadioProfile } from "../src/config/types.ts";
import type { PublicUser } from "../src/auth/user-store.ts";
import type { RigResponse } from "../src/rig/extended-protocol.ts";
import type { RigRequestOptions } from "../src/rig/transport.ts";

class FakeRadioDriver implements RadioDriver {
  initializeCalls = 0;
  closeCalls = 0;
  ptt = false;
  readonly events: string[] = [];

  async initialize(): Promise<void> {
    this.initializeCalls += 1;
    this.events.push("initialize");
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
    this.events.push("close");
  }

  async capabilities(): Promise<RadioCapabilities> {
    return { canTransmit: true, supportsInternalTuner: true };
  }

  async readState(_options?: RadioReadOptions): Promise<RadioState> {
    return { frequencyHz: 14_074_000, mode: "USB", passbandHz: 3_000, ptt: this.ptt };
  }

  async readTelemetry(_mode: "receive" | "transmit"): Promise<RadioMeterSample> {
    return {};
  }

  async readControls(): Promise<RadioControl[]> {
    return [];
  }

  async setFrequency(frequencyHz: number): Promise<number> {
    return frequencyHz;
  }

  async setMode(mode: string, passbandHz = 0): Promise<RadioModeState> {
    return { mode, passbandHz };
  }

  async setControl(_id: string, _value: RadioControlValue): Promise<RadioControl> {
    throw new Error("no controls are available");
  }

  async invokeAction(id: string): Promise<void> {
    if (id !== "action:TUNER") throw new Error(`action ${id} is unavailable`);
    this.events.push("tuner");
  }

  async writePtt(enabled: boolean): Promise<void> {
    this.ptt = enabled;
    this.events.push(`write:${enabled}`);
  }

  async readPtt(): Promise<boolean> {
    this.events.push(`read:${this.ptt}`);
    return this.ptt;
  }
}

class RecordingRequester implements RigRequester {
  readonly commands: string[] = [];
  readonly requests: Array<{ command: string; options: RigRequestOptions | undefined }> = [];

  async request(command: string, options?: RigRequestOptions): Promise<RigResponse> {
    this.commands.push(command);
    this.requests.push({ command, options });
    if (command === "\\get_ptt") {
      return { command: "get_ptt", fields: new Map([["PTT", "0"]]), values: [], report: 0 };
    }
    return { command: command.slice(1), fields: new Map(), values: [], report: 0 };
  }
}

test("RadioRuntime accepts a transport-neutral driver and preserves strict PTT", async () => {
  const driver = new FakeRadioDriver();
  const runtime = new RadioRuntime(profile(), driver);

  await runtime.initialize();
  assert.equal(driver.initializeCalls, 1);
  assert.deepEqual(driver.events, ["initialize", "read:false"]);

  const control = await runtime.acquireControl("device", user());
  const transmit = await runtime.startTransmit("device", user(), control.lease.token, "voice");
  assert.deepEqual(driver.events.slice(-2), ["write:true", "read:true"]);
  await runtime.stopTransmit("device", transmit.leaseToken);

  await runtime.close();
  assert.equal(driver.closeCalls, 1);
});

test("HamlibDriver never maps RFPOWER to measured RF power", async () => {
  const requester = new RecordingRequester();
  const driver = new HamlibDriver(new HamlibRig(requester));

  const sample = await driver.readTelemetry("transmit");

  assert.equal(sample.rfPowerRatio, undefined);
  assert.equal(requester.commands.includes("\\get_level RFPOWER"), false);
});

test("HamlibDriver uses ordinary PTT evidence for ON confirmation and safety evidence for OFF recovery", async () => {
  const requester = new RecordingRequester();
  const driver = new HamlibDriver(new HamlibRig(requester));

  await driver.writePtt(true);
  await driver.readPtt();
  await driver.readPtt({ purpose: "off-recovery" });

  assert.deepEqual(
    requester.requests.filter((request) => request.command === "\\get_ptt").map((request) => request.options),
    [
      { source: "control" },
      { priority: "safety", source: "ptt-off" },
    ],
  );
});

function profile(): RadioProfile {
  return {
    id: "main",
    name: "Main",
    hamlibModelId: 1035,
    connection: { kind: "network-rigctld", host: "127.0.0.1", port: 4532 },
    audioInput: { backend: "alsa", id: "input" },
    audioOutput: { backend: "alsa", id: "output" },
    ptt: { method: "RIG" },
    station: { callsign: "BI1XYZ", grid: "OM89" },
    hardwareTxEnabled: true,
  };
}

function user(): PublicUser {
  return {
    id: "operator",
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
