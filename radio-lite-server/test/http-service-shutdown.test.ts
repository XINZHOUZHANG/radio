import assert from "node:assert/strict";
import { Agent, get } from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import WebSocket, { type RawData } from "ws";

import { DeviceStore } from "../src/auth/device-store.ts";
import { UserStore } from "../src/auth/user-store.ts";
import { RadioConfigStore } from "../src/config/radio-config-store.ts";
import type { RadioProfile } from "../src/config/types.ts";
import type {
  RadioControl,
  RadioControlValue,
  RadioDriver,
} from "../src/rig/radio-driver.ts";
import { RadioRuntime } from "../src/rig/radio-runtime.ts";
import { RadioLiteService } from "../src/server/radio-lite-service.ts";

test("close releases an idle keep-alive connection promptly", { timeout: 2_000 }, async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-shutdown-idle-"));
  const service = new RadioLiteService({ dataDirectory: directory });
  const agent = new Agent({ keepAlive: true, maxSockets: 1 });
  context.after(async () => {
    agent.destroy();
    await service.close().catch(() => undefined);
    await rm(directory, { recursive: true, force: true });
  });

  const address = await service.listen();
  await getAndDrain(address.port, agent);

  const startedAt = performance.now();
  await service.close();
  const elapsedMs = performance.now() - startedAt;

  assert.ok(elapsedMs < 500, `idle keep-alive delayed shutdown by ${String(elapsedMs)} ms`);
});

test("shutdown confirms PTT OFF before forcing an active HTTP connection closed", { timeout: 2_000 }, async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-shutdown-force-"));
  const radioConfigPath = join(directory, "radios.json");
  const profile = shutdownProfile();
  const radios = new RadioConfigStore(radioConfigPath);
  await radios.load();
  await radios.upsert(profile);

  const users = new UserStore(join(directory, "users.json"));
  await users.load();
  const admin = await users.initializeAdmin("shutdown-admin", "shutdown-password");
  const devices = new DeviceStore(join(directory, "devices.json"));
  await devices.load();
  const credentials = await devices.pair(admin.id, "Shutdown test client");

  const events: string[] = [];
  const rig = new ShutdownRig(events);
  const service = new RadioLiteService({
    dataDirectory: directory,
    radioConfigPath,
    userStore: users,
    deviceStore: devices,
    shutdownDeadlineMs: 25,
    onShutdownWarning: (message) => {
      assert.match(message, /deadline.*forcing active HTTP connections closed/iu);
      events.push("force-http");
    },
    runtimeFactory: async (runtimeProfile, _managedPort, safetyEvents) => {
      const runtime = new RadioRuntime(
        runtimeProfile,
        rig,
        async () => undefined,
        Date.now,
        { safetyEvents },
      );
      await runtime.initialize();
      return runtime;
    },
  });
  let webSocket: WebSocket | null = null;
  let stalledConnection: Socket | null = null;
  context.after(async () => {
    stalledConnection?.destroy();
    webSocket?.terminate();
    await service.close().catch(() => undefined);
    await rm(directory, { recursive: true, force: true });
  });

  const address = await service.listen();
  webSocket = new WebSocket(`ws://127.0.0.1:${address.port}/ws/control`, "radio-lite.v1");
  await onceOpen(webSocket);
  assert.equal((await sendJsonAndReceive(webSocket, {
    t: "auth.device",
    deviceId: credentials.deviceId,
    accessToken: credentials.accessToken,
  })).t, "auth.ok");
  assert.equal((await nextJsonMessage(webSocket)).t, "safety.snapshot.begin");
  assert.equal((await nextJsonMessage(webSocket)).t, "safety.snapshot");
  assert.equal((await nextJsonMessage(webSocket)).t, "safety.snapshot.end");

  const acquired = await sendJsonAndReceive(webSocket, { t: "control.acquire", radioId: profile.id });
  assert.equal(acquired.t, "control.acquired");
  const tuning = await sendJsonAndReceive(webSocket, {
    t: "rig.action.invoke",
    radioId: profile.id,
    controlToken: acquired.controlToken,
    id: "action:TUNER",
    commandId: "shutdown-tuning",
  });
  assert.equal(tuning.t, "rig.action.confirmed");

  stalledConnection = await openStalledRequest(address.port);
  const closing = service.close();
  const closedWithinDeadline = await settlesWithin(closing, 250);
  if (!closedWithinDeadline) {
    stalledConnection.destroy();
  }
  await closing;

  assert.equal(closedWithinDeadline, true, "active HTTP connection exceeded the shutdown deadline");
  const pttOffIndex = events.indexOf("ptt-off");
  const forceIndex = events.indexOf("force-http");
  assert.notEqual(pttOffIndex, -1, "shutdown did not execute PTT OFF");
  assert.notEqual(forceIndex, -1, "shutdown did not report forced HTTP connection cleanup");
  assert.ok(pttOffIndex < forceIndex, `unsafe shutdown order: ${events.join(" -> ")}`);
});

