import assert from "node:assert/strict";
import { test } from "node:test";

import type { HardwareDiscoveryResult } from "../src/config/hardware-discovery.ts";
import type { RadioProfile } from "../src/config/types.ts";
import {
  HardwarePreflight,
  HardwarePreflightCleanupUncertainError,
  hardwarePreflightRigctldTarget,
  type ReadOnlyRigSession,
} from "../src/config/hardware-preflight.ts";
import type { RigResponse } from "../src/rig/extended-protocol.ts";

const dummyProfile: RadioProfile = {
  id: "dummy",
  name: "Safe Dummy",
  hamlibModelId: 1,
  connection: { kind: "hamlib-dummy" },
  ptt: { method: "None" },
  audioInput: { backend: "pulse", id: "dummy-input" },
  audioOutput: { backend: "pulse", id: "dummy-output" },
  station: { callsign: "BI1ABC", grid: "OM89" },
  hardwareTxEnabled: false,
};

const networkProfile: RadioProfile = {
  ...dummyProfile,
  id: "main",
  name: "Network rigctld",
  hamlibModelId: 1049,
  connection: { kind: "network-rigctld", host: "100.64.0.8", port: 4_532 },
  ptt: { method: "RIG" },
  audioInput: { backend: "alsa", id: "hw:1,0" },
  audioOutput: { backend: "alsa", id: "hw:2,0" },
};

test("Dummy hardware preflight succeeds deterministically without opening hardware", async () => {
  let opened = false;
  let discovered = false;
  const preflight = new HardwarePreflight({
    now: () => 12_345,
    openRig: async () => {
      opened = true;
      throw new Error("Dummy must not open rigctld");
    },
    discover: async () => {
      discovered = true;
      throw new Error("Dummy must not inspect host hardware");
    },
  });

  const result = await preflight.test(dummyProfile);

  assert.equal(opened, false);
  assert.equal(discovered, false);
  assert.equal(result.profileId, "dummy");
  assert.equal(result.testedAtMs, 12_345);
  assert.equal(result.readOnly, true);
  assert.equal(result.overallStatus, "passed");
  assert.deepEqual(result.checks.map(({ id, status }) => ({ id, status })), [
    { id: "cat", status: "passed" },
    { id: "capabilities", status: "passed" },
    { id: "audioInput", status: "passed" },
    { id: "audioOutput", status: "passed" },
  ]);
  assert.equal(result.checks[0]?.details.frequencyHz, "14074000");
  assert.equal(result.checks[0]?.details.mode, "PKTUSB");
});

test("real-radio preflight issues only read commands and reports CAT, capabilities and audio", async () => {
  const commands: string[] = [];
  let closed = false;
  const session: ReadOnlyRigSession = {
    request: async (command) => {
      commands.push(command);
      return responseFor(command);
    },
    close: async () => { closed = true; },
  };
  const preflight = new HardwarePreflight({
    now: () => 67_890,
    openRig: async (profile) => {
      assert.deepEqual(profile, networkProfile);
      return session;
    },
    discover: async () => discoveryWithAudio(),
  });

  const result = await preflight.test(networkProfile);

  assert.equal(closed, true);
  assert.equal(result.overallStatus, "passed");
  assert.deepEqual(commands, [
    "\\get_freq",
    "\\get_mode",
    "\\get_ptt",
    "\\get_func TUNER",
    "\\get_level ?",
    "\\get_func ?",
  ]);
  assert(commands.every((command) => command.startsWith("\\get_")));
  assert(!commands.some((command) => /set_|set_ptt|TUNER 1/u.test(command)));
  const cat = result.checks.find((check) => check.id === "cat");
  assert.equal(cat?.details.frequencyHz, "14074000");
  assert.equal(cat?.details.mode, "PKTUSB");
  assert.equal(cat?.details.passbandHz, "3000");
  const capabilities = result.checks.find((check) => check.id === "capabilities");
  assert.equal(capabilities?.details.pttReadback, "true");
  assert.equal(capabilities?.details.internalTunerReadback, "true");
  assert.equal(capabilities?.details.readableLevels, "AF,RFPOWER,SQL");
  assert.equal(capabilities?.details.readableFunctions, "NB,NR,TUNER");
  assert.equal(result.checks.find((check) => check.id === "audioInput")?.status, "passed");
  assert.equal(result.checks.find((check) => check.id === "audioOutput")?.status, "passed");
});

test("preflight returns actionable failed and warning checks instead of saving or transmitting", async () => {
  let closed = false;
  const preflight = new HardwarePreflight({
    openRig: async () => ({
      request: async () => { throw new Error("rigctld connection refused accessToken=secret_value"); },
      close: async () => { closed = true; },
    }),
    discover: async () => ({
      ...discoveryWithAudio(),
      audioInputs: [],
      audioOutputs: [],
      warnings: ["audio_discovery_unavailable"],
    }),
  });

  const result = await preflight.test(networkProfile);

  assert.equal(closed, true);
  assert.equal(result.overallStatus, "failed");
  assert.equal(result.checks.find((check) => check.id === "cat")?.status, "failed");
  assert(!result.checks.find((check) => check.id === "cat")?.message.includes("secret_value"));
  assert.match(result.checks.find((check) => check.id === "cat")?.message ?? "", /\[redacted\]/u);
  assert.equal(result.checks.find((check) => check.id === "capabilities")?.status, "failed");
  const audioInput = result.checks.find((check) => check.id === "audioInput");
  const audioOutput = result.checks.find((check) => check.id === "audioOutput");
  assert.equal(audioInput?.status, "warning");
  assert.equal(audioOutput?.status, "warning");
  assert.match(audioInput?.message ?? "", /could not be enumerated/u);
  assert.match(audioOutput?.message ?? "", /could not be enumerated/u);
  assert.doesNotMatch(audioInput?.message ?? "", /was not found/u);
});

