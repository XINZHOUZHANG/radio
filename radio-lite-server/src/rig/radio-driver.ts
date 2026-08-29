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
};

export type RadioControlValue = boolean | number | string | null;

export type RadioControl = {
  id: string;
  kind: "level" | "function" | "passband";
  token: string;
  value: RadioControlValue;
  minimum: number;
  maximum: number;
  step: number;
  unit: "ratio" | "decibel" | "index" | "boolean" | "hertz";
  transmitLocked: boolean;
};

export type RadioModeState = {
  mode: string;
  passbandHz: number;
};

export type RadioReadOptions = {
  source?: "telemetry" | "control";
};

export interface RadioDriver {
  initialize(): Promise<void>;
  close(): Promise<void>;
  capabilities(): Promise<RadioCapabilities>;
  readState(options?: RadioReadOptions): Promise<RadioState>;
  readTelemetry(mode: "receive" | "transmit"): Promise<RadioMeterSample>;
  readControls(): Promise<RadioControl[]>;
  setFrequency(frequencyHz: number): Promise<number>;
  setMode(mode: string, passbandHz?: number): Promise<RadioModeState>;
  setControl(id: string, value: RadioControlValue): Promise<RadioControl>;
  invokeAction(id: string): Promise<void>;
  writePtt(enabled: boolean): Promise<void>;
  readPtt(): Promise<boolean>;
}
