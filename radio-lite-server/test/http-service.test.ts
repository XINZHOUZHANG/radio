import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import WebSocket from "ws";

import { DeviceStore } from "../src/auth/device-store.ts";
import { SessionStore } from "../src/auth/session-store.ts";
import { UserStore } from "../src/auth/user-store.ts";
import { parseAdif } from "../src/log/adif.ts";
import { decodeMediaFrame, encodeMediaFrame, MediaKind } from "../src/media/frame.ts";
import type { MediaPolicy } from "../src/media/adaptive-policy.ts";
import type { MediaWorkerOutput } from "../src/media/media-hub.ts";
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
  const microphonePackets: Buffer[] = [];
  const mediaPolicies: MediaPolicy[] = [];
  let mediaOutput: MediaWorkerOutput | undefined;
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
    mediaWorkerFactory: async (_profile, _radioSlot, output) => {
      mediaOutput = output;
      return {
        updatePolicy: (policy) => { mediaPolicies.push(policy); },
        writeAudioUplink: (frame) => {
          microphonePackets.push(Buffer.from(frame.payload));
          return true;
        },
        close: async () => undefined,
      };
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

  response = await postJson(
    `${base}/api/v1/logs`,
    {
      radioId: "main",
      call: "JA1ABC",
      startedAtMs: Date.UTC(2026, 7, 25, 12, 30, 0),
      endedAtMs: Date.UTC(2026, 7, 25, 12, 32, 0),
      frequencyHz: 14_250_000,
      mode: "SSB",
      rstSent: "59",
      rstReceived: "57",
      grid: "PM95",
      comment: "Manual iOS log",
    },
    { Cookie: cookie!, "X-CSRF-Token": login.csrfToken },
  );
  assert.equal(response.status, 201);
  const savedQso = await response.json();
  assert.equal(savedQso.record.source, "VOICE_MANUAL");
  assert.equal(savedQso.record.myCall, "BI1ABC");

  response = await fetch(`${base}/api/v1/logs?limit=10`, {
    headers: {
      Authorization: `Bearer ${credentials.accessToken}`,
      "X-Radio-Lite-Device-Id": credentials.deviceId,
    },
  });
  assert.equal(response.status, 200);
  const listedLog = await response.json();
  assert.equal(listedLog.total, 1);
  assert.equal(listedLog.records[0].call, "JA1ABC");

  response = await fetch(`${base}/api/v1/logs/grids?resolution=4`, {
    headers: { Cookie: cookie! },
  });
  assert.equal(response.status, 200);
  const grids = await response.json();
  assert.equal(grids.grids[0].grid, "PM95");
  assert.equal(grids.grids[0].qsoCount, 1);

  response = await fetch(`${base}/api/v1/logs/export`, { headers: { Cookie: cookie! } });
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^application\/adif/u);
  const exportedLog = Buffer.from(await response.arrayBuffer());
  assert.equal(parseAdif(exportedLog).records.length, 1);

  response = await fetch(`${base}/api/v1/logs/import`, {
    method: "POST",
    headers: {
      "Content-Type": "application/adif",
      Cookie: cookie!,
      "X-CSRF-Token": login.csrfToken,
    },
    body: exportedLog,
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { imported: 0, duplicates: 1 });

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
    commandId: "ptt-without-media",
  });
  assert.equal(reply.t, "command.error");
  assert.equal(reply.code, "media_required");
  assert.equal(rig.ptt, false);

  const mediaSocket = new WebSocket(
    `ws://127.0.0.1:${address.port}/ws/media`,
    "radio-lite.v1",
  );
  context.after(() => mediaSocket.terminate());
  await new Promise<void>((resolve, reject) => {
    mediaSocket.once("open", resolve);
    mediaSocket.once("error", reject);
  });
  mediaSocket.send(JSON.stringify({
    t: "auth.device",
    deviceId: credentials.deviceId,
    accessToken: credentials.accessToken,
  }));
  const mediaAuthenticated = await nextJsonMessage(mediaSocket);
  assert.equal(mediaAuthenticated.t, "auth.ok");
  assert.equal(mediaAuthenticated.channel, "media");

  reply = await sendJsonAndReceive(mediaSocket, {
    t: "media.subscribe",
    radioId: "main",
    spectrumVisible: true,
  });
  assert.equal(reply.t, "media.subscribed");
  assert.equal(reply.radioSlot, 0);
  assert.equal(reply.policy.opusBitrate, 20_000);

  reply = await sendJsonAndReceive(mediaSocket, {
    t: "media.network",
    rttMs: 2_500,
    packetLossPercent: 10,
    bufferedBytes: 600_000,
    spectrumVisible: false,
  });
  assert.equal(reply.t, "media.policy");
  assert.equal(reply.policy.tier, "severe");
  assert.equal(reply.policy.spectrumBins, 0);
  assert.equal(mediaPolicies.at(-1)?.tier, "severe");

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

  reply = await sendJsonAndReceive(mediaSocket, {
    t: "media.uplink.bind",
    radioId: "main",
    transmitToken,
  });
  assert.equal(reply.t, "media.uplink.bound");

  mediaSocket.send(encodeMediaFrame({
    kind: MediaKind.audioUplink,
    flags: 0,
    radioSlot: 0,
    sequence: 1,
    timestampUs: 10_000_000n,
    payload: Buffer.from([0xf8, 0xff, 0xfe]),
  }));
  await waitFor(() => microphonePackets.length === 1);
  assert.deepEqual(microphonePackets[0], Buffer.from([0xf8, 0xff, 0xfe]));

  const downlinkReply = nextBinaryMessage(mediaSocket);
  mediaOutput?.audioDownlink(Buffer.from([1, 2, 3]), 10_001_000n);
  const downlink = decodeMediaFrame(await downlinkReply);
  assert.equal(downlink.kind, MediaKind.audioDownlink);
  assert.deepEqual(downlink.payload, Buffer.from([1, 2, 3]));

  reply = await sendJsonAndReceive(webSocket, {
    t: "tx.heartbeat",
    radioId: "main",
    controlToken,
    transmitToken,
  });
  assert.equal(reply.t, "tx.alive");

  const uplinkEnded = nextJsonMessage(mediaSocket);
  reply = await sendJsonAndReceive(webSocket, {
    t: "tx.stop",
    radioId: "main",
    transmitToken,
    commandId: "ptt-stop-1",
  });
  assert.equal(reply.t, "tx.stopped");
  assert.equal(rig.ptt, false);
  assert.equal((await uplinkEnded).t, "media.uplink.ended");

  reply = await sendJsonAndReceive(webSocket, {
    t: "tx.start",
    radioId: "main",
    controlToken,
    mode: "voice",
    commandId: "ptt-start-2",
  });
  assert.equal(reply.t, "tx.started");
  assert.equal(rig.ptt, true);
  const secondTransmitToken = reply.transmitToken;

  reply = await sendJsonAndReceive(mediaSocket, {
    t: "media.uplink.bind",
    radioId: "main",
    transmitToken: secondTransmitToken,
  });
  assert.equal(reply.t, "media.uplink.bound");

  mediaSocket.close();
  await new Promise<void>((resolve) => mediaSocket.once("close", () => resolve()));
  await waitFor(() => rig.ptt === false);
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

function nextBinaryMessage(webSocket: WebSocket): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    webSocket.once("message", (data, isBinary) => {
      if (!isBinary) {
        reject(new Error(`expected binary WebSocket message, received: ${data.toString()}`));
        return;
      }
      resolve(Buffer.isBuffer(data) ? data : Buffer.from(data as ArrayBuffer));
    });
    webSocket.once("error", reject);
  });
}

async function waitFor(predicate: () => boolean, timeoutMs = 1_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) {
      throw new Error("condition was not satisfied before timeout");
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 5));
  }
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
