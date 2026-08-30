import assert from "node:assert/strict";
import { test } from "node:test";

import { HamlibRig } from "../src/rig/hamlib-rig.ts";

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
      if (command === "\\set_level RFPOWER ?") {
        return responseValues("set_level", ["(0.000000..1.000000/0.010000)"]);
      }
      if (command === "\\get_level RFPOWER") return responseValues("get_level", ["0.25"]);
      if (command === "\\get_level STRENGTH") return responseValues("get_level", ["-73"]);
      if (command === "\\get_func NB") return responseValues("get_func", ["1"]);
      if (command === "\\get_mode") {
        return response("get_mode", { Mode: "USB", Passband: "2400" });
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
    { id: "passband:CURRENT", value: 2400 },
  ]);
  assert.deepEqual(second, first);
  assert.equal(commands.filter((command) => command === "\\get_level ?").length, 1);
  assert.equal(commands.filter((command) => command === "\\set_level ?").length, 1);
});

function response(command: string, fields: Record<string, string>) {
  return { command, fields: new Map(Object.entries(fields)), values: [], report: 0 };
}

function responseValues(command: string, values: string[]) {
  return { command, fields: new Map<string, string>(), values, report: 0 };
}
