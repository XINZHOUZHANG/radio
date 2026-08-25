export function pcm16LeToInt16(value: Buffer): Int16Array {
  if (value.length % 2 !== 0) {
    throw new Error("PCM S16_LE byte length must be even");
  }
  const samples = new Int16Array(value.length / 2);
  for (let index = 0; index < samples.length; index += 1) {
    samples[index] = value.readInt16LE(index * 2);
  }
  return samples;
}

export function int16ToPcm16Le(value: Int16Array): Buffer {
  const pcm = Buffer.allocUnsafe(value.length * 2);
  for (let index = 0; index < value.length; index += 1) {
    pcm.writeInt16LE(value[index], index * 2);
  }
  return pcm;
}

export function resampleInt16(
  input: Int16Array,
  inputSampleRate: number,
  outputSampleRate: number,
): Int16Array {
  validateSampleRate(inputSampleRate, "input sample rate");
  validateSampleRate(outputSampleRate, "output sample rate");
  if (input.length === 0) {
    return new Int16Array(0);
  }
  if (inputSampleRate === outputSampleRate) {
    return input.slice();
  }
  const outputLength = Math.max(
    1,
    Math.round(input.length * outputSampleRate / inputSampleRate),
  );
  const output = new Int16Array(outputLength);
  const step = inputSampleRate / outputSampleRate;
  for (let index = 0; index < output.length; index += 1) {
    const position = index * step;
    const left = Math.min(input.length - 1, Math.floor(position));
    const right = Math.min(input.length - 1, left + 1);
    const fraction = position - left;
    output[index] = clampInt16(Math.round(
      input[left] + (input[right] - input[left]) * fraction,
    ));
  }
  return output;
}

/**
 * Stateful linear resampler for a continuous mono PCM stream. One trailing
 * sample is retained so interpolation remains continuous across pipe chunks.
 */
export class StreamingPcm16Resampler {
  readonly #inputSampleRate: number;
  readonly #outputSampleRate: number;
  readonly #step: number;
  #previousSample: number | null = null;
  #position = 0;

  constructor(inputSampleRate: number, outputSampleRate: number) {
    validateSampleRate(inputSampleRate, "input sample rate");
    validateSampleRate(outputSampleRate, "output sample rate");
    this.#inputSampleRate = inputSampleRate;
    this.#outputSampleRate = outputSampleRate;
    this.#step = inputSampleRate / outputSampleRate;
  }

  push(input: Int16Array): Int16Array {
    if (input.length === 0) {
      return new Int16Array(0);
    }
    const source = this.#previousSample === null
      ? input
      : prependSample(this.#previousSample, input);
    const estimatedLength = Math.max(
      0,
      Math.ceil((source.length - 1 - this.#position) / this.#step) + 1,
    );
    const output = new Int16Array(estimatedLength);
    let outputLength = 0;
    while (this.#position < source.length - 1) {
      const left = Math.floor(this.#position);
      const fraction = this.#position - left;
      output[outputLength] = clampInt16(Math.round(
        source[left] + (source[left + 1] - source[left]) * fraction,
      ));
      outputLength += 1;
      this.#position += this.#step;
    }
    const retainedIndex = source.length - 1;
    this.#position -= retainedIndex;
    this.#previousSample = source[retainedIndex];
    return outputLength === output.length ? output : output.slice(0, outputLength);
  }

  reset(): void {
    this.#previousSample = null;
    this.#position = 0;
  }

  get inputSampleRate(): number {
    return this.#inputSampleRate;
  }

  get outputSampleRate(): number {
    return this.#outputSampleRate;
  }
}

function prependSample(previous: number, input: Int16Array): Int16Array {
  const joined = new Int16Array(input.length + 1);
  joined[0] = previous;
  joined.set(input, 1);
  return joined;
}

function validateSampleRate(value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value < 8_000 || value > 192_000) {
    throw new Error(`${field} must be in 8000..192000 Hz`);
  }
}

function clampInt16(value: number): number {
  return Math.max(-32_768, Math.min(32_767, value));
}
