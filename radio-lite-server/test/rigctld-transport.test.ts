import assert from "node:assert/strict";
import { createConnection, createServer, type Server, type Socket } from "node:net";
import { Duplex } from "node:stream";
import { test } from "node:test";

import { encodeRigCommand, ExtendedResponseParser } from "../src/rig/extended-protocol.ts";
import {
  HamlibRig,
  normalizeHamlibMode,
  RigModeError,
} from "../src/rig/hamlib-rig.ts";
import {
  RigctldTransport,
  RigQueueBusyError,
  RigReportError,
  RigTelemetryDroppedError,
  type RigctldTransportOptions,
} from "../src/rig/transport.ts";

test("receive ordinary commands begin at least 500 ms apart", async (context) => {
  const clock = new TransportClock();
  const fixture = deferredTransportFixture({ now: clock.now, delay: clock.delay });
  context.after(async () => fixture.transport.close());
  fixture.transport.setCommandMode("receive");

  const first = fixture.transport.request("\\get_freq");
  await fixture.socket.waitForWrite("\\get_freq\n");
  fixture.socket.replyActive("Frequency: 14074000");
  await first;

  const second = fixture.transport.request("\\get_mode");
  await clock.advanceBy(499);
  assert.equal(fixture.socket.writes.includes("\\get_mode\n"), false);
  await clock.advanceBy(1);
  await fixture.socket.waitForWrite("\\get_mode\n");
  fixture.socket.replyActive("Mode: USB", "Passband: 3000");
  await second;

  const third = fixture.transport.request("\\get_ptt");
  await clock.advanceBy(500);
  await fixture.socket.waitForWrite("\\get_ptt\n");
  fixture.socket.replyActive("PTT: 0");
  await third;

  assert.deepEqual(
    fixture.transport.commandTrace().map(({ startedAtMs }) => startedAtMs),
    [0, 500, 1_000],
  );
});

test("immediate-budget safety OFF stays active while the yielded ordinary request is requeued", async (context) => {
  const fixture = deferredTransportFixture();
  context.after(async () => fixture.transport.close());

  const ordinary = fixture.transport.request("\\get_freq");
  const off = fixture.transport.request("\\set_ptt 0", { priority: "safety", source: "ptt-off" });

  await fixture.socket.waitForWrite("\\set_ptt 0\n");
  await nextTurn();
  assert.deepEqual(fixture.socket.writes, ["\\set_ptt 0\n"],
    "a yielded ordinary continuation must not replace active safety OFF");
  fixture.socket.replyActive();
  await off;
  await fixture.socket.waitForWrite("\\get_freq\n");
  fixture.socket.replyActive("Frequency: 14074000");
  await ordinary;

  assert.deepEqual(
    fixture.transport.commandTrace().map(({ command }) => command),
    ["\\set_ptt 0", "\\get_freq"],
  );
});

test("emergency OFF cancels a pending ordinary budget wait", async (context) => {
  const clock = new TransportClock();
  const fixture = deferredTransportFixture({ now: clock.now, delay: clock.delay });
  context.after(async () => fixture.transport.close());
  fixture.transport.setCommandMode("receive");

  const first = fixture.transport.request("\\get_freq");
  await fixture.socket.waitForWrite("\\get_freq\n");
  fixture.socket.replyActive("Frequency: 14074000");
  await first;
  const delayed = fixture.transport.request("\\get_mode");
  const off = fixture.transport.request("\\set_ptt 0", { priority: "safety", source: "ptt-off" });

  await fixture.socket.waitForWrite("\\set_ptt 0\n");
  assert.equal(fixture.transport.commandTrace().length, 1);
  fixture.socket.replyActive();
  await off;
  await clock.advanceBy(500);
  await fixture.socket.waitForWrite("\\get_mode\n");
  fixture.socket.replyActive("Mode: USB", "Passband: 3000");
  await delayed;

  assert.equal(fixture.transport.commandTrace()[1]?.startedAtMs, 0);
});

test("ordinary command waiting for CAT budget counts toward the normal queue limit", async (context) => {
  const clock = new TransportClock();
  const fixture = deferredTransportFixture({
    now: clock.now,
    delay: clock.delay,
    normalQueueLimit: 1,
  });
  context.after(async () => fixture.transport.close());

  const first = fixture.transport.request("\\get_freq");
  await fixture.socket.waitForWrite("\\get_freq\n");
  fixture.socket.replyActive("Frequency: 14074000");
  await first;
  const delayed = fixture.transport.request("\\get_mode");
  const delayedRejected = assert.rejects(delayed, /transport closed/u);
  const overflow = fixture.transport.request("\\set_freq 14074000");

  await assertRejectsOnNextTurn(overflow, RigQueueBusyError);

  await fixture.transport.close();
  await delayedRejected;
});

