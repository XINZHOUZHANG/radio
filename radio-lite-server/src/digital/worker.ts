import type { RadioProfile } from "../config/types.ts";
import type {
  DigitalDecodeBatchInput,
  DigitalMode,
} from "./types.ts";

export type DigitalEncodeRequest = {
  requestId: string;
  radioId: string;
  mode: DigitalMode;
  message: string;
  audioFrequencyHz: number;
};

export type PreparedDigitalTransmission = {
  requestId: string;
  radioId: string;
  mode: DigitalMode;
  message: string;
  audioFrequencyHz: number;
  sampleRate: number;
  durationMs: number;
  payload: unknown;
};

export type DigitalWorkerOutput = {
  decoded(batch: DigitalDecodeBatchInput): void;
  fault(error: unknown): void;
};

export type DigitalWorker = {
  start(output: DigitalWorkerOutput): Promise<void>;
  prepare(request: DigitalEncodeRequest): Promise<PreparedDigitalTransmission>;
  transmit(prepared: PreparedDigitalTransmission, signal: AbortSignal): Promise<void>;
  stopTransmission(): Promise<void>;
  close(): Promise<void>;
};

export type DigitalWorkerFactory = (
  profile: RadioProfile,
) => Promise<DigitalWorker> | DigitalWorker;
