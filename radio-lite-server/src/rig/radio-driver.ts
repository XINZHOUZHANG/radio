export type RadioCapabilities = {
  canTransmit: boolean;
  supportsInternalTuner: boolean;
};

export type RadioState = {
  frequencyHz: number;
  mode: string;
  passbandHz: number;
  ptt: boolean;
};

export type RadioMeterSample = {
  ptt?: boolean;
  strengthDbRelativeS9?: number;
  swr?: number;
  alcRatio?: number;
  rfPowerRatio?: number;
  rfPowerWatts?: number;
  availableMeters?: string[];
};

export type RadioControlValue = boolean | number | string | null;

export type RadioControlGroup =
  | "antenna"
  | "rf"
  | "audio"
  | "mode"
  | "cw"
  | "repeater"
  | "spectrum"
  | "system";

export type RadioControlAccess = "read-only" | "read-write" | "action";
export type RadioControlPresentation =
  | "meter"
  | "toggle"
  | "slider"
  | "discrete"
  | "enum"
  | "offset"
  | "button";
export type RadioControlUnit =
  | "ratio"
  | "decibel"
  | "hertz"
  | "watts"
  | "milliseconds"
  | "index"
  | "boolean";
export type RadioControlOption = {
  value: Exclude<RadioControlValue, null>;
  label: string;
};

export type RadioControl = {
  id: string;
  kind: "level" | "function" | "parameter" | "mode" | "operation" | "passband" | "action";
  token: string;
  /** Optional only for source compatibility with pre-catalogue driver fixtures. */
  group?: RadioControlGroup;
  access?: RadioControlAccess;
  presentation?: RadioControlPresentation;
  value: RadioControlValue;
  minimum?: number;
  maximum?: number;
  step?: number;
  unit?: RadioControlUnit;
  options?: RadioControlOption[];
  transmitLocked: boolean;
};

export type RadioModeState = {
  mode: string;
  passbandHz: number;
};

export type RadioReadOptions = {
  source?: "telemetry" | "control";
};

export type RadioPttReadOptions = {
  purpose?: "off-recovery";
};

export class ReceiveOnlyRadioError extends Error {
  constructor(message = "radio is receive-only") {
    super(message);
    this.name = "ReceiveOnlyRadioError";
  }
}

export interface RadioDriver {
  readonly receiveOnly?: boolean;
  initialize(): Promise<void>;
  prepareTelemetry?(): Promise<void>;
  close(): Promise<void>;
  capabilities(): Promise<RadioCapabilities>;
  readState(options?: RadioReadOptions): Promise<RadioState>;
  readTelemetry(mode: "receive" | "transmit"): Promise<RadioMeterSample>;
  readControls(): Promise<RadioControl[]>;
  setFrequency(frequencyHz: number): Promise<number>;
  setMode(mode: string, passbandHz?: number): Promise<RadioModeState>;
  setControl(id: string, value: RadioControlValue): Promise<RadioControl>;
  invokeAction(id: string): Promise<void>;
  engageInternalTuner?(): Promise<boolean>;
  writePtt(enabled: boolean): Promise<void>;
  readPtt(options?: RadioPttReadOptions): Promise<boolean>;
}
