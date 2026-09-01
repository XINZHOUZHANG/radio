import type { PttMethod } from "../config/types.ts";
import type { RigResponse } from "./extended-protocol.ts";
import { HamlibControlCatalogue } from "./radio-control-catalogue.ts";
import type { RadioControl, RadioControlValue, RadioMeterSample, RadioState } from "./radio-driver.ts";
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
const CONTROL_READ_REQUEST = { source: "control" } as const satisfies RigRequestOptions;

const TELEMETRY_METER_TOKENS = [
  "STRENGTH",
  "SWR",
  "ALC",
  "RFPOWER_METER_WATTS",
  "RFPOWER_METER",
] as const;

const EXPLICIT_OPERATION_TOKENS = [
  "MODE",
  "PASSBAND",
  "SPLIT",
  "RIT",
  "XIT",
  "TUNING_STEP",
  "REPEATER_SHIFT",
  "REPEATER_OFFSET",
  "CTCSS",
  "DCS",
] as const;

export type HamlibRigState = RadioState;

export type HamlibRigControl = RadioControl & { value: RadioControlValue };

type HamlibRigControlDefinition = Omit<HamlibRigControl, "value">;
type HamlibCapabilityTokens = ReadonlySet<string> | null;

export type HamlibRigOptions = {
  pttMethod?: PttMethod;
  onWarning?: (message: string) => void;
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

const TRANSMIT_LOCKED_CONTROL_IDS = new Set([
  "level:RFPOWER", "level:MICGAIN", "level:COMP", "level:MONITOR_GAIN", "level:VOXDELAY",
  "level:VOXGAIN", "level:ANTIVOX", "level:BKINDL", "level:BKIN_DLYMS", "level:KEYSPD",
  "function:COMP", "function:MON", "function:VOX", "function:SBKIN", "function:FBKIN",
  "action:TUNER", "mode:CURRENT", "passband:CURRENT", "operation:SPLIT", "operation:XIT",
  "repeater:SHIFT", "repeater:OFFSET", "repeater:CTCSS", "repeater:DCS",
]);

export function isTransmitLockedRigControlId(id: string): boolean {
  return TRANSMIT_LOCKED_CONTROL_IDS.has(id);
}

export class HamlibRig {
  readonly #transport: RigRequester;
  readonly #controlCatalogue = new HamlibControlCatalogue();
  readonly #unavailablePttIsSafe: boolean;
  readonly #onWarning: (message: string) => void;
  #lastCommandedPttForDisplayOnly = false;
  #controlDefinitions: Promise<readonly HamlibRigControlDefinition[]> | null = null;
  #vfoOperations: Promise<HamlibCapabilityTokens> | null = null;
  #writableFunctions: Promise<HamlibCapabilityTokens> | null = null;
  #telemetryMeters: Promise<Set<string>> | null = null;
  readonly #disabledTelemetryMeters = new Set<string>();
  #tunerSwitchWritable: boolean | null | undefined;

  constructor(transport: RigRequester, options: HamlibRigOptions = {}) {
    this.#transport = transport;
    this.#unavailablePttIsSafe = options.pttMethod === "None";
    this.#onWarning = options.onWarning ?? ((message) => {
      process.emitWarning(message, { code: "RADIO_LITE_TUNER_READBACK" });
    });
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

  async discoverTelemetryMeters(): Promise<string[]> {
    const meters = await this.#discoverTelemetryMeters();
    return this.#publishedTelemetryMeters(meters);
  }

  async readTelemetry(mode: "receive" | "transmit"): Promise<RadioMeterSample> {
    const meters = await this.#discoverTelemetryMeters();
    const sample: RadioMeterSample = {};
    if (mode === "receive") {
      sample.strengthDbRelativeS9 = await this.#readOptionalTelemetryMeter("STRENGTH", meters);
    } else {
      sample.ptt = await this.#readPtt(TELEMETRY_REQUEST);
      sample.swr = await this.#readOptionalTelemetryMeter("SWR", meters);
      sample.alcRatio = await this.#readOptionalTelemetryMeter("ALC", meters);
      const actualPowerToken = this.#availableTelemetryMeter("RFPOWER_METER_WATTS", meters)
        ? "RFPOWER_METER_WATTS"
        : this.#availableTelemetryMeter("RFPOWER_METER", meters)
          ? "RFPOWER_METER"
          : null;
      if (actualPowerToken !== null) {
        const actualPower = await this.#readOptionalTelemetryMeter(actualPowerToken, meters);
        if (actualPowerToken === "RFPOWER_METER_WATTS") {
          sample.rfPowerWatts = actualPower;
        } else {
          sample.rfPowerRatio = actualPower;
        }
      }
    }
    sample.availableMeters = this.#publishedTelemetryMeters(meters);
    return sample;
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

  async setControl(id: string, value: RadioControlValue): Promise<HamlibRigControl> {
    const definition = (await this.#discoverControlDefinitions())
      .find((candidate) => candidate.id === id);
    if (definition === undefined) {
      throw new Error(`control ${id} is unavailable`);
    }
    if (definition.access !== "read-write") {
      throw new Error(`control ${id} is not writable`);
    }
    const normalized = normalizeControlValue(definition, value);
    return this.#writeAndConfirmControl(definition, normalized);
  }

  async #writeAndConfirmControl(
    definition: HamlibRigControlDefinition,
    normalized: Exclude<RadioControlValue, null>,
  ): Promise<HamlibRigControl> {
    const numeric = () => numericControlValue(normalized);
    if (definition.kind === "level") {
      await this.#transport.request(
        "\\set_level " + definition.token + " " + formatRigNumber(numeric()),
      );
    } else if (definition.kind === "function") {
      await this.#transport.request(
        "\\set_func " + definition.token + " " + (normalized === true ? "1" : "0"),
      );
    } else if (definition.kind === "mode") {
      const current = await this.#transport.request("\\get_mode");
      const confirmed = await this.setMode(
        stringControlValue(normalized),
        integerField(current, "Passband"),
      );
      return { ...definition, value: normalizeHamlibMode(confirmed.mode) };
    } else if (definition.kind === "passband") {
      const current = await this.#transport.request("\\get_mode");
      const confirmed = await this.setMode(tokenField(current, "Mode"), numeric());
      return { ...definition, value: confirmed.passbandHz };
    } else {
      const command = operationWriteCommand(definition.id, normalized);
      if (command === null) {
        throw new Error("control " + definition.id + " requires an explicit command adapter");
      }
      await this.#transport.request(command);
    }

    let confirmedValue: RadioControlValue;
    try {
      confirmedValue = await this.#readControlValue(definition);
    } catch (error) {
      if (!(error instanceof RigReportError) || error.report !== -11) throw error;
      confirmedValue = normalized;
    }
    if (!controlValuesMatch(definition, normalized, confirmedValue)) {
      if (definition.id === "function:TUNER") {
        this.#onWarning(
          "TUNER read-back mismatch: requested " + normalized + ", received " + confirmedValue,
        );
        return { ...definition, value: normalized };
      }
      throw new Error(
        "control read-back mismatch: requested " + normalized + ", received " + confirmedValue,
      );
    }
    return { ...definition, value: confirmedValue };
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
    return this.#readPtt(SAFETY_READ_REQUEST);
  }

  /** Read physical PTT evidence for an ordinary control operation. */
  async readPttForControl(): Promise<boolean> {
    return this.#readPtt(CONTROL_READ_REQUEST);
  }

  async #readPtt(options: RigRequestOptions): Promise<boolean> {
    const confirmed = booleanField(
      await this.#transport.request("\\get_ptt", options),
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
    try {
      await this.#transport.request("\\set_func TUNER 1");
      this.#tunerSwitchWritable = true;
    } catch (error) {
      if (!(error instanceof RigReportError) || error.report !== -11) {
        throw error;
      }
      this.#tunerSwitchWritable = false;
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

  async #discoverTelemetryMeters(): Promise<Set<string>> {
    this.#telemetryMeters ??= this.#queryCapabilityTokens(
      "\\get_level ?",
      "Level",
      TELEMETRY_REQUEST,
    ).then((tokens) => tokens === null ? new Set<string>() : new Set(tokens)).catch((error) => {
      this.#telemetryMeters = null;
      throw error;
    });
    return this.#telemetryMeters;
  }

  #availableTelemetryMeter(token: string, meters: ReadonlySet<string>): boolean {
    return meters.has(token) && !this.#disabledTelemetryMeters.has(token);
  }

  #publishedTelemetryMeters(meters: ReadonlySet<string>): string[] {
    const available = ["STRENGTH", "SWR", "ALC"].filter((token) =>
      this.#availableTelemetryMeter(token, meters));
    if (this.#availableTelemetryMeter("RFPOWER_METER_WATTS", meters)) {
      available.push("RFPOWER_METER_WATTS");
    } else if (this.#availableTelemetryMeter("RFPOWER_METER", meters)) {
      available.push("RFPOWER_METER");
    }
    return available;
  }

  async #readOptionalTelemetryMeter(
    token: string,
    meters: ReadonlySet<string>,
  ): Promise<number | undefined> {
    if (!this.#availableTelemetryMeter(token, meters)) return undefined;
    try {
      return numericResponseValue(
        await this.#transport.request(`\\get_level ${token}`, TELEMETRY_REQUEST),
        token,
      );
    } catch (error) {
      if (error instanceof RigReportError && error.report === -11) {
        this.#disabledTelemetryMeters.add(token);
        return undefined;
      }
      throw error;
    }
  }

  async #loadControlDefinitions(): Promise<readonly HamlibRigControlDefinition[]> {
    const [
      readableLevels,
      writableLevels,
      readableFunctions,
      writableFunctions,
      modes,
      vfoOperations,
    ] =
      await Promise.all([
        this.#discoverTelemetryMeters(),
        this.#queryCapabilityTokens("\\set_level ?", "Level", TELEMETRY_REQUEST),
        this.#queryCapabilityTokens("\\get_func ?", "Func", TELEMETRY_REQUEST),
        this.#discoverWritableFunctions(),
        this.#queryCapabilityTokens("\\set_mode ?", "Mode", TELEMETRY_REQUEST)
          .catch(() => null),
        this.#discoverVfoOperations().catch(() => null),
      ]);
    const readableLevelSet = readableLevels ?? new Set<string>();
    const writableLevelSet = writableLevels ?? new Set<string>();
    const readableFunctionSet = readableFunctions ?? new Set<string>();
    const writableFunctionSet = writableFunctions ?? new Set<string>();
    const supportedOperations = await this.#discoverSupportedOperations(modes);
    const tunerActionSupported = vfoOperations?.has("TUNE") === true;
    const tunerSwitchSupported = tunerActionSupported || writableFunctionSet.has("TUNER");
    const candidates = await this.#controlCatalogue.discover({
      levels: [...readableLevelSet],
      functions: tunerSwitchSupported
        ? [...new Set([...readableFunctionSet, "TUNER"])]
        : [...readableFunctionSet].filter((token) => token !== "TUNER"),
      actions: tunerActionSupported ? ["TUNER"] : [],
      operations: supportedOperations,
      modes: modes === null ? [] : [...modes],
    });
    const usable = candidates.filter((definition) => {
      if (definition.kind === "level") {
        return definition.access === "read-only" || writableLevelSet.has(definition.token);
      }
      if (definition.kind === "function" || definition.kind === "action") {
        if (definition.kind === "action" && definition.token === "TUNER") {
          return tunerActionSupported;
        }
        if (definition.kind === "function" && definition.token === "TUNER") {
          return tunerSwitchSupported;
        }
        return writableFunctionSet.has(definition.token);
      }
      return true;
    });
    return Promise.all(usable.map(async (definition) => {
      const { value: _value, ...metadata } = definition;
      return metadata.kind === "level" && metadata.access === "read-write"
        ? this.#levelDefinitionWithRigGranularity(metadata, TELEMETRY_REQUEST)
        : metadata;
    }));
  }

  async #discoverSupportedOperations(
    modes: HamlibCapabilityTokens,
  ): Promise<string[]> {
    const supported: string[] = [];
    for (const token of EXPLICIT_OPERATION_TOKENS) {
      const [candidate] = await this.#controlCatalogue.discover({
        operations: [token],
        modes: modes === null ? [] : [...modes],
      });
      if (candidate === undefined) continue;
      try {
        await this.#readControlValue(candidate, TELEMETRY_REQUEST);
        supported.push(token);
      } catch {
        // Optional operations are public only after a valid one-shot read.
      }
    }
    return supported;
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
  ): Promise<RadioControlValue> {
    if (definition.kind === "action") return null;
    if (definition.kind === "mode") {
      return normalizeHamlibMode(tokenField(
        await this.#transport.request("\\get_mode", options),
        "Mode",
      ));
    }
    if (definition.kind === "passband") {
      return integerField(
        await this.#transport.request("\\get_mode", options),
        "Passband",
      );
    }
    const operationRead = operationReadCommand(definition.id);
    if (operationRead !== null) {
      const response = await this.#transport.request(operationRead, options);
      if (definition.id === "operation:SPLIT") {
        return numericResponseValue(response, "Split") !== 0;
      }
      if (definition.id === "repeater:SHIFT") {
        return normalizedRepeaterShift(responseValue(response, "Rptr Shift"));
      }
      return numericResponseValue(response, operationReadField(definition.id));
    }
    const command = definition.kind === "level" ? "get_level" : "get_func";
    const response = await this.#transport.request(`\\${command} ${definition.token}`, options);
    const value = numericResponseValue(response, definition.token);
    return definition.kind === "function" ? value !== 0 : value;
  }
}

