import { performance } from "node:perf_hooks";

export type CatCommandMode = "receive" | "transmit";
export type CatCommandDelay = (milliseconds: number, signal: AbortSignal) => Promise<void>;

export type CatCommandLimiterOptions = {
  now?: () => number;
  delay?: CatCommandDelay;
};

/** Enforces the radio's start-to-start ordinary CAT command budget. */
export class CatCommandLimiter {
  readonly #now: () => number;
  readonly #delay: CatCommandDelay;
  #mode: CatCommandMode = "receive";
  #nextStartAtMs = 0;
  #modeRevision = 0;
  #modeDelayAbort = new AbortController();

  constructor(options: CatCommandLimiterOptions = {}) {
    this.#now = options.now ?? (() => performance.now());
    this.#delay = options.delay ?? delay;
  }

  setMode(mode: CatCommandMode): void {
    if (mode === this.#mode) return;
    this.#mode = mode;
    this.#modeRevision += 1;
    this.#modeDelayAbort.abort();
    this.#modeDelayAbort = new AbortController();
  }

  async waitForBudget(signal?: AbortSignal): Promise<void> {
    while (true) {
      signal?.throwIfAborted();
      const remainingMs = this.#nextStartAtMs - this.#now();
      if (remainingMs <= 0) {
        this.#nextStartAtMs = this.#now() + intervalFor(this.#mode);
        return;
      }
      const revision = this.#modeRevision;
      const modeSignal = this.#modeDelayAbort.signal;
      const combined = signal === undefined
        ? modeSignal
        : AbortSignal.any([signal, modeSignal]);
      try {
        await this.#delay(remainingMs, combined);
      } catch (error) {
        signal?.throwIfAborted();
        if (revision !== this.#modeRevision) continue;
        throw error;
      }
    }
  }
}

function intervalFor(mode: CatCommandMode): number {
  return mode === "receive" ? 500 : 250;
}

function delay(milliseconds: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, milliseconds);
    timer.unref();
    const onAbort = () => {
      clearTimeout(timer);
      reject(signal.reason instanceof Error ? signal.reason : new Error("CAT command wait aborted"));
    };
    signal.addEventListener("abort", onAbort, { once: true });
  });
}
