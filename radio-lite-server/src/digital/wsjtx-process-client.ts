import { fork, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";

import type { DigitalMode } from "./types.ts";
import type {
  WsjtxChildRequest,
  WsjtxChildResponse,
  WsjtxDecodedFrame,
  WsjtxDecodedMessage,
  WsjtxEncodedMessage,
} from "./wsjtx-protocol.ts";

export type WsjtxEncodeResult = Omit<WsjtxEncodedMessage, "t" | "id">;
export type WsjtxDecodeResult = { frames: WsjtxDecodedFrame[] };

export type WsjtxProcessClientOptions = {
  forkProcess?: typeof fork;
  childPath?: string;
  startupTimeoutMs?: number;
  requestTimeoutMs?: number;
  shutdownTimeoutMs?: number;
  onFault?: (error: unknown) => void;
};

type PendingRequest = {
  timer: ReturnType<typeof setTimeout>;
  resolve(value: WsjtxChildResponse): void;
  reject(error: Error): void;
};

export class WsjtxProcessClient {
  readonly #forkProcess: typeof fork;
  readonly #childPath: string;
  readonly #startupTimeoutMs: number;
  readonly #requestTimeoutMs: number;
  readonly #shutdownTimeoutMs: number;
  readonly #onFault: (error: unknown) => void;
  readonly #pending = new Map<string, PendingRequest>();
  #child: ChildProcess | null = null;
  #startPromise: Promise<void> | null = null;
  #resolveStart: (() => void) | null = null;
  #rejectStart: ((error: Error) => void) | null = null;
  #startupTimer: ReturnType<typeof setTimeout> | null = null;
  #nextRequestId = 1;
  #closing = false;
  #closed = false;
  #faulted = false;

  constructor(options: WsjtxProcessClientOptions = {}) {
    this.#forkProcess = options.forkProcess ?? fork;
    this.#childPath = options.childPath ?? fileURLToPath(new URL("./wsjtx-child.ts", import.meta.url));
    this.#startupTimeoutMs = boundedInteger(
      options.startupTimeoutMs ?? 15_000,
      "DSP startup timeout",
      100,
      60_000,
    );
    this.#requestTimeoutMs = boundedInteger(
      options.requestTimeoutMs ?? 45_000,
      "DSP request timeout",
      1_000,
      120_000,
    );
    this.#shutdownTimeoutMs = boundedInteger(
      options.shutdownTimeoutMs ?? 2_000,
      "DSP shutdown timeout",
      100,
      10_000,
    );
    this.#onFault = options.onFault ?? (() => undefined);
  }

  start(): Promise<void> {
    if (this.#closed || this.#closing) {
      return Promise.reject(new Error("WSJT-X process client is closed"));
    }
    if (this.#startPromise !== null) {
      return this.#startPromise;
    }
    this.#startPromise = new Promise<void>((resolve, reject) => {
      this.#resolveStart = resolve;
      this.#rejectStart = reject;
    });
    let child: ChildProcess;
    try {
      child = this.#forkProcess(this.#childPath, [], {
        execArgv: ["--experimental-strip-types"],
        serialization: "advanced",
        stdio: ["ignore", "ignore", "pipe", "ipc"],
      });
    } catch (error) {
      this.#fail(error);
      return this.#startPromise;
    }
    this.#child = child;
    const diagnostics: string[] = [];
    child.stderr?.on("data", (chunk: Buffer) => {
      diagnostics.push(chunk.toString("utf8"));
      while (diagnostics.join("").length > 4_096) {
        diagnostics.shift();
      }
    });
    child.on("message", (message) => this.#handleMessage(message));
    child.once("error", (error) => this.#fail(error));
    child.once("exit", (code, signal) => {
      if (!this.#closing && !this.#closed) {
        const detail = diagnostics.join("").trim().slice(-1_024);
        this.#fail(new Error(
          `WSJT-X DSP exited (${code ?? signal ?? "unknown"})${detail ? `: ${detail}` : ""}`,
        ));
      }
    });
    this.#startupTimer = setTimeout(() => {
      this.#fail(new Error("WSJT-X DSP startup timed out"));
    }, this.#startupTimeoutMs);
    this.#startupTimer.unref();
    return this.#startPromise;
  }

  async encode(value: {
    mode: DigitalMode;
    message: string;
    audioFrequencyHz: number;
  }): Promise<WsjtxEncodeResult> {
    const response = await this.#request({
      t: "encode",
      id: this.#requestId(),
      ...value,
    });
    if (response.t !== "encoded") {
      throw new Error("WSJT-X DSP returned an unexpected encode response");
    }
    if (!(response.pcm instanceof Int16Array) || response.pcm.length === 0) {
      throw new Error("WSJT-X DSP returned invalid encoded PCM");
    }
    return {
      pcm: response.pcm,
      sampleRate: response.sampleRate,
      durationMs: response.durationMs,
      messageSent: response.messageSent,
    };
  }

  async decode(value: {
    mode: DigitalMode;
    pcm: Int16Array;
    nominalFrequencyHz: number;
    myCall: string;
    myGrid?: string;
  }): Promise<WsjtxDecodeResult> {
    const response = await this.#request({
      t: "decode",
      id: this.#requestId(),
      ...value,
    });
    if (response.t !== "decoded" || !Array.isArray(response.frames)) {
      throw new Error("WSJT-X DSP returned an unexpected decode response");
    }
    return { frames: response.frames };
  }

  async close(): Promise<void> {
    if (this.#closed) {
      return;
    }
    this.#closing = true;
    this.#clearStartupTimer();
    const child = this.#child;
    this.#rejectAll(new Error("WSJT-X process client is closing"));
    this.#rejectStart?.(new Error("WSJT-X process client is closing"));
    this.#resolveStart = null;
    this.#rejectStart = null;
    if (child !== null && child.exitCode === null && child.signalCode === null) {
      const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
      if (child.connected) {
        child.send({ t: "shutdown" } satisfies WsjtxChildRequest);
      }
      await Promise.race([exited, delay(this.#shutdownTimeoutMs)]);
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGKILL");
        await Promise.race([exited, delay(this.#shutdownTimeoutMs)]);
      }
    }
    this.#child = null;
    this.#closing = false;
    this.#closed = true;
  }

  async #request(request: Exclude<WsjtxChildRequest, { t: "shutdown" }>): Promise<WsjtxChildResponse> {
    await this.start();
    if (this.#faulted || this.#closing || this.#closed) {
      throw new Error("WSJT-X DSP is unavailable");
    }
    const child = this.#child;
    if (child === null || !child.connected) {
      throw new Error("WSJT-X DSP IPC is unavailable");
    }
    return new Promise<WsjtxChildResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(request.id);
        const error = new Error(`WSJT-X DSP request timed out (${request.t})`);
        reject(error);
        this.#fail(error);
      }, this.#requestTimeoutMs);
      timer.unref();
      this.#pending.set(request.id, { timer, resolve, reject });
      child.send(request, (error) => {
        if (error === null) {
          return;
        }
        const pending = this.#pending.get(request.id);
        if (pending === undefined) {
          return;
        }
        this.#pending.delete(request.id);
        clearTimeout(pending.timer);
        pending.reject(error);
        this.#fail(error);
      });
    });
  }

  #handleMessage(value: unknown): void {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      this.#fail(new Error("WSJT-X DSP sent an invalid response"));
      return;
    }
    const response = value as WsjtxChildResponse;
    if (response.t === "ready") {
      this.#clearStartupTimer();
      this.#resolveStart?.();
      this.#resolveStart = null;
      this.#rejectStart = null;
      return;
    }
    if (response.t === "fatal") {
      this.#fail(new Error(response.message));
      return;
    }
    if (response.t !== "encoded" && response.t !== "decoded" && response.t !== "error") {
      this.#fail(new Error("WSJT-X DSP sent an unsupported response"));
      return;
    }
    const pending = this.#pending.get(response.id);
    if (pending === undefined) {
      return;
    }
    this.#pending.delete(response.id);
    clearTimeout(pending.timer);
    if (response.t === "error") {
      const error = new Error(response.message);
      error.name = response.code ?? "WSJTXError";
      pending.reject(error);
    } else {
      pending.resolve(response);
    }
  }

  #fail(error: unknown): void {
    if (this.#faulted || this.#closed || this.#closing) {
      return;
    }
    this.#faulted = true;
    const failure = error instanceof Error ? error : new Error(String(error));
    this.#clearStartupTimer();
    this.#rejectStart?.(failure);
    this.#resolveStart = null;
    this.#rejectStart = null;
    this.#rejectAll(failure);
    const child = this.#child;
    if (child !== null && child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
    }
    this.#onFault(failure);
  }

  #rejectAll(error: Error): void {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.#pending.clear();
  }

  #clearStartupTimer(): void {
    if (this.#startupTimer !== null) {
      clearTimeout(this.#startupTimer);
      this.#startupTimer = null;
    }
  }

  #requestId(): string {
    const id = `dsp_${this.#nextRequestId}`;
    this.#nextRequestId += 1;
    return id;
  }
}

function boundedInteger(value: number, field: string, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${field} must be in ${minimum}..${maximum}`);
  }
  return value;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds);
    timer.unref();
  });
}
