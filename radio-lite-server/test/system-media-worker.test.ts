import assert from "node:assert/strict";
import type { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough, Writable } from "node:stream";
import { test } from "node:test";

import { MediaKind, type MediaFrame } from "../src/media/frame.ts";
import { OggOpusPacketReader, OggOpusWriter } from "../src/media/ogg-opus.ts";
import * as systemMedia from "../src/media/system-media-worker.ts";
import {
  captureCommand,
  createSystemAudioDuplexProbe,
  opusDecoderCommand,
  opusEncoderCommand,
  playbackCommand,
  SystemMediaWorker,
  type SystemMediaWorkerOptions,
} from "../src/media/system-media-worker.ts";

test("system media executable requirements follow each configured audio backend", () => {
  const requirements = (systemMedia as Record<string, unknown>).requiredSystemMediaExecutables;
  assert.equal(typeof requirements, "function");
  const requiredSystemMediaExecutables = requirements as (
    profile: { audioInput: { backend: "alsa" | "pulse"; id: string }; audioOutput: { backend: "alsa" | "pulse"; id: string } },
  ) => { audioInput: string[]; audioOutput: string[] };
  const cases = [
    {
      input: { backend: "alsa" as const, id: "hw:1,0" },
      output: { backend: "alsa" as const, id: "hw:2,0" },
      expectedInput: ["arecord", "stdbuf", "opusenc"],
      expectedOutput: ["stdbuf", "opusdec", "aplay"],
    },
    {
      input: { backend: "pulse" as const, id: "radio-source" },
      output: { backend: "pulse" as const, id: "radio-sink" },
      expectedInput: ["parec", "stdbuf", "opusenc"],
      expectedOutput: ["stdbuf", "opusdec", "pacat"],
    },
    {
      input: { backend: "pulse" as const, id: "radio-source" },
      output: { backend: "alsa" as const, id: "hw:2,0" },
      expectedInput: ["parec", "stdbuf", "opusenc"],
      expectedOutput: ["stdbuf", "opusdec", "aplay"],
    },
  ];

  for (const value of cases) {
    assert.deepEqual(
      requiredSystemMediaExecutables({ audioInput: value.input, audioOutput: value.output }),
      { audioInput: value.expectedInput, audioOutput: value.expectedOutput },
    );
  }
});

test("system media commands pass configured device ids as literal argv without a shell", () => {
  const suspicious = "hw:Radio;touch /tmp/not-executed";
  const capture = captureCommand({ backend: "alsa", id: suspicious });
  const playback = playbackCommand({ backend: "alsa", id: suspicious });
  assert.equal(capture.file, "arecord");
  assert.equal(capture.args[capture.args.indexOf("-D") + 1], suspicious);
  assert.equal(playback.file, "aplay");
  assert.equal(playback.args[playback.args.indexOf("-D") + 1], suspicious);
  assert.ok(!capture.args.includes("sh"));
});

test("ALSA worker commands bound capture and playback buffering for live radio", () => {
  const capture = captureCommand({ backend: "alsa", id: "plughw:CARD=FT710,DEV=0" });
  const playback = playbackCommand({ backend: "alsa", id: "plughw:CARD=FT710,DEV=0" });

  assert.ok(capture.args.includes("--buffer-time=80000"));
  assert.ok(capture.args.includes("--period-time=20000"));
  assert.ok(playback.args.includes("--buffer-time=80000"));
  assert.ok(playback.args.includes("--period-time=20000"));
});

test("native ALSA commands use the negotiated rate and selected latency target", () => {
  const endpoint = { backend: "alsa" as const, id: "hw:3,0" };
  const capture = captureCommand(endpoint, {
    sampleRate: 48_000,
    latency: "low",
  });
  const playback = playbackCommand(endpoint, {
    sampleRate: 48_000,
    latency: "stable",
  });

  assert.equal(capture.args[capture.args.indexOf("-r") + 1], "48000");
  assert.ok(capture.args.includes("--buffer-time=40000"));
  assert.ok(capture.args.includes("--period-time=10000"));
  assert.equal(playback.args[playback.args.indexOf("-r") + 1], "48000");
  assert.ok(playback.args.includes("--buffer-time=160000"));
  assert.ok(playback.args.includes("--period-time=40000"));
});

