import assert from "node:assert/strict";
import { test } from "node:test";

import { AdaptiveMediaPolicy } from "../src/media/adaptive-policy.ts";
import { decodeMediaFrame, MediaKind, type MediaFrame } from "../src/media/frame.ts";
import {
  MediaHub,
  type MediaClientTransport,
  type MediaWorker,
  type MediaWorkerFactory,
  type MediaWorkerOutput,
} from "../src/media/media-hub.ts";
import { decodeSpectrumPayload } from "../src/media/spectrum-payload.ts";

test("voice transmit token binds only to the matching authenticated principal", async (context) => {
  const fixture = createFixture();
  context.after(() => fixture.hub.close());
  fixture.connect("media-a", "device:a", "user-a");
  fixture.connect("media-b", "device:b", "user-a");
  await fixture.hub.subscribe("media-a", "main", true);
  await fixture.hub.subscribe("media-b", "main", true);
  fixture.hub.registerTransmit({
    radioId: "main",
    ownerId: "control-a",
    principalId: "device:a",
    userId: "user-a",
    transmitToken: "tx-token",
    mode: "voice",
    heartbeatDeadlineMs: 8_000,
    hardDeadlineMs: 180_000,
  });

  await assert.rejects(
    fixture.hub.bindUplink("media-b", "main", "tx-token"),
    /same authenticated principal/u,
  );
  await fixture.hub.bindUplink("media-a", "main", "tx-token");
  const accepted = fixture.hub.receiveUplink("media-a", uplinkFrame(0, 1, [10, 11, 12]));
  assert.equal(accepted, true);
  assert.deepEqual(fixture.worker?.uplinkPayloads, [Buffer.from([10, 11, 12])]);
});

test("media disconnect immediately de-keys its bound voice transmission", async (context) => {
  const fixture = createFixture();
  context.after(() => fixture.hub.close());
  fixture.connect("media-a", "device:a", "user-a");
  await fixture.hub.subscribe("media-a", "main", true);
  fixture.hub.registerTransmit({
    radioId: "main",
    ownerId: "control-a",
    principalId: "device:a",
    userId: "user-a",
    transmitToken: "tx-token",
    mode: "voice",
    heartbeatDeadlineMs: 8_000,
    hardDeadlineMs: 180_000,
  });
  await fixture.hub.bindUplink("media-a", "main", "tx-token");

  await fixture.hub.disconnect("media-a");
  assert.deepEqual(fixture.stops, [{
    radioId: "main",
    ownerId: "control-a",
    transmitToken: "tx-token",
    reason: "media_disconnected",
  }]);
});

test("voice PTT without a timely microphone binding is automatically de-keyed", async (context) => {
  const fixture = createFixture(() => 1_000, 20);
  context.after(() => fixture.hub.close());
  fixture.connect("media-a", "device:a", "user-a");
  await fixture.hub.subscribe("media-a", "main", true);
  assert.equal(fixture.hub.hasReadySubscription("device:a", "user-a", "main"), true);
  fixture.hub.registerTransmit({
    radioId: "main",
    ownerId: "control-a",
    principalId: "device:a",
    userId: "user-a",
    transmitToken: "unbound-token",
    mode: "voice",
    heartbeatDeadlineMs: 8_000,
    hardDeadlineMs: 180_000,
  });
  await new Promise<void>((resolve) => setTimeout(resolve, 40));
  assert.equal(fixture.stops.length, 1);
  assert.equal(fixture.stops[0].reason, "uplink_bind_timeout");
});

test("media worker failure revokes voice PTT and removes the failed pipeline", async (context) => {
  const fixture = createFixture();
  context.after(() => fixture.hub.close());
  const transport = fixture.connect("media-a", "device:a", "user-a");
  await fixture.hub.subscribe("media-a", "main", true);
  fixture.hub.registerTransmit({
    radioId: "main",
    ownerId: "control-a",
    principalId: "device:a",
    userId: "user-a",
    transmitToken: "tx-token",
    mode: "voice",
    heartbeatDeadlineMs: 8_000,
    hardDeadlineMs: 180_000,
  });
  await fixture.hub.bindUplink("media-a", "main", "tx-token");
  fixture.output?.fault(new Error("capture device unplugged"));
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(fixture.stops.at(-1)?.reason, "media_worker_failed");
  assert.equal(fixture.worker?.closed, true);
  assert.equal(
    (transport.json[0] as { code?: string }).code,
    "media_worker_failed",
  );
});

