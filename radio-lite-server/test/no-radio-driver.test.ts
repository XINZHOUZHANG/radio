import assert from "node:assert/strict";
import { test } from "node:test";

import { NoRadioDriver } from "../src/rig/no-radio-driver.ts";
import { ReceiveOnlyRadioError } from "../src/rig/radio-driver.ts";

test("no-radio exposes a deterministic receive-only lifecycle", async () => {
  const driver = new NoRadioDriver();

  await driver.initialize();
  await driver.initialize();

  assert.deepEqual(await driver.capabilities(), {
    canTransmit: false,
    supportsInternalTuner: false,
  });
  assert.deepEqual(await driver.readState(), {
    frequencyHz: 0,
    mode: "",
    passbandHz: 0,
    ptt: false,
  });
  assert.deepEqual(await driver.readTelemetry("receive"), {});
  assert.deepEqual(await driver.readControls(), []);
  assert.equal(await driver.readPtt(), false);
  assert.equal(await driver.readPtt({ purpose: "off-recovery" }), false);

  await driver.writePtt(false);
  await driver.close();
  await driver.close();
});

test("no-radio rejects every transmit or rig mutation with one stable error type", async () => {
  const driver = new NoRadioDriver();
  const writes = [
    () => driver.writePtt(true),
    () => driver.setFrequency(7_074_000),
    () => driver.setMode("USB", 3_000),
    () => driver.setControl("level:AF", 0.5),
    () => driver.invokeAction("action:TUNER"),
  ];

  for (const write of writes) {
    await assert.rejects(write(), (error: unknown) =>
      error instanceof ReceiveOnlyRadioError && /receive-only/u.test(error.message),
    );
  }

  assert.deepEqual(await driver.readState(), {
    frequencyHz: 0,
    mode: "",
    passbandHz: 0,
    ptt: false,
  });
});
