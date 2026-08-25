import type { MediaPolicy } from "./adaptive-policy.ts";
import type { MediaFrame } from "./frame.ts";
import type {
  MediaWorker,
  MediaWorkerFactory,
  MediaWorkerOutput,
  SpectrumCapability,
} from "./media-hub.ts";

export const createSyntheticMediaWorker: MediaWorkerFactory = async (
  _profile,
  _radioSlot,
  output,
) => new SyntheticMediaWorker(output);

export class SyntheticMediaWorker implements MediaWorker {
  readonly spectrumCapability: SpectrumCapability = {
    available: true,
    source: "synthetic",
    simulated: true,
    supportsWaterfall: true,
    maxBins: 512,
    maxFps: 5,
    spanHz: 3_000,
  };
  readonly #output: MediaWorkerOutput;
  #policy: MediaPolicy = {
    tier: "normal",
    opusBitrate: 20_000,
    opusFrameMs: 20,
    spectrumBins: 512,
    spectrumFps: 5,
  };
  #timer: ReturnType<typeof setInterval> | null = null;
  #phase = 0;
  #closed = false;

  constructor(output: MediaWorkerOutput) {
    this.#output = output;
    this.#resetTimer();
  }

  updatePolicy(policy: MediaPolicy): void {
    if (this.#closed) {
      throw new Error("synthetic media worker is closed");
    }
    this.#policy = { ...policy };
    this.#resetTimer();
  }

  writeAudioUplink(_frame: MediaFrame): boolean {
    return !this.#closed;
  }

  async close(): Promise<void> {
    this.#closed = true;
    if (this.#timer !== null) {
      clearInterval(this.#timer);
      this.#timer = null;
    }
  }

  #resetTimer(): void {
    if (this.#timer !== null) {
      clearInterval(this.#timer);
      this.#timer = null;
    }
    if (this.#closed || this.#policy.spectrumBins === 0 || this.#policy.spectrumFps === 0) {
      return;
    }
    this.#timer = setInterval(() => this.#emitSpectrum(), Math.ceil(1_000 / this.#policy.spectrumFps));
    this.#timer.unref();
  }

  #emitSpectrum(): void {
    const bins = new Uint8Array(this.#policy.spectrumBins);
    for (let index = 0; index < bins.length; index += 1) {
      const baseline = 20 + 6 * Math.sin(index * 0.19 + this.#phase);
      const first = 145 * gaussian(index, bins.length * 0.36 + Math.sin(this.#phase) * 3, 2.5);
      const second = 100 * gaussian(index, bins.length * 0.67, 5);
      bins[index] = Math.max(0, Math.min(255, Math.round(baseline + first + second)));
    }
    this.#phase = (this.#phase + 0.15) % (Math.PI * 2);
    this.#output.spectrum({
      centerFrequencyHz: 14_074_000,
      spanHz: 3_000,
      noiseFloorTenthsDbm: -1_200,
      bins,
    });
  }
}

function gaussian(value: number, center: number, width: number): number {
  const distance = (value - center) / width;
  return Math.exp(-0.5 * distance * distance);
}
