export const DIGITAL_MODES = ["FT8", "FT4"] as const;

export type DigitalMode = (typeof DIGITAL_MODES)[number];
export type SlotParity = "even" | "odd";

export type RawDigitalDecode = {
  message: string;
  snrDb: number;
  deltaTimeSeconds: number;
  audioFrequencyHz: number;
  confidence?: number;
};

export type DigitalDecode = {
  id: string;
  message: string;
  snrDb: number;
  deltaTimeSeconds: number;
  audioFrequencyHz: number;
  confidence: number;
};

export type DigitalDecodeBatch = {
  radioId: string;
  mode: DigitalMode;
  slotStartMs: number;
  slotEndMs: number;
  receivedAtMs: number;
  revision: number;
  decodes: DigitalDecode[];
};

export type DigitalDecodeBatchInput = {
  radioId: string;
  mode: DigitalMode;
  slotStartMs: number;
  receivedAtMs: number;
  frames: readonly RawDigitalDecode[];
};

export type DigitalDecodeSnapshot = {
  radioId: string;
  revision: number;
  batches: DigitalDecodeBatch[];
};

export function isDigitalMode(value: unknown): value is DigitalMode {
  return value === "FT8" || value === "FT4";
}
