import type { RigResponse } from "./extended-protocol.ts";

export type RigRequester = {
  request(command: string): Promise<RigResponse>;
};

export type HamlibRigState = {
  frequencyHz: number;
  mode: string;
  passbandHz: number;
  ptt: boolean;
};

export class HamlibRig {
  readonly #transport: RigRequester;

  constructor(transport: RigRequester) {
    this.#transport = transport;
  }

  async readState(): Promise<HamlibRigState> {
    const [frequency, mode, ptt] = await Promise.all([
      this.#transport.request("\\get_freq"),
      this.#transport.request("\\get_mode"),
      this.#transport.request("\\get_ptt"),
    ]);
    return {
      frequencyHz: integerField(frequency, "Frequency"),
      mode: tokenField(mode, "Mode"),
      passbandHz: integerField(mode, "Passband"),
      ptt: booleanField(ptt, "PTT"),
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
    const normalized = mode.trim().toUpperCase();
    if (!/^[A-Z0-9_-]{1,16}$/u.test(normalized)) {
      throw new Error("mode is invalid");
    }
    if (!Number.isSafeInteger(passbandHz) || passbandHz < 0 || passbandHz > 100_000) {
      throw new Error("passbandHz is invalid");
    }
    await this.#transport.request(`\\set_mode ${normalized} ${passbandHz}`);
    const response = await this.#transport.request("\\get_mode");
    const confirmedMode = tokenField(response, "Mode");
    const confirmedPassband = integerField(response, "Passband");
    if (confirmedMode !== normalized || (passbandHz !== 0 && confirmedPassband !== passbandHz)) {
      throw new Error("mode read-back mismatch");
    }
    return { mode: confirmedMode, passbandHz: confirmedPassband };
  }

  async setPtt(enabled: boolean): Promise<boolean> {
    if (typeof enabled !== "boolean") {
      throw new Error("PTT state must be boolean");
    }
    await this.#transport.request(`\\set_ptt ${enabled ? 1 : 0}`);
    const confirmed = booleanField(await this.#transport.request("\\get_ptt"), "PTT");
    if (confirmed !== enabled) {
      throw new Error("PTT read-back mismatch");
    }
    return confirmed;
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
