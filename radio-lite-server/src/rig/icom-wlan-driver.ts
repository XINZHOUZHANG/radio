import type { DriverAudioDuplex } from "../media/driver-audio.ts";
import type {
  RadioCapabilities,
  RadioControl,
  RadioControlValue,
  RadioDriver,
  RadioMeterSample,
  RadioModeState,
  RadioPttReadOptions,
  RadioReadOptions,
  RadioState,
} from "./radio-driver.ts";
import type {
  IcomWlanControlId,
  IcomWlanMode,
  IcomWlanPort,
} from "./icom-wlan-port.ts";

const CONTROL_ORDER: readonly IcomWlanControlId[] = [
  "operation:SPLIT",
  "operation:RIT",
  "operation:XIT",
];

const CONTROL_DEFINITIONS: Readonly<Record<IcomWlanControlId, Omit<RadioControl, "value">>> = {
  "operation:SPLIT": {
    id: "operation:SPLIT",
    kind: "operation",
    token: "SPLIT",
    group: "mode",
    access: "read-write",
    presentation: "toggle",
    unit: "boolean",
    transmitLocked: true,
  },
  "operation:RIT": {
    id: "operation:RIT",
    kind: "operation",
    token: "RIT",
    group: "mode",
    access: "read-write",
    presentation: "offset",
    minimum: -9_999,
    maximum: 9_999,
    step: 1,
    unit: "hertz",
    transmitLocked: false,
  },
  "operation:XIT": {
    id: "operation:XIT",
    kind: "operation",
    token: "XIT",
    group: "mode",
    access: "read-write",
    presentation: "offset",
    minimum: -9_999,
    maximum: 9_999,
    step: 1,
    unit: "hertz",
    transmitLocked: true,
  },
};

const ICOM_MODES = new Set([
  "LSB",
  "USB",
  "AM",
  "CW",
  "RTTY",
  "FM",
  "WFM",
  "CW_R",
  "RTTY_R",
  "DV",
]);

export class IcomWlanDriver implements RadioDriver {
  readonly audio: DriverAudioDuplex;

  readonly #port: IcomWlanPort;
  #capabilities: Promise<RadioCapabilities> | null = null;

  constructor(port: IcomWlanPort) {
    this.#port = port;
    this.audio = port.audio;
  }

  initialize(): Promise<void> {
    return this.#port.initialize();
  }

  async prepareTelemetry(): Promise<void> {}

  close(): Promise<void> {
    return this.#port.close();
  }

  capabilities(): Promise<RadioCapabilities> {
    this.#capabilities ??= this.#loadCapabilities();
    return this.#capabilities;
  }

  async readState(_options?: RadioReadOptions): Promise<RadioState> {
    const [frequencyHz, mode, ptt] = await Promise.all([
      this.#port.readFrequency(),
      this.#port.readMode(),
      this.#port.readPtt(),
    ]);
    return {
      frequencyHz,
      mode: displayMode(mode),
      passbandHz: 0,
      ptt,
    };
  }

  async readTelemetry(mode: "receive" | "transmit"): Promise<RadioMeterSample> {
    const [meters, ptt] = await Promise.all([
      this.#port.readMeters(mode),
      mode === "transmit" ? this.#port.readPtt() : Promise.resolve(undefined),
    ]);
    const sample: RadioMeterSample = {};
    const availableMeters: string[] = [];
    if (mode === "receive") {
      if (meters.strengthDbRelativeS9 !== undefined) {
        sample.strengthDbRelativeS9 = meters.strengthDbRelativeS9;
        availableMeters.push("STRENGTH");
      }
    } else {
      sample.ptt = ptt;
      if (meters.swr !== undefined) {
        sample.swr = meters.swr;
        availableMeters.push("SWR");
      }
      if (meters.alcPercent !== undefined) {
        sample.alcRatio = meters.alcPercent / 100;
        availableMeters.push("ALC");
      }
      if (meters.rfPowerPercent !== undefined) {
        sample.rfPowerRatio = meters.rfPowerPercent / 100;
        availableMeters.push("RFPOWER_METER");
      }
      if (meters.rfPowerWatts !== undefined) {
        sample.rfPowerWatts = meters.rfPowerWatts;
        availableMeters.push("RFPOWER_METER_WATTS");
      }
    }
    sample.availableMeters = availableMeters;
    return sample;
  }

