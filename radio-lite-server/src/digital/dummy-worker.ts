import type {
  DigitalEncodeRequest,
  DigitalWorker,
  DigitalWorkerOutput,
  PreparedDigitalTransmission,
} from "./worker.ts";
import type { DigitalDecodeBatchInput } from "./types.ts";

export type DummyDigitalWorkerOptions = {
  playbackDelayMs?: number;
};

export class DummyDigitalWorker implements DigitalWorker {
  readonly #playbackDelayMs: number;
  #output: DigitalWorkerOutput | null = null;
  #timer: ReturnType<typeof setTimeout> | null = null;
  #rejectPlayback: ((error: Error) => void) | null = null;
  #abortCleanup: (() => void) | null = null;
  #closed = false;

  constructor(options: DummyDigitalWorkerOptions = {}) {
    this.#playbackDelayMs = boundedInteger(options.playbackDelayMs ?? 10, "playbackDelayMs", 0, 60_000);
  }

  async start(output: DigitalWorkerOutput): Promise<void> {
    if (this.#closed) {
      throw new Error("dummy digital worker is closed");
    }
    if (this.#output !== null) {
      throw new Error("dummy digital worker is already started");
    }
    this.#output = output;
  }

  async prepare(request: DigitalEncodeRequest): Promise<PreparedDigitalTransmission> {
    this.#assertStarted();
    return {
      ...request,
      sampleRate: 12_000,
      durationMs: request.mode === "FT8" ? 12_640 : 6_000,
      payload: Buffer.from(request.message, "ascii"),
    };
  }

  transmit(prepared: PreparedDigitalTransmission, signal: AbortSignal): Promise<void> {
    this.#assertStarted();
    if (this.#timer !== null) {
      return Promise.reject(new Error("dummy digital worker is already transmitting"));
    }
    if (signal.aborted) {
      return Promise.reject(abortError());
    }
    return new Promise<void>((resolve, reject) => {
      const onAbort = () => {
        const rejectPlayback = reject;
        this.#clearPlayback();
        rejectPlayback(abortError());
      };
      this.#rejectPlayback = reject;
      this.#abortCleanup = () => signal.removeEventListener("abort", onAbort);
      signal.addEventListener("abort", onAbort, { once: true });
      this.#timer = setTimeout(() => {
        this.#timer = null;
        this.#rejectPlayback = null;
        this.#abortCleanup?.();
        this.#abortCleanup = null;
        resolve();
      }, this.#playbackDelayMs);
      this.#timer.unref();
    });
  }

  async stopTransmission(): Promise<void> {
    const reject = this.#rejectPlayback;
    this.#clearPlayback();
    reject?.(abortError());
  }

  injectDecodeBatch(batch: DigitalDecodeBatchInput): void {
    this.#assertStarted();
    this.#output!.decoded(batch);
  }

  injectFault(error: unknown): void {
    this.#assertStarted();
    this.#output!.fault(error);
  }

  async close(): Promise<void> {
    if (this.#closed) {
      return;
    }
    this.#closed = true;
    await this.stopTransmission();
    this.#output = null;
  }

  #clearPlayback(): void {
    if (this.#timer !== null) {
      clearTimeout(this.#timer);
      this.#timer = null;
    }
    this.#abortCleanup?.();
    this.#abortCleanup = null;
    this.#rejectPlayback = null;
  }

  #assertStarted(): void {
    if (this.#closed || this.#output === null) {
      throw new Error("dummy digital worker is not running");
    }
  }
}

function boundedInteger(value: unknown, field: string, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new Error(`${field} must be in ${minimum}..${maximum}`);
  }
  return value as number;
}

function abortError(): Error {
  const error = new Error("digital transmission was aborted");
  error.name = "AbortError";
  return error;
}
