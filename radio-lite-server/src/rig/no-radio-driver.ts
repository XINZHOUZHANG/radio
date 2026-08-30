import {
  ReceiveOnlyRadioError,
  type RadioCapabilities,
  type RadioControl,
  type RadioControlValue,
  type RadioDriver,
  type RadioMeterSample,
  type RadioModeState,
  type RadioPttReadOptions,
  type RadioReadOptions,
  type RadioState,
} from "./radio-driver.ts";

const RECEIVE_STATE: Readonly<RadioState> = {
  frequencyHz: 0,
  mode: "",
  passbandHz: 0,
  ptt: false,
};

export class NoRadioDriver implements RadioDriver {
  readonly receiveOnly = true;

  async initialize(): Promise<void> {}

  async prepareTelemetry(): Promise<void> {}

  async close(): Promise<void> {}

  async capabilities(): Promise<RadioCapabilities> {
    return { canTransmit: false, supportsInternalTuner: false };
  }

  async readState(_options?: RadioReadOptions): Promise<RadioState> {
    return { ...RECEIVE_STATE };
  }

  async readTelemetry(_mode: "receive" | "transmit"): Promise<RadioMeterSample> {
    return {};
  }

  async readControls(): Promise<RadioControl[]> {
    return [];
  }

  async setFrequency(_frequencyHz: number): Promise<number> {
    throw new ReceiveOnlyRadioError();
  }

  async setMode(_mode: string, _passbandHz?: number): Promise<RadioModeState> {
    throw new ReceiveOnlyRadioError();
  }

  async setControl(_id: string, _value: RadioControlValue): Promise<RadioControl> {
    throw new ReceiveOnlyRadioError();
  }

  async invokeAction(_id: string): Promise<void> {
    throw new ReceiveOnlyRadioError();
  }

  async writePtt(enabled: boolean): Promise<void> {
    if (enabled) throw new ReceiveOnlyRadioError();
  }

  async readPtt(_options?: RadioPttReadOptions): Promise<boolean> {
    return false;
  }
}
