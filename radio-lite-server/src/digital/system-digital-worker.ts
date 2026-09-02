import type { RadioProfile } from "../config/types.ts";
import type {
  DigitalAudioConsumer,
  DigitalAudioPort,
  PcmCaptureChunk,
} from "../media/media-hub.ts";
import {
  pcm16LeToInt16,
  StreamingPcm16Resampler,
} from "../media/pcm-resampler.ts";
import {
  type CompletedPcmSlot,
  UtcPcmSlotAssembler,
} from "./pcm-slot-assembler.ts";
import type { DigitalDecodeBatchInput, DigitalMode, RawDigitalDecode } from "./types.ts";
import type {
  DigitalEncodeRequest,
  DigitalWorker,
  DigitalWorkerOutput,
  PreparedDigitalTransmission,
} from "./worker.ts";
import {
  WsjtxProcessClient,
  type WsjtxDecodeResult,
  type WsjtxEncodeResult,
} from "./wsjtx-process-client.ts";

const DSP_SAMPLE_RATE = 12_000;
const NOMINAL_AUDIO_FREQUENCY_HZ = 1_500;
const MAX_CAPTURE_CLOCK_JUMP_MS = 250;

export type WsjtxClient = {
  start(): Promise<void>;
  encode(value: {
    mode: DigitalMode;
    message: string;
    audioFrequencyHz: number;
  }): Promise<WsjtxEncodeResult>;
  decode(value: {
    mode: DigitalMode;
    pcm: Int16Array;
    nominalFrequencyHz: number;
    myCall: string;
    myGrid?: string;
  }): Promise<WsjtxDecodeResult>;
  close(): Promise<void>;
};

export type SystemDigitalWorkerOptions = {
  openAudio(consumer: DigitalAudioConsumer): Promise<DigitalAudioPort>;
  clientFactory?: (onFault: (error: unknown) => void) => WsjtxClient;
  now?: () => number;
  nominalAudioFrequencyHz?: number;
};

export class SystemDigitalWorker implements DigitalWorker {
  readonly #profile: RadioProfile;
  readonly #openAudio: (consumer: DigitalAudioConsumer) => Promise<DigitalAudioPort>;
  readonly #client: WsjtxClient;
  readonly #now: () => number;
  readonly #nominalAudioFrequencyHz: number;
  readonly #assemblers: UtcPcmSlotAssembler[];
  readonly #pendingSlots: CompletedPcmSlot[] = [];
  #output: DigitalWorkerOutput | null = null;
  #audio: DigitalAudioPort | null = null;
  #resampler: StreamingPcm16Resampler | null = null;
  #captureInputSampleRate: number | null = null;
  #expectedCaptureStartMs: number | null = null;
  #nextResampledStartMs: number | null = null;
  #decodeBusy = false;
  #transmitting = false;
  #started = false;
  #closed = false;
  #faulted = false;

  constructor(profile: RadioProfile, options: SystemDigitalWorkerOptions) {
    this.#profile = profile;
    this.#openAudio = options.openAudio;
    this.#now = options.now ?? Date.now;
    this.#nominalAudioFrequencyHz = boundedInteger(
      options.nominalAudioFrequencyHz ?? NOMINAL_AUDIO_FREQUENCY_HZ,
      "nominal digital audio frequency",
      200,
      5_000,
    );
    this.#client = options.clientFactory?.((error) => this.#fail(error)) ??
      new WsjtxProcessClient({ onFault: (error) => this.#fail(error) });
    this.#assemblers = (["FT8", "FT4"] as const).map((mode) =>
      new UtcPcmSlotAssembler({
        mode,
        sampleRate: DSP_SAMPLE_RATE,
        emitAfterMs: mode === "FT8" ? 13_000 : 6_000,
        onSlot: (slot) => this.#enqueueDecode(slot),
      }),
    );
  }

