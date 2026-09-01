import {
  IcomControl,
  getModeString,
} from "icom-wlan-node";
import type {
  AudioFrame,
  IcomMode,
} from "icom-wlan-node";

import type { IcomWlanConnection } from "../config/types.ts";
import {
  BoundedDriverAudioDuplex,
  type DriverAudioDuplex,
} from "../media/driver-audio.ts";

export const ICOM_WLAN_MODELS = [
  "IC-705",
  "IC-905",
  "IC-7300",
  "IC-9700",
  "IC-7610",
  "IC-7760",
] as const;

export type SupportedIcomWlanModel = typeof ICOM_WLAN_MODELS[number];
export type IcomWlanControlId =
  | "operation:SPLIT"
  | "operation:RIT"
  | "operation:XIT"
  | "function:TUNER";
export type IcomWlanTunerState = "off" | "on" | "tuning";

export type IcomWlanMode = {
  mode: string;
  dataMode: boolean;
};

export type IcomWlanMeters = {
  strengthDbRelativeS9?: number;
  swr?: number;
  alcPercent?: number;
  rfPowerPercent?: number;
  rfPowerWatts?: number;
};

export type IcomWlanPortCapabilities = {
  model: SupportedIcomWlanModel;
  canTransmit: boolean;
  supportsInternalTuner: boolean;
  controls: IcomWlanControlId[];
};

export interface IcomWlanPort {
  readonly audio: DriverAudioDuplex;
  initialize(): Promise<void>;
  close(): Promise<void>;
  capabilities(): Promise<IcomWlanPortCapabilities>;
  readFrequency(): Promise<number>;
  writeFrequency(frequencyHz: number): Promise<void>;
  readMode(): Promise<IcomWlanMode>;
  writeMode(mode: IcomWlanMode): Promise<void>;
  readPtt(): Promise<boolean>;
  writePtt(enabled: boolean): Promise<void>;
  readMeters(mode: "receive" | "transmit"): Promise<IcomWlanMeters>;
  readControl(id: IcomWlanControlId): Promise<boolean | number>;
  writeControl(id: IcomWlanControlId, value: boolean | number): Promise<void>;
  readTunerState(): Promise<IcomWlanTunerState>;
  writeTunerEnabled(enabled: boolean): Promise<void>;
  invokeTuner(): Promise<void>;
  onFatalConnection(listener: (error: Error) => void): () => void;
}

export class IcomWlanPortError extends Error {
  constructor(operation: string) {
    super(`ICOM WLAN ${operation} failed`);
    this.name = "IcomWlanPortError";
  }
}

export class IcomWlanFatalConnectionError extends Error {
  constructor() {
    super("ICOM WLAN connection lost");
    this.name = "IcomWlanFatalConnectionError";
  }
}

export class IcomWlanNodePort implements IcomWlanPort {
  readonly audio: BoundedDriverAudioDuplex;

  readonly #control: IcomControl;
  readonly #fatalListeners = new Set<(error: Error) => void>();
  #initializePromise: Promise<void> | null = null;
  #closePromise: Promise<void> | null = null;
  #supportTx: boolean | undefined;
  #closing = false;
  #fatalEmitted = false;

