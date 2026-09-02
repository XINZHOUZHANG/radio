import { slotDurationMs } from "./slots.ts";
import type { DigitalMode } from "./types.ts";

export type CompletedPcmSlot = {
  mode: DigitalMode;
  slotStartMs: number;
  slotEndMs: number;
  sampleRate: number;
  pcm: Int16Array;
};

export type PcmSlotAssemblerOptions = {
  mode: DigitalMode;
  sampleRate?: number;
  maxMissingMs?: number;
  emitAfterMs?: number;
  onSlot(slot: CompletedPcmSlot): void;
};

type ActiveSlot = {
  startTick: number;
  pcm: Int16Array;
  firstWritten: number;
  lastWritten: number;
  internalMissing: number;
  emitted: boolean;
};

/** Aligns continuous PCM to exact FT8/FT4 UTC slots without trusting pipe chunk boundaries. */
export class UtcPcmSlotAssembler {
  readonly #mode: DigitalMode;
  readonly #sampleRate: number;
  readonly #slotSamples: number;
  readonly #emitAfterSamples: number;
  readonly #maxMissingSamples: number;
  readonly #onSlot: (slot: CompletedPcmSlot) => void;
  #active: ActiveSlot | null = null;

  constructor(options: PcmSlotAssemblerOptions) {
    this.#mode = options.mode;
    this.#sampleRate = safeSampleRate(options.sampleRate ?? 12_000);
    const slotMs = slotDurationMs(this.#mode);
    this.#slotSamples = Math.round(slotMs * this.#sampleRate / 1_000);
    const emitAfterMs = finiteRange(options.emitAfterMs ?? slotMs, "emitAfterMs", 1, slotMs);
    this.#emitAfterSamples = Math.round(emitAfterMs * this.#sampleRate / 1_000);
    const maxMissingMs = finiteRange(options.maxMissingMs ?? 150, "maxMissingMs", 0, 1_000);
    this.#maxMissingSamples = Math.round(maxMissingMs * this.#sampleRate / 1_000);
    this.#onSlot = options.onSlot;
  }

  push(pcm: Int16Array, startedAtMs: number): void {
    if (!(pcm instanceof Int16Array)) {
      throw new TypeError("slot PCM must be an Int16Array");
    }
    if (pcm.length === 0) {
      return;
    }
    const ticksPerMs = this.#sampleRate / 1_000;
    if (!Number.isFinite(startedAtMs) || startedAtMs < 0) {
      throw new Error("PCM start time must be a non-negative timestamp");
    }
    let absoluteTick = Math.round(startedAtMs * ticksPerMs);
    if (!Number.isSafeInteger(absoluteTick)) {
      throw new Error("PCM start time is outside the supported range");
    }
    let sourceOffset = 0;
    while (sourceOffset < pcm.length) {
      const slotStartTick = Math.floor(absoluteTick / this.#slotSamples) * this.#slotSamples;
      if (this.#active !== null && slotStartTick < this.#active.startTick) {
        throw new Error("PCM chunks must arrive in chronological order");
      }
      if (this.#active === null || slotStartTick > this.#active.startTick) {
        this.#finishActive();
        this.#active = this.#newSlot(slotStartTick);
      }
      const active = this.#active;
      const targetOffset = absoluteTick - active.startTick;
      const available = this.#slotSamples - targetOffset;
      const count = Math.min(pcm.length - sourceOffset, available);
      if (count <= 0) {
        this.#finishActive();
        continue;
      }
      if (active.lastWritten >= 0 && targetOffset > active.lastWritten) {
        active.internalMissing += targetOffset - active.lastWritten;
      }
      active.pcm.set(pcm.subarray(sourceOffset, sourceOffset + count), targetOffset);
      active.firstWritten = Math.min(active.firstWritten, targetOffset);
      active.lastWritten = Math.max(active.lastWritten, targetOffset + count);
      this.#emitEarlyIfReady(active);
      sourceOffset += count;
      absoluteTick += count;
      if (active.lastWritten >= this.#slotSamples) {
        this.#finishActive();
      }
    }
  }

  reset(): void {
    this.#active = null;
  }

  #newSlot(startTick: number): ActiveSlot {
    return {
      startTick,
      pcm: new Int16Array(this.#slotSamples),
      firstWritten: this.#slotSamples,
      lastWritten: -1,
      internalMissing: 0,
      emitted: false,
    };
  }

  #emitEarlyIfReady(active: ActiveSlot): void {
    if (
      active.emitted ||
      active.lastWritten < this.#emitAfterSamples ||
      active.firstWritten + active.internalMissing > this.#maxMissingSamples
    ) {
      return;
    }
    this.#emit(active);
  }

  #finishActive(): void {
    const active = this.#active;
    this.#active = null;
    if (active === null || active.lastWritten < 0 || active.emitted) {
      return;
    }
    const leadingMissing = active.firstWritten;
    const trailingMissing = Math.max(0, this.#slotSamples - active.lastWritten);
    if (leadingMissing + active.internalMissing + trailingMissing > this.#maxMissingSamples) {
      return;
    }
    this.#emit(active);
  }

  #emit(active: ActiveSlot): void {
    active.emitted = true;
    const slotStartMs = Math.round(active.startTick * 1_000 / this.#sampleRate);
    this.#onSlot({
      mode: this.#mode,
      slotStartMs,
      slotEndMs: slotStartMs + slotDurationMs(this.#mode),
      sampleRate: this.#sampleRate,
      pcm: active.pcm.slice(),
    });
  }
}

function safeSampleRate(value: number): number {
  if (!Number.isSafeInteger(value) || value < 1_000 || value > 192_000) {
    throw new Error("sampleRate must be in 1000..192000 Hz");
  }
  return value;
}

function finiteRange(value: number, field: string, minimum: number, maximum: number): number {
  if (!Number.isFinite(value) || value < minimum || value > maximum) {
    throw new Error(`${field} must be in ${minimum}..${maximum}`);
  }
  return value;
}