test("trace ring retains chronological entries 76 through 1099", async (context) => {
  const fixture = deferredTransportFixture();
  context.after(async () => fixture.transport.close());

  for (let index = 0; index < 1_100; index += 1) {
    const command = `\\get_freq ${index}`;
    const request = fixture.transport.request(command, { priority: "safety", source: "ptt-off" });
    await fixture.socket.waitForWrite(`${command}\n`);
    fixture.socket.replyActive("Frequency: 14074000");
    await request;
  }

  const trace = fixture.transport.commandTrace();
  assert.equal(trace.length, 1_024);
  assert.equal(trace[0]?.command, "\\get_freq 76");
  assert.equal(trace.at(-1)?.command, "\\get_freq 1099");
});

test("extended protocol parser handles fragmented fields and report framing", () => {
  const parser = new ExtendedResponseParser();
  assert.deepEqual(parser.feed(Buffer.from("get_freq:|Fre")), []);
  const responses = parser.feed(Buffer.from("quency: 14074000|RPRT 0|\n"));
  assert.equal(responses.length, 1);
  assert.equal(responses[0].command, "get_freq");
  assert.equal(responses[0].fields.get("Frequency"), "14074000");
  assert.equal(responses[0].report, 0);
  assert.deepEqual(encodeRigCommand("\\get_freq"), Buffer.from("|\\get_freq\n"));
  assert.throws(() => encodeRigCommand("\\get_freq\n\\set_ptt 1"), /one line/u);
});

test("unfinished ordinary request remains observable in DeferredSocket", async (context) => {
  const fixture = deferredTransportFixture();
  context.after(async () => fixture.transport.close());

  const pending = fixture.transport.request("\\get_freq");
  await fixture.socket.waitForPendingCommands(1);

  assert.equal(fixture.socket.pendingCommands(), 1);
  fixture.socket.reply("Frequency: 14074000");
  assert.equal((await pending).fields.get("Frequency"), "14074000");
  assert.equal(fixture.socket.pendingCommands(), 0);
});

test("safety OFF runs before queued telemetry while preserving normal FIFO", async (context) => {
  const fixture = deferredTransportFixture();
  context.after(async () => fixture.transport.close());

  const ordinary = fixture.transport.request("\\get_freq", { source: "telemetry" });
  await fixture.socket.waitForWrite("\\get_freq\n");
  const queued = fixture.transport.request("\\get_mode", { source: "telemetry" });
  const off = fixture.transport.request("\\set_ptt 0", {
    priority: "safety",
    source: "ptt-off",
  });

  fixture.socket.replyActive("Frequency: 14074000");
  await ordinary;
  await fixture.socket.waitForWrite("\\set_ptt 0\n");
  assert.equal(fixture.socket.writes.at(-1), "\\set_ptt 0\n");
  fixture.socket.replyActive();
  await off;
  await fixture.socket.waitForWrite("\\get_mode\n");
  fixture.socket.replyActive("Mode: USB", "Passband: 3000");
  await queued;

  assert.deepEqual(
    fixture.transport.commandTrace().map(({ command, priority, source }) => ({
      command,
      priority,
      source,
    })),
    [
      { command: "\\get_freq", priority: "normal", source: "telemetry" },
      { command: "\\set_ptt 0", priority: "safety", source: "ptt-off" },
      { command: "\\get_mode", priority: "normal", source: "telemetry" },
    ],
  );
});

test("a stuck ordinary command destroys the socket after 250 ms before recovery OFF", async (context) => {
  const fixture = reconnectingTransportFixture();
  context.after(async () => fixture.transport.close());

  const blocker = fixture.transport.request("\\get_freq", { source: "telemetry" });
  const first = await fixture.waitForSocket(1);
  await first.waitForWrite("\\get_freq\n");
  const blockerRejected = assert.rejects(blocker, /interrupted for safety recovery/u);
  const off = fixture.transport.request("\\set_ptt 0", {
    priority: "safety",
    source: "ptt-off",
  });

  await blockerRejected;
  const replacement = await fixture.waitForSocket(2);
  await replacement.waitForWrite("\\set_ptt 0\n");
  assert.equal(first.destroyed, true);
  replacement.replyActive();
  await off;
});

test("normal queue rejects explicit control at 32 entries and drops telemetry", async () => {
  const fixture = deferredTransportFixture();
  const blocker = fixture.transport.request("\\get_freq", { source: "telemetry" });
  await fixture.socket.waitForWrite("\\get_freq\n");
  const queued = Array.from({ length: 32 }, (_, index) =>
    fixture.transport.request(`\\set_freq ${7_074_000 + index}`, { source: "control" }));

  await assert.rejects(
    fixture.transport.request("\\set_freq 14074000", { source: "control" }),
    RigQueueBusyError,
  );
  await assert.rejects(
    fixture.transport.request("\\get_mode", { source: "telemetry" }),
    RigTelemetryDroppedError,
  );

  const blockerRejected = assert.rejects(blocker, /transport closed/u);
  const queuedRejected = Promise.all(queued.map((request) =>
    assert.rejects(request, /transport closed/u)));
  await fixture.transport.close();
  await blockerRejected;
  await queuedRejected;
});