test("radio configuration invalidation de-keys voice and permits a fresh media subscription", async (context) => {
  const fixture = createFixture();
  context.after(() => fixture.hub.close());
  const transport = fixture.connect("media-a", "device:a", "user-a");
  await fixture.hub.subscribe("media-a", "main", true);
  const originalWorker = fixture.worker;
  const digitalFaults: string[] = [];
  const digitalPort = await fixture.hub.openDigitalAudio("main", {
    pcm: () => undefined,
    fault: (error) => digitalFaults.push(error instanceof Error ? error.message : String(error)),
  });
  context.after(() => digitalPort.close());
  fixture.hub.registerTransmit({
    radioId: "main",
    ownerId: "control-a",
    principalId: "device:a",
    userId: "user-a",
    transmitToken: "tx-token",
    mode: "voice",
    heartbeatDeadlineMs: 8_000,
    hardDeadlineMs: 180_000,
  });
  await fixture.hub.bindUplink("media-a", "main", "tx-token");

  await fixture.hub.invalidate("main");

  assert.equal(originalWorker?.closed, true);
  assert.equal(fixture.stops.at(-1)?.reason, "media_configuration_changed");
  assert.deepEqual(digitalFaults, ["radio media configuration changed"]);
  assert.deepEqual(transport.json.at(-1), {
    t: "media.error",
    code: "media_configuration_changed",
    message: "radio media configuration changed",
    reconnectRequired: true,
  });
  assert.equal(fixture.hub.hasReadySubscription("device:a", "user-a", "main"), false);
  await assert.rejects(
    digitalPort.play(new Int16Array([1]), 12_000, new AbortController().signal),
    /unavailable/u,
  );

  await fixture.hub.subscribe("media-a", "main", true);
  assert.notEqual(fixture.worker, originalWorker);
  assert.equal(fixture.hub.hasReadySubscription("device:a", "user-a", "main"), true);
});

test("radio configuration invalidation survives an old worker close failure", async (context) => {
  const fixture = createFixture();
  context.after(() => fixture.hub.close());
  fixture.connect("media-a", "device:a", "user-a");
  await fixture.hub.subscribe("media-a", "main", true);
  const originalWorker = fixture.worker!;
  originalWorker.failClose = true;

  await assert.doesNotReject(fixture.hub.invalidate("main"));
  await fixture.hub.subscribe("media-a", "main", false);
  assert.notEqual(fixture.worker, originalWorker);
});

test("expired, replayed and oversized microphone frames are rejected", async (context) => {
  let nowMs = 1_000;
  const fixture = createFixture(() => nowMs);
  context.after(() => fixture.hub.close());
  fixture.connect("media-a", "device:a", "user-a");
  await fixture.hub.subscribe("media-a", "main", true);
  fixture.hub.registerTransmit({
    radioId: "main",
    ownerId: "control-a",
    principalId: "device:a",
    userId: "user-a",
    transmitToken: "tx-token",
    mode: "voice",
    heartbeatDeadlineMs: 2_000,
    hardDeadlineMs: 10_000,
  });
  await fixture.hub.bindUplink("media-a", "main", "tx-token");

  assert.equal(fixture.hub.receiveUplink("media-a", uplinkFrame(0, 5, [1])), true);
  assert.throws(() => fixture.hub.receiveUplink("media-a", uplinkFrame(0, 5, [2])), /sequence/u);
  assert.throws(
    () => fixture.hub.receiveUplink("media-a", uplinkFrame(0, 6, new Array(1_501).fill(0))),
    /payload/u,
  );
  nowMs = 2_001;
  assert.throws(() => fixture.hub.receiveUplink("media-a", uplinkFrame(0, 7, [3])), /expired/u);
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(fixture.stops.at(-1)?.reason, "transmit_expired");
});

test("downlink and spectrum frames broadcast without accumulating stale media", async (context) => {
  const fixture = createFixture();
  context.after(() => fixture.hub.close());
  const fast = fixture.connect("fast", "device:a", "user-a");
  const slow = fixture.connect("slow", "device:b", "user-b");
  slow.bufferedAmount = 100_000;
  await fixture.hub.subscribe("fast", "main", true);
  await fixture.hub.subscribe("slow", "main", true);

  fixture.output?.audioDownlink(Buffer.from([0xf8, 0xff, 0xfe]), 123n);
  fixture.output?.spectrum({
    centerFrequencyHz: 14_074_000,
    spanHz: 3_000,
    noiseFloorTenthsDbm: -1_100,
    bins: Uint8Array.from({ length: 512 }, (_, index) => index % 256),
  }, 456n);

  assert.equal(fast.binary.length, 2);
  assert.equal(slow.binary.length, 0);
  const audio = decodeMediaFrame(fast.binary[0]);
  assert.equal(audio.kind, MediaKind.audioDownlink);
  assert.equal(audio.timestampUs, 123n);
  const spectrum = decodeMediaFrame(fast.binary[1]);
  assert.equal(spectrum.kind, MediaKind.spectrum);
  assert.equal(decodeSpectrumPayload(spectrum.payload).bins.length, 512);
  assert.equal(fixture.hub.statistics("slow").droppedFrames, 2);
});

