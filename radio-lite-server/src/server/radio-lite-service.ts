import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { WebSocket, WebSocketServer, type RawData } from "ws";

import { AuditLog } from "../auth/audit-log.ts";
import { DeviceStore, InvalidDeviceCredentialError, RefreshTokenReuseError } from "../auth/device-store.ts";
import { PairingService } from "../auth/pairing-service.ts";
import { parseCookieHeader, SessionStore } from "../auth/session-store.ts";
import {
  CodeRateLimitError,
  InvalidOrExpiredCodeError,
  SixDigitCodeVault,
  type SixDigitCodeVaultOptions,
} from "../auth/six-digit-codes.ts";
import { type PublicUser, UserStore } from "../auth/user-store.ts";
import { RadioConfigStore } from "../config/radio-config-store.ts";
import { HardwareDiscovery } from "../config/hardware-discovery.ts";
import { ControlBusyError, InvalidControlLeaseError } from "../control/control-lease.ts";
import {
  HardwareTransmitDisabledError,
  RadioRuntimeRegistry,
  TransmitPermissionError,
  type RadioRuntimeFactory,
} from "../rig/radio-runtime.ts";
import { RigReportError, RigTransportError } from "../rig/transport.ts";
import { InvalidLeaseError, InterlockConflictError } from "../safety/transmit-interlock.ts";
import { decodeMediaFrame, MediaFrameError, MediaKind } from "../media/frame.ts";
import {
  MediaHub,
  type MediaWorkerFactory,
} from "../media/media-hub.ts";
import { SyntheticMediaWorker } from "../media/synthetic-media-worker.ts";
import { SystemMediaWorker } from "../media/system-media-worker.ts";
import { AdifLogStore } from "../log/adif-log-store.ts";
import { DigitalRadioHub, DigitalWorkerUnavailableError } from "../digital/hub.ts";
import { DummyDigitalWorker } from "../digital/dummy-worker.ts";
import { SystemDigitalWorker } from "../digital/system-digital-worker.ts";
import { isDigitalMode } from "../digital/types.ts";
import type { DigitalWorkerFactory } from "../digital/worker.ts";

export type RadioLiteServiceOptions = {
  dataDirectory: string;
  radioConfigPath?: string;
  now?: () => number;
  codeOptions?: SixDigitCodeVaultOptions;
  sessionStore?: SessionStore;
  userStore?: UserStore;
  deviceStore?: DeviceStore;
  secureCookies?: boolean;
  runtimeFactory?: RadioRuntimeFactory;
  hardwareDiscovery?: HardwareDiscovery;
  mediaWorkerFactory?: MediaWorkerFactory;
  digitalWorkerFactory?: DigitalWorkerFactory;
  logStore?: AdifLogStore;
  logPath?: string;
};

type SessionPrincipal = {
  token: string;
  user: PublicUser;
};

type HttpPrincipal = {
  sessionToken: string | null;
  deviceId: string | null;
  user: PublicUser;
};

export class RadioLiteService {
  readonly #now: () => number;
  readonly #users: UserStore;
  readonly #devices: DeviceStore;
  readonly #radios: RadioConfigStore;
  readonly #sessions: SessionStore;
  readonly #codes: SixDigitCodeVault;
  readonly #pairing: PairingService;
  readonly #audit: AuditLog;
  readonly #runtimes: RadioRuntimeRegistry;
  readonly #media: MediaHub;
  readonly #log: AdifLogStore;
  readonly #digital: DigitalRadioHub;
  readonly #hardwareDiscovery: HardwareDiscovery;
  readonly #secureCookies: boolean;
  #server: Server | null = null;
  #webSocketServer: WebSocketServer | null = null;
  readonly #webSockets = new Set<WebSocket>();
  readonly #controlWebSockets = new Set<WebSocket>();
  #initialized = false;
  #setupCode: string | null = null;

