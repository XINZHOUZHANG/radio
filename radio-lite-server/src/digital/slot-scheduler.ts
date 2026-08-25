import { nextSlotStart } from "./slots.ts";
import type { DigitalMode, SlotParity } from "./types.ts";

export type SlotSchedulerOptions = {
  now?: () => number;
  setTimer?: (callback: () => void, delayMs: number) => ReturnType<typeof setTimeout>;
  clearTimer?: (timer: ReturnType<typeof setTimeout>) => void;
  onError?: (error: unknown) => void;
};

export class UtcSlotScheduler {
  readonly #now: () => number;
  readonly #setTimer: (callback: () => void, delayMs: number) => ReturnType<typeof setTimeout>;
  readonly #clearTimer: (timer: ReturnType<typeof setTimeout>) => void;
  readonly #onError: (error: unknown) => void;
  #timer: ReturnType<typeof setTimeout> | null = null;
  #generation = 0;

  constructor(options: SlotSchedulerOptions = {}) {
    this.#now = options.now ?? Date.now;
    this.#setTimer = options.setTimer ?? setTimeout;
    this.#clearTimer = options.clearTimer ?? clearTimeout;
    this.#onError = options.onError ?? (() => undefined);
  }

  schedule(
    mode: DigitalMode,
    parity: SlotParity,
    callback: (slotStartMs: number) => void | Promise<void>,
  ): number {
    this.cancel();
    const generation = ++this.#generation;
    const now = this.#now();
    const slotStartMs = nextSlotStart(mode, now, parity);
    const timer = this.#setTimer(() => {
      if (generation !== this.#generation) {
        return;
      }
      this.#timer = null;
      Promise.resolve(callback(slotStartMs)).catch(this.#onError);
    }, Math.max(0, slotStartMs - now));
    if (typeof timer === "object" && timer !== null && "unref" in timer) {
      timer.unref();
    }
    this.#timer = timer;
    return slotStartMs;
  }

  cancel(): void {
    this.#generation += 1;
    if (this.#timer !== null) {
      this.#clearTimer(this.#timer);
      this.#timer = null;
    }
  }
}
