import { createConnection, type Socket } from "node:net";
import { performance } from "node:perf_hooks";

import {
  encodeRigCommand,
  ExtendedResponseParser,
  RigProtocolError,
  type RigResponse,
} from "./extended-protocol.ts";

export class RigTransportError extends Error {}
export class RigQueueBusyError extends Error {}
export class RigTelemetryDroppedError extends Error {}

export class RigReportError extends Error {
  readonly report: number;

  constructor(command: string, report: number) {
    super(`rigctld ${command} failed with RPRT ${report}`);
    this.report = report;
  }
}

export type RigRequestPriority = "safety" | "normal";
export type RigRequestSource = "control" | "telemetry" | "ptt-off";

export type RigRequestOptions = {
  priority?: RigRequestPriority;
  source?: RigRequestSource;
  timeoutMs?: number;
};

export type RigCommandTrace = Readonly<{
  command: string;
  source: RigRequestSource;
  priority: RigRequestPriority;
  startedAtMs: number;
  finishedAtMs: number;
}>;

export type RigctldTransportOptions = {
  /** Compatibility override for the normal-command default. */
  timeoutMs?: number;
  safetyTimeoutMs?: number;
  connect?: typeof createConnection;
  now?: () => number;
  normalQueueLimit?: number;
  safetyBreakAfterMs?: number;
};

type RigRequest = {
  command: string;
  encoded: Buffer;
  priority: RigRequestPriority;
  source: RigRequestSource;
  timeoutMs: number;
  startedAtMs: number | null;
  settled: boolean;
  resolve: (response: RigResponse) => void;
  reject: (error: Error) => void;
};

type ConnectionAttempt = {
  socket: Socket;
  cancel: (error: Error) => void;
};