test("persistent rigctld transport serializes commands and HamlibRig confirms read-back", async (context) => {
  const fake = await startFakeRigctld();
  const clock = new InstantClock();
  const transport = new RigctldTransport("127.0.0.1", fake.port, {
    now: clock.now,
    delay: clock.delay,
  });
  context.after(async () => {
    await transport.close();
    await closeServer(fake.server);
  });
  const rig = new HamlibRig(transport);

  assert.equal(await rig.setFrequency(7_074_000), 7_074_000);
  assert.deepEqual(await rig.setMode("usb", 2_400), { mode: "USB", passbandHz: 2_400 });
  assert.equal(await rig.setPtt(true), true);
  assert.equal(await rig.supportsInternalTuner(), true);
  await rig.startInternalTuner();
  assert.deepEqual(await rig.readState(), {
    frequencyHz: 7_074_000,
    mode: "USB",
    passbandHz: 2_400,
    ptt: true,
  });
  assert.equal(fake.connectionCount(), 1);
  assert.deepEqual(fake.commands.slice(0, 2), ["\\set_freq 7074000", "\\get_freq"]);
});

test("DATA-U and common digital aliases use Hamlib PKTUSB", async () => {
  assert.equal(normalizeHamlibMode("DATA-U"), "PKTUSB");
  assert.equal(normalizeHamlibMode("USB-DATA"), "PKTUSB");
  assert.equal(normalizeHamlibMode("DIGU"), "PKTUSB");
  assert.equal(normalizeHamlibMode("DATA-L"), "PKTLSB");
  assert.equal(normalizeHamlibMode("DIGL"), "PKTLSB");

  const commands: string[] = [];
  let activeMode = "PKTUSB";
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command.startsWith("\\set_mode ")) {
        activeMode = command.split(" ")[1] ?? activeMode;
      }
      if (command === "\\get_mode") {
        return response("get_mode", { Mode: activeMode, Passband: "3000" });
      }
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  assert.deepEqual(await rig.setMode("DATA-U"), { mode: "PKTUSB", passbandHz: 3_000 });
  assert.deepEqual(await rig.setMode("DATA-L"), { mode: "PKTLSB", passbandHz: 3_000 });
  assert.deepEqual(commands, [
    "\\set_mode PKTUSB 0",
    "\\get_mode",
    "\\set_mode PKTLSB 0",
    "\\get_mode",
  ]);
});

test("equivalent digital-mode readback aliases confirm the requested mode", async () => {
  const rig = new HamlibRig({
    request: async (command: string) => command === "\\get_mode"
      ? response("get_mode", { Mode: "USB-DATA", Passband: "3000" })
      : response(command.slice(1).split(" ")[0], {}),
  });

  assert.deepEqual(await rig.setMode("DATA-U"), { mode: "USB-DATA", passbandHz: 3_000 });
});

test("a Hamlib mode rejection becomes a mode-specific error", async () => {
  const rig = new HamlibRig({
    request: async (command: string) => {
      throw new RigReportError(command.slice(1).split(" ")[0], -1);
    },
  });

  await assert.rejects(rig.setMode("DATA-U"), (error: unknown) =>
    error instanceof RigModeError &&
      error.reason === "rejected" &&
      error.requestedMode === "DATA-U" &&
      error.hamlibMode === "PKTUSB" &&
      error.report === -1,
  );
});

test("PTT None caches commanded state when Hamlib rejects get_ptt and set_ptt", async () => {
  const commands: string[] = [];
  const requester = {
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\get_freq") return response("get_freq", { Frequency: "14074000" });
      if (command === "\\get_mode") return response("get_mode", { Mode: "USB", Passband: "3000" });
      if (command === "\\get_ptt" || command.startsWith("\\set_ptt ")) {
        throw new RigReportError(command.slice(1).split(" ")[0], -11);
      }
      return response(command.slice(1), {});
    },
  };
  const rig = new HamlibRig(requester, { pttMethod: "None" });

  assert.equal((await rig.readState()).ptt, false);
  assert.equal(await rig.setPtt(true), true);
  assert.equal((await rig.readState()).ptt, true);
  assert.ok(commands.includes("\\set_ptt 1"));
});

test("strict PTT read never falls back to the PTT None command cache", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\get_freq") return response("get_freq", { Frequency: "14074000" });
      if (command === "\\get_mode") return response("get_mode", { Mode: "USB", Passband: "3000" });
      throw new RigReportError(command.slice(1).split(" ")[0], -11);
    },
  }, { pttMethod: "None" });

  assert.equal(await rig.setPtt(true), true);
  assert.equal(await rig.setPtt(false), false);
  assert.equal((await rig.readState()).ptt, false, "display state keeps compatibility cache");
  await assert.rejects(rig.readPtt(), (error: unknown) =>
    error instanceof RigReportError && error.report === -11,
  );
  assert.equal(commands.at(-1), "\\get_ptt");
});

test("PTT OFF command is not physical OFF evidence", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  await rig.writePtt(false);
  assert.deepEqual(commands, ["\\set_ptt 0"]);
});

test("raw PTT write plus strict read uses exactly two CAT commands", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\get_ptt") return response("get_ptt", { PTT: "0" });
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  await rig.writePtt(false);
  assert.equal(await rig.readPtt(), false);
  assert.deepEqual(commands, ["\\set_ptt 0", "\\get_ptt"]);
});

