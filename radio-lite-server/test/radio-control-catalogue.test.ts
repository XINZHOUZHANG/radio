import assert from "node:assert/strict";
import { test } from "node:test";

import { HamlibControlCatalogue } from "../src/rig/radio-control-catalogue.ts";

const catalogue = new HamlibControlCatalogue();

test("maps reported Hamlib tokens to grouped descriptors", async () => {
  const controls = await catalogue.discover({
    levels: ["RFPOWER", "STRENGTH", "MICGAIN"],
    functions: ["NB", "TUNER"],
    parameters: ["KEYSPD"],
  });

  assert.deepEqual(controls.map(({ id, group, access, presentation }) => ({
    id,
    group,
    access,
    presentation,
  })), [
    { id: "level:RFPOWER", group: "rf", access: "read-write", presentation: "slider" },
    { id: "level:STRENGTH", group: "rf", access: "read-only", presentation: "meter" },
    { id: "level:MICGAIN", group: "audio", access: "read-write", presentation: "slider" },
    { id: "function:NB", group: "rf", access: "read-write", presentation: "toggle" },
    { id: "function:TUNER", group: "rf", access: "read-write", presentation: "toggle" },
    { id: "action:TUNER", group: "rf", access: "action", presentation: "button" },
    { id: "parameter:KEYSPD", group: "cw", access: "read-write", presentation: "discrete" },
  ]);
});

test("omits malformed and unsupported advertised controls", async () => {
  const controls = await catalogue.discover({
    levels: ["VENDOR_MAGIC", "", "RFPOWER_METERISH", "rfpower"],
    functions: ["VENDOR_TUNER"],
  });
  assert.deepEqual(controls, []);
});

test("describes the complete generic level and function surface", async () => {
  const controls = await catalogue.discover({
    levels: [
      "RFPOWER", "RF", "AGC", "PREAMP", "ATT", "IF", "PBT_IN", "PBT_OUT", "NOTCHF",
      "AF", "SQL", "MICGAIN", "COMP", "MONITOR_GAIN", "VOXDELAY", "VOXGAIN", "ANTIVOX", "BAL",
      "BKINDL", "BKIN_DLYMS", "CWPITCH", "KEYSPD", "STRENGTH", "SWR", "ALC",
      "RFPOWER_METER", "RFPOWER_METER_WATTS",
    ],
    functions: [
      "NB", "NR", "APF", "ANF", "MN", "COMP", "MON", "VOX", "MUTE", "LOCK", "TUNER",
      "SBKIN", "FBKIN",
    ],
  });

  assert.deepEqual(controls.map((control) => control.id), [
    "level:RFPOWER", "level:RF", "level:AGC", "level:PREAMP", "level:ATT", "level:IF",
    "level:PBT_IN", "level:PBT_OUT", "level:NOTCHF", "level:AF", "level:SQL",
    "level:MICGAIN", "level:COMP", "level:MONITOR_GAIN", "level:VOXDELAY", "level:VOXGAIN",
    "level:ANTIVOX", "level:BAL", "level:BKINDL", "level:BKIN_DLYMS", "level:CWPITCH",
    "level:KEYSPD", "level:STRENGTH", "level:SWR", "level:ALC", "level:RFPOWER_METER",
    "level:RFPOWER_METER_WATTS", "function:NB", "function:NR", "function:APF", "function:ANF",
    "function:MN", "function:COMP", "function:MON", "function:VOX", "function:MUTE",
    "function:LOCK", "function:TUNER", "function:SBKIN", "function:FBKIN", "action:TUNER",
  ]);

  assert.deepEqual(controls.find(({ id }) => id === "level:RFPOWER"), {
    id: "level:RFPOWER", kind: "level", token: "RFPOWER", group: "rf", access: "read-write",
    presentation: "slider", value: null, minimum: 0, maximum: 1, step: 0.01, unit: "ratio",
    transmitLocked: true,
  });
  assert.deepEqual(controls.find(({ id }) => id === "level:RFPOWER_METER_WATTS"), {
    id: "level:RFPOWER_METER_WATTS", kind: "level", token: "RFPOWER_METER_WATTS", group: "rf",
    access: "read-only", presentation: "meter", value: null, unit: "watts", transmitLocked: false,
  });
  assert.deepEqual(controls.find(({ id }) => id === "function:LOCK"), {
    id: "function:LOCK", kind: "function", token: "LOCK", group: "mode", access: "read-write",
    presentation: "toggle", value: null, minimum: 0, maximum: 1, step: 1, unit: "boolean",
    transmitLocked: false,
  });
  assert.deepEqual(controls.find(({ id }) => id === "function:TUNER"), {
    id: "function:TUNER", kind: "function", token: "TUNER", group: "rf", access: "read-write",
    presentation: "toggle", value: null, minimum: 0, maximum: 1, step: 1, unit: "boolean",
    transmitLocked: true,
  });
  assert.deepEqual(controls.find(({ id }) => id === "action:TUNER"), {
    id: "action:TUNER", kind: "action", token: "TUNER", group: "rf", access: "action",
    presentation: "button", value: null, transmitLocked: true,
  });
});

test("describes explicit operation, CW, and repeater controls only when reported", async () => {
  const controls = await catalogue.discover({
    operations: [
      "MODE", "PASSBAND", "SPLIT", "RIT", "XIT", "TUNING_STEP", "REPEATER_SHIFT",
      "REPEATER_OFFSET", "CTCSS", "DCS",
    ],
    modes: ["USB", "LSB", "CW"],
  });

  assert.deepEqual(controls.map(({ id, group, presentation, transmitLocked }) => ({
    id,
    group,
    presentation,
    transmitLocked,
  })), [
    { id: "mode:CURRENT", group: "mode", presentation: "enum", transmitLocked: true },
    { id: "passband:CURRENT", group: "mode", presentation: "discrete", transmitLocked: true },
    { id: "operation:SPLIT", group: "mode", presentation: "toggle", transmitLocked: true },
    { id: "operation:RIT", group: "mode", presentation: "offset", transmitLocked: false },
    { id: "operation:XIT", group: "mode", presentation: "offset", transmitLocked: true },
    { id: "operation:TUNING_STEP", group: "mode", presentation: "discrete", transmitLocked: false },
    { id: "repeater:SHIFT", group: "repeater", presentation: "enum", transmitLocked: true },
    { id: "repeater:OFFSET", group: "repeater", presentation: "offset", transmitLocked: true },
    { id: "repeater:CTCSS", group: "repeater", presentation: "enum", transmitLocked: true },
    { id: "repeater:DCS", group: "repeater", presentation: "enum", transmitLocked: true },
  ]);
  assert.deepEqual(controls[0]?.options, [
    { value: "USB", label: "USB" },
    { value: "LSB", label: "LSB" },
    { value: "CW", label: "CW" },
  ]);
});
