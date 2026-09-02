export type SpectrumAnalysis = {
  bins: Uint8Array;
  noiseFloorTenthsDbm: number;
};

export const SPECTRUM_SPAN_HZ = 3_000;

export class PcmSpectrumAnalyzer {
  readonly #sampleRate: number;
  readonly #fftSize: number;
  #samples: number[] = [];

  constructor(options: { sampleRate?: number; fftSize?: number } = {}) {
    this.#sampleRate = positiveInteger(options.sampleRate ?? 16_000, "sample rate");
    this.#fftSize = positivePowerOfTwo(options.fftSize ?? 4_096, "FFT size");
    if (this.#fftSize < 256 || this.#fftSize > 8_192) {
      throw new Error("FFT size must be in 256..8192");
    }
  }

  get sampleRate(): number { return this.#sampleRate; }

  push(pcmS16Le: Uint8Array): void {
    if (!(pcmS16Le instanceof Uint8Array) || pcmS16Le.byteLength % 2 !== 0) {
      throw new Error("PCM input must contain complete 16-bit samples");
    }
    const buffer = Buffer.isBuffer(pcmS16Le)
      ? pcmS16Le
      : Buffer.from(pcmS16Le.buffer, pcmS16Le.byteOffset, pcmS16Le.byteLength);
    for (let offset = 0; offset < buffer.length; offset += 2) {
      this.#samples.push(buffer.readInt16LE(offset) / 32_768);
    }
    if (this.#samples.length > this.#fftSize) {
      this.#samples = this.#samples.slice(-this.#fftSize);
    }
  }

  analyze(binCount: 128 | 256 | 512): SpectrumAnalysis | null {
    if (binCount !== 128 && binCount !== 256 && binCount !== 512) {
      throw new Error("spectrum bins must be 128, 256 or 512");
    }
    const rawBins = Math.min(
      this.#fftSize / 2,
      Math.floor(this.#fftSize * SPECTRUM_SPAN_HZ / this.#sampleRate) + 1,
    );
    if (binCount > rawBins) {
      throw new Error("spectrum bins exceed the FFT Nyquist output");
    }
    if (this.#samples.length < this.#fftSize) {
      return null;
    }
    const real = new Float64Array(this.#fftSize);
    const imaginary = new Float64Array(this.#fftSize);
    for (let index = 0; index < this.#fftSize; index += 1) {
      const hann = 0.5 * (1 - Math.cos(2 * Math.PI * index / (this.#fftSize - 1)));
      real[index] = this.#samples[index] * hann;
    }
    fftInPlace(real, imaginary);
    const decibels = new Float64Array(rawBins);
    for (let index = 0; index < rawBins; index += 1) {
      const magnitude = Math.hypot(real[index], imaginary[index]) / (this.#fftSize / 2);
      decibels[index] = Math.max(-160, 20 * Math.log10(Math.max(magnitude, 1e-8)));
    }
    const bins = new Uint8Array(binCount);
    const groupSize = rawBins / binCount;
    for (let index = 0; index < binCount; index += 1) {
      let peakDb = -160;
      const start = Math.floor(index * groupSize);
      const end = Math.max(start + 1, Math.floor((index + 1) * groupSize));
      for (let source = start; source < end; source += 1) {
        peakDb = Math.max(peakDb, decibels[source]);
      }
      bins[index] = Math.round(Math.max(0, Math.min(255, (peakDb + 100) * 2.55)));
    }
    const sorted = [...decibels].sort((left, right) => left - right);
    const noiseFloorDb = sorted[Math.floor(sorted.length / 2)];
    return {
      bins,
      noiseFloorTenthsDbm: Math.max(-3_276, Math.min(3_276, Math.round(noiseFloorDb * 10))),
    };
  }
}

function fftInPlace(real: Float64Array, imaginary: Float64Array): void {
  const length = real.length;
  for (let index = 1, reversed = 0; index < length; index += 1) {
    let bit = length >> 1;
    for (; (reversed & bit) !== 0; bit >>= 1) {
      reversed ^= bit;
    }
    reversed ^= bit;
    if (index < reversed) {
      [real[index], real[reversed]] = [real[reversed], real[index]];
      [imaginary[index], imaginary[reversed]] = [imaginary[reversed], imaginary[index]];
    }
  }
  for (let size = 2; size <= length; size <<= 1) {
    const angle = -2 * Math.PI / size;
    const stepReal = Math.cos(angle);
    const stepImaginary = Math.sin(angle);
    for (let start = 0; start < length; start += size) {
      let twiddleReal = 1;
      let twiddleImaginary = 0;
      for (let offset = 0; offset < size / 2; offset += 1) {
        const even = start + offset;
        const odd = even + size / 2;
        const oddReal = real[odd] * twiddleReal - imaginary[odd] * twiddleImaginary;
        const oddImaginary = real[odd] * twiddleImaginary + imaginary[odd] * twiddleReal;
        real[odd] = real[even] - oddReal;
        imaginary[odd] = imaginary[even] - oddImaginary;
        real[even] += oddReal;
        imaginary[even] += oddImaginary;
        const nextReal = twiddleReal * stepReal - twiddleImaginary * stepImaginary;
        twiddleImaginary = twiddleReal * stepImaginary + twiddleImaginary * stepReal;
        twiddleReal = nextReal;
      }
    }
  }
}

function positivePowerOfTwo(value: number, field: string): number {
  const integer = positiveInteger(value, field);
  if ((integer & (integer - 1)) !== 0) {
    throw new Error(`${field} must be a power of two`);
  }
  return integer;
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}
