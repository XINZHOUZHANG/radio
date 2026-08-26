import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import WebSocket, { type RawData } from "ws";

import { DeviceStore } from "../src/auth/device-store.ts";
import { SessionStore } from "../src/auth/session-store.ts";
import { UserStore } from "../src/auth/user-store.ts";
import { DummyDigitalWorker } from "../src/digital/dummy-worker.ts";
import {
  HardwarePreflightCleanupUncertainError,
  type HardwarePreflightResult,
} from "../src/config/hardware-preflight.ts";
import type { RadioProfile } from "../src/config/types.ts";
import { parseAdif } from "../src/log/adif.ts";
import { decodeMediaFrame, encodeMediaFrame, MediaKind } from "../src/media/frame.ts";
import type { MediaPolicy } from "../src/media/adaptive-policy.ts";
import type { MediaWorkerOutput } from "../src/media/media-hub.ts";
import { RigModeError } from "../src/rig/hamlib-rig.ts";
import {
  RadioRuntime,
  RadioRuntimeCleanupUncertainError,
  type RigControl,
} from "../src/rig/radio-runtime.ts";
import { RadioLiteService } from "../src/server/radio-lite-service.ts";

test("HTTP service completes setup, login, pairing and radio configuration", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-http-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  let userNumber = 0;
  let deviceNumber = 0;
  let tokenNumber = 0;
  const codes = [123456, 654321];
  const now = () => 10_000;
  const users = new UserStore(join(directory, "users.json"), {
    now,
    idFactory: () => `user-${++userNumber}`,
  });
  const devices = new DeviceStore(join(directory, "devices.json"), {
    now,
    idFactory: () => `device-${++deviceNumber}`,
    tokenFactory: () => `device_${String(++tokenNumber).padStart(40, "0")}`,
  });
  const sessions = new SessionStore({
    now,
    tokenFactory: () => "session_".padEnd(43, "s"),
    csrfKey: Buffer.alloc(32, 5),
  });
  const rig = new ApiFakeRig();
  let failRuntimeClose = false;
  const cleanupPreflightStarted = deferred<void>();
  const allowCleanupPreflightFailure = deferred<void>();
  const testedProfiles: RadioProfile[] = [];
  const hardwareTestResult: HardwarePreflightResult = {
    profileId: "dummy",
    testedAtMs: now(),
    readOnly: true,
    overallStatus: "passed",
    checks: [
      { id: "cat", status: "passed", message: "Dummy CAT readback is available", details: {} },
      { id: "capabilities", status: "passed", message: "Dummy capabilities are available", details: {} },
      { id: "audioInput", status: "passed", message: "Dummy input is available", details: {} },
      { id: "audioOutput", status: "passed", message: "Dummy output is available", details: {} },
    ],
  };
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
      const runtime = new RadioRuntime(profile, rig, async () => {
        if (failRuntimeClose) {
          throw new Error("test runtime cleanup remained uncertain");
        }
      }, now);
      await runtime.initialize();
      return runtime;
    },
    hardwarePreflight: {
      test: async (profile) => {
        testedProfiles.push(profile);
        if (profile.id === "cleanup-uncertain") {
          throw new HardwarePreflightCleanupUncertainError("test cleanup remained uncertain");
        }
        if (profile.id === "cleanup-inflight") {
          cleanupPreflightStarted.resolve();
          await allowCleanupPreflightFailure.promise;
          throw new HardwarePreflightCleanupUncertainError("in-flight cleanup remained uncertain");
        }
        return hardwareTestResult;
      },
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
    digitalWorkerFactory: () => new DummyDigitalWorker({ playbackDelayMs: 0 }),
  });
  const address = await service.listen();
  context.after(() => service.close().catch(() => undefined));
  const base = `http://127.0.0.1:${address.port}`;

  let response = await fetch(`${base}/healthz`);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, "ok");
  assert.equal(service.setupCode, "123456");

  const longPassword = "界".repeat(1_200);

  response = await postJson(`${base}/api/v1/setup/initialize`, {
    setupCode: "123456",
    username: "connor",
    password: longPassword,
  });
  assert.equal(response.status, 201);
  const initialized = await response.json();
  assert.equal(initialized.user.role, "admin");

  response = await postJson(`${base}/api/v1/session/login`, {
    username: "connor",
    password: longPassword,
  });
  assert.equal(response.status, 200);
  const login = await response.json();
  const cookie = response.headers.get("set-cookie")?.split(";", 1)[0];
  assert.equal(typeof cookie, "string");
  assert.match(login.csrfToken, /^[A-Za-z0-9_-]{43}$/u);

  response = await fetch(`${base}/api/v1/session`, { headers: { Cookie: cookie! } });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).user.username, "connor");

  const dummyProfile: RadioProfile = {
    id: "dummy",
    name: "Safe Dummy",
    hamlibModelId: 1,
    connection: { kind: "hamlib-dummy" },
    ptt: { method: "None" },
    audioInput: { backend: "pulse", id: "dummy-input" },
    audioOutput: { backend: "pulse", id: "dummy-output" },
    station: { callsign: "BI1ABC", grid: "OM89" },
    hardwareTxEnabled: false,
  };
  response = await postJson(`${base}/api/v1/hardware/test`, { profile: dummyProfile });
  assert.equal(response.status, 401);
  response = await postJson(
    `${base}/api/v1/hardware/test`,
    { profile: dummyProfile },
    { Cookie: cookie!, "X-CSRF-Token": login.csrfToken },
  );
  const hardwareTestBody = await response.json();
  assert.equal(response.status, 200, JSON.stringify(hardwareTestBody));
  assert.deepEqual(hardwareTestBody, hardwareTestResult);
  assert.deepEqual(testedProfiles, [dummyProfile]);
  response = await postJson(
    `${base}/api/v1/hardware/test`,
    { profile: { ...dummyProfile, connection: { kind: "network-rigctld", host: "127.0.0.1", port: 4_532 } } },
    { Cookie: cookie!, "X-CSRF-Token": login.csrfToken },
  );
  assert.equal(response.status, 400);
  assert.deepEqual(testedProfiles, [dummyProfile]);
  response = await fetch(`${base}/api/v1/radios`, { headers: { Cookie: cookie! } });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).radios, []);

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

  const operator = await users.create({
    username: "operator",
    password: "operator-password",
    role: "operator",
    canTransmit: false,
  });
  const operatorDevice = await devices.pair(operator.id, "Operator iPhone");
  response = await postJson(
    `${base}/api/v1/hardware/test`,
    { profile: dummyProfile },
    {
      Authorization: `Bearer ${operatorDevice.accessToken}`,
      "X-Radio-Lite-Device-Id": operatorDevice.deviceId,
    },
  );
  assert.equal(response.status, 403);
  assert.deepEqual(testedProfiles, [dummyProfile]);

  const uncertainCleanupProfile: RadioProfile = {
    ...dummyProfile,
    id: "cleanup-uncertain",
    name: "Cleanup quarantine test",
    hamlibModelId: 1049,
    connection: { kind: "managed-serial", devicePath: "/dev/ttyUSB99", baudRate: 38_400 },
    ptt: { method: "RIG" },
  };
  response = await postJson(
    `${base}/api/v1/hardware/test`,
    { profile: uncertainCleanupProfile },
    { Cookie: cookie!, "X-CSRF-Token": login.csrfToken },
  );
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "hardware_cleanup_uncertain");
  const callsAfterUncertainCleanup = testedProfiles.length;
  response = await postJson(
    `${base}/api/v1/hardware/test`,
    { profile: uncertainCleanupProfile },
    { Cookie: cookie!, "X-CSRF-Token": login.csrfToken },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error.code, "radio_device_busy");
  assert.equal(testedProfiles.length, callsAfterUncertainCleanup);

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
  const savedRadio = await response.json();
  assert.equal(savedRadio.radio.id, "main");
  assert.deepEqual(savedRadio.radio.ptt, { method: "RIG" });
  assert.equal(savedRadio.reconnectRequired, true);

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

  const preflightCallsBeforeBusyCheck = testedProfiles.length;
  response = await postJson(
    `${base}/api/v1/hardware/test`,
    { profile: savedRadio.radio },
    { Cookie: cookie!, "X-CSRF-Token": login.csrfToken },
  );
  const busyPreflight = await response.json();
  assert.equal(response.status, 409, JSON.stringify(busyPreflight));
  assert.equal(busyPreflight.error.code, "radio_device_busy");
  assert.equal(testedProfiles.length, preflightCallsBeforeBusyCheck);

  rig.rejectedMode = "DATA-U";
  reply = await sendJsonAndReceive(webSocket, {
    t: "rig.mode.set",
    radioId: "main",
    controlToken,
    mode: "DATA-U",
    passbandHz: 0,
    commandId: "mode-data-u-rejected",
  });
  assert.equal(reply.t, "command.error");
  assert.equal(reply.requestType, "rig.mode.set");
  assert.equal(reply.code, "rig_mode_rejected");
  assert.match(reply.message, /DATA-U.*PKTUSB/u);
  rig.rejectedMode = null;

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
    t: "rig.controls.get",
    radioId: "main",
    commandId: "controls-1",
  });
  assert.equal(reply.t, "rig.controls");
  assert.equal(reply.commandId, "controls-1");
  assert.deepEqual(reply.controls.map((control: { id: string }) => control.id), [
    "level:RFPOWER",
    "level:AF",
  ]);

  reply = await sendJsonAndReceive(webSocket, {
    t: "rig.controls.get",
    radioId: "main",
    commandId: "controls-extra-field",
    unexpected: true,
  });
  assert.equal(reply.t, "command.error");
  assert.equal(reply.requestType, "rig.controls.get");
  assert.equal(reply.code, "invalid_command");
  assert.match(reply.message, /unknown control field/u);

  reply = await sendJsonAndReceive(webSocket, {
    t: "rig.control.set",
    radioId: "main",
    controlToken,
    controlId: "level:RFPOWER",
    value: 0.3,
    commandId: "control-power-1",
  });
  assert.equal(reply.t, "rig.control.confirmed");
  assert.equal(reply.commandId, "control-power-1");
  assert.equal(reply.control.id, "level:RFPOWER");
  assert.equal(reply.control.value, 0.3);

  reply = await sendJsonAndReceive(webSocket, {
    t: "digital.snapshot.get",
    radioId: "main",
  });
  assert.equal(reply.t, "digital.snapshot", JSON.stringify(reply));
  assert.equal(reply.decodes.revision, 0);
  assert.equal(reply.queue.entries.length, 0);

  reply = await sendJsonUntil(webSocket, {
    t: "digital.queue.add.manual",
    radioId: "main",
    controlToken,
    targetCallsign: "JA1ABC",
    targetGrid: "PM95",
    mode: "FT8",
    audioFrequencyHz: 1_300,
    txParity: "odd",
    commandId: "digital-add-1",
  }, "digital.queue.added");
  assert.equal(reply.commandId, "digital-add-1");
  assert.equal(reply.entry.targetCallsign, "JA1ABC");
  assert.equal(reply.entry.status, "queued");

  reply = await sendJsonUntil(webSocket, {
    t: "digital.auto.stop",
    radioId: "main",
    controlToken,
    commandId: "digital-stop-1",
  }, "digital.auto.stopped");
  assert.equal(reply.commandId, "digital-stop-1");
  assert.equal(reply.stopped.targetCallsign, "JA1ABC");
  assert.equal(reply.queue.entries.length, 0);
  assert.equal(rig.ptt, false);

  reply = await sendJsonAndReceive(webSocket, {
    t: "tx.start",
    radioId: "main",
    controlToken,
    mode: "digital",
    commandId: "unsafe-digital-carrier",
  });
  assert.equal(reply.t, "command.error");
  assert.equal(reply.code, "invalid_command");
  assert.match(reply.message, /FT8\/FT4 queue/u);
  assert.equal(rig.ptt, false);

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
    requestId: "media-subscribe-1",
  });
  assert.equal(reply.t, "media.subscribed");
  assert.equal(reply.requestId, "media-subscribe-1");
  assert.equal(reply.requestType, "media.subscribe");
  assert.equal(reply.radioSlot, 0);
  assert.equal(reply.policy.opusBitrate, 20_000);

  reply = await sendJsonAndReceive(mediaSocket, {
    t: "media.network",
    rttMs: -1,
    packetLossPercent: 0,
    bufferedBytes: 0,
    spectrumVisible: true,
    requestId: "media-network-invalid",
  });
  assert.equal(reply.t, "media.error");
  assert.equal(reply.code, "invalid_media_control");
  assert.equal(reply.requestId, "media-network-invalid");
  assert.equal(reply.requestType, "media.network");

  reply = await sendJsonAndReceive(mediaSocket, {
    t: "media.network",
    rttMs: 2_500,
    packetLossPercent: 10,
    bufferedBytes: 600_000,
    spectrumVisible: false,
    requestId: "media-network-1",
  });
  assert.equal(reply.t, "media.policy");
  assert.equal(reply.requestId, "media-network-1");
  assert.equal(reply.requestType, "media.network");
  assert.equal(reply.policy.tier, "severe");
  assert.equal(reply.policy.spectrumBins, 0);
  assert.equal(mediaPolicies.at(-1)?.tier, "severe");

  reply = await sendJsonAndReceive(mediaSocket, {
    t: "media.unsubscribe",
    requestId: "media-unsubscribe-1",
  });
  assert.equal(reply.t, "media.unsubscribed");
  assert.equal(reply.requestId, "media-unsubscribe-1");
  assert.equal(reply.requestType, "media.unsubscribe");

  reply = await sendJsonAndReceive(mediaSocket, {
    t: "media.subscribe",
    radioId: "main",
    spectrumVisible: true,
    requestId: "media-subscribe-2",
  });
  assert.equal(reply.t, "media.subscribed");
  assert.equal(reply.requestId, "media-subscribe-2");
  assert.equal(reply.requestType, "media.subscribe");

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
    t: "rig.control.set",
    radioId: "main",
    controlToken,
    controlId: "level:RFPOWER",
    value: 0.6,
    commandId: "control-power-during-tx",
  });
  assert.equal(reply.t, "command.error");
  assert.equal(reply.requestType, "rig.control.set");
  assert.equal(reply.code, "rig_control_tx_locked");
  assert.equal(rig.controls.get("level:RFPOWER"), 0.3);

  reply = await sendJsonAndReceive(mediaSocket, {
    t: "media.uplink.bind",
    radioId: "main",
    transmitToken,
    requestId: "media-bind-1",
  });
  assert.equal(reply.t, "media.uplink.bound");
  assert.equal(reply.requestId, "media-bind-1");
  assert.equal(reply.requestType, "media.uplink.bind");

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
    requestId: "media-bind-2",
  });
  assert.equal(reply.t, "media.uplink.bound");
  assert.equal(reply.requestId, "media-bind-2");
  assert.equal(reply.requestType, "media.uplink.bind");

  mediaSocket.close();
  await new Promise<void>((resolve) => mediaSocket.once("close", () => resolve()));
  await waitFor(() => rig.ptt === false);
  webSocket.close();

  const inFlightCleanupProfile: RadioProfile = {
    ...uncertainCleanupProfile,
    id: "cleanup-inflight",
    name: "In-flight cleanup shutdown test",
    connection: { kind: "managed-serial", devicePath: "/dev/ttyUSB98", baudRate: 38_400 },
  };
  const inFlightPreflight = postJson(
    `${base}/api/v1/hardware/test`,
    { profile: inFlightCleanupProfile },
    { Cookie: cookie!, "X-CSRF-Token": login.csrfToken },
  );
  await cleanupPreflightStarted.promise;
  failRuntimeClose = true;
  const closing = service.close();
  let closeSettled = false;
  void closing.then(
    () => { closeSettled = true; },
    () => { closeSettled = true; },
  );
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(closeSettled, false, "shutdown must drain an active hardware preflight");

  allowCleanupPreflightFailure.resolve();
  response = await inFlightPreflight;
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "hardware_cleanup_uncertain");
  await assert.rejects(closing, RadioRuntimeCleanupUncertainError);
  await assert.rejects(fetch(`${base}/healthz`));
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
    const onMessage = (data: RawData) => {
      cleanup();
      try {
        resolve(JSON.parse(data.toString()));
      } catch (error) {
        reject(error);
      }
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      webSocket.off("message", onMessage);
      webSocket.off("error", onError);
    };
    webSocket.once("message", onMessage);
    webSocket.once("error", onError);
  });
}