test("the native duplex probe accepts a clean open and prefers 48 kHz", async () => {
  const commands: Array<{ file: string; args: string[] }> = [];
  const spawnProcess = ((file: string, args: string[]) => {
    commands.push({ file, args: [...args] });
    const child = new FakeProcess();
    queueMicrotask(() => {
      child.emit("spawn");
      child.exitCode = 0;
      child.emit("exit", 0, null);
    });
    return child;
  }) as unknown as typeof spawn;
  const probe = createSystemAudioDuplexProbe(spawnProcess);
  const request = {
    sampleRates: [48_000, 44_100] as const,
    channels: 1 as const,
    format: "s16le" as const,
    latency: "balanced" as const,
    timeoutMs: 500,
  };

  const capture = await probe.open("capture", { backend: "alsa", id: "hw:3,0" }, request);
  const playback = await probe.open("playback", { backend: "alsa", id: "hw:3,0" }, request);

  assert.equal(capture.sampleRate, 48_000);
  assert.equal(playback.sampleRate, 48_000);
  assert.deepEqual(commands.map((command) => command.file), ["arecord", "aplay"]);
  assert(commands.every((command) => command.args.includes("48000")));
});

test("PulseAudio and Opus worker commands use 16 kHz mono 20 ms packets", () => {
  assert.deepEqual(
    captureCommand({ backend: "pulse", id: "alsa_input.usb-radio" }),
    {
      file: "parec",
      args: [
        "--raw",
        "--device=alsa_input.usb-radio",
        "--format=s16le",
        "--channels=1",
        "--rate=16000",
        "--latency-msec=40",
        "--process-time-msec=20",
      ],
    },
  );
  assert.deepEqual(
    playbackCommand({ backend: "pulse", id: "alsa_output.usb-radio" }),
    {
      file: "pacat",
      args: [
        "--playback",
        "--raw",
        "--device=alsa_output.usb-radio",
        "--format=s16le",
        "--channels=1",
        "--rate=16000",
        "--latency-msec=40",
        "--process-time-msec=20",
      ],
    },
  );
  const encoder = opusEncoderCommand(12_000);
  assert.equal(encoder.file, "stdbuf");
  assert.deepEqual(encoder.args.slice(0, 3), ["-i0", "-o0", "opusenc"]);
  assert.ok(encoder.args.includes("--framesize=20"));
  assert.ok(encoder.args.includes("--bitrate=12"));
  assert.ok(encoder.args.includes("--max-delay=0"));
  assert.throws(() => opusEncoderCommand(100_000), /bitrate/u);
});

test("Opus decoder disables stdin and stdout buffering with exact argv", () => {
  assert.deepEqual(opusDecoderCommand(), {
    file: "stdbuf",
    args: [
      "-i0",
      "-o0",
      "opusdec",
      "--quiet",
      "--rate",
      "16000",
      "-",
      "-",
    ],
  });
});

test("system worker advertises a 3 kHz spectrum span with 512 bins", async (context) => {
  const processes: FakeProcess[] = [];
  const spawnProcess = (() => {
    const child = new FakeProcess();
    processes.push(child);
    queueMicrotask(() => child.emit("spawn"));
    return child;
  }) as unknown as typeof spawn;
  const worker = await SystemMediaWorker.create(profile(), {
    audioDownlink: () => undefined,
    spectrum: () => undefined,
    fault: (error) => { throw error; },
  }, { spawnProcess });
  context.after(() => worker.close());

  assert.equal(worker.spectrumCapability.spanHz, 3_000);
  assert.equal(worker.spectrumCapability.maxBins, 512);
});

