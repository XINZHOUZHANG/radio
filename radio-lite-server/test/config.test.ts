import assert from "node:assert/strict";
import { test } from "node:test";

import {
  RADIO_CONFIG_VERSION,
  parseRadioConfig,
} from "../src/config/types.ts";
import {
  parseRigctlModelList,
  resolveCuratedPresets,
} from "../src/config/hamlib-catalog.ts";
import {
  parseAlsaHardwareList,
  parsePactlJson,
  serialDevicesFromNames,
} from "../src/config/discovery.ts";

function validRadio(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "main",
    name: "FT-710",
    hamlibModelId: 1049,
    connection: {
      kind: "managed-serial",
      devicePath: "/dev/serial/by-id/usb-Yaesu_FT-710-if00",
      baudRate: 38_400,
    },
    audioInput: { backend: "alsa", id: "hw:1,0", label: "USB Audio In" },
    audioOutput: { backend: "alsa", id: "hw:1,0", label: "USB Audio Out" },
    station: { callsign: "BI1ABC", grid: "OM89" },
    hardwareTxEnabled: false,
    ...overrides,
  };
}

test("validates and normalizes a multi-radio configuration", () => {
  const result = parseRadioConfig({
    version: RADIO_CONFIG_VERSION,
    radios: [
      validRadio(),
      validRadio({
        id: "remote",
        name: "IC-7300",
        hamlibModelId: 3073,
        connection: { kind: "network-rigctld", host: "100.64.0.8", port: 4532 },
        station: { callsign: "bi1xyz/p", grid: "OM89AA" },
      }),
    ],
  });

  assert.equal(result.radios.length, 2);
  assert.equal(result.radios[1].station.callsign, "BI1XYZ/P");
  assert.equal(result.radios[1].station.grid, "OM89AA");
  assert.deepEqual(result.radios[0].ptt, { method: "RIG" });
});

test("validates Hamlib PTT methods, device paths and GPIO bit numbers", () => {
  const gpio = parseRadioConfig({
    version: RADIO_CONFIG_VERSION,
    radios: [validRadio({
      ptt: { method: "GPIO", path: "/dev/gpiochip0", bit: 4 },
    })],
  });
  assert.deepEqual(gpio.radios[0].ptt, {
    method: "GPIO",
    path: "/dev/gpiochip0",
    bit: 4,
  });

  assert.throws(
    () => parseRadioConfig({
      version: RADIO_CONFIG_VERSION,
      radios: [validRadio({
        ptt: { method: "GPIO", path: "/dev/gpiochip0", bit: 8 },
      })],
    }),
    /bit must be in 0\.\.7/u,
  );
  assert.throws(
    () => parseRadioConfig({
      version: RADIO_CONFIG_VERSION,
      radios: [validRadio({ ptt: { method: "RIG", path: "/dev/ttyUSB1" } })],
    }),
    /path is not used/u,
  );
  assert.throws(
    () => parseRadioConfig({
      version: RADIO_CONFIG_VERSION,
      radios: [validRadio({ ptt: { method: "DTR" } })],
    }),
    /path is required/u,
  );
  assert.throws(
    () => parseRadioConfig({
      version: RADIO_CONFIG_VERSION,
      radios: [validRadio({
        ptt: { method: "AUTO" },
      })],
    }),
    /method is unsupported/u,
  );
  assert.throws(
    () => parseRadioConfig({
      version: RADIO_CONFIG_VERSION,
      radios: [validRadio({
        connection: { kind: "network-rigctld", host: "rig.local", port: 4532 },
        ptt: { method: "DTR", path: "/dev/ttyUSB1" },
      })],
    }),
    /network rigctld manages PTT externally/u,
  );
  assert.throws(
    () => parseRadioConfig({
      version: RADIO_CONFIG_VERSION,
      radios: [validRadio({
        hardwareTxEnabled: true,
        ptt: { method: "None" },
      })],
    }),
    /cannot enable hardware transmission/u,
  );
  assert.throws(
    () => parseRadioConfig({
      version: RADIO_CONFIG_VERSION,
      radios: [validRadio({
        ptt: { method: "DTR", path: "/dev/ttyUSB1", bit: 2 },
      })],
    }),
    /bit is only used/u,
  );
});