  constructor(options: RadioLiteServiceOptions) {
    if (!options.dataDirectory) {
      throw new Error("data directory is required");
    }
    this.#now = options.now ?? Date.now;
    this.#users = options.userStore ?? new UserStore(join(options.dataDirectory, "users.json"), { now: this.#now });
    this.#devices = options.deviceStore ?? new DeviceStore(join(options.dataDirectory, "devices.json"), { now: this.#now });
    this.#radios = new RadioConfigStore(
      options.radioConfigPath ?? join(options.dataDirectory, "radios.json"),
    );
    this.#sessions = options.sessionStore ?? new SessionStore({ now: this.#now });
    this.#codes = new SixDigitCodeVault({ ...options.codeOptions, now: this.#now });
    this.#pairing = new PairingService(this.#codes, this.#devices);
    this.#audit = new AuditLog(join(options.dataDirectory, "audit.jsonl"));
    this.#runtimes = options.runtimeFactory === undefined
      ? new RadioRuntimeRegistry(() => this.#radios.snapshot())
      : new RadioRuntimeRegistry(() => this.#radios.snapshot(), options.runtimeFactory);
    this.#media = new MediaHub({
      radios: () => this.#radios.snapshot(),
      workerFactory: options.mediaWorkerFactory ?? (async (profile, _radioSlot, output) => {
        if (profile.connection.kind === "hamlib-dummy") {
          return new SyntheticMediaWorker(output);
        }
        return SystemMediaWorker.create(profile, output, {
          readCenterFrequencyHz: async () => (await this.#runtimes.get(profile.id)).readState()
            .then((state) => state.frequencyHz),
        });
      }),
      now: this.#now,
      stopVoiceTransmit: async ({ radioId, ownerId, transmitToken, reason }) => {
        let stopped = false;
        try {
          const runtime = await this.#runtimes.get(radioId);
          await runtime.stopTransmit(ownerId, transmitToken);
          stopped = true;
        } catch (error) {
          if (!(error instanceof InvalidLeaseError)) {
            await this.#audit.append({
              occurredAtMs: this.#now(), action: "radio.ptt-stop", result: "failure",
              targetId: radioId, metadata: { reason },
            }).catch(() => undefined);
            return;
          }
        }
        if (stopped) {
          await this.#audit.append({
            occurredAtMs: this.#now(), action: "radio.ptt-stop", result: "success",
            targetId: radioId, metadata: { reason },
          }).catch(() => undefined);
        }
      },
    });
    this.#log = options.logStore ?? new AdifLogStore(
      options.logPath ?? join(options.dataDirectory, "station-log.adif"),
      { now: this.#now },
    );
    this.#digital = new DigitalRadioHub({
      radios: () => this.#radios.snapshot(),
      runtimes: this.#runtimes,
      logStore: this.#log,
      workerFactory: options.digitalWorkerFactory ?? ((profile) => {
        if (profile.connection.kind === "hamlib-dummy") {
          return new DummyDigitalWorker();
        }
        return new SystemDigitalWorker(profile, {
          openAudio: (consumer) => this.#media.openDigitalAudio(profile.id, consumer),
          now: this.#now,
        });
      }),
      now: this.#now,
      onEvent: (event) => this.#broadcastControl(event),
    });
    this.#hardwareDiscovery = options.hardwareDiscovery ?? new HardwareDiscovery();
    this.#secureCookies = options.secureCookies === true;
  }

  get setupCode(): string | null {
    return this.#setupCode;
  }

  async initialize(): Promise<void> {
    if (this.#initialized) {
      return;
    }
    await Promise.all([
      this.#users.load(),
      this.#devices.load(),
      this.#radios.load(),
      this.#log.load(),
    ]);
    if (this.#users.list().length === 0) {
      this.#setupCode = this.#codes.issue("first-admin", "initial_setup", 10 * 60_000).code;
    }
    this.#initialized = true;
  }

  async listen(port = 0, host = "127.0.0.1", allowInsecurePrivateNetwork = false): Promise<{ host: string; port: number }> {
    await this.initialize();
    if (this.#server !== null) {
      throw new Error("service is already listening");
    }
    if (!isLoopback(host) && !allowInsecurePrivateNetwork) {
      throw new Error("plaintext non-loopback listening requires explicit allowInsecurePrivateNetwork");
    }
    const server = createServer((request, response) => {
      void this.#handle(request, response);
    });
    const webSocketServer = new WebSocketServer({
      noServer: true,
      maxPayload: 65_536,
      perMessageDeflate: false,
      handleProtocols: (protocols) => protocols.has("radio-lite.v1") ? "radio-lite.v1" : false,
    });
    server.on("upgrade", (request, socket, head) => {
      const pathname = new URL(request.url ?? "/", "http://radio-lite.invalid").pathname;
      const offered = String(request.headers["sec-websocket-protocol"] ?? "")
        .split(",")
        .map((value) => value.trim());
      if (
        (pathname !== "/ws/control" && pathname !== "/ws/media") ||
        !offered.includes("radio-lite.v1")
      ) {
        socket.write("HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nSec-WebSocket-Protocol: radio-lite.v1\r\n\r\n");
        socket.destroy();
        return;
      }
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        this.#acceptWebSocket(
          webSocket,
          request,
          pathname === "/ws/media" ? "media" : "control",
        );
      });
    });
    server.requestTimeout = 310_000;
    server.headersTimeout = 300_000;
    server.keepAliveTimeout = 30_000;
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, host, () => {
        server.off("error", reject);
        resolve();
      });
    });
    this.#server = server;
    this.#webSocketServer = webSocketServer;
    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new Error("listener did not return a TCP address");
    }
    return { host, port: address.port };
  }

  async close(): Promise<void> {
    const server = this.#server;
    this.#server = null;
    const webSocketServer = this.#webSocketServer;
    this.#webSocketServer = null;
    for (const webSocket of this.#webSockets) {
      webSocket.terminate();
    }
    this.#webSockets.clear();
    this.#controlWebSockets.clear();
    await this.#digital.close();
    await this.#media.close();
    await this.#runtimes.close();
    if (webSocketServer !== null) {
      await new Promise<void>((resolve) => webSocketServer.close(() => resolve()));
    }
    if (server === null) {
      return;
    }
    await new Promise<void>((resolve, reject) => {
      server.close((error) => error === undefined ? resolve() : reject(error));
    });
  }

  #acceptWebSocket(
    webSocket: WebSocket,
    request: IncomingMessage,
    channel: "control" | "media",
  ): void {
    this.#webSockets.add(webSocket);
    const connectionOwnerId = `connection:${randomUUID()}`;
    let authenticated = false;
    let authenticatedUser: PublicUser | null = null;
    let authenticatedPrincipalId: string | null = null;
    let expiryTimer: ReturnType<typeof setTimeout> | null = null;
    let commandTail: Promise<void> = Promise.resolve();
    let mediaTail: Promise<void> = Promise.resolve();
    const authTimer = setTimeout(() => {
      webSocket.close(4401, "authentication timeout");
    }, 300_000);
    authTimer.unref();

    const finishAuthentication = (
      user: PublicUser,
      deviceId: string | null,
      expiresAtMs: number | null,
      principalId: string,
    ): void => {
      authenticated = true;
      authenticatedUser = user;
      authenticatedPrincipalId = principalId;
      clearTimeout(authTimer);
      if (expiresAtMs !== null) {
        const remaining = Math.max(1, expiresAtMs - this.#now());
        expiryTimer = setTimeout(() => {
          webSocket.close(4401, "access credential expired");
        }, remaining);
        expiryTimer.unref();
      }
      sendWebSocketJson(webSocket, {
        t: "auth.ok",
        protocolVersion: 1,
        channel,
        principal: {
          userId: user.id,
          deviceId,
          role: user.role,
          canTransmit: user.canTransmit,
        },
        radios: this.#radios.snapshot().radios,
      });
      if (channel === "control") {
        this.#controlWebSockets.add(webSocket);
      }
      if (channel === "media") {
        this.#media.connect({
          id: connectionOwnerId,
          principalId,
          userId: user.id,
          transport: {
            get bufferedAmount() { return webSocket.bufferedAmount; },
            sendBinary: (value) => {
              if (webSocket.readyState === WebSocket.OPEN) {
                webSocket.send(value, { binary: true });
              }
            },
            sendJson: (value) => sendWebSocketJson(webSocket, value),
          },
        });
      }
    };

    const browser = this.#optionalSession(request);
    if (browser !== null) {
      finishAuthentication(browser.user, null, null, `session:${browser.token}`);
    }

    webSocket.on("message", (data, isBinary) => {
      if (!authenticated) {
        if (isBinary) {
          webSocket.close(4400, "authentication message must be JSON text");
          return;
        }
        let message: unknown;
        try {
          message = JSON.parse(webSocketBytes(data).toString("utf8"));
        } catch {
          webSocket.close(4400, "invalid authentication JSON");
          return;
        }
        if (!isExactDeviceAuth(message)) {
          webSocket.close(4401, "device authentication required");
          return;
        }
        const device = this.#devices.verifyAccess(message.deviceId, message.accessToken);
        const user = device === null
          ? undefined
          : this.#users.list().find(
            (candidate) => candidate.id === device.userId && candidate.enabled,
          );
        if (device === null || user === undefined) {
          webSocket.close(4401, "invalid device access credential");
          return;
        }
        finishAuthentication(user, device.id, device.accessExpiresAtMs, `device:${device.id}`);
        return;
      }

      if (channel === "media") {
        if (isBinary) {
          try {
            const frame = decodeMediaFrame(webSocketBytes(data));
            if (frame.kind !== MediaKind.audioUplink) {
              throw new MediaFrameError("client may send only audio uplink frames");
            }
            this.#media.receiveUplink(connectionOwnerId, frame);
          } catch (error) {
            const message = error instanceof Error ? error.message : "invalid media frame";
            sendWebSocketJson(webSocket, {
              t: "media.error",
              code: /bind an audio uplink/u.test(message)
                ? "uplink_not_bound"
                : /expired/u.test(message)
                  ? "uplink_expired"
                  : "invalid_media_frame",
              message,
            });
          }
          return;
        }
        let message: unknown;
        try {
          message = JSON.parse(webSocketBytes(data).toString("utf8"));
        } catch {
          webSocket.close(4400, "invalid media control message");
          return;
        }
        mediaTail = mediaTail.then(
          () => this.#handleMediaMessage(webSocket, connectionOwnerId, message),
          () => this.#handleMediaMessage(webSocket, connectionOwnerId, message),
        );
        return;
      }

      if (isBinary) {
        webSocket.close(4400, "control messages must be JSON text");
        return;
      }
      let message: unknown;
      try {
        message = JSON.parse(webSocketBytes(data).toString("utf8"));
      } catch {
        webSocket.close(4400, "invalid control JSON");
        return;
      }
      const user = authenticatedUser;
      const principalId = authenticatedPrincipalId;
      if (user === null || principalId === null) {
        webSocket.close(4401, "authentication state unavailable");
        return;
      }
      commandTail = commandTail.then(
        () => this.#handleControlMessage(webSocket, message, user, connectionOwnerId, principalId),
        () => this.#handleControlMessage(webSocket, message, user, connectionOwnerId, principalId),
      );
    });

    webSocket.once("close", () => {
      clearTimeout(authTimer);
      if (expiryTimer !== null) {
        clearTimeout(expiryTimer);
      }
      this.#webSockets.delete(webSocket);
      this.#controlWebSockets.delete(webSocket);
      if (channel === "media") {
        void this.#media.disconnect(connectionOwnerId).catch(() => undefined);
      } else {
        this.#media.revokeOwner(connectionOwnerId);
        void (async () => {
          await this.#digital.ownerDisconnected(connectionOwnerId).catch(() => undefined);
          await this.#runtimes.ownerDisconnected(connectionOwnerId).catch(() => undefined);
        })();
      }
    });
    webSocket.once("error", () => {
      // The close handler owns cleanup. Errors are intentionally not echoed.
    });
  }

  async #handleMediaMessage(
    webSocket: WebSocket,
    clientId: string,
    value: unknown,
  ): Promise<void> {
    try {
      const message = controlMessage(value);
      if (message.t === "ping") {
        exactMessageKeys(message, ["t"]);
        sendWebSocketJson(webSocket, { t: "pong", atMs: this.#now() });
        return;
      }
      if (message.t === "media.subscribe") {
        exactMessageKeys(message, ["t", "radioId", "spectrumVisible"]);
        if (typeof message.spectrumVisible !== "boolean") {
          throw new Error("spectrumVisible must be boolean");
        }
        const subscribed = await this.#media.subscribe(
          clientId,
          messageText(message.radioId, "radioId", 32),
          message.spectrumVisible,
        );
        sendWebSocketJson(webSocket, { t: "media.subscribed", ...subscribed });
        return;
      }
      if (message.t === "media.network") {
        exactMessageKeys(message, [
          "t", "rttMs", "packetLossPercent", "bufferedBytes", "spectrumVisible",
        ]);
        if (typeof message.spectrumVisible !== "boolean") {
          throw new Error("spectrumVisible must be boolean");
        }
        const policy = this.#media.updateNetwork(clientId, {
          rttMs: nonNegativeNumber(message.rttMs, "rttMs"),
          packetLossPercent: nonNegativeNumber(message.packetLossPercent, "packetLossPercent"),
          bufferedBytes: nonNegativeNumber(message.bufferedBytes, "bufferedBytes"),
          spectrumVisible: message.spectrumVisible,
        });
        sendWebSocketJson(webSocket, { t: "media.policy", policy });
        return;
      }
      if (message.t === "media.uplink.bind") {
        exactMessageKeys(message, ["t", "radioId", "transmitToken"]);
        const bound = await this.#media.bindUplink(
          clientId,
          messageText(message.radioId, "radioId", 32),
          messageText(message.transmitToken, "transmitToken", 128),
        );
        sendWebSocketJson(webSocket, { t: "media.uplink.bound", ...bound });
        return;
      }
      if (message.t === "media.unsubscribe") {
        exactMessageKeys(message, ["t"]);
        const radioId = await this.#media.unsubscribe(clientId);
        sendWebSocketJson(webSocket, { t: "media.unsubscribed", radioId });
        return;
      }
      throw new Error("unsupported media message");
    } catch (error) {
      sendWebSocketJson(webSocket, {
        t: "media.error",
        code: "invalid_media_control",
        message: error instanceof Error ? error.message : "invalid media control",
      });
    }
  }

  async #handleControlMessage(
    webSocket: WebSocket,
    value: unknown,
    user: PublicUser,
    ownerId: string,
    principalId: string,
  ): Promise<void> {
    let requestType = "unknown";
    let commandId: string | undefined;
    try {
      const message = controlMessage(value);
      requestType = message.t;
      commandId = optionalMessageText(message.commandId, "commandId", 128);
      if (message.t === "ping") {
        exactMessageKeys(message, ["t"]);
        sendWebSocketJson(webSocket, { t: "pong", atMs: this.#now() });
        return;
      }
      if (message.t === "snapshot.get") {
        exactMessageKeys(message, ["t"]);
        sendWebSocketJson(webSocket, {
          t: "radios.snapshot",
          revision: 1,
          radios: this.#radios.snapshot().radios,
        });
        return;
      }

      const radioId = messageText(message.radioId, "radioId", 32);
      const runtime = await this.#runtimes.get(radioId);
      if (message.t === "control.acquire") {
        exactMessageKeys(message, ["t", "radioId", "force"], ["force"]);
        if (message.force !== undefined && typeof message.force !== "boolean") {
          throw new Error("force must be boolean");
        }
        const result = await runtime.acquireControl(ownerId, user, message.force === true);
        if (result.displacedOwnerId !== null) {
          this.#media.revokeOwner(result.displacedOwnerId);
          await this.#digital.ownerDisconnected(result.displacedOwnerId);
        }
        sendWebSocketJson(webSocket, {
          t: "control.acquired",
          radioId,
          controlToken: result.lease.token,
          expiresAtMs: result.lease.expiresAtMs,
          displaced: result.displacedOwnerId !== null,
        });
        return;
      }
      if (message.t === "control.heartbeat") {
        exactMessageKeys(message, ["t", "radioId", "controlToken"]);
        const lease = runtime.heartbeatControl(
          ownerId,
          messageText(message.controlToken, "controlToken", 128),
        );
        sendWebSocketJson(webSocket, {
          t: "control.alive",
          radioId,
          expiresAtMs: lease.expiresAtMs,
        });
        return;
      }
      if (message.t === "control.release") {
        exactMessageKeys(message, ["t", "radioId", "controlToken"]);
        await this.#digital.ownerDisconnected(ownerId);
        await runtime.releaseControl(
          ownerId,
          messageText(message.controlToken, "controlToken", 128),
        );
        this.#media.revokeOwner(ownerId);
        sendWebSocketJson(webSocket, { t: "control.released", radioId });
        return;
      }
      if (message.t === "rig.state.get") {
        exactMessageKeys(message, ["t", "radioId", "commandId"], ["commandId"]);
        const state = await runtime.readState();
        sendWebSocketJson(webSocket, { t: "rig.state", radioId, commandId, state });
        return;
      }

      const controlToken = () => messageText(message.controlToken, "controlToken", 128);
      if (message.t === "rig.frequency.set") {
        exactMessageKeys(message, ["t", "radioId", "controlToken", "frequencyHz", "commandId"]);
        const frequencyHz = safeInteger(message.frequencyHz, "frequencyHz");
        const confirmed = await runtime.setFrequency(ownerId, controlToken(), frequencyHz);
        sendWebSocketJson(webSocket, {
          t: "rig.frequency.confirmed", radioId, commandId, frequencyHz: confirmed,
        });
        return;
      }
      if (message.t === "rig.mode.set") {
        exactMessageKeys(
          message,
          ["t", "radioId", "controlToken", "mode", "passbandHz", "commandId"],
          ["passbandHz"],
        );
        const result = await runtime.setMode(
          ownerId,
          controlToken(),
          messageText(message.mode, "mode", 16),
          message.passbandHz === undefined ? 0 : safeInteger(message.passbandHz, "passbandHz"),
        );
        sendWebSocketJson(webSocket, { t: "rig.mode.confirmed", radioId, commandId, ...result });
        return;
      }
      if (message.t === "digital.snapshot.get") {
        exactMessageKeys(message, ["t", "radioId"]);
        const digital = await this.#digital.get(radioId);
        sendWebSocketJson(webSocket, {
          t: "digital.snapshot",
          radioId,
          decodes: digital.decodeSnapshot(),
          queue: digital.queueSnapshot(),
          qso: digital.qsoSnapshot(),
        });
        return;
      }
      const digitalContext = () => ({
        ownerId,
        user,
        controlToken: controlToken(),
      });
      if (message.t === "digital.queue.add.decode") {
        exactMessageKeys(
          message,
          ["t", "radioId", "controlToken", "decodeId", "commandId"],
        );
        const digital = await this.#digital.get(radioId);
        const added = await digital.enqueueDecode(
          digitalContext(),
          messageText(message.decodeId, "decodeId", 128),
        );
        sendWebSocketJson(webSocket, {
          t: "digital.queue.added", radioId, commandId, ...added,
        });
        return;
      }
      if (message.t === "digital.queue.add.manual") {
        exactMessageKeys(
          message,
          [
            "t", "radioId", "controlToken", "targetCallsign", "targetGrid", "mode",
            "audioFrequencyHz", "txParity", "commandId",
          ],
          ["targetGrid"],
        );
        if (!isDigitalMode(message.mode)) {
          throw new Error("digital mode must be FT8 or FT4");
        }
        if (message.txParity !== "even" && message.txParity !== "odd") {
          throw new Error("txParity must be even or odd");
        }
        const digital = await this.#digital.get(radioId);
        const added = await digital.enqueueManual(digitalContext(), {
          targetCallsign: messageText(message.targetCallsign, "targetCallsign", 32),
          targetGrid: optionalMessageText(message.targetGrid, "targetGrid", 6),
          mode: message.mode,
          audioFrequencyHz: safeInteger(message.audioFrequencyHz, "audioFrequencyHz"),
          txParity: message.txParity,
        });
        sendWebSocketJson(webSocket, {
          t: "digital.queue.added", radioId, commandId, ...added,
        });
        return;
      }
      if (message.t === "digital.queue.skip") {
        exactMessageKeys(message, ["t", "radioId", "controlToken", "commandId"]);
        const digital = await this.#digital.get(radioId);
        const active = await digital.skip(digitalContext());
        sendWebSocketJson(webSocket, {
          t: "digital.queue.skipped",
          radioId,
          commandId,
          active,
          queue: digital.queueSnapshot(),
          qso: digital.qsoSnapshot(),
        });
        return;
      }
      if (message.t === "digital.queue.remove") {
        exactMessageKeys(
          message,
          ["t", "radioId", "controlToken", "entryId", "commandId"],
        );
        const digital = await this.#digital.get(radioId);
        const removed = await digital.remove(
          digitalContext(),
          messageText(message.entryId, "entryId", 128),
        );
        sendWebSocketJson(webSocket, {
          t: "digital.queue.removed",
          radioId,
          commandId,
          removed,
          queue: digital.queueSnapshot(),
          qso: digital.qsoSnapshot(),
        });
        return;
      }
      if (message.t === "digital.auto.stop") {
        exactMessageKeys(
          message,
          ["t", "radioId", "controlToken", "requeue", "commandId"],
          ["requeue"],
        );
        if (message.requeue !== undefined && typeof message.requeue !== "boolean") {
          throw new Error("requeue must be boolean");
        }
        const digital = await this.#digital.get(radioId);
        const stopped = await digital.stop(digitalContext(), message.requeue === true);
        sendWebSocketJson(webSocket, {
          t: "digital.auto.stopped",
          radioId,
          commandId,
          stopped,
          queue: digital.queueSnapshot(),
        });
        return;
      }
      if (message.t === "tx.start") {
        exactMessageKeys(message, ["t", "radioId", "controlToken", "mode", "commandId"]);
        if (message.mode !== "voice" && message.mode !== "digital" && message.mode !== "tuning") {
          throw new Error("transmit mode must be voice, digital or tuning");
        }
        if (message.mode === "digital") {
          throw new Error("digital transmission must be scheduled through the FT8/FT4 queue");
        }
        if (
          message.mode === "voice" &&
          !this.#media.hasReadySubscription(principalId, user.id, radioId)
        ) {
          throw new MediaSubscriptionRequiredError(
            "voice PTT requires a ready media subscription from the same device",
          );
        }
        const lease = await runtime.startTransmit(ownerId, user, controlToken(), message.mode);
        this.#media.registerTransmit({
          radioId,
          ownerId,
          principalId,
          userId: user.id,
          transmitToken: lease.leaseToken,
          mode: message.mode,
          heartbeatDeadlineMs: lease.heartbeatDeadlineMs,
          hardDeadlineMs: lease.hardDeadlineMs,
        });
        await this.#audit.append({
          occurredAtMs: this.#now(), action: "radio.ptt-start", result: "success",
          actorUserId: user.id, targetId: radioId, metadata: { mode: message.mode },
        });
        sendWebSocketJson(webSocket, {
          t: "tx.started", radioId, commandId, transmitToken: lease.leaseToken,
          heartbeatDeadlineMs: lease.heartbeatDeadlineMs,
          hardDeadlineMs: lease.hardDeadlineMs,
        });
        return;
      }
      if (message.t === "tx.heartbeat") {
        exactMessageKeys(
          message,
          ["t", "radioId", "controlToken", "transmitToken"],
        );
        const transmitToken = messageText(message.transmitToken, "transmitToken", 128);
        const lease = await runtime.heartbeatTransmit(
          ownerId,
          controlToken(),
          transmitToken,
        );
        this.#media.refreshTransmit(
          transmitToken,
          lease.heartbeatDeadlineMs,
          lease.hardDeadlineMs,
        );
        sendWebSocketJson(webSocket, {
          t: "tx.alive", radioId, heartbeatDeadlineMs: lease.heartbeatDeadlineMs,
        });
        return;
      }
      if (message.t === "tx.stop") {
        exactMessageKeys(message, ["t", "radioId", "transmitToken", "commandId"]);
        const transmitToken = messageText(message.transmitToken, "transmitToken", 128);
        await runtime.stopTransmit(ownerId, transmitToken);
        this.#media.endTransmit(transmitToken);
        await this.#audit.append({
          occurredAtMs: this.#now(), action: "radio.ptt-stop", result: "success",
          actorUserId: user.id, targetId: radioId,
        });
        sendWebSocketJson(webSocket, { t: "tx.stopped", radioId, commandId });
        return;
      }
      throw new Error("unsupported control message");
    } catch (error) {
      const mapped = mapControlError(error);
      sendWebSocketJson(webSocket, {
        t: "command.error",
        requestType,
        commandId,
        code: mapped.code,
        message: mapped.message,
      });
    }
  }

  #broadcastControl(value: unknown): void {
    for (const webSocket of this.#controlWebSockets) {
      if (webSocket.readyState === WebSocket.OPEN && webSocket.bufferedAmount <= 256 * 1_024) {
        sendWebSocketJson(webSocket, value);
      }
    }
  }

  async #handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    try {
      const method = request.method ?? "GET";
      const url = new URL(request.url ?? "/", "http://radio-lite.invalid");
      validateOrigin(request);
      if (method === "GET" && url.pathname === "/healthz") {
        sendJson(response, 200, { status: "ok", service: "radio-lite", protocolVersion: 1 });
        return;
      }
      if (method === "GET" && url.pathname === "/api/v1/setup/status") {
        sendJson(response, 200, { initializationRequired: this.#users.list().length === 0 });
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/setup/initialize") {
        const body = await jsonObject(request, ["setupCode", "username", "password"]);
        if (this.#users.list().length !== 0) {
          throw new HttpError(409, "already_initialized", "server is already initialized");
        }
        this.#codes.redeem(text(body.setupCode, "setupCode"), "initial_setup", sourceAddress(request));
        const user = await this.#users.initializeAdmin(
          text(body.username, "username"),
          passwordText(body.password),
        );
        this.#setupCode = null;
        await this.#audit.append({
          occurredAtMs: this.#now(), action: "auth.setup", result: "success",
          actorUserId: user.id, sourceAddress: sourceAddress(request),
        });
        sendJson(response, 201, { user });
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/session/login") {
        const body = await jsonObject(request, ["username", "password"]);
        const user = await this.#users.authenticate(
          text(body.username, "username"),
          passwordText(body.password),
        );
        if (user === null) {
          await this.#audit.append({
            occurredAtMs: this.#now(), action: "auth.login", result: "denied",
            sourceAddress: sourceAddress(request),
          });
          throw new HttpError(401, "invalid_login", "invalid username or password");
        }
        const created = this.#sessions.create(user);
        response.setHeader("Set-Cookie", sessionCookie(created.token, this.#secureCookies));
        await this.#audit.append({
          occurredAtMs: this.#now(), action: "auth.login", result: "success",
          actorUserId: user.id, sourceAddress: sourceAddress(request),
        });
        sendJson(response, 200, { user, csrfToken: created.csrfToken });
        return;
      }
      if (method === "GET" && url.pathname === "/api/v1/session") {
        const principal = this.#requireSession(request, false);
        sendJson(response, 200, {
          user: principal.user,
          csrfToken: this.#sessions.csrfToken(principal.token),
        });
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/session/logout") {
        const principal = this.#requireSession(request, true);
        this.#sessions.revoke(principal.token);
        response.setHeader("Set-Cookie", expiredSessionCookie(this.#secureCookies));
        sendJson(response, 200, { ok: true });
        return;
      }
      if (method === "GET" && url.pathname === "/api/v1/users") {
        this.#requireAdmin(request, false);
        sendJson(response, 200, { users: this.#users.list() });
        return;
      }
      if (method === "GET" && url.pathname === "/api/v1/hardware/discovery") {
        this.#requireAdmin(request, false);
        sendJson(response, 200, await this.#hardwareDiscovery.discover());
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/users") {
        this.#requireAdmin(request, true);
        const body = await jsonObject(request, ["username", "password", "role", "canTransmit", "mustChangePassword"], ["canTransmit", "mustChangePassword"]);
        const user = await this.#users.create({
          username: text(body.username, "username"),
          password: passwordText(body.password),
          role: body.role === "admin" ? "admin" : body.role === "operator" ? "operator" : invalidRole(),
          canTransmit: optionalBoolean(body.canTransmit, "canTransmit"),
          mustChangePassword: optionalBoolean(body.mustChangePassword, "mustChangePassword"),
        });
        sendJson(response, 201, { user });
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/pairing/code") {
        const principal = this.#requireAdmin(request, true);
        const body = await jsonObject(request, ["userId"]);
        const userId = text(body.userId, "userId");
        const target = this.#users.list().find((user) => user.id === userId && user.enabled);
        if (target === undefined) {
          throw new HttpError(404, "user_not_found", "enabled user not found");
        }
        const issued = this.#pairing.issueForUser(userId);
        await this.#audit.append({
          occurredAtMs: this.#now(), action: "device.pairing-issued", result: "success",
          actorUserId: principal.user.id, targetId: userId, sourceAddress: sourceAddress(request),
        });
        sendJson(response, 201, issued);
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/pairing/redeem") {
        const body = await jsonObject(request, ["code", "deviceName"]);
        const credentials = await this.#pairing.redeem(
          text(body.code, "code"),
          text(body.deviceName, "deviceName"),
          sourceAddress(request),
        );
        sendJson(response, 201, credentials);
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/device/refresh") {
        const body = await jsonObject(request, ["deviceId", "refreshToken"]);
        const credentials = await this.#devices.refresh(
          text(body.deviceId, "deviceId"),
          text(body.refreshToken, "refreshToken"),
        );
        sendJson(response, 200, credentials);
        return;
      }
      if (method === "GET" && url.pathname === "/api/v1/radios") {
        this.#requireHttpPrincipal(request, false);
        sendJson(response, 200, this.#radios.snapshot());
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/radios") {
        this.#requireAdmin(request, true);
        const body = await jsonObject(request, ["profile", "hardwareTxConfirmation"], ["hardwareTxConfirmation"]);
        if (body.profile === null || typeof body.profile !== "object" || Array.isArray(body.profile)) {
          throw new HttpError(400, "invalid_request", "profile must be an object");
        }
        const profile = body.profile as Record<string, unknown>;
        if (profile.hardwareTxEnabled === true && body.hardwareTxConfirmation !== profile.id) {
          throw new HttpError(409, "hardware_tx_confirmation_required", "confirm the exact radio id to enable hardware TX");
        }
        const saved = await this.#radios.upsert(profile);
        await this.#digital.invalidate(saved.id);
        await this.#media.invalidate(saved.id);
        await this.#runtimes.invalidate(saved.id);
        sendJson(response, 200, { radio: saved, reconnectRequired: true });
        return;
      }
      if (method === "GET" && url.pathname === "/api/v1/logs") {
        this.#requireHttpPrincipal(request, false);
        exactQueryKeys(url, ["limit", "offset"]);
        const limit = queryInteger(url, "limit", 100, 1, 1_000);
        const offset = queryInteger(url, "offset", 0, 0, Number.MAX_SAFE_INTEGER);
        sendJson(response, 200, {
          records: this.#log.list(limit, offset),
          total: this.#log.count,
          limit,
          offset,
        });
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/logs") {
        const principal = this.#requireHttpPrincipal(request, true);
        const body = await jsonObject(
          request,
          [
            "radioId", "call", "startedAtMs", "endedAtMs", "frequencyHz", "band",
            "mode", "submode", "rstSent", "rstReceived", "grid", "txPowerWatts", "comment",
          ],
          ["endedAtMs", "band", "submode", "rstSent", "rstReceived", "grid", "txPowerWatts", "comment"],
        );
        const radioId = messageText(body.radioId, "radioId", 32);
        const profile = this.#radios.snapshot().radios.find((radio) => radio.id === radioId);
        if (profile === undefined) {
          throw new HttpError(404, "radio_not_found", "radio does not exist");
        }
        const saved = await this.#log.append({
          radioId,
          source: "VOICE_MANUAL",
          call: messageText(body.call, "call", 32),
          startedAtMs: safeInteger(body.startedAtMs, "startedAtMs"),
          endedAtMs: optionalSafeInteger(body.endedAtMs, "endedAtMs"),
          frequencyHz: safeInteger(body.frequencyHz, "frequencyHz"),
          band: optionalMessageText(body.band, "band", 16),
          mode: messageText(body.mode, "mode", 32),
          submode: optionalMessageText(body.submode, "submode", 32),
          rstSent: optionalMessageText(body.rstSent, "rstSent", 16),
          rstReceived: optionalMessageText(body.rstReceived, "rstReceived", 16),
          grid: optionalMessageText(body.grid, "grid", 8),
          myCall: profile.station.callsign,
          myGrid: profile.station.grid,
          txPowerWatts: optionalNumber(body.txPowerWatts, "txPowerWatts"),
          comment: optionalMessageText(body.comment, "comment", 256),
        });
        await this.#audit.append({
          occurredAtMs: this.#now(), action: "log.qso-create", result: "success",
          actorUserId: principal.user.id, actorDeviceId: principal.deviceId ?? undefined,
          targetId: saved.record.id, metadata: { created: saved.created, source: "VOICE_MANUAL" },
        });
        sendJson(response, saved.created ? 201 : 200, saved);
        return;
      }
      if (method === "GET" && url.pathname === "/api/v1/logs/grids") {
        this.#requireHttpPrincipal(request, false);
        exactQueryKeys(url, ["resolution"]);
        const resolution = queryInteger(url, "resolution", 4, 2, 8);
        if (resolution !== 2 && resolution !== 4 && resolution !== 6 && resolution !== 8) {
          throw new HttpError(400, "invalid_grid_resolution", "resolution must be 2, 4, 6 or 8");
        }
        sendJson(response, 200, { resolution, grids: this.#log.gridSummary(resolution) });
        return;
      }
      if (method === "GET" && url.pathname === "/api/v1/logs/export") {
        this.#requireHttpPrincipal(request, false);
        sendBuffer(response, 200, await this.#log.export(), {
          "Content-Type": "application/adif; charset=us-ascii",
          "Content-Disposition": "attachment; filename=radio-lite-log.adi",
        });
        return;
      }
      if (method === "POST" && url.pathname === "/api/v1/logs/import") {
        const principal = this.#requireAdmin(request, true);
        const content = await requestBytes(
          request,
          16 * 1_024 * 1_024,
          ["application/adif", "application/octet-stream", "text/plain"],
        );
        const result = await this.#log.import(content);
        await this.#audit.append({
          occurredAtMs: this.#now(), action: "log.adif-import", result: "success",
          actorUserId: principal.user.id, actorDeviceId: principal.deviceId ?? undefined,
          metadata: result,
        });
        sendJson(response, 200, result);
        return;
      }
      throw new HttpError(404, "not_found", "endpoint not found");
    } catch (error) {
      const mapped = mapError(error);
      sendJson(response, mapped.status, { error: { code: mapped.code, message: mapped.message } });
    }
  }

  #requireAdmin(request: IncomingMessage, csrf: boolean): HttpPrincipal {
    const principal = this.#requireHttpPrincipal(request, csrf);
    if (principal.user.role !== "admin") {
      throw new HttpError(403, "admin_required", "administrator permission required");
    }
    return principal;
  }

  #requireHttpPrincipal(request: IncomingMessage, csrf: boolean): HttpPrincipal {
    const sessionToken = parseCookieHeader(request.headers.cookie).get("rr_session");
    if (sessionToken !== undefined) {
      const session = this.#requireSession(request, csrf);
      return { sessionToken: session.token, deviceId: null, user: session.user };
    }
    const authorization = request.headers.authorization;
    const deviceIdHeader = request.headers["x-radio-lite-device-id"];
    if (typeof authorization !== "string" || typeof deviceIdHeader !== "string") {
      throw new HttpError(401, "authentication_required", "authentication required");
    }
    const matched = /^Bearer ([A-Za-z0-9_-]{20,512})$/u.exec(authorization);
    if (matched === null || deviceIdHeader.length < 1 || deviceIdHeader.length > 128) {
      throw new HttpError(401, "invalid_device_credential", "device credential is invalid");
    }
    const device = this.#devices.verifyAccess(deviceIdHeader, matched[1]);
    const user = device === null
      ? undefined
      : this.#users.list().find((candidate) => candidate.id === device.userId && candidate.enabled);
    if (device === null || user === undefined) {
      throw new HttpError(401, "invalid_device_credential", "device credential is invalid");
    }
    return { sessionToken: null, deviceId: device.id, user };
  }

  #optionalSession(request: IncomingMessage): SessionPrincipal | null {
    try {
      return this.#requireSession(request, false);
    } catch {
      return null;
    }
  }

  #requireSession(request: IncomingMessage, csrf: boolean): SessionPrincipal {
    const token = parseCookieHeader(request.headers.cookie).get("rr_session");
    if (token === undefined) {
      throw new HttpError(401, "authentication_required", "authentication required");
    }
    const userId = this.#sessions.candidateUserId(token);
    const user = userId === null ? undefined : this.#users.list().find((item) => item.id === userId);
    if (this.#sessions.resolve(token, user) === null || user === undefined) {
      throw new HttpError(401, "invalid_session", "session is invalid or expired");
    }
    if (csrf && !this.#sessions.validateCsrf(token, String(request.headers["x-csrf-token"] ?? ""))) {
      throw new HttpError(403, "invalid_csrf", "CSRF token is invalid");
    }
    return { token, user };
  }
}

