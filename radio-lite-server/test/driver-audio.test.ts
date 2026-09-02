import assert from "node:assert/strict";
import { test } from "node:test";

import {
  BoundedDriverAudioDuplex,
  DriverAudioClosedError,
} from "../src/media/driver-audio.ts";

test("driver audio preserves exact 12 kHz mono PCM frames", async () => {
  const writes: Int16Array[] = [];
  const audio = new BoundedDriverAudioDuplex(async (frame) => {
    writes.push(frame);
  });
  const received = Int16Array.of(100, -100, 200, -200);
  const transmitted = Int16Array.of(-300, 300, -400, 400);

  audio.pushRx(received);
  assert.deepEqual(await audio.read(), received);
  await audio.write(transmitted);

  assert.equal(audio.sampleRateHz, 12_000);
  assert.equal(audio.channelCount, 1);
  assert.deepEqual(writes, [transmitted]);
});

test("driver audio bounds RX and drops the oldest frame on overflow", async () => {
  const audio = new BoundedDriverAudioDuplex(async () => undefined, { maxRxFrames: 2 });

  audio.pushRx(Int16Array.of(1));
  audio.pushRx(Int16Array.of(2));
  audio.pushRx(Int16Array.of(3));

  assert.deepEqual(await audio.read(), Int16Array.of(2));
  assert.deepEqual(await audio.read(), Int16Array.of(3));
});

test("driver audio close rejects pending and future work deterministically", async () => {
  let releaseWrite: (() => void) | undefined;
  const audio = new BoundedDriverAudioDuplex(() => new Promise<void>((resolve) => {
    releaseWrite = resolve;
  }));
  const pendingRead = audio.read();
  const pendingWrite = audio.write(Int16Array.of(7));

  audio.close();

  await assert.rejects(pendingRead, DriverAudioClosedError);
  await assert.rejects(pendingWrite, DriverAudioClosedError);
  await assert.rejects(audio.read(), DriverAudioClosedError);
  await assert.rejects(audio.write(Int16Array.of(8)), DriverAudioClosedError);
  releaseWrite?.();
});
