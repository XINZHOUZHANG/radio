import { createServer } from "node:net";
import { constants } from "node:fs";
import { access } from "node:fs/promises";
import { delimiter, join } from "node:path";

import {
  negotiateAudioRoute,
  requiredSystemMediaExecutables,
  resolveAudioRoute,
  systemAudioDuplexProbe,
  type AudioDuplexProbe,
} from "../media/system-media-worker.ts";
export { resolveAudioRoute } from "../media/system-media-worker.ts";
import type { RigResponse } from "../rig/extended-protocol.ts";
import { ManagedRigctldProcess } from "../rig/managed-process.ts";
import { rigctldTarget, type RigctldTarget } from "../rig/rigctld-command.ts";
import { RigctldTransport } from "../rig/transport.ts";
import type { HardwareDiscoveryResult } from "./hardware-discovery.ts";
import { HardwareDiscovery } from "./hardware-discovery.ts";
import type { AudioEndpoint, RadioProfile } from "./types.ts";

export type HardwarePreflightStatus = "passed" | "warning" | "failed";
export type HardwarePreflightCheckId = "cat" | "capabilities" | "audioInput" | "audioOutput";

export type HardwarePreflightCheck = {
  id: HardwarePreflightCheckId;
  status: HardwarePreflightStatus;
  message: string;
  details: Record<string, string>;
};

export type HardwarePreflightResult = {
  profileId: string;
  testedAtMs: number;
  readOnly: true;
  overallStatus: HardwarePreflightStatus;
  checks: HardwarePreflightCheck[];
  negotiatedRates?: { input: number; output: number };
};

export type HardwarePreflightRunner = {
  test(profile: RadioProfile): Promise<HardwarePreflightResult>;
};

export class HardwarePreflightCleanupUncertainError extends Error {}

export type ReadOnlyRigSession = {
  request(command: string): Promise<RigResponse>;
  close(): Promise<void>;
};

export type HardwarePreflightOptions = {
  now?: () => number;
  openRig?: (profile: RadioProfile) => Promise<ReadOnlyRigSession>;
  discover?: () => Promise<HardwareDiscoveryResult>;
  commandAvailable?: (executable: string) => Promise<boolean>;
  duplexProbe?: AudioDuplexProbe;
};

const READ_ONLY_COMMANDS = [
  "\\get_freq",
  "\\get_mode",
  "\\get_ptt",
  "\\get_func TUNER",
  "\\get_level ?",
  "\\get_func ?",
] as const;

/**
 * Tests a draft profile without registering a runtime or changing server state.
 * Every rigctld request in this class is an explicit get_* query. It never
 * acquires a control lease and never sends PTT, tuner, frequency or mode writes.
 */
export class HardwarePreflight implements HardwarePreflightRunner {
  readonly #now: () => number;
  readonly #openRig: (profile: RadioProfile) => Promise<ReadOnlyRigSession>;
  readonly #discover: () => Promise<HardwareDiscoveryResult>;
  readonly #commandAvailable: (executable: string) => Promise<boolean>;
  readonly #duplexProbe: AudioDuplexProbe;

  constructor(options: HardwarePreflightOptions = {}) {
    this.#now = options.now ?? Date.now;
    this.#openRig = options.openRig ?? openDefaultReadOnlyRig;
    const discovery = new HardwareDiscovery();
    this.#discover = options.discover ?? (() => discovery.discover());
    this.#commandAvailable = options.commandAvailable ?? commandAvailableOnPath;
    this.#duplexProbe = options.duplexProbe ?? systemAudioDuplexProbe;
  }