export class RigctldTransport {
  readonly #host: string;
  readonly #port: number;
  readonly #normalTimeoutMs: number;
  readonly #safetyTimeoutMs: number;
  readonly #connect: typeof createConnection;
  readonly #now: () => number;
  readonly #normalQueueLimit: number;
  readonly #safetyBreakAfterMs: number;
  #socket: Socket | null = null;
  #connecting: ConnectionAttempt | null = null;
  #parser = new ExtendedResponseParser();
  #pending: {
    resolve: (response: RigResponse) => void;
    reject: (error: Error) => void;
  } | null = null;
  #safetyQueue: RigRequest[] = [];
  #normalQueue: RigRequest[] = [];
  #active: RigRequest | null = null;
  #safetyBreakTimer: ReturnType<typeof setTimeout> | null = null;
  #trace: RigCommandTrace[] = [];
  #closed = false;
  #closePromise: Promise<void> | null = null;

  constructor(host: string, port: number, options: RigctldTransportOptions = {}) {
    if (!host || /[\0\r\n]/u.test(host)) {
      throw new Error("rigctld host is invalid");
    }
    if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
      throw new Error("rigctld port must be in 1..65535");
    }
    this.#host = host;
    this.#port = port;
    this.#normalTimeoutMs = positiveInteger(
      options.timeoutMs ?? 10_000,
      "rigctld timeout",
    );
    this.#safetyTimeoutMs = positiveInteger(
      options.safetyTimeoutMs ?? 1_000,
      "rigctld safety timeout",
    );
    this.#connect = options.connect ?? createConnection;
    this.#now = options.now ?? (() => performance.now());
    this.#normalQueueLimit = positiveInteger(
      options.normalQueueLimit ?? 32,
      "rigctld normal queue limit",
    );
    this.#safetyBreakAfterMs = positiveInteger(
      options.safetyBreakAfterMs ?? 250,
      "rigctld safety break delay",
    );
  }

  request(command: string, options: RigRequestOptions = {}): Promise<RigResponse> {
    const encoded = encodeRigCommand(command);
    const priority = options.priority ?? "normal";
    const source = options.source ?? "control";
    validatePriority(priority);
    validateSource(source);
    const timeoutMs = positiveInteger(
      options.timeoutMs ?? (
        priority === "safety" ? this.#safetyTimeoutMs : this.#normalTimeoutMs
      ),
      "rigctld request timeout",
    );
    if (this.#closed) {
      return Promise.reject(new RigTransportError("rigctld transport is closed"));
    }
    if (priority === "normal" && this.#normalQueue.length >= this.#normalQueueLimit) {
      return Promise.reject(
        source === "telemetry"
          ? new RigTelemetryDroppedError("rig_telemetry_dropped")
          : new RigQueueBusyError("rig_queue_busy"),
      );
    }

    let resolve!: (response: RigResponse) => void;
    let reject!: (error: Error) => void;
    const promise = new Promise<RigResponse>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    const request: RigRequest = {
      command,
      encoded,
      priority,
      source,
      timeoutMs,
      startedAtMs: null,
      settled: false,
      resolve,
      reject,
    };
    if (priority === "safety") {
      this.#safetyQueue.push(request);
    } else {
      this.#normalQueue.push(request);
    }
    this.#pump();
    this.#refreshSafetyBreakTimer();
    return promise;
  }

  commandTrace(): readonly RigCommandTrace[] {
    return this.#trace.map((entry) => ({ ...entry }));
  }

  close(): Promise<void> {
    if (this.#closePromise !== null) return this.#closePromise;
    this.#closed = true;
    this.#clearSafetyBreakTimer();
    const error = new RigTransportError("rigctld transport closed");
    for (const queued of this.#safetyQueue.splice(0)) this.#rejectQueued(queued, error);
    for (const queued of this.#normalQueue.splice(0)) this.#rejectQueued(queued, error);

    const socket = this.#socket;
    const connectingSocket = this.#connecting?.socket ?? null;
    this.#cancelConnecting(error);
    this.#failPending(error);
    this.#socket = null;
    this.#parser.reset();
    if (this.#active !== null) this.#settleActive(this.#active, null, error);

    const closing = (async () => {
      const sockets = [...new Set([socket, connectingSocket].filter(
        (value): value is Socket => value !== null,
      ))];
      await Promise.all(sockets.map((value) => closeSocket(value)));
    })();
    this.#closePromise = closing;
    return closing;
  }

  #pump(): void {
    if (this.#closed || this.#active !== null) return;
    const next = this.#safetyQueue.shift() ?? this.#normalQueue.shift();
    if (next === undefined) {
      this.#clearSafetyBreakTimer();
      return;
    }
    this.#active = next;
    next.startedAtMs = this.#now();
    this.#refreshSafetyBreakTimer();
    void this.#execute(next).then(
      (response) => this.#settleActive(next, response, null),
      (error: unknown) => this.#settleActive(
        next,
        null,
        error instanceof Error ? error : new RigTransportError(String(error)),
      ),
    );
  }

  async #execute(request: RigRequest): Promise<RigResponse> {
    if (this.#closed || request.settled || this.#active !== request) {
      throw new RigTransportError("rigctld request was cancelled");
    }
    const socket = await this.#ensureConnected(request.timeoutMs, request.priority);
    if (this.#closed || request.settled || this.#active !== request) {
      throw new RigTransportError("rigctld request was cancelled");
    }
    const response = await new Promise<RigResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending = null;
        this.#destroySocket();
        reject(new RigTransportError(
          `rigctld command timed out after ${request.timeoutMs} ms`,
        ));
      }, request.timeoutMs);
      if (request.priority === "normal") timer.unref();
      this.#pending = {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      };
      socket.write(request.encoded, (error) => {
        if (error !== null && error !== undefined) {
          this.#failPending(new RigTransportError(
            "unable to write rigctld command",
            { cause: error },
          ));
        }
      });
    });
    if (response.report !== 0) {
      throw new RigReportError(response.command, response.report);
    }
    return response;
  }

  async #ensureConnected(
    timeoutMs: number,
    priority: RigRequestPriority,
  ): Promise<Socket> {
    if (this.#socket !== null && !this.#socket.destroyed) {
      return this.#socket;
    }
    this.#parser = new ExtendedResponseParser();
    return new Promise<Socket>((resolve, reject) => {
      const socket = this.#connect({ host: this.#host, port: this.#port });
      let settled = false;
      const timer = setTimeout(() => {
        fail(new RigTransportError(`rigctld connection timed out after ${timeoutMs} ms`));
      }, timeoutMs);
      if (priority === "normal") timer.unref();
      const cleanup = () => {
        clearTimeout(timer);
        socket.off("error", onError);
        socket.off("connect", onConnect);
        if (this.#connecting === attempt) this.#connecting = null;
      };
      const fail = (error: Error) => {
        if (settled) return;
        settled = true;
        cleanup();
        socket.destroy();
        reject(error);
      };
      const onError = (error: Error) => {
        fail(new RigTransportError("unable to connect to rigctld", { cause: error }));
      };
      const onConnect = () => {
        if (settled) return;
        if (this.#closed) {
          fail(new RigTransportError("rigctld transport is closed"));
          return;
        }
        settled = true;
        cleanup();
        socket.setNoDelay(true);
        this.#socket = socket;
        this.#attachSocket(socket);
        resolve(socket);
      };
      const attempt: ConnectionAttempt = { socket, cancel: fail };
      this.#connecting = attempt;
      socket.once("error", onError);
      socket.once("connect", onConnect);
    });
  }

  #attachSocket(socket: Socket): void {
    socket.on("data", (data) => {
      try {
        const responses = this.#parser.feed(data);
        for (const response of responses) {
          const pending = this.#pending;
          if (pending === null) {
            throw new RigProtocolError("rigctld sent an unsolicited response");
          }
          this.#pending = null;
          pending.resolve(response);
        }
      } catch (error) {
        this.#failPending(error instanceof Error ? error : new RigProtocolError(String(error)));
        this.#destroySocket();
      }
    });
    socket.on("error", (error) => {
      this.#failPending(new RigTransportError("rigctld socket failed", { cause: error }));
      this.#destroySocket();
    });
    socket.on("close", () => {
      if (this.#socket === socket) {
        this.#socket = null;
      }
      this.#failPending(new RigTransportError("rigctld connection closed"));
    });
  }

  #settleActive(
    request: RigRequest,
    response: RigResponse | null,
    error: Error | null,
  ): void {
    if (request.settled) return;
    request.settled = true;
    if (this.#active === request) this.#active = null;
    this.#trace.push({
      command: request.command,
      source: request.source,
      priority: request.priority,
      startedAtMs: request.startedAtMs ?? this.#now(),
      finishedAtMs: this.#now(),
    });
    if (error === null && response !== null) {
      request.resolve(response);
    } else {
      request.reject(error ?? new RigTransportError("rigctld request failed"));
    }
    this.#pump();
    this.#refreshSafetyBreakTimer();
  }

  #rejectQueued(request: RigRequest, error: Error): void {
    if (request.settled) return;
    request.settled = true;
    request.reject(error);
  }

  #refreshSafetyBreakTimer(): void {
    const active = this.#active;
    if (
      this.#closed ||
      active === null ||
      active.priority !== "normal" ||
      this.#safetyQueue.length === 0
    ) {
      this.#clearSafetyBreakTimer();
      return;
    }
    if (this.#safetyBreakTimer !== null) return;
    const blocked = active;
    const handle = setTimeout(() => {
      if (this.#safetyBreakTimer === handle) this.#safetyBreakTimer = null;
      if (
        !this.#closed &&
        this.#active === blocked &&
        !blocked.settled &&
        blocked.priority === "normal" &&
        this.#safetyQueue.length > 0
      ) {
        const error = new RigTransportError(
          "ordinary rigctld command interrupted for safety recovery",
        );
        this.#cancelConnecting(error);
        this.#failPending(error);
        this.#destroySocket();
        this.#settleActive(blocked, null, error);
      }
      this.#refreshSafetyBreakTimer();
    }, this.#safetyBreakAfterMs);
    // Safety escalation is deliberately referenced.
    this.#safetyBreakTimer = handle;
  }

  #clearSafetyBreakTimer(): void {
    if (this.#safetyBreakTimer === null) return;
    clearTimeout(this.#safetyBreakTimer);
    this.#safetyBreakTimer = null;
  }

  #cancelConnecting(error: Error): void {
    const connecting = this.#connecting;
    this.#connecting = null;
    connecting?.cancel(error);
  }

  #failPending(error: Error): void {
    const pending = this.#pending;
    this.#pending = null;
    pending?.reject(error);
  }

  #destroySocket(): void {
    const socket = this.#socket;
    this.#socket = null;
    socket?.destroy();
    this.#parser.reset();
  }
}

function validatePriority(value: string): asserts value is RigRequestPriority {
  if (value !== "safety" && value !== "normal") {
    throw new Error("rigctld request priority is invalid");
  }
}

function validateSource(value: string): asserts value is RigRequestSource {
  if (value !== "control" && value !== "telemetry" && value !== "ptt-off") {
    throw new Error("rigctld request source is invalid");
  }
}

function closeSocket(socket: Socket): Promise<void> {
  if (socket.closed) return Promise.resolve();
  return new Promise<void>((resolve) => {
    const timer = setTimeout(() => socket.destroy(), 1_000);
    timer.unref();
    socket.once("close", () => {
      clearTimeout(timer);
      resolve();
    });
    socket.end();
  });
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}
