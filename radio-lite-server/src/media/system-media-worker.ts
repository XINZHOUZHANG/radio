import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

import type { AudioEndpoint, RadioProfile } from "../config/types.ts";
import type { MediaPolicy } from "./adaptive-policy.ts";
import type {
  MediaWorker,
  MediaWorkerFactory,
  MediaWorkerOutput,
} from "./media-hub.ts";
import type { MediaFrame } from "./frame.ts";
import { OggOpusPacketReader, OggOpusWriter } from "./ogg-opus.ts";
import { PcmSpectrumAnalyzer } from "./spectrum-analyzer.ts";

export type MediaCommand = {
  file: string;
  args: string[];
};

export type SystemMediaWorkerOptions = {
  spawnProcess?: typeof spawn;
  readCenterFrequencyHz?: () => Promise<number>;
  now?: () => number;
};

const SAMPLE_RATE = 16_000;
const CHANNELS = 1;
const MAX_PROCESS_INPUT_BYTES = 64 * 1_024;

export function captureCommand(endpoint: AudioEndpoint): MediaCommand {
  return endpoint.backend === "alsa"
    ? {
        file: "arecord",
        args: ["-q", "-D", endpoint.id, "-t", "raw", "-f", "S16_LE", "-c", "1", "-r", String(SAMPLE_RATE)],
      }
    : {
        file: "parec",
        args: ["--raw", `--device=${endpoint.id}`, "--format=s16le", "--channels=1", `--rate=${SAMPLE_RATE}`],
      };
}

export function playbackCommand(endpoint: AudioEndpoint): MediaCommand {
  return endpoint.backend === "alsa"
    ? {
        file: "aplay",
        args: ["-q", "-D", endpoint.id, "-t", "raw", "-f", "S16_LE", "-c", "1", "-r", String(SAMPLE_RATE)],
      }
    : {
        file: "pacat",
        args: ["--playback", "--raw", `--device=${endpoint.id}`, "--format=s16le", "--channels=1", `--rate=${SAMPLE_RATE}`],
      };
}

export function opusEncoderCommand(bitrate: number): MediaCommand {
  if (!Number.isSafeInteger(bitrate) || bitrate < 6_000 || bitrate > 64_000) {
    throw new Error("Opus bitrate must be in 6000..64000 bit/s");
  }
  return {
    file: "opusenc",
    args: [
      "--quiet",
      "--raw",
      `--raw-rate=${SAMPLE_RATE}`,
      `--raw-chan=${CHANNELS}`,
      "--framesize=20",
      `--bitrate=${Math.round(bitrate / 1_000)}`,
      "--max-delay=20",
      "-",
      "-",
    ],
  };
}

export function opusDecoderCommand(): MediaCommand {
  return {
    file: "opusdec",
    args: ["--quiet", "--rate", String(SAMPLE_RATE), "-", "-"],
  };
}

export const createSystemMediaWorker: MediaWorkerFactory = async (
  profile,
  _radioSlot,
  output,
) => SystemMediaWorker.create(profile, output);

