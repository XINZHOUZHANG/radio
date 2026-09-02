import { WSJTXLib, WSJTXMode } from "wsjtx-lib";

import type {
  WsjtxChildRequest,
  WsjtxChildResponse,
  WsjtxDecodeRequestMessage,
  WsjtxEncodeRequestMessage,
} from "./wsjtx-protocol.ts";

const library = new WSJTXLib({ maxThreads: 1, encodeSampleRate: 12_000 });
let tail: Promise<void> = Promise.resolve();
let shuttingDown = false;

process.on("message", (value: unknown) => {
  if (shuttingDown) {
    return;
  }
  tail = tail.then(
    () => handleMessage(value),
    () => handleMessage(value),
  );
});

process.once("disconnect", () => {
  shuttingDown = true;
});

process.once("uncaughtException", (error) => fatal(error));
process.once("unhandledRejection", (error) => fatal(error));
send({ t: "ready" });

async function handleMessage(value: unknown): Promise<void> {
  let request: WsjtxChildRequest;
  try {
    request = childRequest(value);
  } catch (error) {
    fatal(error);
    return;
  }
  if (request.t === "shutdown") {
    shuttingDown = true;
    process.disconnect();
    return;
  }
  try {
    if (request.t === "encode") {
      await encode(request);
    } else {
      await decode(request);
    }
  } catch (error) {
    send({
      t: "error",
      id: request.id,
      message: errorMessage(error),
      ...(errorCode(error) === undefined ? {} : { code: errorCode(error) }),
    });
  }
}

async function encode(request: WsjtxEncodeRequestMessage): Promise<void> {
  const result = await library.encode(
    nativeMode(request.mode),
    request.message,
    request.audioFrequencyHz,
    1,
  );
  if (normalizeMessage(result.messageSent) !== normalizeMessage(request.message)) {
    throw new Error(
      `encoder changed message text: requested="${request.message}" sent="${result.messageSent}"`,
    );
  }
  const pcm = floatToInt16(result.audioData);
  send({
    t: "encoded",
    id: request.id,
    pcm,
    sampleRate: result.sampleRate,
    durationMs: Math.round(pcm.length * 1_000 / result.sampleRate),
    messageSent: result.messageSent.trim(),
  });
}

async function decode(request: WsjtxDecodeRequestMessage): Promise<void> {
  const result = await library.decode(nativeMode(request.mode), request.pcm, {
    frequency: request.nominalFrequencyHz,
    txFrequency: request.nominalFrequencyHz,
    threads: 1,
    lowFreq: 200,
    highFreq: 4_000,
    tolerance: 20,
    apDecode: true,
    decodeDepth: 1,
    myCall: request.myCall,
    myGrid: request.myGrid,
  });
  if (!result.success) {
    throw new Error(result.error ?? "WSJT-X decode failed");
  }
  send({
    t: "decoded",
    id: request.id,
    frames: result.messages.map((message) => ({
      message: message.text.trim(),
      snrDb: message.snr,
      deltaTimeSeconds: message.deltaTime,
      audioFrequencyHz: message.deltaFrequency,
      confidence: 1,
    })),
  });
}

function childRequest(value: unknown): WsjtxChildRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid DSP child request");
  }
  const request = value as Record<string, unknown> & { t?: unknown };
  if (request.t === "shutdown") {
    return { t: "shutdown" };
  }
  if (request.t !== "encode" && request.t !== "decode") {
    throw new Error("unsupported DSP child request");
  }
  if (typeof request.id !== "string" || !/^[A-Za-z0-9_-]{1,128}$/u.test(request.id)) {
    throw new Error("invalid DSP request id");
  }
  if (request.mode !== "FT8" && request.mode !== "FT4") {
    throw new Error("invalid DSP mode");
  }
  if (request.t === "encode") {
    if (
      typeof request.message !== "string" || request.message.length < 1 ||
      request.message.length > 37 || !validAudioFrequency(request.audioFrequencyHz)
    ) {
      throw new Error("invalid DSP encode request");
    }
    return request as unknown as WsjtxEncodeRequestMessage;
  }
  if (
    !(request.pcm instanceof Int16Array) || request.pcm.length < 1 ||
    request.pcm.length > 12_000 * 20 ||
    !validAudioFrequency(request.nominalFrequencyHz) ||
    typeof request.myCall !== "string" || request.myCall.length < 3 || request.myCall.length > 16 ||
    (request.myGrid !== undefined &&
      (typeof request.myGrid !== "string" || request.myGrid.length < 4 || request.myGrid.length > 6))
  ) {
    throw new Error("invalid DSP decode request");
  }
  return request as unknown as WsjtxDecodeRequestMessage;
}

function nativeMode(mode: "FT8" | "FT4"): WSJTXMode {
  return mode === "FT8" ? WSJTXMode.FT8 : WSJTXMode.FT4;
}

function floatToInt16(input: Float32Array): Int16Array {
  const output = new Int16Array(input.length);
  for (let index = 0; index < input.length; index += 1) {
    const value = Math.max(-1, Math.min(1, input[index]));
    output[index] = Math.max(-32_768, Math.min(32_767, Math.round(value * 32_768)));
  }
  return output;
}

function validAudioFrequency(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= 6_000;
}

function normalizeMessage(value: string): string {
  return value.trim().toUpperCase().replace(/\s+/gu, " ");
}

function send(value: WsjtxChildResponse): void {
  if (process.connected && !shuttingDown) {
    process.send?.(value);
  }
}

function fatal(error: unknown): void {
  if (shuttingDown) {
    return;
  }
  send({ t: "fatal", message: errorMessage(error) });
  shuttingDown = true;
  process.exitCode = 1;
  process.disconnect();
}

function errorCode(error: unknown): string | undefined {
  if (error !== null && typeof error === "object" && "code" in error) {
    const value = (error as { code?: unknown }).code;
    return typeof value === "string" ? value : undefined;
  }
  return undefined;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