  constructor(connection: IcomWlanConnection) {
    this.#control = new IcomControl({
      control: { ip: connection.host, port: connection.port ?? 50_001 },
      userName: connection.username,
      password: connection.password,
      model: "auto",
    });
    this.audio = new BoundedDriverAudioDuplex((frame) => {
      try {
        this.#control.sendAudioPcm16(frame);
      } catch {
        throw new IcomWlanPortError("audio write");
      }
    });
    this.#control.configureMonitoring({ autoReconnect: false });
    this.#control.events.on("capabilities", (capabilities) => {
      this.#supportTx = capabilities.supportTX;
    });
    this.#control.events.on("audio", (frame) => this.#acceptAudio(frame));
    this.#control.events.on("error", () => this.#emitFatal());
    this.#control.events.on("connectionLost", () => this.#emitFatal());
    this.#control.events.on("reconnectFailed", () => this.#emitFatal());
  }

  initialize(): Promise<void> {
    this.#initializePromise ??= this.#run("initialization", async () => {
      await this.#control.connect();
      this.#supportedModel();
    });
    return this.#initializePromise;
  }

  close(): Promise<void> {
    this.#closePromise ??= (async () => {
      this.#closing = true;
      this.audio.close();
      try {
        await this.#control.disconnect({ silent: true });
      } catch {
        throw new IcomWlanPortError("close");
      }
    })();
    return this.#closePromise;
  }

  async capabilities(): Promise<IcomWlanPortCapabilities> {
    const profile = this.#control.profile;
    const supportsInternalTuner = profile.functions.includes("TUNER");
    return {
      model: this.#supportedModel(),
      canTransmit: this.#supportTx ?? true,
      supportsInternalTuner,
      controls: [
        ...(profile.supportsX25X26 ? ["operation:SPLIT" as const] : []),
        ...(profile.functions.includes("RIT") ? ["operation:RIT" as const] : []),
        ...(profile.functions.includes("XIT") ? ["operation:XIT" as const] : []),
        ...(supportsInternalTuner ? ["function:TUNER" as const] : []),
      ],
    };
  }

  readFrequency(): Promise<number> {
    return this.#required("frequency read", () => this.#control.readOperatingFrequency());
  }

  writeFrequency(frequencyHz: number): Promise<void> {
    return this.#run("frequency write", () => this.#control.setFrequency(frequencyHz));
  }

  async readMode(): Promise<IcomWlanMode> {
    const value = await this.#required("mode read", () => this.#control.readOperatingMode());
    const mode = value.modeName ?? getModeString(value.mode);
    if (mode === undefined) throw new IcomWlanPortError("mode read");
    return {
      mode,
      dataMode: value.dataMode === true,
    };
  }

  writeMode(mode: IcomWlanMode): Promise<void> {
    return this.#run("mode write", () =>
      this.#control.setMode(mode.mode as IcomMode, { dataMode: mode.dataMode }));
  }

  readPtt(): Promise<boolean> {
    return this.#required("PTT read", () => this.#control.readPtt());
  }

  writePtt(enabled: boolean): Promise<void> {
    return this.#run("PTT write", () => this.#control.setPtt(enabled));
  }

  async readMeters(mode: "receive" | "transmit"): Promise<IcomWlanMeters> {
    if (mode === "receive") {
      const strength = await this.#run("meter read", () => this.#control.getLevelMeter());
      return strength === null ? {} : { strengthDbRelativeS9: strength.dBm + 73 };
    }
    const [swr, alc, power] = await this.#run("meter read", () => Promise.all([
      this.#control.readSWR(),
      this.#control.readALC(),
      this.#control.readPowerLevel(),
    ]));
    return {
      ...(swr === null ? {} : { swr: swr.swr }),
      ...(alc === null ? {} : { alcPercent: alc.percent }),
      ...(power === null ? {} : { rfPowerPercent: power.percent }),
      ...(power?.watts === undefined ? {} : { rfPowerWatts: power.watts }),
    };
  }

  async readControl(id: IcomWlanControlId): Promise<boolean | number> {
    switch (id) {
      case "operation:SPLIT":
        return this.#required("control read", () => this.#control.getSplitEnabled());
      case "operation:RIT":
        return this.#required("control read", () => this.#control.getRitOffset());
      case "operation:XIT":
        return this.#required("control read", () => this.#control.getXitOffset());
      case "function:TUNER":
        return (await this.readTunerState()) !== "off";
    }
  }

  writeControl(id: IcomWlanControlId, value: boolean | number): Promise<void> {
    if (id === "function:TUNER") {
      return this.writeTunerEnabled(value as boolean);
    }
    return this.#run("control write", () => {
      switch (id) {
        case "operation:SPLIT":
          this.#control.setSplitEnabled(value as boolean);
          break;
        case "operation:RIT":
          this.#control.setRitOffset(value as number);
          break;
        case "operation:XIT":
          this.#control.setXitOffset(value as number);
          break;
      }
    });
  }

  async readTunerState(): Promise<IcomWlanTunerState> {
    const status = await this.#required("tuner status read", () => this.#control.readTunerStatus());
    switch (status.state) {
      case "OFF": return "off";
      case "ON": return "on";
      case "TUNING": return "tuning";
    }
  }

  writeTunerEnabled(enabled: boolean): Promise<void> {
    return this.#run("tuner enable write", () => this.#control.setTunerEnabled(enabled));
  }

  invokeTuner(): Promise<void> {
    return this.#run("tuner action", () => this.#control.startManualTune());
  }

  onFatalConnection(listener: (error: Error) => void): () => void {
    this.#fatalListeners.add(listener);
    return () => this.#fatalListeners.delete(listener);
  }

  #acceptAudio(frame: AudioFrame): void {
    if (frame.pcm16.byteLength % 2 !== 0) return;
    const samples = new Int16Array(frame.pcm16.byteLength / 2);
    for (let index = 0; index < samples.length; index += 1) {
      samples[index] = frame.pcm16.readInt16LE(index * 2);
    }
    this.audio.pushRx(samples);
  }

  #emitFatal(): void {
    if (this.#closing || this.#fatalEmitted) return;
    this.#fatalEmitted = true;
    this.audio.close();
    const error = new IcomWlanFatalConnectionError();
    for (const listener of this.#fatalListeners) listener(error);
  }

  #supportedModel(): SupportedIcomWlanModel {
    const model = this.#control.profile.modelId;
    if ((ICOM_WLAN_MODELS as readonly string[]).includes(model)) {
      return model as SupportedIcomWlanModel;
    }
    throw new IcomWlanPortError("model validation");
  }

  async #required<T>(operation: string, action: () => Promise<T | null>): Promise<T> {
    const value = await this.#run(operation, action);
    if (value === null) throw new IcomWlanPortError(operation);
    return value;
  }

  async #run<T>(operation: string, action: () => Promise<T> | T): Promise<T> {
    try {
      return await action();
    } catch (error) {
      if (error instanceof IcomWlanPortError) throw error;
      throw new IcomWlanPortError(operation);
    }
  }
}
