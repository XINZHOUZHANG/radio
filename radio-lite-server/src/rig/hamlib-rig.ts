import type { PttMethod } from "../config/types.ts";
import type { RigResponse } from "./extended-protocol.ts";
import type { RadioControl, RadioState } from "./radio-driver.ts";
import { RigReportError, type RigRequestOptions } from "./transport.ts";

export type RigRequester = {
  request(command: string, options?: RigRequestOptions): Promise<RigResponse>;
};

const TELEMETRY_REQUEST = { source: "telemetry" } as const satisfies RigRequestOptions;
const PTT_OFF_REQUEST = {
  priority: "safety",
  source: "ptt-off",
} as const satisfies RigRequestOptions;
const SAFETY_READ_REQUEST = {
  priority: "safety",
  source: "ptt-off",
} as const satisfies RigRequestOptions;

export type HamlibRigState = RadioState;

export type HamlibRigControlKind = "level" | "function" | "passband";
export type HamlibRigControlUnit = "ratio" | "decibel" | "index" | "boolean" | "hertz";

export type HamlibRigControl = RadioControl & {
  kind: HamlibRigControlKind;
  value: number;
  unit: HamlibRigControlUnit;
};

type HamlibRigControlDefinition = Omit<HamlibRigControl, "value">;
type HamlibCapabilityTokens = ReadonlySet<string> | null;

export type HamlibRigOptions = {
  pttMethod?: PttMethod;
};

export type RigModeErrorReason = "rejected" | "unconfirmed";

export class InternalTunerUnsupportedError extends Error {}

export class RigModeError extends Error {
  readonly requestedMode: string;
  readonly hamlibMode: string;
  readonly reason: RigModeErrorReason;
  readonly report: number | null;

  constructor(
    requestedMode: string,
    hamlibMode: string,
    reason: RigModeErrorReason,
    report: number | null = null,
    options: ErrorOptions = {},
  ) {
    const detail = report === null ? "" : `, RPRT ${report}`;
    super(
      reason === "rejected"
        ? `radio rejected mode ${requestedMode} (Hamlib ${hamlibMode}${detail})`
        : `radio did not confirm mode ${requestedMode} (Hamlib ${hamlibMode})`,
      options,
    );
    this.name = "RigModeError";
    this.requestedMode = requestedMode;
    this.hamlibMode = hamlibMode;
    this.reason = reason;
    this.report = report;
  }
}

const DIGITAL_MODE_ALIASES = new Map<string, string>([
  ["DATAU", "PKTUSB"],
  ["DATAUSB", "PKTUSB"],
  ["USBD", "PKTUSB"],
  ["USBDATA", "PKTUSB"],
  ["DIGU", "PKTUSB"],
  ["PKTUSB", "PKTUSB"],
  ["DATAL", "PKTLSB"],
  ["DATALSB", "PKTLSB"],
  ["LSBD", "PKTLSB"],
  ["LSBDATA", "PKTLSB"],
  ["DIGL", "PKTLSB"],
  ["PKTLSB", "PKTLSB"],
  ["DATAFM", "PKTFM"],
  ["FMD", "PKTFM"],
  ["FMDATA", "PKTFM"],
  ["DIGFM", "PKTFM"],
  ["PKTFM", "PKTFM"],
]);

/**
 * Convert operator-facing digital mode names to rigctld's canonical tokens.
 * Hamlib calls the DATA-U/USB-D mode used by FT8 `PKTUSB`.
 */
export function normalizeHamlibMode(mode: string): string {
  const normalized = mode.trim().toUpperCase();
  const aliasKey = normalized.replace(/[\s_-]+/gu, "");
  const canonical = DIGITAL_MODE_ALIASES.get(aliasKey) ?? normalized;
  if (!/^[A-Z0-9_-]{1,16}$/u.test(canonical)) {
    throw new Error("mode is invalid");
  }
  return canonical;
}

const LEVEL_CONTROL_DEFINITIONS: readonly HamlibRigControlDefinition[] = [
  levelDefinition("RFPOWER", "ratio", 0, 1, 0.01, true),
  levelDefinition("AF", "ratio", 0, 1, 0.01),
  levelDefinition("RF", "ratio", 0, 1, 0.01),
  levelDefinition("SQL", "ratio", 0, 1, 0.01),
  levelDefinition("MICGAIN", "ratio", 0, 1, 0.01, true),
  levelDefinition("COMP", "ratio", 0, 1, 0.01, true),
  levelDefinition("AGC", "index", 0, 6, 1),
  levelDefinition("ATT", "decibel", 0, 60, 1),
  levelDefinition("PREAMP", "decibel", 0, 60, 1),
  levelDefinition("NB", "ratio", 0, 1, 0.01),
  levelDefinition("NR", "ratio", 0, 1, 0.01),
];

