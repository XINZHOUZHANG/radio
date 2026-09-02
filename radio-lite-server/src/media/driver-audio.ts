export const DRIVER_AUDIO_SAMPLE_RATE_HZ = 12_000 as const;
export const DRIVER_AUDIO_CHANNEL_COUNT = 1 as const;

export interface DriverAudioSource {
  readonly sampleRateHz: typeof DRIVER_AUDIO_SAMPLE_RATE_HZ;
  readonly channelCount: typeof DRIVER_AUDIO_CHANNEL_COUNT;
  read(): Promise<Int16Array>;
}

export interface DriverAudioSink {
  readonly sampleRateHz: typeof DRIVER_AUDIO_SAMPLE_RATE_HZ;
  readonly channelCount: typeof DRIVER_AUDIO_CHANNEL_COUNT;
  write(frame: Int16Array): Promise<void>;
}

export interface DriverAudioDuplex extends DriverAudioSource, DriverAudioSink {
  close(): void;
}

export class DriverAudioClosedError extends Error {
  constructor() {
    super("driver audio is closed");
    this.name = "DriverAudioClosedError";
  }
}

type PendingRead = {
  resolve: (frame: Int16Array) => void;
  reject: (error: Error) => void;
};

type PendingWrite = {
  reject: (error: Error) => void;
};

export class BoundedDriverAudioDuplex implements DriverAudioDuplex {
  readonly sampleRateHz = DRIVER_AUDIO_SAMPLE_RATE_HZ;
  readonly channelCount = DRIVER_AUDIO_CHANNEL_COUNT;

  readonly #writeFrame: (frame: Int16Array) => Promise<void> | void;
  readonly #maxRxFrames: number;
  readonly #rxFrames: Int16Array[] = [];
  readonly #pendingReads: PendingRead[] = [];
  readonly #pendingWrites = new Set<PendingWrite>();
  #closedError: DriverAudioClosedError | null = null;

  constructor(
    writeFrame: (frame: Int16Array) => Promise<void> | void,
    options: { maxRxFrames?: number } = {},
  ) {
    const maxRxFrames = options.maxRxFrames ?? 32;
    if (!Number.isSafeInteger(maxRxFrames) || maxRxFrames < 1) {
      throw new RangeError("maxRxFrames must be a positive integer");
    }
    this.#writeFrame = writeFrame;
    this.#maxRxFrames = maxRxFrames;
  }

  pushRx(frame: Int16Array): boolean {
    if (this.#closedError !== null) return false;
    const copy = frame.slice();
    const reader = this.#pendingReads.shift();
    if (reader !== undefined) {
      reader.resolve(copy);
      return true;
    }
    if (this.#rxFrames.length === this.#maxRxFrames) this.#rxFrames.shift();
    this.#rxFrames.push(copy);
    return true;
  }

  read(): Promise<Int16Array> {
    const frame = this.#rxFrames.shift();
    if (frame !== undefined) return Promise.resolve(frame);
    if (this.#closedError !== null) return Promise.reject(this.#closedError);
    return new Promise<Int16Array>((resolve, reject) => {
      this.#pendingReads.push({ resolve, reject });
    });
  }

  write(frame: Int16Array): Promise<void> {
    if (this.#closedError !== null) return Promise.reject(this.#closedError);
    const copy = frame.slice();
    return new Promise<void>((resolve, reject) => {
      const pending = { reject };
      this.#pendingWrites.add(pending);
      let completion: Promise<void>;
      try {
        completion = Promise.resolve(this.#writeFrame(copy));
      } catch (error) {
        completion = Promise.reject(error);
      }
      void completion.then(
        () => {
          if (this.#pendingWrites.delete(pending)) resolve();
        },
        (error: unknown) => {
          if (this.#pendingWrites.delete(pending)) reject(error);
        },
      );
    });
  }

  close(): void {
    if (this.#closedError !== null) return;
    this.#closedError = new DriverAudioClosedError();
    this.#rxFrames.length = 0;
    for (const reader of this.#pendingReads.splice(0)) reader.reject(this.#closedError);
    for (const writer of this.#pendingWrites) writer.reject(this.#closedError);
    this.#pendingWrites.clear();
  }
}