test("de-key CAT commands use the safety queue", async (context) => {
  const fixture = deferredTransportFixture();
  context.after(async () => fixture.transport.close());
  const rig = new HamlibRig(fixture.transport);

  const tunerOff = rig.writeInternalTuner(false);
  await fixture.socket.waitForWrite("\\set_func TUNER 0\n");
  fixture.socket.replyActive();
  await tunerOff;
  const pttOff = rig.writePtt(false);
  await fixture.socket.waitForWrite("\\set_ptt 0\n");
  fixture.socket.replyActive();
  await pttOff;
  const readback = rig.readPtt();
  await fixture.socket.waitForWrite("\\get_ptt\n");
  fixture.socket.replyActive("PTT: 0");
  assert.equal(await readback, false);

  assert.deepEqual(
    fixture.transport.commandTrace().map(({ command, priority, source }) => ({
      command,
      priority,
      source,
    })),
    [
      { command: "\\set_func TUNER 0", priority: "safety", source: "ptt-off" },
      { command: "\\set_ptt 0", priority: "safety", source: "ptt-off" },
      { command: "\\get_ptt", priority: "safety", source: "ptt-off" },
    ],
  );
});

test("raw internal tuner write sends exactly one CAT command", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  await rig.writeInternalTuner(false);
  assert.deepEqual(commands, ["\\set_func TUNER 0"]);
});

test("persistent tuner engagement sends one enable command without starting another tune", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  assert.equal(await rig.engageInternalTuner(), true);
  assert.deepEqual(commands, ["\\set_func TUNER 1"]);
});

test("internal tuner start enables a supported tuner switch before the TUNE action", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        return response("vfo_op", { "Mem/VFO Op": "CPY TUNE TOGGLE" });
      }
      if (command === "\\set_func ?") {
        return response("set_func", { Func: "NB NR TUNER" });
      }
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  assert.equal(await rig.supportsInternalTuner(), true);
  assert.equal(await rig.supportsInternalTuner(), true);
  await rig.startInternalTuner();
  assert.deepEqual(commands, [
    "\\vfo_op ?",
    "\\set_func TUNER 1",
    "\\vfo_op TUNE",
  ]);
});

test("internal tuner reports an unsupported VFO action without trying to tune", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["CPY TOGGLE"]);
      }
      throw new Error(`unexpected command ${command}`);
    },
  });

  assert.equal(await rig.supportsInternalTuner(), false);
  assert.equal(await rig.supportsInternalTuner(), false);
  await assert.rejects(rig.startInternalTuner(), /does not support internal tuning/u);
  assert.deepEqual(commands, ["\\vfo_op ?"]);
});

test("internal tuner treats a rejected capability query as unknown and surfaces the TUNE result", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        throw new RigReportError("vfo_op", -11);
      }
      if (command === "\\set_func ?") {
        return responseValues("set_func", ["NB NR"]);
      }
      if (command === "\\vfo_op TUNE") {
        throw new RigReportError("vfo_op", -1);
      }
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  assert.equal(await rig.supportsInternalTuner(), true);
  assert.equal(await rig.supportsInternalTuner(), true);
  await assert.rejects(rig.startInternalTuner(), (error: unknown) =>
    error instanceof RigReportError && error.report === -1,
  );
  assert.deepEqual(commands, ["\\vfo_op ?", "\\set_func TUNER 1", "\\vfo_op TUNE"]);
});

test("internal tuner probes the TUNER switch without querying function capabilities", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["TUNE"]);
      }
      if (command === "\\set_func ?") {
        throw new RigReportError("set_func", -11);
      }
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  await rig.startInternalTuner();

  assert.deepEqual(commands, [
    "\\vfo_op ?",
    "\\set_func TUNER 1",
    "\\vfo_op TUNE",
  ]);
});

test("internal tuner falls back to TUNE when an unknown TUNER switch returns ENIMPL", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["TUNE"]);
      }
      if (command === "\\set_func ?" || command === "\\set_func TUNER 1") {
        throw new RigReportError("set_func", -11);
      }
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  await rig.startInternalTuner();
  assert.deepEqual(commands, [
    "\\vfo_op ?",
    "\\set_func TUNER 1",
    "\\vfo_op TUNE",
  ]);

  commands.length = 0;
  assert.equal(await rig.engageInternalTuner(), false);
  assert.deepEqual(commands, ["\\set_func TUNER 1"]);

  commands.length = 0;
  await rig.writeInternalTuner(false);
  assert.deepEqual(commands, []);
});

test("internal tuner preserves a non-ENIMPL TUNER probe error without starting TUNE", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["TUNE"]);
      }
      if (command === "\\set_func ?") {
        throw new RigReportError("set_func", -11);
      }
      if (command === "\\set_func TUNER 1") {
        throw new RigReportError("set_func", -2);
      }
      throw new Error(`unexpected command ${command}`);
    },
  });

  await assert.rejects(rig.startInternalTuner(), (error: unknown) =>
    error instanceof RigReportError && error.report === -2,
  );
  assert.deepEqual(commands, ["\\vfo_op ?", "\\set_func TUNER 1"]);
});

