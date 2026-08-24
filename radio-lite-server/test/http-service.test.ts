import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import WebSocket from "ws";

import { DeviceStore } from "../src/auth/device-store.ts";
import { SessionStore } from "../src/auth/session-store.ts";
import { UserStore } from "../src/auth/user-store.ts";
import { RadioRuntime, type RigControl } from "../src/rig/radio-runtime.ts";
import { RadioLiteService } from "../src/server/radio-lite-service.ts";

test("HTTP service completes setup, login, pairing and radio configuration", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-http-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  let userNumber = 0;
  let tokenNumber = 0;
  const codes = [123456, 654321];
  const now = () => 10_000;
  const users = new UserStore(join(directory, "users.json"), {
    now,
    idFactory: () => `user-${++userNumber}`,
  });
  const devices = new DeviceStore(join(directory, "devices.json"), {
    now,
    idFactory: () => "device-1",
    tokenFactory: () => `device_${String(++tokenNumber).padStart(40, "0")}`,
  });
  const sessions = new SessionStore({
    now,
    tokenFactory: () => "session_".padEnd(43, "s"),
    csrfKey: Buffer.alloc(32, 5),
  });
  const rig = new ApiFakeRig();
  const service = new RadioLiteService({
    dataDirectory: directory,
    now,
    userStore: users,
    deviceStore: devices,
    sessionStore: sessions,
    codeOptions: {
      codeFactory: () => codes.shift() ?? 999999,
      hmacKey: Buffer.alloc(32, 6),
    },
    runtimeFactory: async (profile) => {
      const runtime = new RadioRuntime(profile, rig, async () => undefined, now);
      await runtime.initialize();
      return runtime;
    },
  });
  const address = await service.listen();
  context.after(() => service.close());
  const base = `http://127.0.0.1:${address.port}`;

  let response = await fetch(`${base}/healthz`);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, "ok");
  assert.equal(service.setupCode, "123456");

  response = await postJson(`${base}/api/v1/setup/initialize`, {
    setupCode: "123456",
    username: "connor",
    password: "Admin radio password 2026!",
  });
  assert.equal(response.status, 201);
  const initialized = await response.json();
  assert.equal(initialized.user.role, "admin");

  response = await postJson(`${base}/api/v1/session/login`, {
    username: "connor",
    password: "Admin radio password 2026!",
  });
  assert.equal(response.status, 200);
  const login = await response.json();
  const cookie = response.headers.get("set-cookie")?.split(";", 1)[0];
  assert.equal(typeof cookie, "string");
  assert.match(login.csrfToken, /^[A-Za-z0-9_-]{43}$/u);

  response = await fetch(`${base}/api/v1/session`, { headers: { Cookie: cookie! } });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).user.username, "connor");

  response = await postJson(
    `${base}/api/v1/pairing/code`,
    { userId: initialized.user.id },
    { Cookie: cookie!, "X-CSRF-Token": login.csrfToken },
  );
  assert.equal(response.status, 201);
  assert.equal((await response.json()).code, "654321");

  response = await postJson(`${base}/api/v1/pairing/redeem`, {
    code: "654321",
    deviceName: "Connor iPhone",
  });
  assert.equal(response.status, 201);
  const credentials = await response.json();
  assert.equal(credentials.deviceId, "device-1");
  assert.match(credentials.accessToken, /^device_/u);

  response = await postJson(
    `${base}/api/v1/radios`,
    {
      profile: {
        id: "main",
        name: "FT-710",
        hamlibModelId: 1049,
        connection: {
          kind: "managed-serial",
          devicePath: "/dev/serial/by-id/usb-Yaesu_FT-710-if00",
          baudRate: 38_400,
        },
        audioInput: { backend: "alsa", id: "hw:1,0" },
        audioOutput: { backend: "alsa", id: "hw:1,0" },
        station: { callsign: "BI1ABC", grid: "OM89" },
        hardwareTxEnabled: true,
      },
      hardwareTxConfirmation: "main",
    },
    { Cookie: cookie!, "X-CSRF-Token": login.csrfToken },
  );
  assert.equal(response.status, 200);
  assert.equal((await response.json()).radio.id, "main");

  response = await fetch(`${base}/api/v1/radios`, { headers: { Cookie: cookie! } });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).radios.map((radio: { id: string }) => radio.id), ["main"]);

  const webSocket = new WebSocket(
    `ws://127.0.0.1:${address.port}/ws/control`,
    "radio-lite.v1",
  );
  context.after(() => webSocket.terminate());
  await new Promise<void>((resolve, reject) => {
    webSocket.once("open", resolve);
    webSocket.once("error", reject);
  });
  webSocket.send(JSON.stringify({
    t: "auth.device",
    deviceId: credentials.deviceId,
    accessToken: credentials.accessToken,
  }));
  const authenticated = await nextJsonMessage(webSocket);
  assert.equal(authenticated.t, "auth.ok");
  assert.equal(authenticated.channel, "control");
  assert.equal(authenticated.principal.deviceId, "device-1");
  assert.deepEqual(authenticated.radios.map((radio: { id: string }) => radio.id), ["main"]);

  webSocket.send(JSON.stringify({ t: "ping" }));
  assert.equal((await nextJsonMessage(webSocket)).t, "pong");

  let reply = await sendJsonAndReceive(webSocket, { t: "control.acquire", radioId: "main" });
  assert.equal(reply.t, "control.acquired");
  const controlToken = reply.controlToken;

  reply = await sendJsonAndReceive(webSocket, {
    t: "rig.frequency.set",
    radioId: "main",
    controlToken,
    frequencyHz: 7_074_000,
    commandId: "frequency-1",
  });
  assert.equal(reply.t, "rig.frequency.confirmed");
  assert.equal(reply.frequencyHz, 7_074_000);

  reply = await sendJsonAndReceive(webSocket, {
    t: "tx.start",
    radioId: "main",
    controlToken,
    mode: "voice",
    commandId: "ptt-start-1",
  });
  assert.equal(reply.t, "tx.started");
  assert.equal(rig.ptt, true);
  const transmitToken = reply.transmitToken;

  reply = await sendJsonAndReceive(webSocket, {
    t: "tx.heartbeat",
    radioId: "main",
    controlToken,
    transmitToken,
  });
  assert.equal(reply.t, "tx.alive");

  reply = await sendJsonAndReceive(webSocket, {
    t: "tx.stop",
    radioId: "main",
    transmitToken,
    commandId: "ptt-stop-1",
  });
  assert.equal(reply.t, "tx.stopped");
  assert.equal(rig.ptt, false);
  webSocket.close();
});