test("system worker emits 512-bin spectrum frames with a 3 kHz span", async (context) => {
  const processes: FakeProcess[] = [];
  const frames: Array<{ spanHz: number; bins: Uint8Array }> = [];
  const spawnProcess = (() => {
    const child = new FakeProcess();
    processes.push(child);
    queueMicrotask(() => child.emit("spawn"));
    return child;
  }) as unknown as typeof spawn;
  const worker = await SystemMediaWorker.create(profile(), {
    audioDownlink: () => undefined,
    spectrum: (frame) => frames.push(frame),
    fault: (error) => { throw error; },
  }, { spawnProcess, now: () => 5_000 });
  context.after(() => worker.close());

  processes[0].stdout.write(Buffer.alloc(4_096 * 2));
  await delay(240);
  assert.equal(frames.length, 1);
  assert.equal(frames[0].spanHz, 3_000);
  assert.equal(frames[0].bins.length, 512);
});

test("system worker routes capture, Opus packets and playback through bounded child pipes", async (context) => {
  const processes: FakeProcess[] = [];
  const commands: Array<{ file: string; args: string[] }> = [];
  const spawnProcess = ((file: string, args: string[]) => {
    commands.push({ file, args: [...args] });
    const child = new FakeProcess();
    processes.push(child);
    queueMicrotask(() => child.emit("spawn"));
    return child;
  }) as unknown as typeof spawn;
  const downlink: Buffer[] = [];
  const capturedPcm: Array<{ pcm: Buffer; sampleRate: number; startedAtMs: number }> = [];
  const faults: unknown[] = [];
  const worker = await SystemMediaWorker.create(profile(), {
    audioDownlink: (payload) => downlink.push(Buffer.from(payload)),
    spectrum: () => undefined,
    pcmCapture: (value) => capturedPcm.push({ ...value, pcm: Buffer.from(value.pcm) }),
    fault: (error) => faults.push(error),
  }, {
    spawnProcess,
    now: () => 5_000,
    readCenterFrequencyHz: async () => 14_074_000,
  });
  context.after(() => worker.close());
  assert.deepEqual(commands.map((command) => command.file), [
    "arecord", "stdbuf", "stdbuf", "pacat",
  ]);

  const [capture, encoder, decoder, playback] = processes;
  const pcm = Buffer.alloc(2_048);
  capture.stdout.write(pcm);
  await immediate();
  assert.equal(Buffer.concat(encoder.stdinChunks).length, pcm.length);
  assert.equal(capturedPcm.length, 1);
  assert.equal(capturedPcm[0].sampleRate, 16_000);
  assert.equal(capturedPcm[0].startedAtMs, 4_936);
  assert.deepEqual(capturedPcm[0].pcm, pcm);

  const encoded = new OggOpusWriter({ serialNumber: 11 });
  encoder.stdout.write(Buffer.concat([
    encoded.headers(),
    encoded.packet(Buffer.from([0xf8, 0xff, 0xfe])),
  ]));
  await immediate();
  assert.deepEqual(downlink, [Buffer.from([0xf8, 0xff, 0xfe])]);

  const frame: MediaFrame = {
    version: 1,
    kind: MediaKind.audioUplink,
    flags: 0,
    radioSlot: 0,
    sequence: 1,
    timestampUs: 1n,
    payload: Buffer.from([1, 2, 3]),
  };
  assert.equal(worker.writeAudioUplink(frame), true);
  const uplinkReader = new OggOpusPacketReader();
  assert.deepEqual(uplinkReader.push(Buffer.concat(decoder.stdinChunks)), [Buffer.from([1, 2, 3])]);

  decoder.stdout.write(Buffer.from([4, 5, 6, 7]));
  await immediate();
  assert.deepEqual(Buffer.concat(playback.stdinChunks), Buffer.from([4, 5, 6, 7]));

  const playbackBytesBeforeDigital = Buffer.concat(playback.stdinChunks).length;
  const playing = worker.digitalAudio.play(
    new Int16Array(1_200).fill(1_000),
    12_000,
    new AbortController().signal,
  );
  decoder.stdout.write(Buffer.from([9, 9, 9, 9]));
  await playing;
  const afterDigital = Buffer.concat(playback.stdinChunks);
  assert.equal(afterDigital.length - playbackBytesBeforeDigital, 3_200);
  assert.notDeepEqual(afterDigital.subarray(-4), Buffer.from([9, 9, 9, 9]));

  await worker.updatePolicy({
    tier: "severe",
    opusBitrate: 12_000,
    opusFrameMs: 20,
    spectrumBins: 0,
    spectrumFps: 0,
  });
  assert.equal(commands.at(-1)?.file, "stdbuf");
  assert.ok(commands.at(-1)?.args.includes("--bitrate=12"));
  assert.equal(faults.length, 0);
  await worker.close();
  assert.ok(processes.every((process) => process.killed));
});