test("internal tuner enables the switch before TUNE even when set_func capabilities omit TUNER", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["CPY TUNE TOGGLE"]);
      }
      if (command === "\\set_func ?") {
        return responseValues("set_func", ["NB NR"]);
      }
      if (command === "\\get_func TUNER") {
        return responseValues("get_func", ["0"]);
      }
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  await rig.readControls();
  commands.length = 0;
  await rig.startInternalTuner();
  assert.deepEqual(commands, ["\\set_func TUNER 1", "\\vfo_op TUNE"]);
});

test("internal tuner stop disables a working switch even when capabilities omit TUNER", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["CPY TUNE TOGGLE"]);
      }
      if (command === "\\set_func ?") {
        return responseValues("set_func", ["NB NR"]);
      }
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  await rig.startInternalTuner();
  commands.length = 0;
  await rig.writeInternalTuner(false);

  assert.deepEqual(commands, ["\\set_func TUNER 0"]);
});

test("internal tuner stop attempts the real command when TUNER capability is unknown", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["TUNE"]);
      }
      if (command === "\\set_func ?") {
        throw new RigReportError("set_func", -11);
      }
      if (command === "\\set_func TUNER 0") {
        throw new RigReportError("set_func", -2);
      }
      return response(command.slice(1).split(" ")[0], {});
    },
  });

  await rig.startInternalTuner();
  commands.length = 0;
  await assert.rejects(rig.writeInternalTuner(false), (error: unknown) =>
    error instanceof RigReportError && error.report === -2,
  );

  assert.deepEqual(commands, ["\\set_func TUNER 0"]);
});

test("internal tuner surfaces a rejected TUNE action after enabling the supported switch", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["CPY TUNE TOGGLE"]);
      }
      if (command === "\\set_func ?") {
        return responseValues("set_func", ["NB NR TUNER"]);
      }
      if (command === "\\set_func TUNER 1") {
        return response("set_func", {});
      }
      if (command === "\\vfo_op TUNE") {
        throw new RigReportError("vfo_op", -1);
      }
      throw new Error(`unexpected command ${command}`);
    },
  });

  await assert.rejects(rig.startInternalTuner(), (error: unknown) =>
    error instanceof RigReportError && error.report === -1,
  );
  assert.deepEqual(commands, [
    "\\vfo_op ?",
    "\\set_func TUNER 1",
    "\\vfo_op TUNE",
  ]);
});

test("real rigs still surface unavailable PTT read-back from Hamlib", async () => {
  const rig = new HamlibRig({
    request: async (command: string) => {
      if (command === "\\get_freq") return response("get_freq", { Frequency: "14074000" });
      if (command === "\\get_mode") return response("get_mode", { Mode: "USB", Passband: "3000" });
      throw new RigReportError("get_ptt", -11);
    },
  }, { pttMethod: "RIG" });
  await assert.rejects(rig.readState(), (error: unknown) =>
    error instanceof RigReportError && error.report === -11,
  );
  await assert.rejects(rig.readPtt(), (error: unknown) =>
    error instanceof RigReportError && error.report === -11,
  );
  await assert.rejects(rig.setPtt(true), (error: unknown) =>
    error instanceof RigReportError && error.report === -11,
  );
});

test("Hamlib exposes the tuner switch and tune action when TUNE exists but set_func omits TUNER", async () => {
  const commands: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\get_level ?" || command === "\\set_level ?") {
        return responseValues(command.includes("get_") ? "get_level" : "set_level", []);
      }
      if (command === "\\get_func ?" || command === "\\set_func ?") {
        return responseValues(command.includes("get_") ? "get_func" : "set_func", ["NB NR"]);
      }
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["TUNE"]);
      }
      if (command === "\\get_func TUNER") {
        return responseValues("get_func", ["1"]);
      }
      throw new RigReportError(command, -11);
    },
  });

  const controls = await rig.readControls();

  assert.deepEqual(controls.map(({ id }) => id), ["function:TUNER", "action:TUNER"]);
  assert.equal(controls.find(({ id }) => id === "function:TUNER")?.value, true);
  assert.equal(controls.find(({ id }) => id === "action:TUNER")?.value, null);
  assert.equal(commands.includes("\\get_func TUNER"), true);
});

test("TUNER switch read-back mismatch warns without rejecting the accepted write", async () => {
  const commands: string[] = [];
  const warnings: string[] = [];
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\get_level ?" || command === "\\set_level ?") {
        return responseValues(command.includes("get_") ? "get_level" : "set_level", []);
      }
      if (command === "\\get_func ?" || command === "\\set_func ?") {
        return responseValues(command.includes("get_") ? "get_func" : "set_func", ["NB NR"]);
      }
      if (command === "\\vfo_op ?") {
        return responseValues("vfo_op", ["TUNE"]);
      }
      if (command === "\\set_func TUNER 1") {
        return response("set_func", {});
      }
      if (command === "\\get_func TUNER") {
        return responseValues("get_func", ["0"]);
      }
      throw new RigReportError(command, -11);
    },
  }, { onWarning: (message) => warnings.push(message) });

  await rig.readControls();
  commands.length = 0;
  const updated = await rig.setControl("function:TUNER", true);

  assert.equal(updated.value, true);
  assert.deepEqual(commands, ["\\set_func TUNER 1", "\\get_func TUNER"]);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0] ?? "", /TUNER read-back mismatch/u);
});