  async start(output: DigitalWorkerOutput): Promise<void> {
    if (this.#closed) {
      throw new Error("system digital worker is closed");
    }
    if (this.#started || this.#output !== null) {
      throw new Error("system digital worker is already started");
    }
    this.#output = output;
    try {
      await this.#client.start();
      this.#audio = await this.#openAudio({
        pcm: (value) => this.#capture(value),
        fault: (error) => this.#fail(error),
      });
      this.#started = true;
    } catch (error) {
      await this.#audio?.close().catch(() => undefined);
      this.#audio = null;
      await this.#client.close().catch(() => undefined);
      this.#output = null;
      throw error;
    }
  }

  async prepare(request: DigitalEncodeRequest): Promise<PreparedDigitalTransmission> {
    this.#assertReady();
    const encoded = await this.#client.encode({
      mode: request.mode,
      message: request.message,
      audioFrequencyHz: request.audioFrequencyHz,
    });
    if (
      encoded.sampleRate !== DSP_SAMPLE_RATE ||
      !(encoded.pcm instanceof Int16Array) ||
      encoded.pcm.length === 0 ||
      encoded.durationMs < 1 || encoded.durationMs > 20_000
    ) {
      throw new Error("WSJT-X encoder returned invalid PCM metadata");
    }
    return {
      ...request,
      sampleRate: encoded.sampleRate,
      durationMs: encoded.durationMs,
      payload: encoded.pcm,
    };
  }

  async transmit(prepared: PreparedDigitalTransmission, signal: AbortSignal): Promise<void> {
    this.#assertReady();
    if (this.#transmitting) {
      throw new Error("digital transmission is already active");
    }
    if (!(prepared.payload instanceof Int16Array) || prepared.payload.length === 0) {
      throw new Error("prepared digital transmission has invalid PCM");
    }
    const audio = this.#audio;
    if (audio === null) {
      throw new Error("shared radio audio is unavailable");
    }
    this.#transmitting = true;
    this.#pendingSlots.length = 0;
    this.#resetCapture();
    try {
      await audio.play(prepared.payload, prepared.sampleRate, signal);
    } finally {
      this.#transmitting = false;
      this.#resetCapture();
    }
  }

  async stopTransmission(): Promise<void> {
    this.#pendingSlots.length = 0;
    this.#transmitting = false;
    this.#resetCapture();
    await this.#audio?.stop();
    this.#resetCapture();
  }

  async close(): Promise<void> {
    if (this.#closed) {
      return;
    }
    this.#closed = true;
    this.#pendingSlots.length = 0;
    await this.stopTransmission().catch(() => undefined);
    const audio = this.#audio;
    this.#audio = null;
    await audio?.close().catch(() => undefined);
    await this.#client.close().catch(() => undefined);
    this.#output = null;
  }

  #capture(value: PcmCaptureChunk): void {
    if (this.#closed || this.#faulted || !this.#started || this.#transmitting) {
      return;
    }
    const input = pcm16LeToInt16(value.pcm);
    const durationMs = input.length * 1_000 / value.sampleRate;
    if (
      this.#resampler === null ||
      this.#captureInputSampleRate !== value.sampleRate ||
      this.#expectedCaptureStartMs === null ||
      Math.abs(value.startedAtMs - this.#expectedCaptureStartMs) > MAX_CAPTURE_CLOCK_JUMP_MS
    ) {
      this.#resetCapture(value.sampleRate, value.startedAtMs);
    }
    const resampler = this.#resampler;
    const outputStartMs = this.#nextResampledStartMs;
    if (resampler === null || outputStartMs === null) {
      throw new Error("digital PCM resampler could not initialize");
    }
    const resampled = value.sampleRate === DSP_SAMPLE_RATE ? input : resampler.push(input);
    this.#expectedCaptureStartMs = value.startedAtMs + durationMs;
    this.#nextResampledStartMs = outputStartMs + resampled.length * 1_000 / DSP_SAMPLE_RATE;
    if (resampled.length === 0) {
      return;
    }
    for (const assembler of this.#assemblers) {
      assembler.push(resampled, outputStartMs);
    }
  }

  #enqueueDecode(slot: CompletedPcmSlot): void {
    if (this.#closed || this.#faulted || this.#transmitting) {
      return;
    }
    if (!this.#pendingSlots.some(
      (candidate) => candidate.mode === slot.mode && candidate.slotStartMs === slot.slotStartMs,
    )) {
      this.#pendingSlots.push(slot);
      this.#pendingSlots.sort(
        (left, right) => left.slotStartMs - right.slotStartMs || left.mode.localeCompare(right.mode),
      );
      while (this.#pendingSlots.length > 4) {
        this.#pendingSlots.shift();
      }
    }
    void this.#drainDecodeQueue();
  }

  async #drainDecodeQueue(): Promise<void> {
    if (this.#decodeBusy || this.#closed || this.#faulted) {
      return;
    }
    this.#decodeBusy = true;
    try {
      while (!this.#closed && !this.#faulted && this.#pendingSlots.length > 0) {
        const slot = this.#pendingSlots.shift()!;
        const decoded = await this.#client.decode({
          mode: slot.mode,
          pcm: slot.pcm,
          nominalFrequencyHz: this.#nominalAudioFrequencyHz,
          myCall: this.#profile.station.callsign,
          myGrid: this.#profile.station.grid,
        });
        if (this.#closed || this.#faulted || this.#transmitting) {
          continue;
        }
        const batch: DigitalDecodeBatchInput = {
          radioId: this.#profile.id,
          mode: slot.mode,
          slotStartMs: slot.slotStartMs,
          receivedAtMs: Math.max(slot.slotEndMs, Math.trunc(this.#now())),
          frames: decoded.frames.map(safeDecodeFrame).filter(
            (frame): frame is RawDigitalDecode => frame !== null,
          ),
        };
        this.#output?.decoded(batch);
      }
    } catch (error) {
      this.#fail(error);
    } finally {
      this.#decodeBusy = false;
    }
  }

  #resetCapture(sampleRate?: number, startedAtMs?: number): void {
    for (const assembler of this.#assemblers) {
      assembler.reset();
    }
    if (sampleRate === undefined || startedAtMs === undefined) {
      this.#resampler = null;
      this.#captureInputSampleRate = null;
      this.#expectedCaptureStartMs = null;
      this.#nextResampledStartMs = null;
      return;
    }
    this.#resampler = new StreamingPcm16Resampler(sampleRate, DSP_SAMPLE_RATE);
    this.#captureInputSampleRate = sampleRate;
    this.#expectedCaptureStartMs = startedAtMs;
    this.#nextResampledStartMs = startedAtMs;
  }

  #fail(error: unknown): void {
    if (this.#faulted || this.#closed) {
      return;
    }
    this.#faulted = true;
    this.#pendingSlots.length = 0;
    this.#transmitting = false;
    this.#resetCapture();
    this.#output?.fault(error);
    void this.#audio?.stop().catch(() => undefined);
  }

  #assertReady(): void {
    if (this.#closed) {
      throw new Error("system digital worker is closed");
    }
    if (!this.#started || this.#output === null || this.#audio === null || this.#faulted) {
      throw new Error("system digital worker is unavailable");
    }
  }
}

function safeDecodeFrame(value: {
  message: string;
  snrDb: number;
  deltaTimeSeconds: number;
  audioFrequencyHz: number;
  confidence: number;
}): RawDigitalDecode | null {
  if (
    typeof value.message !== "string" || value.message.trim().length === 0 ||
    !Number.isFinite(value.snrDb) || !Number.isFinite(value.deltaTimeSeconds)
  ) {
    return null;
  }
  const frequency = Number.isFinite(value.audioFrequencyHz)
    ? Math.round(value.audioFrequencyHz)
    : NOMINAL_AUDIO_FREQUENCY_HZ;
  return {
    message: value.message.trim(),
    snrDb: Math.max(-60, Math.min(50, value.snrDb)),
    deltaTimeSeconds: Math.max(-10, Math.min(10, value.deltaTimeSeconds)),
    audioFrequencyHz: Math.max(200, Math.min(5_000, frequency)),
    confidence: Number.isFinite(value.confidence)
      ? Math.max(0, Math.min(1, value.confidence))
      : 1,
  };
}

function boundedInteger(value: number, field: string, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${field} must be in ${minimum}..${maximum}`);
  }
  return value;
}