test("system worker re-resolves a stable card and converts 48 kHz capture to internal 16 kHz", async (context) => {
  const processes: FakeProcess[] = [];
  const commands: Array<{ file: string; args: string[] }> = [];
  const spawnProcess = ((file: string, args: string[]) => {
    commands.push({ file, args: [...args] });
    const child = new FakeProcess();
    processes.push(child);
    queueMicrotask(() => child.emit("spawn"));
    return child;
  }) as unknown as typeof spawn;
  const opened: string[] = [];
  const worker = await SystemMediaWorker.create(systemDeviceProfile(), {
    audioDownlink: () => undefined,
    spectrum: () => undefined,
    fault: (error) => { throw error; },
  }, {
    spawnProcess,
    discover: async () => discoveryWithStableCard("hw:3,0"),
    duplexProbe: probeAt48k(opened),
  } as SystemMediaWorkerOptions);
  context.after(() => worker.close());

  assert.deepEqual(opened, ["capture:hw:3,0", "playback:hw:3,0"]);
  assert.equal(commands[0].args[commands[0].args.indexOf("-D") + 1], "hw:3,0");
  assert.equal(commands[0].args[commands[0].args.indexOf("-r") + 1], "48000");
  assert.equal(commands[3].args[commands[3].args.indexOf("-D") + 1], "hw:3,0");
  assert.equal(commands[3].args[commands[3].args.indexOf("-r") + 1], "48000");

  processes[0].stdout.write(pcm16LeFixture(Int16Array.from({ length: 480 }, (_, index) => index)));
  await immediate();
  assert.equal(Buffer.concat(processes[1].stdinChunks).length, 160 * 2);
});

test("system worker makes one reconnect attempt after re-resolving the same stable card", async (context) => {
  const processes: FakeProcess[] = [];
  const commands: Array<{ file: string; args: string[] }> = [];
  let discoveryCalls = 0;
  const faults: unknown[] = [];
  const spawnProcess = ((file: string, args: string[]) => {
    commands.push({ file, args: [...args] });
    const child = new FakeProcess();
    processes.push(child);
    queueMicrotask(() => child.emit("spawn"));
    return child;
  }) as unknown as typeof spawn;
  const worker = await SystemMediaWorker.create(systemDeviceProfile(), {
    audioDownlink: () => undefined,
    spectrum: () => undefined,
    fault: (error) => faults.push(error),
  }, {
    spawnProcess,
    discover: async () => {
      discoveryCalls += 1;
      return discoveryWithStableCard(discoveryCalls === 1 ? "hw:1,0" : "hw:3,0");
    },
    duplexProbe: probeAt48k([]),
  } as SystemMediaWorkerOptions);
  context.after(() => worker.close());

  processes[0].exitCode = 1;
  processes[0].emit("exit", 1, null);
  await immediate();
  await immediate();
  await immediate();

  assert.equal(discoveryCalls, 2);
  assert.equal(commands[4].args[commands[4].args.indexOf("-D") + 1], "hw:3,0");
  assert.equal(faults.length, 0, faults.map((error) => String(error)).join("; "));

  processes[4].exitCode = 1;
  processes[4].emit("exit", 1, null);
  await immediate();
  assert.equal(discoveryCalls, 2);
  assert.equal(faults.length, 1);
});