  async test(profile: RadioProfile): Promise<HardwarePreflightResult> {
    if (profile.connection.kind === "hamlib-dummy") {
      return dummyResult(profile, this.#now());
    }

    const requirements = requiredSystemMediaExecutables(profile);
    const missingAudioInputCommands = await missingCommands(
      requirements.audioInput,
      this.#commandAvailable,
    );
    const missingAudioOutputCommands = await missingCommands(
      requirements.audioOutput,
      this.#commandAvailable,
    );
    const managedRigctldAvailable = profile.connection.kind !== "managed-serial" ||
      await this.#commandAvailable("rigctld");
    const audioPromise = this.#discover()
      .then((value) => ({ value, error: null }))
      .catch((error: unknown) => ({ value: null, error }));
    let session: ReadOnlyRigSession | null = null;
    let cat: HardwarePreflightCheck;
    let capabilities: HardwarePreflightCheck;
    let closeFailed = false;
    let closeFailure: unknown = null;
    if (!managedRigctldAvailable) {
      cat = {
        id: "cat",
        status: "failed",
        message: "Required managed rigctld executable is not available on the service PATH",
        details: { executable: "rigctld" },
      };
      capabilities = {
        id: "capabilities",
        status: "failed",
        message: "Capabilities were not queried because managed rigctld is unavailable",
        details: {},
      };
    } else {
      try {
        session = await this.#openRig(profile);
        const frequency = await session.request(READ_ONLY_COMMANDS[0]);
        const mode = await session.request(READ_ONLY_COMMANDS[1]);
        const frequencyHz = integerField(frequency, "Frequency", 0);
        const modeName = textField(mode, "Mode", 0);
        const passbandHz = integerField(mode, "Passband", 1);
        cat = {
          id: "cat",
          status: "passed",
          message: "CAT connection and frequency/mode readback succeeded",
          details: {
            frequencyHz: String(frequencyHz),
            mode: modeName,
            passbandHz: String(passbandHz),
          },
        };
        capabilities = await readCapabilities(session);
      } catch (error) {
        if (error instanceof HardwarePreflightCleanupUncertainError) {
          throw error;
        }
        const message = safeErrorMessage(error, "CAT readback failed");
        cat = {
          id: "cat",
          status: "failed",
          message,
          details: {},
        };
        capabilities = {
          id: "capabilities",
          status: "failed",
          message: "Capabilities were not queried because CAT readback failed",
          details: {},
        };
      } finally {
        if (session !== null) {
          try {
            await session.close();
          } catch (error) {
            closeFailed = true;
            closeFailure = error;
          }
        }
      }
    }

    if (closeFailed) {
      const closeMessage = safeErrorMessage(closeFailure, "rigctld cleanup failed");
      if (profile.connection.kind === "managed-serial") {
        throw new HardwarePreflightCleanupUncertainError(
          `Managed rigctld cleanup could not be confirmed: ${closeMessage}`,
          { cause: closeFailure },
        );
      }
      capabilities = {
        ...capabilities,
        status: capabilities.status === "failed" ? "failed" : "warning",
        message: `${capabilities.message}; ${closeMessage}`,
        details: { ...capabilities.details, cleanup: "failed" },
      };
    }

    const audio = await audioPromise;
    let audioInputEndpoint = profile.audioInput;
    let audioOutputEndpoint = profile.audioOutput;
    let audioRouteError: unknown = null;
    let negotiatedRates: HardwarePreflightResult["negotiatedRates"];
    if (profile.audioRoute?.kind === "system-device") {
      try {
        if (audio.value === null) throw audio.error ?? new Error("Audio discovery is unavailable");
        const resolved = resolveAudioRoute(profile.audioRoute, audio.value);
        audioInputEndpoint = resolved.input;
        audioOutputEndpoint = resolved.output;
        if (missingAudioInputCommands.length === 0 && missingAudioOutputCommands.length === 0) {
          const negotiated = await negotiateAudioRoute(resolved, this.#duplexProbe);
          negotiatedRates = {
            input: negotiated.input.sampleRate,
            output: negotiated.output.sampleRate,
          };
        }
      } catch (error) {
        audioRouteError = error;
      }
    }
    const audioInput = audioCheck(
      "audioInput",
      audioInputEndpoint,
      audio.value?.audioInputs ?? null,
      audio.error,
      audio.value?.warnings ?? [],
      missingAudioInputCommands,
      audioRouteError,
      negotiatedRates?.input,
    );
    const audioOutput = audioCheck(
      "audioOutput",
      audioOutputEndpoint,
      audio.value?.audioOutputs ?? null,
      audio.error,
      audio.value?.warnings ?? [],
      missingAudioOutputCommands,
      audioRouteError,
      negotiatedRates?.output,
    );
    const checks = [cat, capabilities, audioInput, audioOutput];
    return {
      profileId: profile.id,
      testedAtMs: this.#now(),
      readOnly: true,
      overallStatus: overallStatus(checks),
      checks,
      ...(negotiatedRates === undefined ? {} : { negotiatedRates }),
    };
  }
}

async function readCapabilities(session: ReadOnlyRigSession): Promise<HardwarePreflightCheck> {
  const ptt = await optionalRead(session, READ_ONLY_COMMANDS[2]);
  const tuner = await optionalRead(session, READ_ONLY_COMMANDS[3]);
  const levels = await optionalRead(session, READ_ONLY_COMMANDS[4]);
  const functions = await optionalRead(session, READ_ONLY_COMMANDS[5]);
  const readableLevels = levels === null ? [] : tokenList(levels, "Level");
  const readableFunctions = functions === null ? [] : tokenList(functions, "Func");
  const complete = ptt !== null && tuner !== null && levels !== null && functions !== null;
  return {
    id: "capabilities",
    status: complete ? "passed" : "warning",
    message: complete
      ? "Read-only Hamlib capability queries succeeded"
      : "CAT is available, but one or more optional capability queries are unsupported",
    details: {
      pttReadback: String(ptt !== null),
      internalTunerReadback: String(tuner !== null),
      readableLevels: readableLevels.join(","),
      readableFunctions: readableFunctions.join(","),
    },
  };
}

async function optionalRead(
  session: ReadOnlyRigSession,
  command: typeof READ_ONLY_COMMANDS[number],
): Promise<RigResponse | null> {
  try {
    return await session.request(command);
  } catch {
    return null;
  }
}

function audioCheck(
  id: "audioInput" | "audioOutput",
  endpoint: AudioEndpoint,
  devices: HardwareDiscoveryResult["audioInputs"] | null,
  discoveryError: unknown,
  discoveryWarnings: readonly string[],
  missingExecutables: readonly string[],
  routeError: unknown = null,
  negotiatedRate?: number,
): HardwarePreflightCheck {
  const details: Record<string, string> = {
    backend: endpoint.backend,
    id: endpoint.id,
  };
  if (missingExecutables.length > 0) {
    return {
      id,
      status: "failed",
      message: `Required system executable is unavailable: ${missingExecutables.join(", ")}`,
      details: { ...details, missingExecutables: missingExecutables.join(",") },
    };
  }
  if (routeError !== null) {
    return {
      id,
      status: "failed",
      message: safeErrorMessage(routeError, "Configured audio route could not be resolved"),
      details: { ...details, discovered: "false" },
    };
  }
  if (devices === null) {
    return {
      id,
      status: "warning",
      message: safeErrorMessage(discoveryError, "Audio endpoint discovery is unavailable"),
      details: { ...details, discovered: "false" },
    };
  }
  if (discoveryWarnings.includes("audio_discovery_unavailable")) {
    return {
      id,
      status: "warning",
      message: "Audio devices could not be enumerated on this host",
      details: { ...details, discovered: "false" },
    };
  }
  const matched = devices.find((device) =>
    device.backend === endpoint.backend && device.id === endpoint.id
  );
  if (matched === undefined) {
    return {
      id,
      status: "warning",
      message: "Configured audio endpoint was not found during read-only discovery",
      details: { ...details, discovered: "false" },
    };
  }
  return {
    id,
    status: "passed",
    message: negotiatedRate === undefined
      ? "Configured audio endpoint was found"
      : "Configured audio endpoint opened successfully",
    details: {
      ...details,
      discovered: "true",
      label: matched.label,
      ...(negotiatedRate === undefined ? {} : { negotiatedRate: String(negotiatedRate) }),
    },
  };
}

async function missingCommands(
  executables: readonly string[],
  commandAvailable: (executable: string) => Promise<boolean>,
): Promise<string[]> {
  const missing: string[] = [];
  for (const executable of executables) {
    if (!await commandAvailable(executable)) {
      missing.push(executable);
    }
  }
  return missing;
}

async function commandAvailableOnPath(executable: string): Promise<boolean> {
  const pathEntries = process.env.PATH?.split(delimiter) ?? [];
  return (await Promise.all(pathEntries.map(async (directory) => {
    try {
      await access(join(directory, executable), constants.X_OK);
      return true;
    } catch {
      return false;
    }
  }))).some(Boolean);
}

function dummyResult(profile: RadioProfile, testedAtMs: number): HardwarePreflightResult {
  return {
    profileId: profile.id,
    testedAtMs,
    readOnly: true,
    overallStatus: "passed",
    checks: [
      {
        id: "cat",
        status: "passed",
        message: "Hamlib Dummy deterministic CAT readback succeeded",
        details: { frequencyHz: "14074000", mode: "PKTUSB", passbandHz: "3000" },
      },
      {
        id: "capabilities",
        status: "passed",
        message: "Hamlib Dummy read-only capabilities are available",
        details: {
          pttReadback: "true",
          internalTunerReadback: "true",
          readableLevels: "AF,RF,SQL,RFPOWER,MICGAIN",
          readableFunctions: "NB,NR,ANF,TUNER",
        },
      },
      {
        id: "audioInput",
        status: "passed",
        message: "Synthetic receive-audio input is available",
        details: { backend: profile.audioInput.backend, id: profile.audioInput.id, discovered: "true" },
      },
      {
        id: "audioOutput",
        status: "passed",
        message: "Synthetic transmit-audio output is available",
        details: { backend: profile.audioOutput.backend, id: profile.audioOutput.id, discovered: "true" },
      },
    ],
  };
}

function overallStatus(checks: readonly HardwarePreflightCheck[]): HardwarePreflightStatus {
  if (checks.some((check) => check.status === "failed")) {
    return "failed";
  }
  return checks.some((check) => check.status === "warning") ? "warning" : "passed";
}

function integerField(response: RigResponse, field: string, valueIndex: number): number {
  const raw = response.fields.get(field) ?? response.values[valueIndex];
  if (raw === undefined || !/^-?\d+$/u.test(raw.trim())) {
    throw new Error(`rigctld ${field} readback is malformed`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) {
    throw new Error(`rigctld ${field} readback is outside the safe integer range`);
  }
  return value;
}

function textField(response: RigResponse, field: string, valueIndex: number): string {
  const raw = response.fields.get(field) ?? response.values[valueIndex];
  if (raw === undefined || !/^[A-Za-z0-9_-]{1,32}$/u.test(raw.trim())) {
    throw new Error(`rigctld ${field} readback is malformed`);
  }
  return raw.trim().toUpperCase();
}

function tokenList(response: RigResponse, field: string): string[] {
  const raw = response.fields.get(field) ?? response.values.join(" ");
  return [...new Set(
    raw.split(/\s+/u)
      .map((value) => value.trim().toUpperCase())
      .filter((value) => /^[A-Z][A-Z0-9_]{0,31}$/u.test(value)),
  )].sort();
}

function safeErrorMessage(error: unknown, fallback: string): string {
  if (!(error instanceof Error) || !error.message) {
    return fallback;
  }
  const safe = error.message
    .replace(/\bBearer\s+\S+/giu, "Bearer [redacted]")
    .replace(
      /((?:password|token|secret|credential|cookie)[A-Za-z0-9_.-]*\s*[:=]\s*)\S+/giu,
      "$1[redacted]",
    )
    .replace(/[\0\r\n]+/gu, " ")
    .trim()
    .slice(0, 240);
  return safe || fallback;
}

async function openDefaultReadOnlyRig(profile: RadioProfile): Promise<ReadOnlyRigSession> {
  const managedPort = await availableLoopbackPort();
  const target = hardwarePreflightRigctldTarget(profile, managedPort);
  const managed = target.command === undefined ? null : new ManagedRigctldProcess(target.command);
  try {
    await managed?.start();
    const transport = new RigctldTransport(target.host, target.port);
    return {
      request: (command) => transport.request(assertReadOnlyCommand(command)),
      close: async () => {
        await transport.close().catch(() => undefined);
        await managed?.close();
      },
    };
  } catch (error) {
    try {
      await managed?.close();
    } catch (cleanupError) {
      throw new HardwarePreflightCleanupUncertainError(
        "Managed rigctld cleanup could not be confirmed after startup failure",
        { cause: new AggregateError([error, cleanupError]) },
      );
    }
    throw error;
  }
}

export function hardwarePreflightRigctldTarget(
  profile: RadioProfile,
  managedPort: number,
): RigctldTarget {
  if (profile.connection.kind === "network-rigctld") {
    return rigctldTarget(profile, managedPort);
  }
  return rigctldTarget(
    {
      ...profile,
      ptt: { method: "None" },
      hardwareTxEnabled: false,
    },
    managedPort,
  );
}

function assertReadOnlyCommand(command: string): string {
  if (!READ_ONLY_COMMANDS.includes(command as typeof READ_ONLY_COMMANDS[number])) {
    throw new Error("hardware preflight rejected a non-read-only rig command");
  }
  return command;
}

function availableLoopbackPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.unref();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (address === null || typeof address === "string") {
        server.close();
        reject(new Error("unable to allocate a loopback port for hardware preflight"));
        return;
      }
      const port = address.port;
      server.close((error) => error === undefined ? resolve(port) : reject(error));
    });
  });
}
