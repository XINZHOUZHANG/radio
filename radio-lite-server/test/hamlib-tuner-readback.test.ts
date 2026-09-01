import assert from "node:assert/strict";
import { test } from "node:test";

import type { RigResponse } from "../src/rig/extended-protocol.ts";
import { HamlibRig } from "../src/rig/hamlib-rig.ts";

// These tests pin the FT-710-style Hamlib contract: engage first, verify, then tune.
class TunerRequester {
  readonly commands: string[] = [];
  tunerEnabled = false;
  writableFunctions = "TUNER NB";
  confirmEnable = true;

  async request(command: string): Promise<RigResponse> {
    this.commands.push(command);
    const name = command.slice(1).split(" ")[0] ?? "unknown";
    if (command === "\\vfo_op ?") {
      return response(name, { "Mem/VFO Op": "TUNE" });
    }
    if (command === "\\set_func ?") {
      return response(name, { Func: this.writableFunctions });
    }
    if (command === "\\set_func TUNER 1") {
      this.tunerEnabled = this.confirmEnable;
      return response(name);
    }
    if (command === "\\get_func TUNER") {
      return response(name, { TUNER: this.tunerEnabled ? "1" : "0" });
    }
    if (command === "\\vfo_op TUNE") {
      return response(name);
    }
    throw new Error(`unexpected command ${command}`);
  }
}

test("Hamlib tuner confirms the persistent switch before starting a tune", async () => {
  const requester = new TunerRequester();
  const rig = new HamlibRig(requester);

  await rig.startInternalTuner();

  assert.deepEqual(requester.commands, [
    "\\vfo_op ?",
    "\\set_func ?",
    "\\set_func TUNER 1",
    "\\get_func TUNER",
    "\\vfo_op TUNE",
  ]);
});

test("Hamlib tuner refuses to tune when the persistent switch remains off", async () => {
  const requester = new TunerRequester();
  requester.confirmEnable = false;
  const rig = new HamlibRig(requester);

  await assert.rejects(rig.startInternalTuner(), /tuner enable read-back mismatch/u);
  assert.deepEqual(requester.commands, [
    "\\vfo_op ?",
    "\\set_func ?",
    "\\set_func TUNER 1",
    "\\get_func TUNER",
  ]);
});

test("Hamlib TUNE-only radios do not require a nonexistent tuner switch", async () => {
  const requester = new TunerRequester();
  requester.writableFunctions = "NB NR";
  const rig = new HamlibRig(requester);

  await rig.startInternalTuner();

  assert.deepEqual(requester.commands, [
    "\\vfo_op ?",
    "\\set_func ?",
    "\\vfo_op TUNE",
  ]);
});

function response(command: string, fields: Record<string, string> = {}): RigResponse {
  return {
    command,
    fields: new Map(Object.entries(fields)),
    values: [],
    report: 0,
  };
}
