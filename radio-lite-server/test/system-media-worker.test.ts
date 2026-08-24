import assert from "node:assert/strict";
import type { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { test } from "node:test";

import { MediaKind, type MediaFrame } from "../src/media/frame.ts";
import { OggOpusPacketReader, OggOpusWriter } from "../src/media/ogg-opus.ts";
import {
  captureCommand,
  opusDecoderCommand,
  opusEncoderCommand,
  playbackCommand,
  SystemMediaWorker,
} from "../src/media/system-media-worker.ts";

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
      ],
    },
  );
  const encoder = opusEncoderCommand(12_000);
  assert.equal(encoder.file, "opusenc");
  assert.ok(encoder.args.includes("--framesize=20"));
  assert.ok(encoder.args.includes("--bitrate=12"));
  assert.deepEqual(opusDecoderCommand().args.slice(0, 3), [
    "--quiet", "--rate", "16000",
  ]);
  assert.throws(() => opusEncoderCommand(100_000), /bitrate/u);
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
  const faults: unknown[] = [];
  const worker = await SystemMediaWorker.create({
    id: "main",
    name: "FT-710",
    hamlibModelId: 1049,
    connection: { kind: "network-rigctld", host: "127.0.0.1", port: 4532 },
    audioInput: { backend: "alsa", id: "hw:1,0" },
    audioOutput: { backend: "pulse", id: "radio-sink" },
    station: { callsign: "BI1ABC", grid: "OM89" },
    hardwareTxEnabled: true,
  }, {
    audioDownlink: (payload) => downlink.push(Buffer.from(payload)),
    spectrum: () => undefined,
    fault: (error) => faults.push(error),
  }, {
    spawnProcess,
    now: () => 5_000,
    readCenterFrequencyHz: async () => 14_074_000,
  });
  context.after(() => worker.close());
  assert.deepEqual(commands.map((command) => command.file), [
    "arecord", "opusenc", "opusdec", "pacat",
  ]);

  const [capture, encoder, decoder, playback] = processes;
  const pcm = Buffer.alloc(2_048);
  capture.stdout.write(pcm);
  await immediate();
  assert.equal(Buffer.concat(encoder.stdinChunks).length, pcm.length);

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

  await worker.updatePolicy({
    tier: "severe",
    opusBitrate: 12_000,
    opusFrameMs: 20,
    spectrumBins: 0,
    spectrumFps: 0,
  });
  assert.equal(commands.at(-1)?.file, "opusenc");
  assert.ok(commands.at(-1)?.args.includes("--bitrate=12"));
  assert.equal(faults.length, 0);
  await worker.close();
  assert.ok(processes.every((process) => process.killed));
});

class FakeProcess extends EventEmitter {
  readonly stdin = new PassThrough();
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  readonly stdinChunks: Buffer[] = [];
  pid = 10;
  exitCode: number | null = null;
  signalCode: NodeJS.Signals | null = null;
  killed = false;

  constructor() {
    super();
    this.stdin.on("data", (chunk: Buffer) => this.stdinChunks.push(Buffer.from(chunk)));
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

function immediate(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}