function getAndDrain(port: number, agent: Agent): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = get({ host: "127.0.0.1", port, path: "/healthz", agent }, (response) => {
      response.resume();
      response.once("end", resolve);
      response.once("error", reject);
    });
    request.once("error", reject);
  });
}

function onceOpen(webSocket: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    webSocket.once("open", resolve);
    webSocket.once("error", reject);
  });
}

function openStalledRequest(port: number): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = connect({ host: "127.0.0.1", port });
    socket.once("error", reject);
    socket.once("connect", () => {
      socket.write([
        "POST /api/v1/setup/initialize HTTP/1.1",
        "Host: 127.0.0.1",
        "Content-Type: application/json",
        "Content-Length: 100",
        "Connection: keep-alive",
        "",
        "{",
      ].join("\r\n"));
      setImmediate(() => resolve(socket));
    });
  });
}

async function settlesWithin(operation: Promise<void>, timeoutMs: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timedOut = new Promise<false>((resolve) => {
    timer = setTimeout(() => resolve(false), timeoutMs);
  });
  try {
    return await Promise.race([operation.then(() => true as const), timedOut]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

type JsonQueueWaiter = {
  resolve(value: any): void;
  reject(error: Error): void;
};

type JsonQueue = {
  readonly messages: any[];
  readonly waiters: JsonQueueWaiter[];
  failure: Error | null;
};

const jsonQueues = new WeakMap<WebSocket, JsonQueue>();

function queueFor(webSocket: WebSocket): JsonQueue {
  const existing = jsonQueues.get(webSocket);
  if (existing !== undefined) return existing;
  const queue: JsonQueue = { messages: [], waiters: [], failure: null };
  const fail = (error: Error) => {
    queue.failure = error;
    for (const waiter of queue.waiters.splice(0)) waiter.reject(error);
  };
  webSocket.on("message", (data: RawData, isBinary: boolean) => {
    if (isBinary) return;
    let parsed: any;
    try {
      parsed = JSON.parse(data.toString());
    } catch (error) {
      fail(error instanceof Error ? error : new Error(String(error)));
      return;
    }
    const waiter = queue.waiters.shift();
    if (waiter === undefined) queue.messages.push(parsed);
    else waiter.resolve(parsed);
  });
  webSocket.on("error", fail);
  jsonQueues.set(webSocket, queue);
  return queue;
}

function nextJsonMessage(webSocket: WebSocket): Promise<any> {
  const queue = queueFor(webSocket);
  const message = queue.messages.shift();
  if (message !== undefined) return Promise.resolve(message);
  if (queue.failure !== null) return Promise.reject(queue.failure);
  return new Promise((resolve, reject) => queue.waiters.push({ resolve, reject }));
}

async function sendJsonAndReceive(webSocket: WebSocket, value: unknown): Promise<any> {
  let response = nextJsonMessage(webSocket);
  webSocket.send(JSON.stringify(value));
  while (true) {
    const parsed = await response;
    if (typeof parsed?.t !== "string" || !parsed.t.startsWith("safety.")) return parsed;
    response = nextJsonMessage(webSocket);
  }
}

function shutdownProfile(): RadioProfile {
  return {
    id: "main",
    name: "Shutdown fake",
    hamlibModelId: 1_049,
    connection: { kind: "network-rigctld", host: "127.0.0.1", port: 4_532 },
    audioInput: { backend: "pulse", id: "shutdown-input" },
    audioOutput: { backend: "pulse", id: "shutdown-output" },
    ptt: { method: "RIG" },
    station: { callsign: "N0CALL", grid: "AA00" },
    hardwareTxEnabled: true,
  };
}

class ShutdownRig implements RadioDriver {
  readonly #events: string[];
  #ptt = false;

  constructor(events: string[]) {
    this.#events = events;
  }

  async initialize() {}
  async close() {}
  async capabilities() { return { canTransmit: true, supportsInternalTuner: true }; }
  async readState() {
    return { frequencyHz: 14_074_000, mode: "USB", passbandHz: 3_000, ptt: this.#ptt };
  }
  async readTelemetry() { return { ptt: this.#ptt, availableMeters: ["PTT"] }; }
  async readControls(): Promise<RadioControl[]> {
    return [{
      id: "action:TUNER",
      kind: "action",
      token: "TUNER",
      group: "rf",
      access: "action",
      presentation: "button",
      value: null,
      transmitLocked: true,
    }];
  }
  async setFrequency(frequencyHz: number) { return frequencyHz; }
  async setMode(mode: string, passbandHz = 3_000) { return { mode, passbandHz }; }
  async setControl(_id: string, _value: RadioControlValue): Promise<RadioControl> {
    throw new Error("shutdown test does not expose writable controls");
  }
  async invokeAction(id: string) {
    if (id !== "action:TUNER") throw new Error("unexpected action");
  }
  async writePtt(enabled: boolean) {
    this.#ptt = enabled;
    if (!enabled) this.#events.push("ptt-off");
  }
  async readPtt() { return this.#ptt; }
}