function normalizeControlValue(
  definition: HamlibRigControlDefinition,
  value: RadioControlValue,
): Exclude<RadioControlValue, null> {
  let normalized: Exclude<RadioControlValue, null>;
  if (definition.kind === "mode") {
    if (typeof value !== "string") throw new Error("mode control value must be a string");
    normalized = normalizeHamlibMode(value);
  } else if (definition.id === "operation:SPLIT") {
    if (typeof value !== "boolean") throw new Error("split control value must be boolean");
    normalized = value;
  } else if (definition.kind === "function") {
    if (typeof value === "boolean") {
      normalized = value;
    } else if (value === 0 || value === 1) {
      normalized = value !== 0;
    } else {
      throw new Error("function control value must be boolean or legacy 0/1");
    }
  } else if (definition.id === "repeater:SHIFT") {
    if (typeof value !== "string") throw new Error("repeater shift must be a string");
    normalized = value.trim().toUpperCase();
  } else {
    if (typeof value !== "number" || !Number.isFinite(value)) {
      throw new Error("control value must be finite numeric data");
    }
    normalized = value;
  }

  if (
    definition.options !== undefined &&
    definition.options.length > 0 &&
    !definition.options.some((option) => option.value === normalized)
  ) {
    throw new Error("control value is not an available option");
  }
  if (typeof normalized === "number") validateNumericControlValue(definition, normalized);
  return normalized;
}