class HttpError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

class MediaSubscriptionRequiredError extends Error {}

async function jsonObject(
  request: IncomingMessage,
  allowed: readonly string[],
  optional: readonly string[] = [],
): Promise<Record<string, unknown>> {
  if (!String(request.headers["content-type"] ?? "").toLowerCase().startsWith("application/json")) {
    throw new HttpError(415, "json_required", "Content-Type application/json is required");
  }
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > 32_768) {
      throw new HttpError(413, "body_too_large", "request body is too large");
    }
    chunks.push(buffer);
  }
  let value: unknown;
  try {
    value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "invalid_json", "request body is not valid JSON");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "invalid_request", "request body must be an object");
  }
  const body = value as Record<string, unknown>;
  for (const key of Object.keys(body)) {
    if (!allowed.includes(key)) {
      throw new HttpError(400, "unknown_field", `unknown request field: ${key}`);
    }
  }
  for (const key of allowed) {
    if (!(key in body) && !optional.includes(key)) {
      throw new HttpError(400, "missing_field", `missing request field: ${key}`);
    }
  }
  return body;
}

async function requestBytes(
  request: IncomingMessage,
  maximumBytes: number,
  contentTypes: readonly string[],
): Promise<Buffer> {
  const contentType = String(request.headers["content-type"] ?? "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (!contentTypes.includes(contentType)) {
    throw new HttpError(415, "unsupported_media_type", "request content type is not supported");
  }
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > maximumBytes) {
      throw new HttpError(413, "body_too_large", "request body is too large");
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

function exactQueryKeys(url: URL, allowed: readonly string[]): void {
  for (const key of new Set(url.searchParams.keys())) {
    if (!allowed.includes(key)) {
      throw new HttpError(400, "unknown_query", `unknown query parameter: ${key}`);
    }
    if (url.searchParams.getAll(key).length !== 1) {
      throw new HttpError(400, "duplicate_query", `query parameter appears more than once: ${key}`);
    }
  }
}

function queryInteger(
  url: URL,
  name: string,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const raw = url.searchParams.get(name);
  if (raw === null) {
    return fallback;
  }
  if (!/^(?:0|[1-9][0-9]*)$/u.test(raw)) {
    throw new HttpError(400, "invalid_query", `${name} must be an integer`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new HttpError(400, "invalid_query", `${name} is outside the allowed range`);
  }
  return value;
}

function sendJson(response: ServerResponse, status: number, value: unknown): void {
  if (response.headersSent) {
    return;
  }
  const body = Buffer.from(JSON.stringify(value), "utf8");
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": body.length,
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
  });
  response.end(body);
}