test("preflight distinguishes an empty audio inventory from unavailable enumeration", async () => {
  const preflight = new HardwarePreflight({
    openRig: async () => ({
      request: async (command) => responseFor(command),
      close: async () => undefined,
    }),
    discover: async () => ({
      ...discoveryWithAudio(),
      audioInputs: [],
      audioOutputs: [],
      warnings: [],
    }),
  });

  const result = await preflight.test(networkProfile);

  for (const id of ["audioInput", "audioOutput"] as const) {
    const check = result.checks.find((candidate) => candidate.id === id);
    assert.equal(check?.status, "warning");
    assert.match(check?.message ?? "", /was not found/u);
    assert.doesNotMatch(check?.message ?? "", /could not be enumerated/u);
  }
});

test("managed preflight reports uncertain cleanup so the serial device can remain quarantined", async () => {
  const profile: RadioProfile = {
    ...networkProfile,
    connection: {
      kind: "managed-serial",
      devicePath: "/dev/serial/by-id/usb-radio",
      baudRate: 38_400,
    },
  };
  const preflight = new HardwarePreflight({
    openRig: async () => ({
      request: async (command) => responseFor(command),
      close: async () => { throw new Error("child exit could not be confirmed"); },
    }),
    discover: async () => discoveryWithAudio(),
  });

  await assert.rejects(
    preflight.test(profile),
    HardwarePreflightCleanupUncertainError,
  );
});

test("managed preflight strips every draft PTT device and forces rigctld PTT None", () => {
  for (const ptt of [
    { method: "DTR" as const, path: "/dev/ttyUSB9" },
    { method: "RTS" as const, path: "/dev/ttyUSB8" },
    { method: "CM108" as const, path: "/dev/hidraw7" },
    { method: "GPIO" as const, path: "/dev/gpiochip0", bit: 3 },
    { method: "GPION" as const, path: "/dev/gpiochip1", bit: 5 },
  ]) {
    const profile: RadioProfile = {
      ...networkProfile,
      connection: {
        kind: "managed-serial",
        devicePath: "/dev/serial/by-id/usb-radio",
        baudRate: 38_400,
      },
      ptt,
      hardwareTxEnabled: true,
    };

    const target = hardwarePreflightRigctldTarget(profile, 47_321);
    const args = target.command?.args ?? [];

    assert.equal(target.managed, true);
    assert.deepEqual(args.slice(args.indexOf("-P"), args.indexOf("-P") + 2), ["-P", "NONE"]);
    assert(!args.includes(ptt.method));
    assert(!args.includes(ptt.path));
    assert(!args.some((argument) => argument.startsWith("ptt_bitnum=")));
    assert.equal(profile.ptt, ptt);
    assert.equal(profile.hardwareTxEnabled, true);
  }
});

test("network preflight preserves the external rigctld target without creating a managed command", () => {
  const target = hardwarePreflightRigctldTarget(networkProfile, 47_322);

  assert.deepEqual(target, {
    managed: false,
    host: "100.64.0.8",
    port: 4_532,
  });
});

function responseFor(command: string): RigResponse {
  switch (command) {
  case "\\get_freq":
    return response(command, { Frequency: "14074000" });
  case "\\get_mode":
    return response(command, { Mode: "PKTUSB", Passband: "3000" });
  case "\\get_ptt":
    return response(command, { PTT: "0" });
  case "\\get_func TUNER":
    return response(command, { TUNER: "0" });
  case "\\get_level ?":
    return response(command, { Level: "AF RFPOWER SQL" });
  case "\\get_func ?":
    return response(command, { Func: "NB NR TUNER" });
  default:
    throw new Error(`unexpected command: ${command}`);
  }
}

function response(command: string, fields: Record<string, string>): RigResponse {
  return {
    command: command.slice(1).split(" ", 1)[0] ?? "unknown",
    fields: new Map(Object.entries(fields)),
    values: [],
    report: 0,
  };
}

function discoveryWithAudio(): HardwareDiscoveryResult {
  return {
    hamlibModels: [],
    curatedPresets: [],
    serialDevices: [],
    audioInputs: [{ backend: "alsa", direction: "input", id: "hw:1,0", label: "USB input" }],
    audioOutputs: [{ backend: "alsa", direction: "output", id: "hw:2,0", label: "USB output" }],
    pttMethods: ["RIG"],
    baudRates: [38_400],
    warnings: [],
  };
}
