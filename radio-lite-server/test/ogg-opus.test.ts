import assert from "node:assert/strict";
import { test } from "node:test";

import { OggOpusPacketReader, OggOpusWriter } from "../src/media/ogg-opus.ts";

test("Ogg Opus framing preserves packet boundaries across arbitrary stream chunks", () => {
  const writer = new OggOpusWriter({ serialNumber: 0x1234_5678, inputSampleRate: 16_000 });
  const stream = Buffer.concat([
    writer.headers(),
    writer.packet(Buffer.from([0xf8, 0xff, 0xfe])),
    writer.packet(Buffer.from(Array.from({ length: 510 }, (_, index) => index % 251))),
  ]);
  const reader = new OggOpusPacketReader();
  const packets: Buffer[] = [];
  for (let offset = 0; offset < stream.length; offset += 7) {
    packets.push(...reader.push(stream.subarray(offset, offset + 7)));
  }
  assert.deepEqual(packets, [
    Buffer.from([0xf8, 0xff, 0xfe]),
    Buffer.from(Array.from({ length: 510 }, (_, index) => index % 251)),
  ]);
});

test("Ogg reader rejects a damaged checksum instead of forwarding corrupted audio", () => {
  const writer = new OggOpusWriter({ serialNumber: 7 });
  const page = writer.packet(Buffer.from([1, 2, 3]));
  page[page.length - 1] ^= 0xff;
  const reader = new OggOpusPacketReader({ requireHeaders: false });
  assert.throws(() => reader.push(page), /checksum/u);
});

test("Ogg writer limits packets and advances the 48 kHz Opus granule", () => {
  const writer = new OggOpusWriter({ serialNumber: 9 });
  const first = writer.packet(Buffer.from([1]), 960);
  const second = writer.packet(Buffer.from([2]), 480);
  assert.equal(first.readBigUInt64LE(6), 960n);
  assert.equal(second.readBigUInt64LE(6), 1_440n);
  assert.throws(() => writer.packet(Buffer.alloc(65_026)), /packet/u);
});