export class SystemMediaWorker implements MediaWorker {
  readonly #profile: RadioProfile;
  readonly #output: MediaWorkerOutput;
  readonly #spawnProcess: typeof spawn;
  readonly #readCenterFrequencyHz: () => Promise<number>;
  readonly #now: () => number;
  readonly #analyzer = new PcmSpectrumAnalyzer({ sampleRate: SAMPLE_RATE, fftSize: 1_024 });
  readonly #uplinkWriter = new OggOpusWriter({ inputSampleRate: SAMPLE_RATE });
  readonly #expectedExit = new WeakSet<ChildProcessWithoutNullStreams>();
  readonly #diagnostics = new WeakMap<ChildProcessWithoutNullStreams, string[]>();
  #capture: ChildProcessWithoutNullStreams | null = null;
  #encoder: ChildProcessWithoutNullStreams | null = null;
  #decoder: ChildProcessWithoutNullStreams | null = null;
  #playback: ChildProcessWithoutNullStreams | null = null;
  #encoderReader = new OggOpusPacketReader();
  #policy: MediaPolicy = {
    tier: "normal",
    opusBitrate: 20_000,
    opusFrameMs: 20,
    spectrumBins: 512,
    spectrumFps: 5,
  };
  #spectrumTimer: ReturnType<typeof setInterval> | null = null;
  #spectrumBusy = false;
  #lastCenterFrequencyHz = 0;
  #lastCenterReadAtMs = Number.NEGATIVE_INFINITY;
  #pcmRemainder = Buffer.alloc(0);
  #closed = false;
  #faulted = false;
  #encoderTail: Promise<void> = Promise.resolve();

  private constructor(
    profile: RadioProfile,
    output: MediaWorkerOutput,
    options: SystemMediaWorkerOptions,
  ) {
    this.#profile = profile;
    this.#output = output;
    this.#spawnProcess = options.spawnProcess ?? spawn;
    this.#readCenterFrequencyHz = options.readCenterFrequencyHz ?? (async () => 0);
    this.#now = options.now ?? Date.now;
  }

  static async create(
    profile: RadioProfile,
    output: MediaWorkerOutput,
    options: SystemMediaWorkerOptions = {},
  ): Promise<SystemMediaWorker> {
    if (process.platform !== "linux" && options.spawnProcess === undefined) {
      throw new Error("system audio media worker is supported on Linux only");
    }
    const worker = new SystemMediaWorker(profile, output, options);
    try {
      await worker.#start();
      return worker;
    } catch (error) {
      await worker.close();
      throw error;
    }
  }

  updatePolicy(policy: MediaPolicy): Promise<void> {
    if (this.#closed) {
      return Promise.reject(new Error("media worker is closed"));
    }
    const previousBitrate = this.#policy.opusBitrate;
    this.#policy = { ...policy };
    this.#resetSpectrumTimer();
    if (policy.opusBitrate === previousBitrate) {
      return Promise.resolve();
    }
    const operation = this.#encoderTail.then(
      () => this.#replaceEncoder(policy.opusBitrate),
      () => this.#replaceEncoder(policy.opusBitrate),
    );
    this.#encoderTail = operation.then(() => undefined, () => undefined);
    return operation;
  }

  writeAudioUplink(frame: MediaFrame): boolean {
    const decoder = this.#decoder;
    if (this.#closed || decoder === null || decoder.stdin.destroyed || !decoder.stdin.writable) {
      throw new Error("Opus decoder input is unavailable");
    }
    if (decoder.stdin.writableLength > MAX_PROCESS_INPUT_BYTES) {
      return false;
    }
    return decoder.stdin.write(this.#uplinkWriter.packet(frame.payload));
  }

  async close(): Promise<void> {
    if (this.#closed) {
      return;
    }
    this.#closed = true;
    if (this.#spectrumTimer !== null) {
      clearInterval(this.#spectrumTimer);
      this.#spectrumTimer = null;
    }
    const children = [this.#capture, this.#encoder, this.#decoder, this.#playback]
      .filter((child): child is ChildProcessWithoutNullStreams => child !== null);
    this.#capture = null;
    this.#encoder = null;
    this.#decoder = null;
    this.#playback = null;
    await Promise.all(children.map((child) => this.#terminate(child)));
  }

  async #start(): Promise<void> {
    this.#capture = await this.#spawn(captureCommand(this.#profile.audioInput), "audio capture");
    this.#encoder = await this.#spawn(opusEncoderCommand(this.#policy.opusBitrate), "Opus encoder");
    this.#decoder = await this.#spawn(opusDecoderCommand(), "Opus decoder");
    this.#playback = await this.#spawn(playbackCommand(this.#profile.audioOutput), "audio playback");
    this.#wireCapture();
    this.#wireEncoder(this.#encoder);
    this.#wirePlayback();
    this.#decoder.stdin.write(this.#uplinkWriter.headers());
    this.#resetSpectrumTimer();
  }

  #wireCapture(): void {
    this.#capture?.stdout.on("data", (chunk: Buffer) => {
      const encoder = this.#encoder;
      if (encoder !== null && encoder.stdin.writable && !encoder.stdin.destroyed) {
        if (encoder.stdin.writableLength <= MAX_PROCESS_INPUT_BYTES) {
          encoder.stdin.write(chunk);
        }
      }
      let analysis = this.#pcmRemainder.length === 0
        ? Buffer.from(chunk)
        : Buffer.concat([this.#pcmRemainder, chunk]);
      if (analysis.length % 2 !== 0) {
        this.#pcmRemainder = Buffer.from(analysis.subarray(-1));
        analysis = analysis.subarray(0, -1);
      } else {
        this.#pcmRemainder = Buffer.alloc(0);
      }
      if (analysis.length > 0) {
        this.#analyzer.push(analysis);
      }
    });
  }

  #wireEncoder(encoder: ChildProcessWithoutNullStreams): void {
    const reader = this.#encoderReader;
    encoder.stdout.on("data", (chunk: Buffer) => {
      try {
        for (const packet of reader.push(chunk)) {
          this.#output.audioDownlink(packet, BigInt(Math.trunc(this.#now())) * 1_000n);
        }
      } catch (error) {
        this.#reportFault(error);
      }
    });
  }

  #wirePlayback(): void {
    this.#decoder?.stdout.on("data", (chunk: Buffer) => {
      const playback = this.#playback;
      if (
        playback !== null &&
        playback.stdin.writable &&
        !playback.stdin.destroyed &&
        playback.stdin.writableLength <= MAX_PROCESS_INPUT_BYTES
      ) {
        playback.stdin.write(chunk);
      }
    });
  }

  async #replaceEncoder(bitrate: number): Promise<void> {
    if (this.#closed) {
      return;
    }
    const replacement = await this.#spawn(opusEncoderCommand(bitrate), "Opus encoder");
    if (this.#closed) {
      await this.#terminate(replacement);
      return;
    }
    const previous = this.#encoder;
    this.#encoder = replacement;
    this.#encoderReader = new OggOpusPacketReader();
    this.#wireEncoder(replacement);
    if (previous !== null) {
      await this.#terminate(previous);
    }
  }

  #resetSpectrumTimer(): void {
    if (this.#spectrumTimer !== null) {
      clearInterval(this.#spectrumTimer);
      this.#spectrumTimer = null;
    }
    if (this.#closed || this.#policy.spectrumFps === 0 || this.#policy.spectrumBins === 0) {
      return;
    }
    this.#spectrumTimer = setInterval(() => { void this.#emitSpectrum(); }, Math.ceil(1_000 / this.#policy.spectrumFps));
    this.#spectrumTimer.unref();
  }

  async #emitSpectrum(): Promise<void> {
    if (this.#spectrumBusy || this.#closed || this.#policy.spectrumBins === 0) {
      return;
    }
    this.#spectrumBusy = true;
    try {
      const analysis = this.#analyzer.analyze(this.#policy.spectrumBins);
      if (analysis === null) {
        return;
      }
      const now = this.#now();
      if (now - this.#lastCenterReadAtMs >= 1_000) {
        this.#lastCenterReadAtMs = now;
        try {
          const center = await this.#readCenterFrequencyHz();
          if (Number.isSafeInteger(center) && center >= 0) {
            this.#lastCenterFrequencyHz = center;
          }
        } catch {
          // A temporary CAT read failure must not interrupt received audio.
        }
      }
      this.#output.spectrum({
        centerFrequencyHz: this.#lastCenterFrequencyHz,
        spanHz: SAMPLE_RATE / 2,
        noiseFloorTenthsDbm: analysis.noiseFloorTenthsDbm,
        bins: analysis.bins,
      }, BigInt(Math.trunc(now)) * 1_000n);
    } finally {
      this.#spectrumBusy = false;
    }
  }

  async #spawn(command: MediaCommand, role: string): Promise<ChildProcessWithoutNullStreams> {
    let child: ChildProcessWithoutNullStreams;
    try {
      child = this.#spawnProcess(command.file, command.args, {
        shell: false,
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"],
      }) as ChildProcessWithoutNullStreams;
    } catch (error) {
      throw new Error(`${role} could not start: ${errorMessage(error)}`);
    }
    const diagnostics: string[] = [];
    this.#diagnostics.set(child, diagnostics);
    child.stderr.on("data", (chunk: Buffer) => {
      diagnostics.push(chunk.toString("utf8"));
      while (diagnostics.join("").length > 4_096) {
        diagnostics.shift();
      }
    });
    await new Promise<void>((resolve, reject) => {
      const onSpawn = () => {
        child.off("error", onError);
        resolve();
      };
      const onError = (error: Error) => {
        child.off("spawn", onSpawn);
        reject(new Error(`${role} could not start: ${error.message}`));
      };
      child.once("spawn", onSpawn);
      child.once("error", onError);
    });
    child.once("error", (error) => this.#reportFault(new Error(`${role} failed: ${error.message}`)));
    child.once("exit", (code, signal) => {
      if (!this.#closed && !this.#expectedExit.has(child)) {
        const detail = diagnostics.join("").trim().slice(-1_024);
        this.#reportFault(new Error(
          `${role} exited (${code ?? signal ?? "unknown"})${detail ? `: ${detail}` : ""}`,
        ));
      }
    });
    return child;
  }

  async #terminate(child: ChildProcessWithoutNullStreams): Promise<void> {
    this.#expectedExit.add(child);
    child.stdin.end();
    if (child.exitCode !== null || child.signalCode !== null) {
      return;
    }
    const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
    child.kill("SIGTERM");
    await Promise.race([exited, shortDelay(1_000)]);
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
      await Promise.race([exited, shortDelay(1_000)]);
    }
  }

  #reportFault(error: unknown): void {
    if (this.#faulted || this.#closed) {
      return;
    }
    this.#faulted = true;
    this.#output.fault(error);
    void this.close();
  }
}

function shortDelay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds);
    timer.unref();
  });
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
