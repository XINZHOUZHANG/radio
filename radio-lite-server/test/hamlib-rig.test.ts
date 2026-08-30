import assert from "node:assert/strict";
import { test } from "node:test";

import { HamlibDriver } from "../src/rig/hamlib-driver.ts";
import { HamlibRig } from "../src/rig/hamlib-rig.ts";
import { RigReportError } from "../src/rig/transport.ts";

test("HamlibRig caches one capability discovery and includes readable meters", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\get_level ?") return responseValues("get_level", ["RFPOWER STRENGTH"]);
      if (command === "\\set_level ?") return responseValues("set_level", ["RFPOWER"]);
      if (command === "\\get_func ?" || command === "\\set_func ?") {
        return responseValues(command.includes("get_") ? "get_func" : "set_func", ["NB"]);
      }
      if (command === "\\set_mode ?") return responseValues("set_mode", ["USB"]);
      if (command === "\\set_level RFPOWER ?") {
        return responseValues("set_level", ["(0.000000..1.000000/0.010000)"]);
      }
      if (command === "\\get_level RFPOWER") return responseValues("get_level", ["0.25"]);
      if (command === "\\get_level STRENGTH") return responseValues("get_level", ["-73"]);
      if (command === "\\get_func NB") return responseValues("get_func", ["1"]);
      if (command === "\\get_mode") {
        return response("get_mode", { Mode: "USB", Passband: "2400" });
      }
      if (command.startsWith("\\get_")) {
        throw new RigReportError(command.slice(1).split(" ")[0] ?? "unknown", -11);
      }
      throw new Error(`unexpected command ${command}`);
    },
  });

  const first = await rig.readControls();
  const second = await rig.readControls();
  assert.deepEqual(first.map(({ id, value }) => ({ id, value })), [
    { id: "level:RFPOWER", value: 0.25 },
    { id: "level:STRENGTH", value: -73 },
    { id: "function:NB", value: true },
    { id: "mode:CURRENT", value: "USB" },
    { id: "passband:CURRENT", value: 2400 },
  ]);
  assert.deepEqual(second, first);
  assert.equal(commands.filter((command) => command === "\\get_level ?").length, 1);
  assert.equal(commands.filter((command) => command === "\\set_level ?").length, 1);
});

test("writes split and signed RIT through explicit rigctld commands", async () => {
  const fixture = operationFixture();

  const split = await fixture.driver.setControl("operation:SPLIT", true);
  const rit = await fixture.driver.setControl("operation:RIT", -450);

  assert.deepEqual(fixture.writes, ["\\set_split_vfo 1 VFOB", "\\set_rit -450"]);
  assert.equal(split.value, true);
  assert.equal(rit.value, -450);
});

test("maps typed mode, passband, XIT, tuning-step, and repeater controls", async () => {
  const fixture = operationFixture();

  await fixture.driver.setControl("mode:CURRENT", "PKTUSB");
  await fixture.driver.setControl("passband:CURRENT", 2_700);
  await fixture.driver.setControl("operation:XIT", 250);
  await fixture.driver.setControl("operation:TUNING_STEP", 100);
  await fixture.driver.setControl("repeater:SHIFT", "PLUS");
  await fixture.driver.setControl("repeater:OFFSET", 600_000);
  await fixture.driver.setControl("repeater:CTCSS", 885);
  await fixture.driver.setControl("repeater:DCS", 23);

  assert.deepEqual(fixture.writes, [
    "\\set_mode PKTUSB 2400",
    "\\set_mode PKTUSB 2700",
    "\\set_xit 250",
    "\\set_ts 100",
    "\\set_rptr_shift +",
    "\\set_rptr_offs 600000",
    "\\set_ctcss_tone 885",
    "\\set_dcs_code 23",
  ]);
});

test("rejects wrong typed, enum, bounded, and stepped values before CAT writes", async () => {
  const fixture = operationFixture();

  await assert.rejects(fixture.driver.setControl("operation:SPLIT", 1), /boolean/u);
  await assert.rejects(fixture.driver.setControl("mode:CURRENT", "INVALID"), /available option/u);
  await assert.rejects(fixture.driver.setControl("repeater:SHIFT", "UP"), /available option/u);
  await assert.rejects(fixture.driver.setControl("operation:RIT", 100_000), /outside/u);
  await assert.rejects(fixture.driver.setControl("operation:TUNING_STEP", 10.5), /step/u);

  assert.deepEqual(fixture.writes, []);
});

function operationFixture() {
  const writes: string[] = [];
  let mode = "USB";
  let passband = 2_400;
  const driver = new HamlibDriver(new HamlibRig({
    request: async (command: string) => {
      const name = command.slice(1).split(" ")[0] ?? "unknown";
      if (command === "\\get_level ?" || command === "\\set_level ?") {
        return responseValues(name, [""]);
      }
      if (command === "\\get_func ?" || command === "\\set_func ?") {
        return responseValues(name, [""]);
      }
      if (command === "\\set_mode ?") return responseValues(name, ["USB PKTUSB"]);
      if (command === "\\get_mode") {
        return response("get_mode", { Mode: mode, Passband: String(passband) });
      }
      if (command.startsWith("\\set_mode ")) {
        writes.push(command);
        const [, nextMode = "", nextPassband = ""] = command.split(" ");
        mode = nextMode;
        passband = Number(nextPassband);
        return response(name, {});
      }
      if (command.startsWith("\\set_")) {
        writes.push(command);
        return response(name, {});
      }
      if (command.startsWith("\\get_")) {
        throw new RigReportError(name, -11);
      }
      throw new Error(`unexpected command ${command}`);
    },
  }));
  return { driver, writes };
}

function response(command: string, fields: Record<string, string>) {
  return { command, fields: new Map(Object.entries(fields)), values: [], report: 0 };
}

function responseValues(command: string, values: string[]) {
  return { command, fields: new Map<string, string>(), values, report: 0 };
}
