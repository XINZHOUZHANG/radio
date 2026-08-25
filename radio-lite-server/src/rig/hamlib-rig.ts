import type { PttMethod } from "../config/types.ts";
import type { RigResponse } from "./extended-protocol.ts";
import { RigReportError } from "./transport.ts";

export type RigRequester = {
  request(command: string): Promise<RigResponse>;
};

export type HamlibRigState = {
  frequencyHz: number;
  mode: string;
  passbandHz: number;
  ptt: boolean;
};

export type HamlibRigOptions = {
  pttMethod?: PttMethod;
};

export type RigModeErrorReason = "rejected" | "unconfirmed";

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

export class HamlibRig {
  readonly #transport: RigRequester;
  readonly #unavailablePttIsSafe: boolean;
  #lastCommandedPtt = false;

  constructor(transport: RigRequester, options: HamlibRigOptions = {}) {
    this.#transport = transport;
    this.#unavailablePttIsSafe = options.pttMethod === "None";
  }

  async readState(): Promise<HamlibRigState> {
    const [frequency, mode, ptt] = await Promise.all([
      this.#transport.request("\\get_freq"),
      this.#transport.request("\\get_mode"),
      this.#readPtt(),
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

  async setPtt(enabled: boolean): Promise<boolean> {
    if (typeof enabled !== "boolean") {
      throw new Error("PTT state must be boolean");
    }
    try {
      await this.#transport.request(`\\set_ptt ${enabled ? 1 : 0}`);
    } catch (error) {
      if (!this.#isUnavailablePtt(error)) {
        throw error;
      }
      this.#lastCommandedPtt = enabled;
      return enabled;
    }
    this.#lastCommandedPtt = enabled;
    const confirmed = await this.#readPtt();
    if (confirmed !== enabled) {
      throw new Error("PTT read-back mismatch");
    }
    return confirmed;
  }

  async #readPtt(): Promise<boolean> {
    try {
      const confirmed = booleanField(await this.#transport.request("\\get_ptt"), "PTT");
      this.#lastCommandedPtt = confirmed;
      return confirmed;
    } catch (error) {
      if (this.#isUnavailablePtt(error)) {
        return this.#lastCommandedPtt;
      }
      throw error;
    }
  }

  #isUnavailablePtt(error: unknown): boolean {
    return this.#unavailablePttIsSafe &&
      error instanceof RigReportError &&
      error.report === -11;
  }

  async setInternalTuner(enabled: boolean): Promise<boolean> {
    if (typeof enabled !== "boolean") {
      throw new Error("tuner state must be boolean");
    }
    await this.#transport.request(`\\set_func TUNER ${enabled ? 1 : 0}`);
    const response = await this.#transport.request("\\get_func TUNER");
    const raw = response.values[0] ?? response.fields.get("TUNER");
    if (raw !== "0" && raw !== "1") {
      throw new Error("tuner read-back is malformed");
    }
    const confirmed = raw === "1";
    if (confirmed !== enabled) {
      throw new Error("tuner read-back mismatch");
    }
    return confirmed;
  }
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