function sendBuffer(
  response: ServerResponse,
  status: number,
  body: Buffer,
  headers: Record<string, string>,
): void {
  if (response.headersSent) {
    return;
  }
  response.writeHead(status, {
    ...headers,
    "Content-Length": body.length,
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
  });
  response.end(body);
}

function mapError(error: unknown): HttpError {
  if (error instanceof HttpError) {
    return error;
  }
  if (error instanceof InvalidOrExpiredCodeError) {
    return new HttpError(410, "invalid_or_expired_code", "code is invalid or expired");
  }
  if (error instanceof CodeRateLimitError) {
    return new HttpError(429, "code_rate_limited", "too many invalid code attempts");
  }
  if (error instanceof RefreshTokenReuseError) {
    return new HttpError(401, "refresh_reuse_detected", "device was revoked after credential reuse");
  }
  if (error instanceof InvalidDeviceCredentialError) {
    return new HttpError(401, "invalid_device_credential", "device credential is invalid");
  }
  if (error instanceof Error && /already|duplicate|cannot enable|final enabled/u.test(error.message)) {
    return new HttpError(409, "conflict", error.message);
  }
  if (error instanceof Error && /must|invalid|unsupported|required|unknown|outside|exceeds|ADIF|Maidenhead|characters|precede/u.test(error.message)) {
    return new HttpError(400, "invalid_request", error.message);
  }
  return new HttpError(500, "internal_error", "internal server error");
}