test("digital playback uses absolute deadlines so repeated timer overshoot does not accumulate", async (context) => {
  const clock = new AdvancingPlaybackClock(2);
  const fixture = await createPlaybackFixture(clock);
  context.after(() => fixture.worker.close());

  await fixture.worker.digitalAudio.play(
    new Int16Array(16_000 * 5).fill(1_000),
    16_000,
    new AbortController().signal,
  );

  assert.ok(clock.nowMs >= 5_080, `playback completed too early at ${clock.nowMs} ms`);
  assert.ok(clock.nowMs <= 5_085, `timer overshoot accumulated to ${clock.nowMs} ms`);
});

test("digital playback preserves every PCM byte with no more than 80 ms written ahead", async (context) => {
  const clock = new AdvancingPlaybackClock();
  const fixture = await createPlaybackFixture(clock);
  context.after(() => fixture.worker.close());
  const pcm = Int16Array.from(
    { length: 3_200 },
    (_, index) => (index % 511) - 255,
  );

  await fixture.worker.digitalAudio.play(
    pcm,
    16_000,
    new AbortController().signal,
  );

  assert.deepEqual(Buffer.concat(fixture.playback.stdinChunks), pcm16LeFixture(pcm));
  let writtenBytes = 0;
  let maximumLeadMs = 0;
  for (let index = 0; index < fixture.playback.stdinChunks.length; index += 1) {
    writtenBytes += fixture.playback.stdinChunks[index].length;
    const writtenAudioMs = writtenBytes * 1_000 / (16_000 * 2);
    maximumLeadMs = Math.max(
      maximumLeadMs,
      writtenAudioMs - fixture.playback.writeTimesMs[index],
    );
  }
  assert.equal(maximumLeadMs, 80);
});

test("digital playback waits for the logical audio end and tail after its final write", async (context) => {
  const clock = new AdvancingPlaybackClock();
  const fixture = await createPlaybackFixture(clock);
  context.after(() => fixture.worker.close());

  await fixture.worker.digitalAudio.play(
    new Int16Array(16_000).fill(1_000),
    16_000,
    new AbortController().signal,
  );

  assert.equal(fixture.playback.writeTimesMs.at(-1), 920);
  assert.equal(clock.nowMs, 1_080);
});

test("digital playback aborts a timer wait before writing any later PCM", async (context) => {
  const clock = new BlockingPlaybackClock();
  const fixture = await createPlaybackFixture(clock);
  context.after(() => fixture.worker.close());
  const playing = fixture.worker.digitalAudio.play(
    new Int16Array(16_000).fill(1_000),
    16_000,
    new AbortController().signal,
  );
  const playingResult = playing.then(
    () => null,
    (error: unknown) => error,
  );
  await immediate();

  try {
    assert.equal(Buffer.concat(fixture.playback.stdinChunks).length, 2_560);
  } finally {
    await fixture.worker.digitalAudio.stop();
  }
  const error = await playingResult;
  assert.ok(error instanceof Error && error.name === "AbortError");
  await immediate();
  assert.equal(Buffer.concat(fixture.playback.stdinChunks).length, 2_560);
});

