import assert from "node:assert/strict";
import { test } from "node:test";

import type { HardwareDiscoveryResult } from "../src/config/hardware-discovery.ts";
import type { RadioProfile } from "../src/config/types.ts";
import {
  HardwarePreflight,
  HardwarePreflightCleanupUncertainError,
  hardwarePreflightRigctldTarget,
  resolveAudioRoute,
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
  let commandsProbed = false;
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
    commandAvailable: async () => {
      commandsProbed = true;
      throw new Error("Dummy must not probe system commands");
    },
  });

  const result = await preflight.test(dummyProfile);

  assert.equal(opened, false);
  assert.equal(discovered, false);
  assert.equal(commandsProbed, false);
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
    commandAvailable: async () => true,
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
    commandAvailable: async () => true,
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
    commandAvailable: async () => true,
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
    commandAvailable: async () => true,
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

test("preflight probes the exact ALSA media commands needed by each audio direction", async () => {
  const commands: string[] = [];
  const preflight = new HardwarePreflight({
    openRig: async () => readOnlySession(),
    discover: async () => discoveryWithAudio(),
    commandAvailable: async (command) => {
      commands.push(command);
      return true;
    },
  });

  const result = await preflight.test(networkProfile);

  assert.equal(result.overallStatus, "passed");
  assert.deepEqual(commands, ["arecord", "stdbuf", "opusenc", "stdbuf", "opusdec", "aplay"]);
});

test("preflight probes the exact PulseAudio media commands needed by each audio direction", async () => {
  const commands: string[] = [];
  const pulseProfile: RadioProfile = {
    ...networkProfile,
    audioInput: { backend: "pulse", id: "rx" },
    audioOutput: { backend: "pulse", id: "tx" },
  };
  const preflight = new HardwarePreflight({
    openRig: async () => readOnlySession(),
    discover: async () => ({
      ...discoveryWithAudio(),
      audioInputs: [{ backend: "pulse", direction: "input", id: "rx", label: "Pulse RX" }],
      audioOutputs: [{ backend: "pulse", direction: "output", id: "tx", label: "Pulse TX" }],
    }),
    commandAvailable: async (command) => {
      commands.push(command);
      return true;
    },
  });

  const result = await preflight.test(pulseProfile);

  assert.equal(result.overallStatus, "passed");
  assert.deepEqual(commands, ["parec", "stdbuf", "opusenc", "stdbuf", "opusdec", "pacat"]);
});

test("a missing input command fails only the audio-input preflight check", async () => {
  const preflight = new HardwarePreflight({
    openRig: async () => readOnlySession(),
    discover: async () => discoveryWithAudio(),
    commandAvailable: async (command) => command !== "arecord",
  });

  const result = await preflight.test(networkProfile);

  const input = result.checks.find((check) => check.id === "audioInput");
  const output = result.checks.find((check) => check.id === "audioOutput");
  assert.equal(result.overallStatus, "failed");
  assert.equal(input?.status, "failed");
  assert.match(input?.message ?? "", /arecord/u);
  assert.equal(output?.status, "passed");
});

test("a missing output command fails only the audio-output preflight check", async () => {
  const preflight = new HardwarePreflight({
    openRig: async () => readOnlySession(),
    discover: async () => discoveryWithAudio(),
    commandAvailable: async (command) => command !== "aplay",
  });

  const result = await preflight.test(networkProfile);

  const input = result.checks.find((check) => check.id === "audioInput");
  const output = result.checks.find((check) => check.id === "audioOutput");
  assert.equal(result.overallStatus, "failed");
  assert.equal(input?.status, "passed");
  assert.equal(output?.status, "failed");
  assert.match(output?.message ?? "", /aplay/u);
});