test("Hamlib controls are the safe readable and writable capability intersection", async () => {
  const commands: string[] = [];
  const levelValues = new Map([
    ["AF", "0.42"],
    ["RFPOWER", "0.25"],
  ]);
  const functionValues = new Map([
    ["NB", "1"],
    ["ANF", "0"],
    ["TUNER", "0"],
  ]);
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\get_level ?") {
        return responseValues("get_level", ["AF RFPOWER STRENGTH NB"]);
      }
      if (command === "\\set_level ?") {
        return response("set_level", { Level: "MICGAIN RFPOWER AF RAWSTR" });
      }
      if (command === "\\get_func ?") {
        return response("get_func", { Func: "NB NR ANF TUNER" });
      }
      if (command === "\\set_func ?") {
        return responseValues("set_func", ["COMP NB ANF TUNER"]);
      }
      if (command === "\\set_level AF ?" || command === "\\set_level RFPOWER ?") {
        return responseValues("set_level", ["(0.000000..1.000000/0.010000)"]);
      }
      if (command.startsWith("\\get_level ")) {
        const token = command.split(" ")[1] ?? "";
        return responseValues("get_level", [levelValues.get(token) ?? "0"]);
      }
      if (command.startsWith("\\get_func ")) {
        const token = command.split(" ")[1] ?? "";
        return responseValues("get_func", [functionValues.get(token) ?? "0"]);
      }
      if (command === "\\get_mode") {
        return response("get_mode", { Mode: "PKTUSB", Passband: "3000" });
      }
      throw new Error(`unexpected command ${command}`);
    },
  });

  const controls = await rig.readControls();
  assert.deepEqual(controls.map((control) => control.id), [
    "level:AF",
    "level:RFPOWER",
    "level:STRENGTH",
    "function:NB",
    "function:ANF",
    "function:TUNER",
    "passband:CURRENT",
  ]);
  assert.deepEqual(controls.find((control) => control.id === "level:RFPOWER"), {
    id: "level:RFPOWER",
    kind: "level",
    token: "RFPOWER",
    group: "rf",
    access: "read-write",
    presentation: "slider",
    value: 0.25,
    minimum: 0,
    maximum: 1,
    step: 0.01,
    unit: "ratio",
    transmitLocked: true,
  });
  assert.equal(controls.find((control) => control.id === "level:AF")?.value, 0.42);
  assert.equal(controls.find((control) => control.id === "function:NB")?.value, true);
  assert.deepEqual(controls.at(-1), {
    id: "passband:CURRENT",
    kind: "passband",
    token: "PASSBAND",
    group: "mode",
    access: "read-write",
    presentation: "discrete",
    value: 3_000,
    minimum: 100,
    maximum: 12_000,
    step: 50,
    unit: "hertz",
    options: undefined,
    transmitLocked: true,
  });
  assert.equal(commands.filter((command) => command === "\\get_level ?").length, 1);
  assert.equal(commands.filter((command) => command === "\\set_level ?").length, 1);
});

test("Hamlib control writes validate, write once and confirm the read-back", async () => {
  const commands: string[] = [];
  let rfPower = 0.2;
  let noiseBlanker = false;
  const rig = new HamlibRig({
    request: async (command: string) => {
      commands.push(command);
      if (command === "\\get_level ?" || command === "\\set_level ?") {
        return responseValues(command.includes("get_") ? "get_level" : "set_level", ["RFPOWER"]);
      }
      if (command === "\\get_func ?" || command === "\\set_func ?") {
        return responseValues(command.includes("get_") ? "get_func" : "set_func", ["NB"]);
      }
      if (command === "\\set_level RFPOWER ?") {
        return responseValues("set_level", ["(0.000000..1.000000/0.010000)"]);
      }
      if (command.startsWith("\\set_level RFPOWER ")) {
        rfPower = Number(command.split(" ")[2]);
        return response("set_level", {});
      }
      if (command === "\\get_level RFPOWER") {
        return responseValues("get_level", [String(rfPower)]);
      }
      if (command.startsWith("\\set_func NB ")) {
        noiseBlanker = command.endsWith(" 1");
        return response("set_func", {});
      }
      if (command === "\\get_func NB") {
        return responseValues("get_func", [noiseBlanker ? "1" : "0"]);
      }
      if (command === "\\get_mode") {
        return response("get_mode", { Mode: "USB", Passband: "2400" });
      }
      throw new Error(`unexpected command ${command}`);
    },
  });

  await rig.readControls();
  const power = await rig.setControl("level:RFPOWER", 0.35);
  assert.equal(power.value, 0.35);
  const nb = await rig.setControl("function:NB", 1);
  assert.equal(nb.value, true);
  await assert.rejects(rig.setControl("level:RFPOWER", 1.5), /outside/u);
  await assert.rejects(rig.setControl("level:STRENGTH", 0.5), /unavailable/u);
  assert.deepEqual(commands.slice(-4), [
    "\\set_level RFPOWER 0.35",
    "\\get_level RFPOWER",
    "\\set_func NB 1",
    "\\get_func NB",
  ]);
});

