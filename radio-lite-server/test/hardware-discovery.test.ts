import assert from "node:assert/strict";
import { test } from "node:test";

import { HardwareDiscovery } from "../src/config/hardware-discovery.ts";

test("hardware discovery combines installed Hamlib, stable serial and PulseAudio choices", async () => {
  const discovery = new HardwareDiscovery({
    run: async (executable, args) => {
      if (executable === "rigctl") {
        return "     1  Hamlib                 Dummy                   1.0             Stable\n  1049  Yaesu                  FT-710                  1.0             Stable\n";
      }
      if (executable === "pactl" && args.at(-1) === "sources") {
        return JSON.stringify([{ name: "radio-in", properties: { "device.description": "Radio Input" } }]);
      }
      if (executable === "pactl" && args.at(-1) === "sinks") {
        return JSON.stringify([{ name: "radio-out", properties: { "device.description": "Radio Output" } }]);
      }
      throw new Error("unexpected command");
    },
    readDirectory: async (path) => path === "/dev/serial/by-id"
      ? ["usb-Yaesu_FT-710-if00-port0"]
      : [],
  });

  const result = await discovery.discover();
  assert.deepEqual(result.hamlibModels.map((model) => model.modelId), [1, 1049]);
  assert.equal(result.curatedPresets.find((preset) => preset.slug === "yaesu-ft-710")?.available, true);
  assert.equal(result.serialDevices[0].stable, true);
  assert.equal(result.audioInputs[0].id, "radio-in");
  assert.equal(result.audioOutputs[0].id, "radio-out");
  assert.deepEqual(result.warnings, []);
});

test("audio discovery falls back to ALSA and reports bounded warnings", async () => {
  const discovery = new HardwareDiscovery({
    run: async (executable) => {
      if (executable === "rigctl") throw new Error("missing");
      if (executable === "pactl") throw new Error("missing");
      return "card 1: CODEC [USB Audio CODEC], device 0: USB Audio [USB Audio]";
    },
    readDirectory: async (path) => path === "/dev"
      ? ["ttyUSB0", "ttyS0"]
      : [],
  });
  const result = await discovery.discover();
  assert.deepEqual(result.serialDevices.map((device) => device.path), ["/dev/ttyUSB0"]);
  assert.equal(result.audioInputs[0].backend, "alsa");
  assert.deepEqual(result.warnings, [
    "hamlib_model_discovery_unavailable",
    "pulseaudio_discovery_unavailable_using_alsa",
  ]);
});
