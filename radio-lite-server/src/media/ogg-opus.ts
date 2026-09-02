import { randomBytes } from "node:crypto";

const OGG_HEADER_BYTES = 27;
const MAX_OGG_BODY_BYTES = 255 * 255;
const MAX_READER_BUFFER_BYTES = 2 * 1_024 * 1_024;
const OGG_CAPTURE_PATTERN = Buffer.from("OggS", "ascii");
const OPUS_HEAD = Buffer.from("OpusHead", "ascii");
const OPUS_TAGS = Buffer.from("OpusTags", "ascii");

export class OggOpusError extends Error {}

export type OggOpusWriterOptions = {
  serialNumber?: number;
  inputSampleRate?: number;
  preSkip?: number;
};

export class OggOpusWriter {
  readonly #serialNumber: number;
  readonly #inputSampleRate: number;
  readonly #preSkip: number;
  #pageSequence = 0;
  #granulePosition = 0n;
  #headersWritten = false;

  constructor(options: OggOpusWriterOptions = {}) {
    this.#serialNumber = options.serialNumber ?? randomBytes(4).readUInt32LE(0);
    this.#inputSampleRate = positiveUInt32(options.inputSampleRate ?? 16_000, "input sample rate");
    this.#preSkip = uint16(options.preSkip ?? 312, "pre-skip");
  }

