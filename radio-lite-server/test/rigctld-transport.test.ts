import assert from "node:assert/strict";
import { createServer, type Server, type Socket } from "node:net";
import { test } from "node:test";

import { encodeRigCommand, ExtendedResponseParser } from "../src/rig/extended-protocol.ts";
import { HamlibRig } from "../src/rig/hamlib-rig.ts";
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

function response(command: string, fields: Record<string, string>) {
  return {
    command,
    fields: new Map(Object.entries(fields)),
    values: [],
    report: 0,
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
