import { HamlibRig } from "./hamlib-rig.ts";
import type {
  RadioCapabilities,
  RadioControl,
  RadioControlValue,
  RadioDriver,
  RadioMeterSample,
  RadioModeState,
  RadioReadOptions,
  RadioState,
} from "./radio-driver.ts";

/**
 * Adapts Hamlib's flat controls to the transport-neutral driver boundary.
 * Transport ownership stays with the runtime supervisor, so lifecycle methods
 * deliberately do not start or close rigctld connections.
 */
export class HamlibDriver implements RadioDriver {
  readonly #rig: HamlibRig;
  #capabilities: Promise<RadioCapabilities> | null = null;

  constructor(rig: HamlibRig) {
    this.#rig = rig;
  }

  async initialize(): Promise<void> {}

  async close(): Promise<void> {}

  capabilities(): Promise<RadioCapabilities> {
    this.#capabilities ??= this.#loadCapabilities();
    return this.#capabilities;
  }

  async readState(_options?: RadioReadOptions): Promise<RadioState> {
    return this.#rig.readState();
  }

  async readTelemetry(_mode: "receive" | "transmit"): Promise<RadioMeterSample> {
    // RFPOWER is a transmit-power setting, never a measurement. Meter reads
    // are added only when Hamlib exposes dedicated actual-power meter tokens.
    return {};
  }

  async readControls(): Promise<RadioControl[]> {
    return this.#rig.readControls();
  }

  setFrequency(frequencyHz: number): Promise<number> {
    return this.#rig.setFrequency(frequencyHz);
  }

  setMode(mode: string, passbandHz?: number): Promise<RadioModeState> {
    return this.#rig.setMode(mode, passbandHz);
  }

  async setControl(id: string, value: RadioControlValue): Promise<RadioControl> {
    if (typeof value !== "number") {
      throw new Error("Hamlib flat controls require a numeric value");
    }
    return this.#rig.setControl(id, value);
  }

  async invokeAction(id: string): Promise<void> {
    if (id !== "action:TUNER") throw new Error(`action ${id} is unavailable`);
    await this.#rig.startInternalTuner();
  }

  writePtt(enabled: boolean): Promise<void> {
    return this.#rig.writePtt(enabled);
  }

  readPtt(): Promise<boolean> {
    return this.#rig.readPtt();
  }

  async #loadCapabilities(): Promise<RadioCapabilities> {
    return {
      canTransmit: true,
      supportsInternalTuner: await this.#rig.supportsInternalTuner(),
    };
  }
}