const FUNCTION_CONTROL_DEFINITIONS: readonly HamlibRigControlDefinition[] = [
  functionDefinition("COMP", true),
  functionDefinition("NB"),
  functionDefinition("NR"),
  functionDefinition("ANF"),
  functionDefinition("TUNER", true),
];

const PASSBAND_CONTROL: HamlibRigControlDefinition = {
  id: "passband:CURRENT",
  kind: "passband",
  token: "CURRENT",
  minimum: 100,
  maximum: 12_000,
  step: 50,
  unit: "hertz",
  transmitLocked: false,
};

const TRANSMIT_LOCKED_CONTROL_IDS = new Set(
  [...LEVEL_CONTROL_DEFINITIONS, ...FUNCTION_CONTROL_DEFINITIONS]
    .filter((control) => control.transmitLocked)
    .map((control) => control.id),
);

export function isTransmitLockedRigControlId(id: string): boolean {
  return TRANSMIT_LOCKED_CONTROL_IDS.has(id);
}

export class HamlibRig {
  readonly #transport: RigRequester;
  readonly #unavailablePttIsSafe: boolean;
  #lastCommandedPttForDisplayOnly = false;
  #controlDefinitions: Promise<readonly HamlibRigControlDefinition[]> | null = null;
  #vfoOperations: Promise<HamlibCapabilityTokens> | null = null;
  #writableFunctions: Promise<HamlibCapabilityTokens> | null = null;
  #tunerSwitchWritable: boolean | null | undefined;

  constructor(transport: RigRequester, options: HamlibRigOptions = {}) {
    this.#transport = transport;
    this.#unavailablePttIsSafe = options.pttMethod === "None";
  }

  async readState(): Promise<HamlibRigState> {
    const [frequency, mode, ptt] = await Promise.all([
      this.#transport.request("\\get_freq", TELEMETRY_REQUEST),
      this.#transport.request("\\get_mode", TELEMETRY_REQUEST),
      this.#readPttForDisplay(),
    ]);
    return {
      frequencyHz: integerField(frequency, "Frequency"),
      mode: tokenField(mode, "Mode"),
      passbandHz: integerField(mode, "Passband"),
      ptt,
    };
  }