function validateOrigin(request: IncomingMessage): void {
  const origin = request.headers.origin;
  if (origin === undefined) {
    return;
  }
  const host = request.headers.host;
  try {
    if (host === undefined || new URL(origin).host !== host) {
      throw new Error("mismatch");
    }
  } catch {
    throw new HttpError(403, "origin_mismatch", "request origin is not allowed");
  }
}

function sessionCookie(token: string, secure: boolean): string {
  return `rr_session=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200${secure ? "; Secure" : ""}`;
}

function expiredSessionCookie(secure: boolean): string {
  return `rr_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0${secure ? "; Secure" : ""}`;
}

function text(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length < 1 || value.length > 1_024) {
    throw new HttpError(400, "invalid_request", `${field} must be non-empty text`);
  }
  return value;
}

function passwordText(value: unknown): string {
  if (typeof value !== "string" || value.length < 1) {
    throw new HttpError(400, "invalid_request", "password must be non-empty text");
  }
  return value;
}

function optionalBoolean(value: unknown, field: string): boolean | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "boolean") {
    throw new HttpError(400, "invalid_request", `${field} must be boolean`);
  }
  return value;
}

function invalidRole(): never {
  throw new HttpError(400, "invalid_request", "role must be admin or operator");
}

function sourceAddress(request: IncomingMessage): string {
  return request.socket.remoteAddress ?? "unknown";
}