function validateNumericControlValue(
  definition: HamlibRigControlDefinition,
  value: number,
): void {
  const minimum = definition.minimum;
  const maximum = definition.maximum;
  const step = definition.step;
  if (minimum === undefined || maximum === undefined || step === undefined) {
    if (!Number.isSafeInteger(value)) {
      throw new Error("numeric enum control value must be an integer");
    }
    return;
  }
  const epsilon = Math.max(Math.abs(step) * 1e-6, 1e-9);
  if (value < minimum - epsilon || value > maximum + epsilon) {
    throw new Error("control value is outside " + minimum + ".." + maximum);
  }
  const steps = (value - minimum) / step;
  if (Math.abs(steps - Math.round(steps)) > 1e-6) {
    throw new Error("control value must use step " + step);
  }
  if (definition.kind === "passband" && !Number.isSafeInteger(value)) {
    throw new Error("passband control value must be an integer");
  }
}

function numericControlValue(value: Exclude<RadioControlValue, null>): number {
  if (typeof value !== "number") throw new Error("normalized control value is not numeric");
  return value;
}

function stringControlValue(value: Exclude<RadioControlValue, null>): string {
  if (typeof value !== "string") throw new Error("normalized control value is not a string");
  return value;
}

function controlValuesMatch(
  definition: HamlibRigControlDefinition,
  requested: Exclude<RadioControlValue, null>,
  confirmed: RadioControlValue,
): boolean {
  if (typeof requested === "number" && typeof confirmed === "number") {
    return Math.abs(confirmed - requested) <= Math.max((definition.step ?? 0) / 2, 1e-6);
  }
  return requested === confirmed;
}