test("drain abort keeps voice playback suppressed for the bounded residual window", async (context) => {
  const clock = new AdvancingPlaybackClock();
  const blockedPlayback = new BlockingWritable();
  let wallNowMs = 10_000;
  const fixture = await createPlaybackFixture(
    clock,
    () => wallNowMs,
    blockedPlayback,
  );
  context.after(() => fixture.worker.close());
  const playing = fixture.worker.digitalAudio.play(
    new Int16Array(16_000).fill(1_000),
    16_000,
    new AbortController().signal,
  );
  await immediate();

  assert.equal(blockedPlayback.chunks.length, 1);
  await fixture.worker.digitalAudio.stop();
  await assert.rejects(playing, (error: unknown) =>
    error instanceof Error && error.name === "AbortError"
  );
  blockedPlayback.release();
  await immediate();

  wallNowMs += 139;
  fixture.decoder.stdout.write(Buffer.from([9, 9, 9, 9]));
  await immediate();
  assert.equal(blockedPlayback.chunks.length, 1);

  wallNowMs += 61;
  fixture.decoder.stdout.write(Buffer.from([8, 8, 8, 8]));
  await immediate();
  assert.deepEqual(blockedPlayback.chunks.at(-1), Buffer.from([8, 8, 8, 8]));
});

class FakeProcess extends EventEmitter {
  readonly stdin: Writable;
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  readonly stdinChunks: Buffer[] = [];
  readonly writeTimesMs: number[] = [];
  pid = 10;
  exitCode: number | null = null;
  signalCode: NodeJS.Signals | null = null;
  killed = false;

  constructor(options: { stdin?: Writable; writtenAt?: () => number } = {}) {
    super();
    this.stdin = options.stdin ?? new PassThrough();
    if (this.stdin instanceof PassThrough) {
      this.stdin.on("data", (chunk: Buffer) => {
        this.stdinChunks.push(Buffer.from(chunk));
        this.writeTimesMs.push(options.writtenAt?.() ?? 0);
      });
    }
  }

  kill(signal: NodeJS.Signals = "SIGTERM"): boolean {
    if (this.killed) {
      return true;
    }
    this.killed = true;
    this.signalCode = signal;
    queueMicrotask(() => this.emit("exit", null, signal));
    return true;
  }
}

type PlaybackTestOptions = SystemMediaWorkerOptions & {
  monotonicNow: () => number;
  delayPlayback: (
    milliseconds: number,
    firstSignal: AbortSignal,
    secondSignal: AbortSignal,
  ) => Promise<void>;
};

async function createPlaybackFixture(
  clock: { now: () => number; delay: PlaybackTestOptions["delayPlayback"] },
  wallNow: () => number = () => 5_000,
  playbackStdin?: Writable,
) {
  const processes: FakeProcess[] = [];
  const spawnProcess = (() => {
    const child = processes.length === 3
      ? new FakeProcess({ stdin: playbackStdin, writtenAt: clock.now })
      : new FakeProcess();
    processes.push(child);
    queueMicrotask(() => child.emit("spawn"));
    return child;
  }) as unknown as typeof spawn;
  const options: PlaybackTestOptions = {
    spawnProcess,
    now: wallNow,
    monotonicNow: clock.now,
    delayPlayback: clock.delay,
  };
  const worker = await SystemMediaWorker.create(profile(), {
    audioDownlink: () => undefined,
    spectrum: () => undefined,
    fault: (error) => { throw error; },
  }, options);
  return {
    worker,
    playback: processes[3],
    decoder: processes[2],
  };
}

class AdvancingPlaybackClock {
  nowMs = 0;
  readonly #overshootMs: number;

  constructor(overshootMs = 0) {
    this.#overshootMs = overshootMs;
  }

  readonly now = (): number => this.nowMs;

  readonly delay = async (
    milliseconds: number,
    firstSignal: AbortSignal,
    secondSignal: AbortSignal,
  ): Promise<void> => {
    throwIfTestAborted(firstSignal, secondSignal);
    this.nowMs += Math.max(0, milliseconds) + this.#overshootMs;
    throwIfTestAborted(firstSignal, secondSignal);
  };
}