function isLoopback(host: string): boolean {
  return host === "127.0.0.1" || host === "::1" || host === "localhost";
}

function sendWebSocketJson(webSocket: WebSocket, value: unknown): void {
  if (webSocket.readyState === WebSocket.OPEN) {
    webSocket.send(JSON.stringify(value));
  }
}

function webSocketBytes(data: RawData): Buffer {
  if (Buffer.isBuffer(data)) {
    return data;
  }
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data);
  }
  if (Array.isArray(data)) {
    return Buffer.concat(data);
  }
  throw new TypeError("unsupported WebSocket data representation");
}

function isExactDeviceAuth(value: unknown): value is {
  t: "auth.device";
  deviceId: string;
  accessToken: string;
} {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const item = value as Record<string, unknown>;
  return Object.keys(item).length === 3 &&
    item.t === "auth.device" &&
    typeof item.deviceId === "string" &&
    typeof item.accessToken === "string";
}

function isMessageType(value: unknown, type: string): boolean {
  return value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).length === 1 &&
    (value as Record<string, unknown>).t === type;
}

function controlMessage(value: unknown): Record<string, unknown> & { t: string } {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("control message must be an object");
  }
  const message = value as Record<string, unknown>;
  if (typeof message.t !== "string" || message.t.length < 1 || message.t.length > 64) {
    throw new Error("control message type is invalid");
  }
  return message as Record<string, unknown> & { t: string };
}