  headers(): Buffer {
    if (this.#headersWritten) {
      throw new OggOpusError("Ogg Opus headers were already written");
    }
    this.#headersWritten = true;
    const head = Buffer.alloc(19);
    OPUS_HEAD.copy(head, 0);
    head.writeUInt8(1, 8);
    head.writeUInt8(1, 9);
    head.writeUInt16LE(this.#preSkip, 10);
    head.writeUInt32LE(this.#inputSampleRate, 12);
    head.writeInt16LE(0, 16);
    head.writeUInt8(0, 18);

    const vendor = Buffer.from("Radio Lite", "utf8");
    const tags = Buffer.alloc(8 + 4 + vendor.length + 4);
    OPUS_TAGS.copy(tags, 0);
    tags.writeUInt32LE(vendor.length, 8);
    vendor.copy(tags, 12);
    tags.writeUInt32LE(0, 12 + vendor.length);
    return Buffer.concat([
      this.#page(head, 0x02, 0n),
      this.#page(tags, 0x00, 0n),
    ]);
  }

  packet(packet: Uint8Array, samplesAt48Khz = 960): Buffer {
    if (!(packet instanceof Uint8Array) || packet.byteLength < 1 || packet.byteLength > MAX_OGG_BODY_BYTES) {
      throw new OggOpusError(`Opus packet must contain 1..${MAX_OGG_BODY_BYTES} bytes`);
    }
    if (!Number.isSafeInteger(samplesAt48Khz) || samplesAt48Khz < 120 || samplesAt48Khz > 5_760) {
      throw new OggOpusError("Opus packet duration is invalid");
    }
    this.#granulePosition += BigInt(samplesAt48Khz);
    return this.#page(
      Buffer.from(packet.buffer, packet.byteOffset, packet.byteLength),
      0x00,
      this.#granulePosition,
    );
  }

  #page(packet: Buffer, headerType: number, granulePosition: bigint): Buffer {
    const fullSegments = Math.floor(packet.length / 255);
    const needsTerminator = packet.length % 255 === 0;
    const segmentCount = fullSegments + (needsTerminator ? 1 : 1);
    if (segmentCount > 255) {
      throw new OggOpusError("Opus packet requires too many Ogg lacing segments");
    }
    const page = Buffer.alloc(OGG_HEADER_BYTES + segmentCount + packet.length);
    OGG_CAPTURE_PATTERN.copy(page, 0);
    page.writeUInt8(0, 4);
    page.writeUInt8(headerType, 5);
    page.writeBigUInt64LE(granulePosition, 6);
    page.writeUInt32LE(this.#serialNumber, 14);
    page.writeUInt32LE(this.#pageSequence, 18);
    page.writeUInt32LE(0, 22);
    page.writeUInt8(segmentCount, 26);
    let remaining = packet.length;
    for (let index = 0; index < segmentCount; index += 1) {
      const length = Math.min(255, remaining);
      page.writeUInt8(length, OGG_HEADER_BYTES + index);
      remaining -= length;
    }
    packet.copy(page, OGG_HEADER_BYTES + segmentCount);
    page.writeUInt32LE(oggChecksum(page), 22);
    this.#pageSequence = this.#pageSequence === 0xffff_ffff ? 0 : this.#pageSequence + 1;
    return page;
  }
}

export class OggOpusPacketReader {
  readonly #requireHeaders: boolean;
  #buffer = Buffer.alloc(0);
  #partialPacket: Buffer[] = [];
  #sawHead = false;
  #sawTags = false;

  constructor(options: { requireHeaders?: boolean } = {}) {
    this.#requireHeaders = options.requireHeaders !== false;
  }

  push(chunk: Uint8Array): Buffer[] {
    if (!(chunk instanceof Uint8Array) || chunk.byteLength === 0) {
      return [];
    }
    const incoming = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
    if (this.#buffer.length + incoming.length > MAX_READER_BUFFER_BYTES) {
      throw new OggOpusError("Ogg input buffer exceeded its safety limit");
    }
    this.#buffer = this.#buffer.length === 0
      ? Buffer.from(incoming)
      : Buffer.concat([this.#buffer, incoming]);
    const packets: Buffer[] = [];
    while (this.#buffer.length >= OGG_HEADER_BYTES) {
      if (!this.#buffer.subarray(0, 4).equals(OGG_CAPTURE_PATTERN)) {
        throw new OggOpusError("invalid Ogg capture pattern");
      }
      if (this.#buffer.readUInt8(4) !== 0) {
        throw new OggOpusError("unsupported Ogg stream version");
      }
      const segmentCount = this.#buffer.readUInt8(26);
      if (this.#buffer.length < OGG_HEADER_BYTES + segmentCount) {
        break;
      }
      let bodyLength = 0;
      for (let index = 0; index < segmentCount; index += 1) {
        bodyLength += this.#buffer.readUInt8(OGG_HEADER_BYTES + index);
      }
      const pageLength = OGG_HEADER_BYTES + segmentCount + bodyLength;
      if (this.#buffer.length < pageLength) {
        break;
      }
      const page = this.#buffer.subarray(0, pageLength);
      validateChecksum(page);
      this.#readPage(page, packets);
      this.#buffer = Buffer.from(this.#buffer.subarray(pageLength));
    }
    return packets;
  }

  #readPage(page: Buffer, output: Buffer[]): void {
    const segmentCount = page.readUInt8(26);
    const continued = (page.readUInt8(5) & 0x01) !== 0;
    if (continued !== (this.#partialPacket.length > 0)) {
      throw new OggOpusError("Ogg packet continuation state is invalid");
    }
    let bodyOffset = OGG_HEADER_BYTES + segmentCount;
    for (let index = 0; index < segmentCount; index += 1) {
      const length = page.readUInt8(OGG_HEADER_BYTES + index);
      this.#partialPacket.push(Buffer.from(page.subarray(bodyOffset, bodyOffset + length)));
      bodyOffset += length;
      if (length < 255) {
        const packet = Buffer.concat(this.#partialPacket);
        this.#partialPacket = [];
        if (packet.subarray(0, OPUS_HEAD.length).equals(OPUS_HEAD)) {
          this.#sawHead = true;
          continue;
        }
        if (packet.subarray(0, OPUS_TAGS.length).equals(OPUS_TAGS)) {
          this.#sawTags = true;
          continue;
        }
        if (this.#requireHeaders && (!this.#sawHead || !this.#sawTags)) {
          throw new OggOpusError("Ogg audio arrived before Opus headers");
        }
        output.push(packet);
      }
    }
  }
}

function validateChecksum(page: Buffer): void {
  const expected = page.readUInt32LE(22);
  const copy = Buffer.from(page);
  copy.writeUInt32LE(0, 22);
  if (oggChecksum(copy) !== expected) {
    throw new OggOpusError("Ogg page checksum is invalid");
  }
}

const CRC_TABLE = createCrcTable();

function oggChecksum(value: Uint8Array): number {
  let crc = 0;
  for (const byte of value) {
    crc = ((crc << 8) ^ CRC_TABLE[((crc >>> 24) ^ byte) & 0xff]) >>> 0;
  }
  return crc;
}

function createCrcTable(): Uint32Array {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let value = index << 24;
    for (let bit = 0; bit < 8; bit += 1) {
      value = ((value & 0x8000_0000) !== 0
        ? (value << 1) ^ 0x04c1_1db7
        : value << 1) >>> 0;
    }
    table[index] = value;
  }
  return table;
}

function positiveUInt32(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value < 1 || value > 0xffff_ffff) {
    throw new OggOpusError(`${field} must be a positive UInt32`);
  }
  return value;
}

function uint16(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xffff) {
    throw new OggOpusError(`${field} must be a UInt16`);
  }
  return value;
}