test("rejects duplicate ids, unknown fields, unsafe serial paths and Dummy TX", () => {
  assert.throws(
    () => parseRadioConfig({ version: 1, radios: [validRadio(), validRadio()] }),
    /duplicate radio id/u,
  );
  assert.throws(
    () => parseRadioConfig({ version: 1, radios: [validRadio({ surprise: true })] }),
    /unknown field/u,
  );
  assert.throws(
    () => parseRadioConfig({
      version: 1,
      radios: [validRadio({
        connection: { kind: "managed-serial", devicePath: "COM7" },
      })],
    }),
    /absolute \/dev path/u,
  );
  assert.throws(
    () => parseRadioConfig({
      version: 1,
      radios: [validRadio({ hamlibModelId: 1, hardwareTxEnabled: true })],
    }),
    /Dummy cannot enable/u,
  );
  const dummy = parseRadioConfig({
    version: 1,
    radios: [validRadio({
      id: "dummy",
      name: "Simulator",
      hamlibModelId: 1,
      connection: { kind: "hamlib-dummy" },
    })],
  });
  assert.deepEqual(dummy.radios[0].connection, { kind: "hamlib-dummy" });
  assert.deepEqual(dummy.radios[0].ptt, { method: "None" });
});

test("parses the installed Hamlib catalog instead of freezing model ids", () => {
  const models = parseRigctlModelList(`
 Rig #  Mfg                    Model                   Version         Status
     1  Hamlib                 Dummy                   20230501.0      Beta
  1049  Yaesu                  FT-710                  20250101.0      Stable
  3073  Icom                   IC-7300                 20250101.0      Stable
`);

  assert.deepEqual(models.map((model) => model.modelId), [1, 3073, 1049]);
  const presets = resolveCuratedPresets(models);
  assert.equal(presets.find((item) => item.slug === "yaesu-ft-710")?.hamlibModelId, 1049);
  assert.equal(presets.find((item) => item.slug === "icom-ic-7610")?.available, false);
});

test("prefers stable serial paths and provides a tty fallback", () => {
  const stable = serialDevicesFromNames([
    "usb-Silicon_Labs_CP2102-if00-port0",
    "bad/name",
  ], ["ttyUSB0"]);
  assert.deepEqual(stable.map((device) => device.path), [
    "/dev/serial/by-id/usb-Silicon_Labs_CP2102-if00-port0",
  ]);
  assert.equal(stable[0].stable, true);

  const fallback = serialDevicesFromNames([], ["ttyS0", "ttyACM1", "ttyUSB0"]);
  assert.deepEqual(fallback.map((device) => device.path), ["/dev/ttyACM1", "/dev/ttyUSB0"]);
  assert.equal(fallback[0].stable, false);
});

test("parses PulseAudio and ALSA choices for the iOS wizard", () => {
  const pulse = parsePactlJson(JSON.stringify([
    { name: "alsa_input.usb-radio", properties: { "device.description": "Radio USB Codec" } },
  ]), "input");
  assert.deepEqual(pulse[0], {
    backend: "pulse",
    direction: "input",
    id: "alsa_input.usb-radio",
    label: "Radio USB Codec",
  });

  const alsa = parseAlsaHardwareList(
    "card 1: CODEC [USB Audio CODEC], device 0: USB Audio [USB Audio]",
    "output",
  );
  assert.deepEqual(alsa[0], {
    backend: "alsa",
    direction: "output",
    id: "hw:1,0",
    label: "USB Audio CODEC — USB Audio",
  });
});