  async readControls(): Promise<RadioControl[]> {
    const available = new Set((await this.#port.capabilities()).controls);
    const controls: RadioControl[] = [];
    for (const id of CONTROL_ORDER) {
      if (!available.has(id)) continue;
      controls.push({ ...CONTROL_DEFINITIONS[id], value: await this.#port.readControl(id) });
    }
    return controls;
  }

  async setFrequency(frequencyHz: number): Promise<number> {
    if (!Number.isSafeInteger(frequencyHz) || frequencyHz < 100_000 || frequencyHz > 1_000_000_000_000) {
      throw new RangeError("frequencyHz is outside the supported numeric range");
    }
    await this.#port.writeFrequency(frequencyHz);
    const confirmed = await this.#port.readFrequency();
    if (confirmed !== frequencyHz) throw new Error("frequency read-back mismatch");
    return confirmed;
  }

  async setMode(mode: string, passbandHz = 0): Promise<RadioModeState> {
    if (passbandHz !== 0) {
      throw new Error("ICOM WLAN passband width control is unavailable");
    }
    const requested = parseMode(mode);
    await this.#port.writeMode(requested);
    const confirmed = await this.#port.readMode();
    if (displayMode(confirmed) !== displayMode(requested)) {
      throw new Error("mode read-back mismatch");
    }
    return { mode: displayMode(confirmed), passbandHz: 0 };
  }

  async setControl(id: string, value: RadioControlValue): Promise<RadioControl> {
    if (!isIcomControlId(id)) throw new Error(`control ${id} is unavailable`);
    const available = (await this.#port.capabilities()).controls.includes(id);
    if (!available) throw new Error(`control ${id} is unavailable`);
    const normalized = normalizeControlValue(id, value);
    await this.#port.writeControl(id, normalized);
    const confirmed = await this.#port.readControl(id);
    if (confirmed !== normalized) throw new Error(`control ${id} read-back mismatch`);
    return { ...CONTROL_DEFINITIONS[id], value: confirmed };
  }

  async invokeAction(id: string): Promise<void> {
    if (id !== "action:TUNER" || !(await this.capabilities()).supportsInternalTuner) {
      throw new Error(`action ${id} is unavailable`);
    }
    await this.#port.invokeTuner();
  }

  async writePtt(enabled: boolean): Promise<void> {
    await this.#port.writePtt(enabled);
    const confirmed = await this.#port.readPtt();
    if (confirmed !== enabled) throw new Error("PTT read-back mismatch");
  }

  readPtt(_options?: RadioPttReadOptions): Promise<boolean> {
    return this.#port.readPtt();
  }

  onFatalConnection(listener: (error: Error) => void): () => void {
    return this.#port.onFatalConnection(listener);
  }

  async #loadCapabilities(): Promise<RadioCapabilities> {
    const capabilities = await this.#port.capabilities();
    return {
      canTransmit: capabilities.canTransmit,
      supportsInternalTuner: capabilities.supportsInternalTuner,
    };
  }
}

function parseMode(value: string): IcomWlanMode {
  const normalized = value.trim().toUpperCase().replaceAll("-", "_");
  const dataMode = normalized.endsWith("_D");
  const mode = dataMode ? normalized.slice(0, -2) : normalized;
  if (!ICOM_MODES.has(mode)) throw new Error(`mode ${value.trim()} is unavailable`);
  return { mode, dataMode };
}

function displayMode(value: IcomWlanMode): string {
  return `${value.mode.replaceAll("_", "-")}${value.dataMode ? "-D" : ""}`;
}

function isIcomControlId(id: string): id is IcomWlanControlId {
  return Object.hasOwn(CONTROL_DEFINITIONS, id);
}

function normalizeControlValue(
  id: IcomWlanControlId,
  value: RadioControlValue,
): boolean | number {
  if (id === "operation:SPLIT") {
    if (typeof value !== "boolean") throw new TypeError(`${id} requires a boolean value`);
    return value;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < -9_999 || value > 9_999) {
    throw new RangeError(`${id} requires an integer offset in -9999..9999 Hz`);
  }
  return value;
}