function operationWriteCommand(
  id: string,
  value: Exclude<RadioControlValue, null>,
): string | null {
  if (id === "operation:SPLIT") return "\\set_split_vfo " + (value === true ? "1" : "0") + " VFOB";
  if (id === "operation:RIT") return "\\set_rit " + formatRigNumber(numericControlValue(value));
  if (id === "operation:XIT") return "\\set_xit " + formatRigNumber(numericControlValue(value));
  if (id === "operation:TUNING_STEP") return "\\set_ts " + formatRigNumber(numericControlValue(value));
  if (id === "repeater:SHIFT") return "\\set_rptr_shift " + hamlibRepeaterShift(stringControlValue(value));
  if (id === "repeater:OFFSET") return "\\set_rptr_offs " + formatRigNumber(numericControlValue(value));
  if (id === "repeater:CTCSS") return "\\set_ctcss_tone " + formatRigNumber(numericControlValue(value));
  if (id === "repeater:DCS") return "\\set_dcs_code " + formatRigNumber(numericControlValue(value));
  return null;
}

function operationReadCommand(id: string): string | null {
  if (id === "operation:SPLIT") return "\\get_split_vfo";
  if (id === "operation:RIT") return "\\get_rit";
  if (id === "operation:XIT") return "\\get_xit";
  if (id === "operation:TUNING_STEP") return "\\get_ts";
  if (id === "repeater:SHIFT") return "\\get_rptr_shift";
  if (id === "repeater:OFFSET") return "\\get_rptr_offs";
  if (id === "repeater:CTCSS") return "\\get_ctcss_tone";
  if (id === "repeater:DCS") return "\\get_dcs_code";
  return null;
}

function operationReadField(id: string): string {
  if (id === "operation:RIT") return "RIT";
  if (id === "operation:XIT") return "XIT";
  if (id === "operation:TUNING_STEP") return "Tuning Step";
  if (id === "repeater:OFFSET") return "Rptr Offset";
  if (id === "repeater:CTCSS") return "CTCSS Tone";
  if (id === "repeater:DCS") return "DCS Code";
  return "Value";
}

function hamlibRepeaterShift(value: string): string {
  if (value === "PLUS") return "+";
  if (value === "MINUS") return "-";
  return "None";
}

function normalizedRepeaterShift(value: string): string {
  const normalized = value.trim().toUpperCase();
  if (normalized === "+" || normalized === "PLUS") return "PLUS";
  if (normalized === "-" || normalized === "MINUS") return "MINUS";
  if (normalized === "NONE") return "NONE";
  throw new Error("get_rptr_shift response has invalid repeater shift");
}

function responseValue(response: RigResponse, field: string): string {
  const value = response.values[0] ?? response.fields.get(field) ??
    response.fields.values().next().value;
  if (value === undefined) throw new Error(response.command + " response has no value");
  return value;
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