  async setFrequency(frequencyHz: number): Promise<number> {
    if (!Number.isSafeInteger(frequencyHz) || frequencyHz < 100_000 || frequencyHz > 1_000_000_000_000) {
      throw new Error("frequencyHz is outside the supported numeric range");
    }
    await this.#transport.request(`\\set_freq ${frequencyHz}`);
    const confirmed = integerField(await this.#transport.request("\\get_freq"), "Frequency");
    if (confirmed !== frequencyHz) {
      throw new Error(`frequency read-back mismatch: requested ${frequencyHz}, received ${confirmed}`);
    }
    return confirmed;
  }

  async setMode(mode: string, passbandHz = 0): Promise<{ mode: string; passbandHz: number }> {
    const requestedMode = mode.trim().toUpperCase();
    const normalized = normalizeHamlibMode(mode);
    if (!Number.isSafeInteger(passbandHz) || passbandHz < 0 || passbandHz > 100_000) {
      throw new Error("passbandHz is invalid");
    }
    try {
      await this.#transport.request(`\\set_mode ${normalized} ${passbandHz}`);
    } catch (error) {
      if (error instanceof RigReportError) {
        throw new RigModeError(requestedMode, normalized, "rejected", error.report, { cause: error });
      }
      throw error;
    }
    const response = await this.#transport.request("\\get_mode");
    const confirmedMode = tokenField(response, "Mode");
    const confirmedPassband = integerField(response, "Passband");
    if (
      normalizeHamlibMode(confirmedMode) !== normalized ||
      (passbandHz !== 0 && confirmedPassband !== passbandHz)
    ) {
      throw new RigModeError(requestedMode, normalized, "unconfirmed");
    }
    return { mode: confirmedMode, passbandHz: confirmedPassband };
  }

  async readControls(): Promise<HamlibRigControl[]> {
    const definitions = await this.#discoverControlDefinitions();
    const controls: HamlibRigControl[] = [];
    for (const definition of definitions) {
      try {
        controls.push({
          ...definition,
          value: await this.#readControlValue(definition, TELEMETRY_REQUEST),
        });
      } catch (error) {
        if (!(error instanceof RigReportError)) {
          throw error;
        }
      }
    }
    return controls;
  }

  async setControl(id: string, value: number): Promise<HamlibRigControl> {
    if (!Number.isFinite(value)) {
      throw new Error("control value must be finite");
    }
    const definition = (await this.#discoverControlDefinitions())
      .find((candidate) => candidate.id === id);
    if (definition === undefined) {
      throw new Error(`control ${id} is unavailable`);
    }
    validateControlValue(definition, value);

    if (definition.kind === "level") {
      await this.#transport.request(`\\set_level ${definition.token} ${formatRigNumber(value)}`);
    } else if (definition.kind === "function") {
      await this.#transport.request(`\\set_func ${definition.token} ${value}`);
    } else {
      const mode = await this.#transport.request("\\get_mode");
      await this.setMode(tokenField(mode, "Mode"), value);
    }

    const confirmed = await this.#readControlValue(definition);
    const tolerance = Math.max(definition.step / 2, 1e-6);
    if (Math.abs(confirmed - value) > tolerance) {
      throw new Error(
        `control read-back mismatch: requested ${value}, received ${confirmed}`,
      );
    }
    return { ...definition, value: confirmed };
  }

  async setPtt(enabled: boolean): Promise<boolean> {
    const commandAccepted = await this.#writePttCommand(enabled);
    this.#lastCommandedPttForDisplayOnly = enabled;
    if (!commandAccepted) {
      return enabled;
    }
    const confirmed = await this.#readPttForDisplay();
    if (confirmed !== enabled) {
      throw new Error("PTT read-back mismatch");
    }
    return confirmed;
  }

  /**
   * Send a PTT command without claiming that the physical state changed.
   * Safety callers must follow this with readPtt() in the same recovery attempt.
   */
  async writePtt(enabled: boolean): Promise<void> {
    await this.#writePttCommand(enabled);
    this.#lastCommandedPttForDisplayOnly = enabled;
  }

  /** Read physical PTT evidence directly from Hamlib; command cache is never evidence. */
  async readPtt(): Promise<boolean> {
    const confirmed = booleanField(
      await this.#transport.request("\\get_ptt", SAFETY_READ_REQUEST),
      "PTT",
    );
    this.#lastCommandedPttForDisplayOnly = confirmed;
    return confirmed;
  }

  async #readPttForDisplay(): Promise<boolean> {
    try {
      const confirmed = booleanField(
        await this.#transport.request("\\get_ptt", TELEMETRY_REQUEST),
        "PTT",
      );
      this.#lastCommandedPttForDisplayOnly = confirmed;
      return confirmed;
    } catch (error) {
      if (this.#isUnavailablePtt(error)) {
        return this.#lastCommandedPttForDisplayOnly;
      }
      throw error;
    }
  }

  async #writePttCommand(enabled: boolean): Promise<boolean> {
    if (typeof enabled !== "boolean") {
      throw new Error("PTT state must be boolean");
    }
    try {
      await this.#transport.request(
        `\\set_ptt ${enabled ? 1 : 0}`,
        enabled ? undefined : PTT_OFF_REQUEST,
      );
      return true;
    } catch (error) {
      if (this.#isUnavailablePtt(error)) {
        return false;
      }
      throw error;
    }
  }

  #isUnavailablePtt(error: unknown): boolean {
    return this.#unavailablePttIsSafe &&
      error instanceof RigReportError &&
      error.report === -11;
  }

  async supportsInternalTuner(): Promise<boolean> {
    const vfoOperations = await this.#discoverVfoOperations();
    return vfoOperations === null || vfoOperations.has("TUNE");
  }

  async startInternalTuner(): Promise<void> {
    if (!(await this.supportsInternalTuner())) {
      throw new InternalTunerUnsupportedError(
        "radio does not support internal tuning via Hamlib TUNE",
      );
    }
    const tunerSwitchSupport = await this.#discoverTunerSwitchSupport();
    if (tunerSwitchSupport !== false) {
      try {
        await this.#transport.request("\\set_func TUNER 1");
        this.#tunerSwitchWritable = true;
      } catch (error) {
        if (
          tunerSwitchSupport !== null ||
          !(error instanceof RigReportError) ||
          error.report !== -11
        ) {
          throw error;
        }
        this.#tunerSwitchWritable = false;
      }
    }
    await this.#transport.request("\\vfo_op TUNE");
  }

  /** Send a tuner command without adding a read-back CAT round trip. */
  async writeInternalTuner(enabled: boolean): Promise<void> {
    if (typeof enabled !== "boolean") {
      throw new Error("tuner state must be boolean");
    }
    if (enabled) {
      await this.startInternalTuner();
      return;
    }
    if (this.#tunerSwitchWritable === false) {
      return;
    }
    await this.#transport.request(
      "\\set_func TUNER 0",
      PTT_OFF_REQUEST,
    );
  }

  async #discoverVfoOperations(): Promise<HamlibCapabilityTokens> {
    this.#vfoOperations ??= this.#queryCapabilityTokens(
      "\\vfo_op ?",
      "Mem/VFO Op",
    ).catch((error) => {
      this.#vfoOperations = null;
      throw error;
    });
    return this.#vfoOperations;
  }

  async #discoverWritableFunctions(): Promise<HamlibCapabilityTokens> {
    this.#writableFunctions ??= this.#queryCapabilityTokens(
      "\\set_func ?",
      "Func",
      TELEMETRY_REQUEST,
    ).catch((error) => {
      this.#writableFunctions = null;
      throw error;
    });
    return this.#writableFunctions;
  }

  async #discoverTunerSwitchSupport(): Promise<boolean | null> {
    if (this.#tunerSwitchWritable !== undefined) {
      return this.#tunerSwitchWritable;
    }
    const writableFunctions = await this.#discoverWritableFunctions();
    this.#tunerSwitchWritable = writableFunctions === null
      ? null
      : writableFunctions.has("TUNER");
    return this.#tunerSwitchWritable;
  }

  async #discoverControlDefinitions(): Promise<readonly HamlibRigControlDefinition[]> {
    this.#controlDefinitions ??= this.#loadControlDefinitions().catch((error) => {
      this.#controlDefinitions = null;
      throw error;
    });
    return this.#controlDefinitions;
  }

  async #loadControlDefinitions(): Promise<readonly HamlibRigControlDefinition[]> {
    const [readableLevels, writableLevels, readableFunctions, writableFunctions] =
      await Promise.all([
        this.#queryCapabilityTokens("\\get_level ?", "Level", TELEMETRY_REQUEST),
        this.#queryCapabilityTokens("\\set_level ?", "Level", TELEMETRY_REQUEST),
        this.#queryCapabilityTokens("\\get_func ?", "Func", TELEMETRY_REQUEST),
        this.#discoverWritableFunctions(),
      ]);
    const levelIntersection = intersection(readableLevels, writableLevels);
    const functionIntersection = intersection(readableFunctions, writableFunctions);
    const levels: HamlibRigControlDefinition[] = [];
    for (const definition of LEVEL_CONTROL_DEFINITIONS) {
      if (!levelIntersection.has(definition.token)) {
        continue;
      }
      levels.push(await this.#levelDefinitionWithRigGranularity(definition, TELEMETRY_REQUEST));
    }
    return [
      ...levels,
      ...FUNCTION_CONTROL_DEFINITIONS.filter((definition) =>
        functionIntersection.has(definition.token)),
      PASSBAND_CONTROL,
    ];
  }

  async #queryCapabilityTokens(
    command: string,
    field: string,
    options?: RigRequestOptions,
  ): Promise<HamlibCapabilityTokens> {
    let response: RigResponse;
    try {
      response = await this.#transport.request(command, options);
    } catch (error) {
      if (error instanceof RigReportError) {
        return null;
      }
      throw error;
    }
    const text = response.fields.get(field) ?? response.values.join(" ");
    return new Set(
      text.split(/\s+/u)
        .map((token) => token.trim().toUpperCase())
        .filter((token) => /^[A-Z][A-Z0-9_]{0,31}$/u.test(token)),
    );
  }

  async #levelDefinitionWithRigGranularity(
    fallback: HamlibRigControlDefinition,
    options?: RigRequestOptions,
  ): Promise<HamlibRigControlDefinition> {
    try {
      const response = await this.#transport.request(
        `\\set_level ${fallback.token} ?`,
        options,
      );
      const raw = response.values[0] ?? response.fields.get("Level Value") ?? "";
      const granularity = parseLevelGranularity(raw);
      return granularity === null ? fallback : { ...fallback, ...granularity };
    } catch (error) {
      if (error instanceof RigReportError) {
        return fallback;
      }
      throw error;
    }
  }

  async #readControlValue(
    definition: HamlibRigControlDefinition,
    options?: RigRequestOptions,
  ): Promise<number> {
    if (definition.kind === "passband") {
      return integerField(
        await this.#transport.request("\\get_mode", options),
        "Passband",
      );
    }
    const command = definition.kind === "level" ? "get_level" : "get_func";
    const response = await this.#transport.request(`\\${command} ${definition.token}`, options);
    return numericResponseValue(response, definition.token);
  }
}