class BlockingPlaybackClock {
  readonly now = (): number => 0;

  readonly delay = (
    _milliseconds: number,
    firstSignal: AbortSignal,
    secondSignal: AbortSignal,
  ): Promise<void> => new Promise((_resolve, reject) => {
    const cleanup = () => {
      firstSignal.removeEventListener("abort", onAbort);
      secondSignal.removeEventListener("abort", onAbort);
    };
    const onAbort = () => {
      cleanup();
      const error = new Error("test playback aborted");
      error.name = "AbortError";
      reject(error);
    };
    firstSignal.addEventListener("abort", onAbort, { once: true });
    secondSignal.addEventListener("abort", onAbort, { once: true });
    if (firstSignal.aborted || secondSignal.aborted) {
      onAbort();
    }
  });
}

class BlockingWritable extends Writable {
  readonly chunks: Buffer[] = [];
  #pending: (() => void) | null = null;

  constructor() {
    super({ highWaterMark: 1 });
  }

  override _write(
    chunk: Buffer,
    _encoding: BufferEncoding,
    callback: (error?: Error | null) => void,
  ): void {
    this.chunks.push(Buffer.from(chunk));
    this.#pending = callback;
  }

  release(): void {
    const pending = this.#pending;
    this.#pending = null;
    pending?.();
  }
}

function pcm16LeFixture(value: Int16Array): Buffer {
  const result = Buffer.alloc(value.length * 2);
  for (let index = 0; index < value.length; index += 1) {
    result.writeInt16LE(value[index], index * 2);
  }
  return result;
}

function throwIfTestAborted(firstSignal: AbortSignal, secondSignal: AbortSignal): void {
  if (firstSignal.aborted || secondSignal.aborted) {
    const error = new Error("test playback aborted");
    error.name = "AbortError";
    throw error;
  }
}

function immediate(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function profile() {
  return {
    id: "main",
    name: "FT-710",
    hamlibModelId: 1049,
    connection: { kind: "network-rigctld" as const, host: "127.0.0.1", port: 4532 },
    audioInput: { backend: "alsa" as const, id: "hw:1,0" },
    audioOutput: { backend: "pulse" as const, id: "radio-sink" },
    ptt: { method: "RIG" as const },
    station: { callsign: "BI1ABC", grid: "OM89" },
    hardwareTxEnabled: true,
  };
}

function systemDeviceProfile() {
  return {
    ...profile(),
    audioInput: { backend: "alsa" as const, id: "hw:9,0" },
    audioOutput: { backend: "alsa" as const, id: "hw:9,0" },
    audioRoute: {
      kind: "system-device" as const,
      hardwareId: "usb:1234:5678:SN42",
      latency: "balanced" as const,
    },
  };
}

function discoveryWithStableCard(endpointId: string) {
  const input = {
    backend: "alsa" as const,
    direction: "input" as const,
    id: endpointId,
    label: "USB input",
  };
  const output = {
    backend: "alsa" as const,
    direction: "output" as const,
    id: endpointId,
    label: "USB output",
  };
  return {
    hamlibModels: [],
    curatedPresets: [],
    serialDevices: [],
    audioInputs: [input],
    audioOutputs: [output],
    audioCards: [{
      hardwareId: "usb:1234:5678:SN42",
      label: "USB Audio CODEC (SN42)",
      transport: "usb" as const,
      complete: true,
      input,
      output,
    }],
    pttMethods: ["RIG" as const],
    baudRates: [38_400],
    warnings: [],
  };
}

function probeAt48k(opened: string[]) {
  return {
    open: async (
      direction: "capture" | "playback",
      endpoint: { id: string },
    ) => {
      opened.push(`${direction}:${endpoint.id}`);
      return { sampleRate: 48_000, channels: 1, format: "s16le" as const };
    },
  };
}