test("Hamlib rejects a control write whose read-back does not match", async () => {
  const rig = new HamlibRig({
    request: async (command: string) => {
      if (command === "\\get_level ?" || command === "\\set_level ?") {
        return responseValues(command.includes("get_") ? "get_level" : "set_level", ["RFPOWER"]);
      }
      if (command === "\\get_func ?" || command === "\\set_func ?") {
        return responseValues(command.includes("get_") ? "get_func" : "set_func", []);
      }
      if (command === "\\set_level RFPOWER ?") {
        return responseValues("set_level", ["(0.000000..1.000000/0.010000)"]);
      }
      if (command === "\\get_level RFPOWER") {
        return responseValues("get_level", ["0.10"]);
      }
      if (command === "\\get_mode") {
        return response("get_mode", { Mode: "USB", Passband: "2400" });
      }
      return response(command.slice(1).split(" ")[0] ?? "set_level", {});
    },
  });

  await rig.readControls();
  await assert.rejects(rig.setControl("level:RFPOWER", 0.5), /read-back mismatch/u);
});

function response(command: string, fields: Record<string, string>) {
  return {
    command,
    fields: new Map(Object.entries(fields)),
    values: [],
    report: 0,
  };
}

function responseValues(command: string, values: string[]) {
  return {
    command,
    fields: new Map<string, string>(),
    values,
    report: 0,
  };
}

class DeferredSocket extends Duplex {
  readonly writes: string[] = [];
  readonly #commands: string[] = [];
  readonly #commandWaiters = new Set<() => void>();
  #input = "";

  pendingCommands(): number {
    return this.#commands.length;
  }