function exactMessageKeys(
  message: Record<string, unknown>,
  allowed: readonly string[],
  optional: readonly string[] = [],
): void {
  for (const key of Object.keys(message)) {
    if (!allowed.includes(key)) {
      throw new Error(`unknown control field: ${key}`);
    }
  }
  for (const key of allowed) {
    if (!(key in message) && !optional.includes(key)) {
      throw new Error(`missing control field: ${key}`);
    }
  }
}

function messageText(value: unknown, field: string, max: number): string {
  if (typeof value !== "string" || value.length < 1 || value.length > max || /[\0\r\n]/u.test(value)) {
    throw new Error(`${field} must be non-empty bounded text`);
  }
  return value;
}

function optionalMessageText(value: unknown, field: string, max: number): string | undefined {
  return value === undefined ? undefined : messageText(value, field, max);
}

function safeInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value)) {
    throw new Error(`${field} must be a safe integer`);
  }
  return value as number;
}

function optionalSafeInteger(value: unknown, field: string): number | undefined {
  return value === undefined ? undefined : safeInteger(value, field);
}

function optionalNumber(value: unknown, field: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`${field} must be a finite number`);
  }
  return value;
}

function nonNegativeNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new Error(`${field} must be a non-negative finite number`);
  }
  return value;
}