test("a managed serial profile reports missing rigctld without opening it", async () => {
  const profile: RadioProfile = {
    ...networkProfile,
    connection: { kind: "managed-serial", devicePath: "/dev/ttyUSB0", baudRate: 38_400 },
  };
  let opened = false;
  const preflight = new HardwarePreflight({
    openRig: async () => {
      opened = true;
      return readOnlySession();
    },
    discover: async () => discoveryWithAudio(),
    commandAvailable: async (command) => command !== "rigctld",
  });

  const result = await preflight.test(profile);

  assert.equal(opened, false);
  assert.equal(result.overallStatus, "failed");
  assert.equal(result.checks.find((check) => check.id === "cat")?.status, "failed");
  assert.match(result.checks.find((check) => check.id === "cat")?.message ?? "", /rigctld/u);
});

test("a network rigctld profile does not require a local rigctld executable", async () => {
  const commands: string[] = [];
  const preflight = new HardwarePreflight({
    openRig: async () => readOnlySession(),
    discover: async () => discoveryWithAudio(),
    commandAvailable: async (command) => {
      commands.push(command);
      return command !== "rigctld";
    },
  });

  const result = await preflight.test(networkProfile);

  assert.equal(result.overallStatus, "passed");
  assert(!commands.includes("rigctld"));
});

test("resolves a saved USB card after ALSA renumbering", () => {
  const resolved = resolveAudioRoute(
    { kind: "system-device", hardwareId: "usb:1234:5678:SN42", latency: "balanced" },
    discoveryWithStableCard("hw:3,0"),
  );

  assert.equal(resolved.input.id, "hw:3,0");
  assert.equal(resolved.output.id, "hw:3,0");
});

test("preflight opens both directions on the re-resolved card and records negotiated rates", async () => {
  const opened: string[] = [];
  const duplexProbe = {
    open: async (
      direction: "capture" | "playback",
      endpoint: { id: string },
      request: { sampleRates: readonly number[] },
    ) => {
      opened.push(`${direction}:${endpoint.id}`);
      return { sampleRate: request.sampleRates[0], channels: 1, format: "s16le" as const };
    },
  };
  const profile: RadioProfile = {
    ...networkProfile,
    audioRoute: {
      kind: "system-device",
      hardwareId: "usb:1234:5678:SN42",
      latency: "balanced",
    },
  };
  const preflight = new HardwarePreflight({
    openRig: async () => readOnlySession(),
    discover: async () => discoveryWithStableCard("hw:3,0"),
    commandAvailable: async () => true,
    duplexProbe,
  });

  const result = await preflight.test(profile);

  assert.deepEqual(opened, ["capture:hw:3,0", "playback:hw:3,0"]);
  assert.deepEqual(result.negotiatedRates, { input: 48_000, output: 48_000 });
  assert.equal(result.checks.find((check) => check.id === "audioInput")?.details.id, "hw:3,0");
  assert.equal(result.checks.find((check) => check.id === "audioOutput")?.details.id, "hw:3,0");
});

test("saved system-device routes fail honestly when the stable card is absent", () => {
  assert.throws(
    () => resolveAudioRoute(
      { kind: "system-device", hardwareId: "usb:1234:5678:SN42", latency: "balanced" },
      discoveryWithAudio(),
    ),
    /usb:1234:5678:SN42/u,
  );
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

function readOnlySession(): ReadOnlyRigSession {
  return {
    request: async (command) => responseFor(command),
    close: async () => undefined,
  };
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
    audioCards: [],
    pttMethods: ["RIG"],
    baudRates: [38_400],
    warnings: [],
  };
}

function discoveryWithStableCard(endpointId: string): HardwareDiscoveryResult {
  const input = {
    backend: "alsa" as const,
    direction: "input" as const,
    id: endpointId,
    label: "USB input",
  };
  const output = {
    backend: "alsa" as const,
    direction: "output" as const,
    id: endpointId,
    label: "USB output",
  };
  return {
    ...discoveryWithAudio(),
    audioInputs: [input],
    audioOutputs: [output],
    audioCards: [{
      hardwareId: "usb:1234:5678:SN42",
      label: "USB Audio CODEC (SN42)",
      transport: "usb",
      complete: true,
      input,
      output,
    }],
  };
}
