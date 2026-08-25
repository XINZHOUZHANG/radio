import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { RadioConfigStore } from "../src/config/radio-config-store.ts";
import { parseRadioProfile } from "../src/config/types.ts";
import { rigctldTarget } from "../src/rig/rigctld-command.ts";

function profile(id = "main") {
  return {
    id,
    name: "FT-710",
    hamlibModelId: 1049,
    connection: {
      kind: "managed-serial",
      devicePath: `/dev/serial/by-id/${id}`,
      baudRate: 38_400,
    },
    audioInput: { backend: "alsa", id: "hw:1,0" },
    audioOutput: { backend: "alsa", id: "hw:1,0" },
    station: { callsign: "BI1ABC", grid: "OM89" },
    hardwareTxEnabled: false,
  };
}

test("radio config store serializes concurrent updates and keeps a readable backup", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-config-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "radios.json");
  const store = new RadioConfigStore(path);

  const loaded = await store.load();
  assert.deepEqual(loaded.config.radios, []);
  await Promise.all([store.upsert(profile("one")), store.upsert(profile("two"))]);
  assert.deepEqual(store.snapshot().radios.map((radio) => radio.id), ["one", "two"]);

  await store.upsert(profile("three"));
  const primary = JSON.parse(await readFile(path, "utf8"));
  const backup = JSON.parse(await readFile(`${path}.bak`, "utf8"));
  assert.deepEqual(primary.radios.map((radio: { id: string }) => radio.id), ["one", "three", "two"]);
  assert.deepEqual(backup.radios.map((radio: { id: string }) => radio.id), ["one", "two"]);
});

test("loads a validated backup when the primary config is damaged", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-recovery-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "radios.json");
  const store = new RadioConfigStore(path);
  await store.load();
  await store.upsert(profile("one"));
  await store.upsert(profile("two"));
  await writeFile(path, "{broken", "utf8");

  const recovered = await new RadioConfigStore(path).load();
  assert.equal(recovered.recoveredFromBackup, true);
  assert.deepEqual(recovered.config.radios.map((radio) => radio.id), ["one"]);
});

test("builds managed rigctld argv without a shell and leaves network targets external", () => {
  const managed = rigctldTarget(parseRadioProfile(profile()), 4601);
  assert.equal(managed.managed, true);
  assert.deepEqual(managed.command, {
    executable: "rigctld",
    args: [
      "-m", "1049", "-r", "/dev/serial/by-id/main", "-s", "38400",
      "-P", "RIG",
      "-T", "127.0.0.1", "-t", "4601",
    ],
    host: "127.0.0.1",
    port: 4601,
  });

  const networkProfile = parseRadioProfile({
    ...profile(),
    connection: { kind: "network-rigctld", host: "rig.local", port: 4532 },
  });
  const network = rigctldTarget(networkProfile, 4602);
  assert.deepEqual(network, { managed: false, host: "rig.local", port: 4532 });

  const dummy = rigctldTarget(parseRadioProfile({
    ...profile("dummy"),
    hamlibModelId: 1,
    connection: { kind: "hamlib-dummy" },
  }), 4603);
  assert.deepEqual(dummy.command?.args, [
    "-m", "1", "-P", "NONE", "-T", "127.0.0.1", "-t", "4603",
  ]);
});

test("passes Hamlib PTT method, device and GPIO bit without invoking a shell", () => {
  const gpio = rigctldTarget(parseRadioProfile({
    ...profile(),
    ptt: { method: "GPIO", path: "/dev/gpiochip0", bit: 4 },
  }), 4604);
  assert.deepEqual(gpio.command?.args, [
    "-m", "1049", "-r", "/dev/serial/by-id/main", "-s", "38400",
    "-P", "GPIO", "-p", "/dev/gpiochip0", "-C", "ptt_bitnum=4",
    "-T", "127.0.0.1", "-t", "4604",
  ]);

  const none = rigctldTarget(parseRadioProfile({
    ...profile("dummy"),
    hamlibModelId: 1,
    connection: { kind: "hamlib-dummy" },
    ptt: { method: "None" },
  }), 4605);
  assert.deepEqual(none.command?.args, [
    "-m", "1", "-P", "NONE", "-T", "127.0.0.1", "-t", "4605",
  ]);
});