  async waitForPendingCommands(count: number): Promise<void> {
    while (this.#commands.length < count) {
      await new Promise<void>((resolve) => this.#commandWaiters.add(resolve));
    }
  }

  async waitForWrite(expected: string): Promise<void> {
    while (!this.writes.includes(expected)) {
      await new Promise<void>((resolve) => this.#commandWaiters.add(resolve));
    }
  }

  replyActive(...fields: string[]): void {
    this.reply(...fields);
  }

  reply(...fields: string[]): void {
    const command = this.#commands.shift();
    if (command === undefined) {
      throw new Error("DeferredSocket has no pending command to reply to");
    }
    const name = command.slice(1).split(" ")[0];
    const body = fields.length === 0 ? "" : `${fields.join("|")}|`;
    this.push(Buffer.from(`${name}:|${body}RPRT 0|\n`, "ascii"));
  }

  setNoDelay(_noDelay?: boolean): this {
    return this;
  }

  override _read(): void {}

  override _write(
    chunk: Buffer | string,
    encoding: BufferEncoding,
    callback: (error?: Error | null) => void,
  ): void {
    this.#input += Buffer.isBuffer(chunk) ? chunk.toString("ascii") : Buffer.from(chunk, encoding).toString("ascii");
    while (this.#input.includes("\n")) {
      const newline = this.#input.indexOf("\n");
      const wire = this.#input.slice(0, newline);
      this.#input = this.#input.slice(newline + 1);
      const command = wire.startsWith("|") ? wire.slice(1) : wire;
      this.#commands.push(command);
      this.writes.push(`${command}\n`);
      for (const resolve of this.#commandWaiters) resolve();
      this.#commandWaiters.clear();
    }
    callback();
  }

  override _final(callback: (error?: Error | null) => void): void {
    this.push(null);
    callback();
  }
}

function deferredTransportFixture(
  options: Pick<RigctldTransportOptions, "now" | "delay" | "normalQueueLimit"> = {},
): {
  transport: RigctldTransport;
  socket: DeferredSocket;
} {
  const socket = new DeferredSocket();
  const connect = (() => {
    queueMicrotask(() => socket.emit("connect"));
    return socket as unknown as Socket;
  }) as typeof createConnection;
  const clock = options.now === undefined && options.delay === undefined ? new InstantClock() : null;
  return {
    socket,
    transport: new RigctldTransport("deferred.test", 4_532, {
      connect,
      now: options.now ?? clock?.now,
      delay: options.delay ?? clock?.delay,
      normalQueueLimit: options.normalQueueLimit,
    }),
  };
}

async function assertRejectsOnNextTurn(
  promise: Promise<unknown>,
  expected: new (...args: never[]) => Error,
): Promise<void> {
  const outcome = await Promise.race([
    promise.then(
      () => ({ kind: "fulfilled" as const }),
      (error: unknown) => ({ kind: "rejected" as const, error }),
    ),
    new Promise<{ kind: "pending" }>((resolve) => setImmediate(() => resolve({ kind: "pending" }))),
  ]);
  assert.equal(outcome.kind, "rejected", "queue overflow must reject without waiting for CAT budget");
  if (outcome.kind === "rejected") assert.ok(outcome.error instanceof expected);
}

async function nextTurn(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
}

class TransportClock {
  #now = 0;
  #timers: Array<{
    dueAtMs: number;
    resolve: () => void;
    signal: AbortSignal;
    onAbort: () => void;
  }> = [];

  now = (): number => this.#now;

  delay = (milliseconds: number, signal: AbortSignal): Promise<void> => new Promise((resolve, reject) => {
    const timer = {
      dueAtMs: this.#now + milliseconds,
      resolve,
      signal,
      onAbort: () => {},
    };
    timer.onAbort = () => {
      this.#timers = this.#timers.filter((candidate) => candidate !== timer);
      reject(signal.reason instanceof Error ? signal.reason : new Error("delay aborted"));
    };
    signal.addEventListener("abort", timer.onAbort, { once: true });
    this.#timers.push(timer);
  });

  async advanceBy(milliseconds: number): Promise<void> {
    this.#now += milliseconds;
    const due = this.#timers.filter((timer) => timer.dueAtMs <= this.#now);
    this.#timers = this.#timers.filter((timer) => timer.dueAtMs > this.#now);
    for (const timer of due) {
      timer.signal.removeEventListener("abort", timer.onAbort);
      timer.resolve();
    }
    await new Promise<void>((resolve) => queueMicrotask(resolve));
  }
}

class InstantClock {
  #now = 0;

  now = (): number => this.#now;

  delay = async (milliseconds: number, signal: AbortSignal): Promise<void> => {
    signal.throwIfAborted();
    this.#now += milliseconds;
  };
}

function reconnectingTransportFixture(): {
  transport: RigctldTransport;
  waitForSocket(count: number): Promise<DeferredSocket>;
} {
  const sockets: DeferredSocket[] = [];
  const waiters = new Set<() => void>();
  const connect = (() => {
    const socket = new DeferredSocket();
    sockets.push(socket);
    for (const resolve of waiters) resolve();
    waiters.clear();
    queueMicrotask(() => socket.emit("connect"));
    return socket as unknown as Socket;
  }) as typeof createConnection;
  return {
    transport: new RigctldTransport("reconnecting.test", 4_532, { connect }),
    async waitForSocket(count) {
      while (sockets.length < count) {
        await new Promise<void>((resolve) => waiters.add(resolve));
      }
      const socket = sockets[count - 1];
      if (socket === undefined) throw new Error("expected DeferredSocket was not created");
      return socket;
    },
  };
}

async function startFakeRigctld(): Promise<{
  server: Server;
  port: number;
  commands: string[];
  connectionCount: () => number;
}> {
  const commands: string[] = [];
  let connections = 0;
  let frequency = 14_074_000;
  let mode = "USB";
  let passband = 3_000;
  let ptt = false;
  let tuner = false;
  const server = createServer((socket: Socket) => {
    connections += 1;
    let buffer = "";
    socket.on("data", (data) => {
      buffer += data.toString("ascii");
      while (buffer.includes("\n")) {
        const index = buffer.indexOf("\n");
        const wire = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        const command = wire.startsWith("|") ? wire.slice(1) : wire;
        commands.push(command);
        const [name, ...args] = command.split(" ");
        if (name === "\\set_freq") frequency = Number(args[0]);
        if (name === "\\set_mode") { mode = args[0]; passband = Number(args[1]) || 2_400; }
        if (name === "\\set_ptt") ptt = args[0] === "1";
        if (name === "\\set_func" && args[0] === "TUNER") tuner = args[1] === "1";
        if (name === "\\vfo_op" && args[0] === "TUNE") tuner = true;
        const response = responseFor(name, args, { frequency, mode, passband, ptt, tuner });
        const split = Math.max(1, Math.floor(response.length / 2));
        socket.write(response.slice(0, split));
        setImmediate(() => socket.write(response.slice(split)));
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("no test address");
  return { server, port: address.port, commands, connectionCount: () => connections };
}

function responseFor(
  command: string,
  args: readonly string[],
  state: { frequency: number; mode: string; passband: number; ptt: boolean; tuner: boolean },
): string {
  const header = command.slice(1);
  if (command === "\\get_freq") return `${header}:|Frequency: ${state.frequency}|RPRT 0|\n`;
  if (command === "\\get_mode") return `${header}:|Mode: ${state.mode}|Passband: ${state.passband}|RPRT 0|\n`;
  if (command === "\\get_ptt") return `${header}:|PTT: ${state.ptt ? 1 : 0}|RPRT 0|\n`;
  if (command === "\\get_func") return `${header}:|${state.tuner ? 1 : 0}|RPRT 0|\n`;
  if (command === "\\set_func" && args[0] === "?") return `${header}:|Func: NB NR TUNER|RPRT 0|\n`;
  if (command === "\\vfo_op") return `${header}:|Mem/VFO Op: TUNE TOGGLE|RPRT 0|\n`;
  return `${header}:|RPRT 0|\n`;
}

function closeServer(server: Server): Promise<void> {
  return new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}