function levelDefinition(
  token: string,
  unit: HamlibRigControlUnit,
  minimum: number,
  maximum: number,
  step: number,
  transmitLocked = false,
): HamlibRigControlDefinition {
  return {
    id: `level:${token}`,
    kind: "level",
    token,
    minimum,
    maximum,
    step,
    unit,
    transmitLocked,
  };
}

function functionDefinition(token: string, transmitLocked = false): HamlibRigControlDefinition {
  return {
    id: `function:${token}`,
    kind: "function",
    token,
    minimum: 0,
    maximum: 1,
    step: 1,
    unit: "boolean",
    transmitLocked,
  };
}

function intersection(
  left: HamlibCapabilityTokens,
  right: HamlibCapabilityTokens,
): Set<string> {
  if (left === null || right === null) {
    return new Set();
  }
  return new Set([...left].filter((value) => right.has(value)));
}

function parseLevelGranularity(
  value: string,
): Pick<HamlibRigControlDefinition, "minimum" | "maximum" | "step"> | null {
  const match = /^\(\s*([-+]?\d+(?:\.\d+)?)\.\.([-+]?\d+(?:\.\d+)?)\/([-+]?\d+(?:\.\d+)?)\s*\)$/u
    .exec(value.trim());
  if (match === null) {
    return null;
  }
  const minimum = Number(match[1]);
  const maximum = Number(match[2]);
  const step = Number(match[3]);
  if (![minimum, maximum, step].every(Number.isFinite) || minimum >= maximum || step <= 0) {
    return null;
  }
  return { minimum, maximum, step };
}

