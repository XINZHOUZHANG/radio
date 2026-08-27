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
import { RigctldTransport, RigReportError } from "../src/rig/transport.ts";

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

test("persistent rigctld transport serializes commands and HamlibRig confirms read-back", async (context) => {
  const fake = await startFakeRigctld();
  const transport = new RigctldTransport("127.0.0.1", fake.port);
  context.after(async () => {
    await transport.close();
    await closeServer(fake.server);
  });
  const rig = new HamlibRig(transport);

  assert.equal(await rig.setFrequency(7_074_000), 7_074_000);
  assert.deepEqual(await rig.setMode("usb", 2_400), { mode: "USB", passbandHz: 2_400 });
  assert.equal(await rig.setPtt(true), true);
  assert.equal(await rig.setInternalTuner(true), true);
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
  await assert.rejects(rig.setPtt(true), (error: unknown) =>
    error instanceof RigReportError && error.report === -11,
  );
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
        return responseValues("set_func", ["COMP NB ANF"]);
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
    "level:RFPOWER",
    "level:AF",
    "function:NB",
    "function:ANF",
    "passband:CURRENT",
  ]);
  assert.deepEqual(controls[0], {
    id: "level:RFPOWER",
    kind: "level",
    token: "RFPOWER",
    value: 0.25,
    minimum: 0,
    maximum: 1,
    step: 0.01,
    unit: "ratio",
    transmitLocked: true,
  });
  assert.equal(controls[1]?.value, 0.42);
  assert.equal(controls[2]?.value, 1);
  assert.deepEqual(controls.at(-1), {
    id: "passband:CURRENT",
    kind: "passband",
    token: "CURRENT",
    value: 3_000,
    minimum: 100,
    maximum: 12_000,
    step: 50,
    unit: "hertz",
    transmitLocked: false,
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
  assert.equal(nb.value, 1);
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
      this.#commands.push(wire.startsWith("|") ? wire.slice(1) : wire);
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

function deferredTransportFixture(): {
  transport: RigctldTransport;
  socket: DeferredSocket;
} {
  const socket = new DeferredSocket();
  const connect = (() => {
    queueMicrotask(() => socket.emit("connect"));
    return socket as unknown as Socket;
  }) as typeof createConnection;
  return {
    socket,
    transport: new RigctldTransport("deferred.test", 4_532, { connect }),
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
        const response = responseFor(name, { frequency, mode, passband, ptt, tuner });
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
  state: { frequency: number; mode: string; passband: number; ptt: boolean; tuner: boolean },
): string {
  const header = command.slice(1);
  if (command === "\\get_freq") return `${header}:|Frequency: ${state.frequency}|RPRT 0|\n`;
  if (command === "\\get_mode") return `${header}:|Mode: ${state.mode}|Passband: ${state.passband}|RPRT 0|\n`;
  if (command === "\\get_ptt") return `${header}:|PTT: ${state.ptt ? 1 : 0}|RPRT 0|\n`;
  if (command === "\\get_func") return `${header}:|${state.tuner ? 1 : 0}|RPRT 0|\n`;
  return `${header}:|RPRT 0|\n`;
}

function closeServer(server: Server): Promise<void> {
  return new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}
