import assert from "node:assert/strict";
import { test } from "node:test";

import {
  RADIO_CONFIG_VERSION,
  parseRadioConfig,
  parseRadioProfile,
  toPublicRadioProfile,
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

test("loads an ICOM WLAN profile but exposes only an allowlisted public projection", () => {
  const stored = parseRadioProfile({
    id: "icom",
    name: "IC-7610",
    connection: {
      kind: "icom-wlan",
      host: "192.168.10.20",
      port: 50001,
      username: "station",
      password: "station-secret",
    },
    audioRoute: { kind: "driver-stream" },
    ptt: { method: "RIG" },
    station: { callsign: "BI1ABC", grid: "OM89" },
    hardwareTxEnabled: false,
  });

  assert.equal(stored.connection.kind, "icom-wlan");
  if (stored.connection.kind !== "icom-wlan") throw new Error("expected ICOM WLAN profile");
  assert.equal(stored.connection.password, "station-secret");
  const publicValue = toPublicRadioProfile(stored);
  assert.equal(JSON.stringify(publicValue).includes("station-secret"), false);
  assert.equal("password" in publicValue.connection, false);
  assert.deepEqual(publicValue.connection, {
    kind: "icom-wlan",
    host: "192.168.10.20",
    port: 50001,
    username: "station",
  });
  assert.equal("hamlibModelId" in publicValue, false);
  assert.equal("audioInput" in publicValue, false);
  assert.equal("audioOutput" in publicValue, false);
});

test("loads every legacy version-1 profile without changing its shape", () => {
  const managed = validRadio({ ptt: { method: "RIG" } });
  const external = validRadio({
    id: "external",
    connection: { kind: "network-rigctld", host: "rig.local", port: 4532 },
    ptt: { method: "RIG" },
  });
  const dummy = validRadio({
    id: "dummy",
    name: "Simulator",
    hamlibModelId: 1,
    connection: { kind: "hamlib-dummy" },
    ptt: { method: "None" },
  });
  const legacyFixture = { version: 1, radios: [managed, external, dummy] };

  assert.deepEqual(parseRadioConfig(legacyFixture), legacyFixture);
});

test("parses exact new connection unions without legacy-only fields", () => {
  const profiles = parseRadioConfig({
    version: 1,
    radios: [
      {
        id: "receive",
        name: "Receive only",
        connection: { kind: "no-radio" },
        audioRoute: { kind: "none" },
        ptt: { method: "None" },
        station: { callsign: "BI1ABC" },
        hardwareTxEnabled: false,
      },
      {
        id: "tci",
        name: "SunSDR",
        connection: {
          kind: "tci",
          url: "ws://192.168.10.30:40001",
          trx: 0,
          allowPublicEndpoint: true,
        },
        audioRoute: { kind: "driver-stream" },
        ptt: { method: "RIG" },
        station: { callsign: "BI1ABC" },
        hardwareTxEnabled: false,
      },
    ],
  });

  assert.deepEqual(profiles.radios[0].connection, { kind: "no-radio" });
  assert.deepEqual(profiles.radios[1].connection, {
    kind: "tci",
    url: "ws://192.168.10.30:40001",
    trx: 0,
    allowPublicEndpoint: true,
  });
  for (const profile of profiles.radios) {
    assert.equal("hamlibModelId" in profile, false);
    assert.equal("audioInput" in profile, false);
    assert.equal("audioOutput" in profile, false);
  }

  assert.throws(() => parseRadioProfile({
    ...profiles.radios[0],
    connection: { kind: "no-radio", host: "unexpected" },
  }), /unknown field/u);
  assert.throws(() => parseRadioProfile({
    ...profiles.radios[1],
    connection: { ...profiles.radios[1].connection, password: "not-allowed" },
  }), /unknown field/u);
});

test("legacy connections and system-device routes retain legacy required fields", () => {
  for (const connection of [
    { kind: "managed-serial", devicePath: "/dev/ttyUSB0" },
    { kind: "network-rigctld", host: "rig.local", port: 4532 },
    { kind: "hamlib-dummy" },
  ]) {
    const { hamlibModelId: _, ...withoutModel } = validRadio({ connection });
    assert.throws(() => parseRadioProfile(withoutModel), /hamlibModelId is required/u);
  }

  const { audioInput: _, audioOutput: __, ...withoutEndpoints } = validRadio({
    connection: {
      kind: "icom-wlan",
      host: "192.168.10.20",
      username: "station",
      password: "station-secret",
    },
    audioRoute: {
      kind: "system-device",
      hardwareId: "usb:1234:5678:SN42",
      latency: "balanced",
    },
  });
  delete withoutEndpoints.hamlibModelId;
  assert.throws(() => parseRadioProfile(withoutEndpoints), /audioInput is required/u);
});

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

test("legacy version-1 profile remains valid without audioRoute", () => {
  const result = parseRadioConfig({ version: 1, radios: [validRadio()] });
  assert.equal(result.radios[0].audioRoute, undefined);
});

test("system-device routes retain stable identity and resolved legacy endpoints", () => {
  const result = parseRadioConfig({
    version: 1,
    radios: [validRadio({
      audioRoute: {
        kind: "system-device",
        hardwareId: "usb:1234:5678:SN42",
        latency: "balanced",
      },
    })],
  });
  assert.deepEqual(result.radios[0].audioRoute, {
    kind: "system-device",
    hardwareId: "usb:1234:5678:SN42",
    latency: "balanced",
  });
  assert.deepEqual(result.radios[0].audioInput, {
    backend: "alsa", id: "hw:1,0", label: "USB Audio In",
  });
  assert.deepEqual(result.radios[0].audioOutput, {
    backend: "alsa", id: "hw:1,0", label: "USB Audio Out",
  });
});

test("audio routes accept only their exact union members", () => {
  assert.deepEqual(parseRadioConfig({
    version: 1,
    radios: [validRadio({ audioRoute: { kind: "driver-stream" } })],
  }).radios[0].audioRoute, { kind: "driver-stream" });
  assert.deepEqual(parseRadioConfig({
    version: 1,
    radios: [validRadio({ audioRoute: { kind: "none" } })],
  }).radios[0].audioRoute, { kind: "none" });
  assert.throws(() => parseRadioConfig({
    version: 1,
    radios: [validRadio({ audioRoute: { kind: "system-device", hardwareId: "unknown", latency: "balanced" } })],
  }), /hardwareId must identify a stable card/u);
  assert.throws(() => parseRadioConfig({
    version: 1,
    radios: [validRadio({ audioRoute: { kind: "driver-stream", latency: "low" } })],
  }), /unknown field/u);
  assert.throws(() => parseRadioConfig({
    version: 1,
    radios: [validRadio({
      audioRoute: { kind: "system-device", hardwareId: "usb:1234\n5678", latency: "low" },
    })],
  }), /hardwareId must identify a stable card/u);
  assert.throws(() => parseRadioConfig({
    version: 1,
    radios: [validRadio({
      audioRoute: { kind: "system-device", hardwareId: "alsa:2", latency: "low" },
    })],
  }), /hardwareId must identify a stable card/u);
  assert.throws(() => parseRadioConfig({
    version: 1,
    radios: [validRadio({
      audioRoute: {
        kind: "system-device", hardwareId: "alsa_input.usb-radio", latency: "low",
      },
    })],
  }), /hardwareId must identify a stable card/u);
  assert.throws(() => parseRadioConfig({
    version: 1,
    radios: [validRadio({
      audioRoute: {
        kind: "system-device", hardwareId: "alsa:alsa_input.usb-radio", latency: "low",
      },
    })],
  }), /hardwareId must identify a stable card/u);
  assert.throws(() => parseRadioConfig({
    version: 1,
    radios: [validRadio({
      audioRoute: {
        kind: "system-device", hardwareId: "alsa:alsa_output.usb-radio", latency: "low",
      },
    })],
  }), /hardwareId must identify a stable card/u);
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
    metadata: {
      alsaCard: "1",
      alsaCardId: "CODEC",
      alsaCardName: "USB Audio CODEC",
    },
  });
});

test("retains a PipeWire ALSA card id without promoting Pulse display metadata", () => {
  const [endpoint] = parsePactlJson(JSON.stringify([{
    name: "alsa_input.usb-radio",
    properties: {
      "alsa.card": "2",
      "alsa.card_name": "USB PnP Sound Device",
      "api.alsa.card.id": "CODEC",
      "api.alsa.card.name": "USB PnP Sound Device",
    },
  }]), "input");

  assert.deepEqual(endpoint?.metadata, {
    alsaCard: "2",
    alsaCardId: "CODEC",
    alsaCardName: "USB PnP Sound Device",
  });
});
