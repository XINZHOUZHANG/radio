import type { DigitalMode } from "./types.ts";

export type WsjtxEncodeRequestMessage = {
  t: "encode";
  id: string;
  mode: DigitalMode;
  message: string;
  audioFrequencyHz: number;
};

export type WsjtxDecodeRequestMessage = {
  t: "decode";
  id: string;
  mode: DigitalMode;
  pcm: Int16Array;
  nominalFrequencyHz: number;
  myCall: string;
  myGrid?: string;
};

export type WsjtxShutdownMessage = { t: "shutdown" };

export type WsjtxChildRequest =
  | WsjtxEncodeRequestMessage
  | WsjtxDecodeRequestMessage
  | WsjtxShutdownMessage;

export type WsjtxReadyMessage = { t: "ready" };

export type WsjtxEncodedMessage = {
  t: "encoded";
  id: string;
  pcm: Int16Array;
  sampleRate: number;
  durationMs: number;
  messageSent: string;
};

export type WsjtxDecodedFrame = {
  message: string;
  snrDb: number;
  deltaTimeSeconds: number;
  audioFrequencyHz: number;
  confidence: number;
};

export type WsjtxDecodedMessage = {
  t: "decoded";
  id: string;
  frames: WsjtxDecodedFrame[];
};

export type WsjtxErrorMessage = {
  t: "error";
  id: string;
  message: string;
  code?: string;
};

export type WsjtxFatalMessage = {
  t: "fatal";
  message: string;
};

export type WsjtxChildResponse =
  | WsjtxReadyMessage
  | WsjtxEncodedMessage
  | WsjtxDecodedMessage
  | WsjtxErrorMessage
  | WsjtxFatalMessage;