function sendJsonAndReceive(webSocket: WebSocket, value: unknown): Promise<any> {
  const response = nextJsonMessage(webSocket);
  webSocket.send(JSON.stringify(value));
  return response;
}

function sendJsonUntil(webSocket: WebSocket, value: unknown, expectedType: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const onMessage = (data: RawData, isBinary: boolean) => {
      if (isBinary) {
        return;
      }
      try {
        const parsed = JSON.parse(data.toString());
        if (parsed.t === expectedType) {
          cleanup();
          resolve(parsed);
        }
      } catch (error) {
        cleanup();
        reject(error);
      }
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      webSocket.off("message", onMessage);
      webSocket.off("error", onError);
    };
    webSocket.on("message", onMessage);
    webSocket.on("error", onError);
    webSocket.send(JSON.stringify(value));
  });
}

function nextBinaryMessage(webSocket: WebSocket): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const onMessage = (data: RawData, isBinary: boolean) => {
      cleanup();
      if (!isBinary) {
        reject(new Error(`expected binary WebSocket message, received: ${data.toString()}`));
        return;
      }
      resolve(Buffer.isBuffer(data) ? data : Buffer.from(data as ArrayBuffer));
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      webSocket.off("message", onMessage);
      webSocket.off("error", onError);
    };
    webSocket.once("message", onMessage);
    webSocket.once("error", onError);
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

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
} {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

class ApiFakeRig implements RigControl {
  frequencyHz = 14_074_000;
  mode = "USB";
  passbandHz = 3_000;
  ptt = false;
  tuner = false;
  rejectedMode: string | null = null;
  controls = new Map<string, number>([
    ["level:RFPOWER", 0.5],
    ["level:AF", 0.4],
  ]);

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
    if (value === this.rejectedMode) {
      throw new RigModeError(value, "PKTUSB", "rejected", -1);
    }
    this.mode = value;
    this.passbandHz = passband || 2_400;
    return { mode: this.mode, passbandHz: this.passbandHz };
  }
  async setPtt(value: boolean) { this.ptt = value; return value; }
  async setInternalTuner(value: boolean) { this.tuner = value; return value; }
  async readControls() {
    return [...this.controls].map(([id, value]) => ({
      id,
      kind: "level" as const,
      token: id.split(":")[1]!,
      value,
      minimum: 0,
      maximum: 1,
      step: 0.01,
      unit: "ratio" as const,
      transmitLocked: id === "level:RFPOWER",
    }));
  }
  async setControl(id: string, value: number) {
    const control = (await this.readControls()).find((candidate) => candidate.id === id);
    if (control === undefined) throw new Error("control unavailable");
    this.controls.set(id, value);
    return { ...control, value };
  }
}
