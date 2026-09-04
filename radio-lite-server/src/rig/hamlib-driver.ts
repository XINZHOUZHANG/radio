import { HamlibRig } from "./hamlib-rig.ts";
import type { CatCommandMode } from "./cat-command-limiter.ts";
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

/**
 * Adapts Hamlib's flat controls to the transport-neutral driver boundary.
 * Transport ownership stays with the runtime supervisor, so lifecycle methods
 * deliberately do not start or close rigctld connections.
 */
export class HamlibDriver implements RadioDriver {
  readonly #rig: HamlibRig;
  readonly #onTransportMode: (mode: CatCommandMode) => void;
  #capabilities: Promise<RadioCapabilities> | null = null;

  constructor(
    rig: HamlibRig,
    options: { onTransportMode?: (mode: CatCommandMode) => void } = {},
  ) {
    this.#rig = rig;
    this.#onTransportMode = options.onTransportMode ?? (() => undefined);
  }

  async initialize(): Promise<void> {}

  async prepareTelemetry(): Promise<void> {
    // Warm the readable-level catalogue once, outside every steady telemetry
    // tick and after managed rigctld startup. This keeps a TX tick to PTT,
    // SWR, ALC, and one actual-power read.
    await this.#rig.discoverTelemetryMeters();
  }

  async close(): Promise<void> {}

  capabilities(): Promise<RadioCapabilities> {
    this.#capabilities ??= this.#loadCapabilities();
    return this.#capabilities;
  }

  async readState(_options?: RadioReadOptions): Promise<RadioState> {
    const state = await this.#rig.readState();
    this.#onTransportMode(state.ptt ? "transmit" : "receive");
    return state;
  }

  async readTelemetry(mode: "receive" | "transmit"): Promise<RadioMeterSample> {
    const sample = await this.#rig.readTelemetry(mode);
    if (sample.ptt !== undefined) {
      this.#onTransportMode(sample.ptt ? "transmit" : "receive");
    }
    return sample;
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
    return this.#rig.setControl(id, value);
  }

  async invokeAction(id: string): Promise<void> {
    if (id !== "action:TUNER") throw new Error(`action ${id} is unavailable`);
    await this.#rig.startInternalTuner();
  }

  engageInternalTuner(): Promise<boolean> {
    return this.#rig.engageInternalTuner();
  }

  writePtt(enabled: boolean): Promise<void> {
    return this.#rig.writePtt(enabled);
  }

  async readPtt(options?: RadioPttReadOptions): Promise<boolean> {
    const ptt = await (options?.purpose === "off-recovery"
      ? this.#rig.readPtt()
      : this.#rig.readPttForControl());
    this.#onTransportMode(ptt ? "transmit" : "receive");
    return ptt;
  }

  async #loadCapabilities(): Promise<RadioCapabilities> {
    return {
      canTransmit: true,
      supportsInternalTuner: await this.#rig.supportsInternalTuner(),
    };
  }
}
