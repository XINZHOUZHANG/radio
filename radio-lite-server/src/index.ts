import { resolve } from "node:path";

import { RadioLiteService } from "./server/radio-lite-service.ts";

const dataDirectory = resolve(process.env.RADIO_LITE_DATA_DIR ?? "./data");
const host = process.env.RADIO_LITE_HOST ?? "127.0.0.1";
const port = parsePort(process.env.RADIO_LITE_PORT ?? "8787");
const allowInsecure = process.env.RADIO_LITE_ALLOW_INSECURE === "1";

const service = new RadioLiteService({ dataDirectory });
let shutdownStarted = false;
let requestedExitCode = 0;

const beginShutdown = (exitCode: number): void => {
  requestedExitCode = Math.max(requestedExitCode, exitCode);
  if (shutdownStarted) return;
  shutdownStarted = true;
  void service.close().then(
    () => process.exit(requestedExitCode),
    () => {
      process.stderr.write("Radio Lite shutdown cleanup could not be confirmed.\n");
      process.exit(1);
    },
  );
};

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  process.once(signal, () => beginShutdown(0));
}
process.once("uncaughtException", (error) => {
  process.stderr.write(`Radio Lite uncaught exception: ${errorMessage(error)}\n`);
  beginShutdown(1);
});
process.once("unhandledRejection", (reason) => {
  process.stderr.write(`Radio Lite unhandled rejection: ${errorMessage(reason)}\n`);
  beginShutdown(1);
});

await service.initialize();
if (service.setupCode !== null) {
  process.stdout.write(`Radio Lite first administrator code: ${service.setupCode}\n`);
  process.stdout.write("The code expires in 10 minutes and is never written to disk.\n");
}
const address = await service.listen(port, host, allowInsecure);
process.stdout.write(`Radio Lite listening on http://${address.host}:${address.port}\n`);

function parsePort(value: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 65_535) {
    throw new Error("RADIO_LITE_PORT must be in 1..65535");
  }
  return parsed;
}

function errorMessage(value: unknown): string {
  return value instanceof Error ? value.stack ?? value.message : String(value);
}
