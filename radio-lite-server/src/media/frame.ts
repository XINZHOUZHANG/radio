export const MEDIA_PROTOCOL_VERSION = 1;
export const MEDIA_HEADER_BYTES = 16;
export const MAX_MEDIA_PAYLOAD_BYTES = 65_536 - MEDIA_HEADER_BYTES;

export const MediaKind = {
  audioDownlink: 1,
  audioUplink: 2,
  spectrum: 3,
  statistics: 4,
} as const;

export type MediaKindValue = typeof MediaKind[keyof typeof MediaKind];

export type MediaFrame = {
  version: typeof MEDIA_PROTOCOL_VERSION;
  kind: MediaKindValue;
  flags: number;
  radioSlot: number;
  sequence: number;
  timestampUs: bigint;
  payload: Buffer;
};

export class MediaFrameError extends Error {}

export function encodeMediaFrame(
  frame: Omit<MediaFrame, "version"> & { version?: typeof MEDIA_PROTOCOL_VERSION },
): Buffer {
  const version = frame.version ?? MEDIA_PROTOCOL_VERSION;
  if (version !== MEDIA_PROTOCOL_VERSION) {
    throw new MediaFrameError("unsupported media protocol version");
  }
  if (!Object.values(MediaKind).includes(frame.kind)) {
    throw new MediaFrameError("unknown media frame kind");
  }
  byte(frame.flags, "flags");
  byte(frame.radioSlot, "radioSlot");
  uint32(frame.sequence, "sequence");
  if (typeof frame.timestampUs !== "bigint" || frame.timestampUs < 0n || frame.timestampUs > 0xffff_ffff_ffff_ffffn) {
    throw new MediaFrameError("timestampUs must be an unsigned 64-bit integer");
  }
  if (!Buffer.isBuffer(frame.payload) || frame.payload.length > MAX_MEDIA_PAYLOAD_BYTES) {
    throw new MediaFrameError(`media payload must be a Buffer up to ${MAX_MEDIA_PAYLOAD_BYTES} bytes`);
  }
  const encoded = Buffer.allocUnsafe(MEDIA_HEADER_BYTES + frame.payload.length);
  encoded.writeUInt8(version, 0);
  encoded.writeUInt8(frame.kind, 1);
  encoded.writeUInt8(frame.flags, 2);
  encoded.writeUInt8(frame.radioSlot, 3);
  encoded.writeUInt32BE(frame.sequence, 4);
  encoded.writeBigUInt64BE(frame.timestampUs, 8);
  frame.payload.copy(encoded, MEDIA_HEADER_BYTES);
  return encoded;
}

export function decodeMediaFrame(encoded: Uint8Array): MediaFrame {
  const buffer = Buffer.isBuffer(encoded)
    ? encoded
    : Buffer.from(encoded.buffer, encoded.byteOffset, encoded.byteLength);
  if (buffer.length < MEDIA_HEADER_BYTES || buffer.length > 65_536) {
    throw new MediaFrameError("media frame length is invalid");
  }
  const version = buffer.readUInt8(0);
  if (version !== MEDIA_PROTOCOL_VERSION) {
    throw new MediaFrameError("unsupported media protocol version");
  }
  const kind = buffer.readUInt8(1);
  if (!Object.values(MediaKind).includes(kind as MediaKindValue)) {
    throw new MediaFrameError("unknown media frame kind");
  }
  return {
    version,
    kind: kind as MediaKindValue,
    flags: buffer.readUInt8(2),
    radioSlot: buffer.readUInt8(3),
    sequence: buffer.readUInt32BE(4),
    timestampUs: buffer.readBigUInt64BE(8),
    payload: Buffer.from(buffer.subarray(MEDIA_HEADER_BYTES)),
  };
}

function byte(value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value < 0 || value > 255) {
    throw new MediaFrameError(`${field} must be an unsigned byte`);
  }
}

function uint32(value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xffff_ffff) {
    throw new MediaFrameError(`${field} must be an unsigned 32-bit integer`);
  }
}