test("client network reports update policy and hidden spectrum sends no spectrum", async (context) => {
  const fixture = createFixture();
  context.after(() => fixture.hub.close());
  const client = fixture.connect("media-a", "device:a", "user-a");
  const subscribed = await fixture.hub.subscribe("media-a", "main", true);
  assert.equal(subscribed.policy.tier, "normal");
  const policy = fixture.hub.updateNetwork("media-a", {
    rttMs: 2_500,
    packetLossPercent: 10,
    bufferedBytes: 600_000,
    spectrumVisible: false,
  });
  assert.equal(policy.tier, "severe");
  assert.equal(policy.spectrumBins, 0);

  fixture.output?.spectrum({
    centerFrequencyHz: 7_074_000,
    spanHz: 3_000,
    noiseFloorTenthsDbm: -1_200,
    bins: new Uint8Array(512),
  });
  assert.equal(client.binary.length, 0);
  assert.equal(fixture.worker?.policies.at(-1)?.tier, "severe");
});

test("digital DSP opens the existing media worker for shared PCM capture and playback", async (context) => {
  const fixture = createFixture();
  context.after(() => fixture.hub.close());
  const captured: Buffer[] = [];
  const faults: string[] = [];
  const port = await fixture.hub.openDigitalAudio("main", {
    pcm: (value) => captured.push(Buffer.from(value.pcm)),
    fault: (error) => faults.push(error instanceof Error ? error.message : String(error)),
  });
  context.after(() => port.close());
  fixture.output!.pcmCapture?.({
    pcm: Buffer.from([1, 0, 2, 0]),
    sampleRate: 16_000,
    startedAtMs: 1_000,
  });
  assert.deepEqual(captured, [Buffer.from([1, 0, 2, 0])]);
  await port.play(new Int16Array([1, 2]), 12_000, new AbortController().signal);
  assert.deepEqual(fixture.worker!.digitalPlayback, [new Int16Array([1, 2])]);
  await port.stop();
  assert.equal(fixture.worker!.digitalStopCount, 0, "completed playback already released ownership");
  fixture.output!.fault(new Error("capture failed"));
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.deepEqual(faults, ["capture failed"]);
  await assert.rejects(
    port.play(new Int16Array([1]), 12_000, new AbortController().signal),
    /unavailable/u,
  );
});

function createFixture(now: () => number = () => 1_000, uplinkBindTimeoutMs = 3_000) {
  let worker: FakeMediaWorker | undefined;
  let output: MediaWorkerOutput | undefined;
  const factory: MediaWorkerFactory = async (_profile, _radioSlot, sink) => {
    output = sink;
    worker = new FakeMediaWorker();
    return worker;
  };
  const stops: Array<{
    radioId: string;
    ownerId: string;
    transmitToken: string;
    reason: string;
  }> = [];
  const hub = new MediaHub({
    radios: () => ({
      version: 1,
      radios: [{
        id: "main",
        name: "Dummy",
        hamlibModelId: 1,
        connection: { kind: "hamlib-dummy" },
        audioInput: { backend: "alsa", id: "dummy" },
        audioOutput: { backend: "alsa", id: "dummy" },
        ptt: { method: "None" },
        station: { callsign: "BI1ABC", grid: "OM89" },
        hardwareTxEnabled: false,
      }],
    }),
    workerFactory: factory,
    now,
    uplinkBindTimeoutMs,
    stopVoiceTransmit: async (request) => { stops.push(request); },
  });
  const clients = new Map<string, FakeTransport>();
  return {
    hub,
    stops,
    get worker() { return worker; },
    get output() { return output; },
    connect(id: string, principalId: string, userId: string) {
      const transport = new FakeTransport();
      clients.set(id, transport);
      hub.connect({ id, principalId, userId, transport });
      return transport;
    },
  };
}

class FakeMediaWorker implements MediaWorker {
  readonly uplinkPayloads: Buffer[] = [];
  readonly digitalPlayback: Int16Array[] = [];
  readonly policies = [new AdaptiveMediaPolicy().current()];
  readonly digitalAudio = {
    sampleRate: 16_000,
    play: async (pcm: Int16Array) => { this.digitalPlayback.push(pcm.slice()); },
    stop: async () => { this.digitalStopCount += 1; },
  };
  digitalStopCount = 0;
  closed = false;
  failClose = false;

  updatePolicy(policy: ReturnType<AdaptiveMediaPolicy["current"]>): void {
    this.policies.push(policy);
  }

  writeAudioUplink(frame: MediaFrame): boolean {
    this.uplinkPayloads.push(Buffer.from(frame.payload));
    return true;
  }

  async close(): Promise<void> {
    this.closed = true;
    if (this.failClose) {
      throw new Error("worker close failed");
    }
  }
}

class FakeTransport implements MediaClientTransport {
  bufferedAmount = 0;
  readonly binary: Buffer[] = [];
  readonly json: unknown[] = [];

  sendBinary(value: Buffer): void { this.binary.push(Buffer.from(value)); }
  sendJson(value: unknown): void { this.json.push(value); }
}

function uplinkFrame(radioSlot: number, sequence: number, payload: number[]): MediaFrame {
  return {
    version: 1,
    kind: MediaKind.audioUplink,
    flags: 0,
    radioSlot,
    sequence,
    timestampUs: 1_000n,
    payload: Buffer.from(payload),
  };
}
