const SPECTRUM_HEADER_BYTES = 16;

export type SpectrumPayload = {
  centerFrequencyHz: number;
  spanHz: number;
  noiseFloorTenthsDbm: number;
  bins: Uint8Array;
};

export function encodeSpectrumPayload(value: SpectrumPayload): Buffer {
  if (!Number.isSafeInteger(value.centerFrequencyHz) || value.centerFrequencyHz < 0) {
    throw new Error("centerFrequencyHz must be a non-negative safe integer");
  }
  if (!Number.isSafeInteger(value.spanHz) || value.spanHz < 1 || value.spanHz > 0xffff_ffff) {
    throw new Error("spanHz must be in 1..4294967295");
  }
  if (
    !Number.isSafeInteger(value.noiseFloorTenthsDbm) ||
    value.noiseFloorTenthsDbm < -3_276 ||
    value.noiseFloorTenthsDbm > 3_276
  ) {
    throw new Error("noiseFloorTenthsDbm is outside the signed 16-bit dBm range");
  }
  if (!(value.bins instanceof Uint8Array) || value.bins.length < 16 || value.bins.length > 4_096) {
    throw new Error("spectrum must contain 16..4096 UInt8 bins");
  }
  const payload = Buffer.allocUnsafe(SPECTRUM_HEADER_BYTES + value.bins.length);
  payload.writeBigUInt64BE(BigInt(value.centerFrequencyHz), 0);
  payload.writeUInt32BE(value.spanHz, 8);
  payload.writeInt16BE(value.noiseFloorTenthsDbm, 12);
  payload.writeUInt16BE(value.bins.length, 14);
  Buffer.from(value.bins.buffer, value.bins.byteOffset, value.bins.byteLength).copy(
    payload,
    SPECTRUM_HEADER_BYTES,
  );
  return payload;
}

export function decodeSpectrumPayload(payload: Uint8Array): SpectrumPayload {
  const buffer = Buffer.isBuffer(payload)
    ? payload
    : Buffer.from(payload.buffer, payload.byteOffset, payload.byteLength);
  if (buffer.length < SPECTRUM_HEADER_BYTES) {
    throw new Error("spectrum payload is truncated");
  }
  const binCount = buffer.readUInt16BE(14);
  if (binCount < 16 || binCount > 4_096 || buffer.length !== SPECTRUM_HEADER_BYTES + binCount) {
    throw new Error("spectrum bin count does not match payload length");
  }
  const center = buffer.readBigUInt64BE(0);
  if (center > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error("spectrum center frequency exceeds JavaScript safe integer range");
  }
  return {
    centerFrequencyHz: Number(center),
    spanHz: buffer.readUInt32BE(8),
    noiseFloorTenthsDbm: buffer.readInt16BE(12),
    bins: Uint8Array.from(buffer.subarray(SPECTRUM_HEADER_BYTES)),
  };
}