function mapControlError(error: unknown): { code: string; message: string } {
  if (error instanceof DigitalWorkerUnavailableError) {
    return { code: "digital_worker_unavailable", message: error.message };
  }
  if (error instanceof MediaSubscriptionRequiredError) {
    return { code: "media_required", message: error.message };
  }
  if (error instanceof ControlBusyError) {
    return { code: "control_busy", message: "radio control is held by another operator" };
  }
  if (error instanceof InvalidControlLeaseError) {
    return { code: "invalid_control_lease", message: "radio control lease is invalid or expired" };
  }
  if (error instanceof TransmitPermissionError) {
    return { code: "transmit_forbidden", message: "account is not permitted to transmit" };
  }
  if (error instanceof HardwareTransmitDisabledError) {
    return { code: "hardware_tx_disabled", message: "hardware transmission is disabled" };
  }
  if (error instanceof InterlockConflictError) {
    return { code: "transmit_interlocked", message: error.message };
  }
  if (error instanceof InvalidLeaseError) {
    return { code: "invalid_transmit_lease", message: "transmit lease is invalid or expired" };
  }
  if (error instanceof RigReportError) {
    return { code: "hamlib_report", message: `Hamlib rejected the command (RPRT ${error.report})` };
  }
  if (error instanceof RigTransportError) {
    return { code: "hamlib_unavailable", message: "Hamlib connection is unavailable" };
  }
  if (error instanceof Error && /radio does not exist/u.test(error.message)) {
    return { code: "radio_not_found", message: "radio does not exist" };
  }
  if (error instanceof Error && /must|invalid|unknown|unsupported|outside/u.test(error.message)) {
    return { code: "invalid_command", message: error.message };
  }
  return { code: "command_failed", message: "radio command failed" };
}