function postJson(
  url: string,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<Response> {
  return fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

function nextJsonMessage(webSocket: WebSocket): Promise<any> {
  return new Promise((resolve, reject) => {
    webSocket.once("message", (data) => {
      try {
        resolve(JSON.parse(data.toString()));
      } catch (error) {
        reject(error);
      }
    });
    webSocket.once("error", reject);
  });
}

function sendJsonAndReceive(webSocket: WebSocket, value: unknown): Promise<any> {
  const response = nextJsonMessage(webSocket);
  webSocket.send(JSON.stringify(value));
  return response;
}

class ApiFakeRig implements RigControl {
  frequencyHz = 14_074_000;
  mode = "USB";
  passbandHz = 3_000;
  ptt = false;
  tuner = false;

  async readState() {
    return {
      frequencyHz: this.frequencyHz,
      mode: this.mode,
      passbandHz: this.passbandHz,
      ptt: this.ptt,
    };
  }
  async setFrequency(value: number) { this.frequencyHz = value; return value; }
  async setMode(value: string, passband = 0) {
    this.mode = value;
    this.passbandHz = passband || 2_400;
    return { mode: this.mode, passbandHz: this.passbandHz };
  }
  async setPtt(value: boolean) { this.ptt = value; return value; }
  async setInternalTuner(value: boolean) { this.tuner = value; return value; }
}