function validateControlValue(definition: HamlibRigControlDefinition, value: number): void {
  const epsilon = Math.max(Math.abs(definition.step) * 1e-6, 1e-9);
  if (value < definition.minimum - epsilon || value > definition.maximum + epsilon) {
    throw new Error(`control value is outside ${definition.minimum}..${definition.maximum}`);
  }
  const steps = (value - definition.minimum) / definition.step;
  if (Math.abs(steps - Math.round(steps)) > 1e-6) {
    throw new Error(`control value must use step ${definition.step}`);
  }
  if (definition.kind === "function" && value !== 0 && value !== 1) {
    throw new Error("function control value must be 0 or 1");
  }
  if (definition.kind === "passband" && !Number.isSafeInteger(value)) {
    throw new Error("passband control value must be an integer");
  }
}

function formatRigNumber(value: number): string {
  return Number.isSafeInteger(value) ? String(value) : value.toString();
}

function numericResponseValue(response: RigResponse, fallbackField: string): number {
  const raw = response.values[0]
    ?? response.fields.get(fallbackField)
    ?? response.fields.values().next().value;
  const value = raw === undefined ? Number.NaN : Number(raw.trim());
  if (!Number.isFinite(value)) {
    throw new Error(`${response.command} response has invalid value`);
  }
  return value;
}

function integerField(response: RigResponse, field: string): number {
  const raw = response.fields.get(field);
  const value = raw === undefined ? Number.NaN : Number(raw);
  if (!Number.isSafeInteger(value)) {
    throw new Error(`${response.command} response has invalid ${field}`);
  }
  return value;
}

function tokenField(response: RigResponse, field: string): string {
  const value = response.fields.get(field)?.trim().toUpperCase();
  if (value === undefined || !/^[A-Z0-9_-]{1,32}$/u.test(value)) {
    throw new Error(`${response.command} response has invalid ${field}`);
  }
  return value;
}

function booleanField(response: RigResponse, field: string): boolean {
  const value = response.fields.get(field)?.trim();
  if (value !== "0" && value !== "1") {
    throw new Error(`${response.command} response has invalid ${field}`);
  }
  return value === "1";
}
