import { execFile } from "node:child_process";
import { readdir } from "node:fs/promises";

import {
  parseAlsaHardwareList,
  parsePactlJson,
  serialDevicesFromNames,
  type DiscoveredAudioDevice,
  type SerialDevice,
} from "./discovery.ts";
import { pairAudioCards, type DiscoveredAudioCard } from "./audio-cards.ts";
import {
  parseRigctlModelList,
  resolveCuratedPresets,
  type HamlibModel,
  type ResolvedRigPreset,
} from "./hamlib-catalog.ts";
import { PTT_METHODS, SERIAL_BAUD_RATES, type PttMethod } from "./types.ts";

export type DiscoveryCommandRunner = (
  executable: string,
  args: readonly string[],
) => Promise<string>;

export type DirectoryReader = (path: string) => Promise<string[]>;

export type HardwareDiscoveryResult = {
  hamlibModels: HamlibModel[];
  curatedPresets: ResolvedRigPreset[];
  serialDevices: SerialDevice[];
  audioInputs: DiscoveredAudioDevice[];
  audioOutputs: DiscoveredAudioDevice[];
  audioCards: DiscoveredAudioCard[];
  pttMethods: PttMethod[];
  baudRates: number[];
  warnings: string[];
};

export type HardwareDiscoveryOptions = {
  run?: DiscoveryCommandRunner;
  readDirectory?: DirectoryReader;
};

export class HardwareDiscovery {
  readonly #run: DiscoveryCommandRunner;
  readonly #readDirectory: DirectoryReader;

  constructor(options: HardwareDiscoveryOptions = {}) {
    this.#run = options.run ?? runCommand;
    this.#readDirectory = options.readDirectory ?? readDirectoryNames;
  }

  async discover(): Promise<HardwareDiscoveryResult> {
    const warnings: string[] = [];
    const [hamlibModels, serialDevices, audio] = await Promise.all([
      this.#discoverHamlib(warnings),
      this.#discoverSerial(warnings),
      this.#discoverAudio(warnings),
    ]);
    return {
      hamlibModels,
      curatedPresets: resolveCuratedPresets(hamlibModels),
      serialDevices,
      audioInputs: audio.inputs,
      audioOutputs: audio.outputs,
      audioCards: pairAudioCards(audio),
      pttMethods: [...PTT_METHODS],
      baudRates: [...SERIAL_BAUD_RATES],
      warnings,
    };
  }

  async #discoverHamlib(warnings: string[]): Promise<HamlibModel[]> {
    try {
      return parseRigctlModelList(await this.#run("rigctl", ["-l"]));
    } catch {
      warnings.push("hamlib_model_discovery_unavailable");
      return [];
    }
  }

  async #discoverSerial(warnings: string[]): Promise<SerialDevice[]> {
    let stable: string[] = [];
    let fallback: string[] = [];
    try {
      stable = await this.#readDirectory("/dev/serial/by-id");
    } catch {
      // Many systems have no by-id directory until a USB serial device is attached.
    }
    if (stable.length === 0) {
      try {
        fallback = await this.#readDirectory("/dev");
      } catch {
        warnings.push("serial_discovery_unavailable");
      }
    }
    return serialDevicesFromNames(stable, fallback);
  }

  async #discoverAudio(
    warnings: string[],
  ): Promise<{ inputs: DiscoveredAudioDevice[]; outputs: DiscoveredAudioDevice[] }> {
    try {
      const [sources, sinks] = await Promise.all([
        this.#run("pactl", ["-f", "json", "list", "sources"]),
        this.#run("pactl", ["-f", "json", "list", "sinks"]),
      ]);
      return {
        inputs: parsePactlJson(sources, "input"),
        outputs: parsePactlJson(sinks, "output"),
      };
    } catch {
      try {
        const [capture, playback] = await Promise.all([
          this.#run("arecord", ["-l"]),
          this.#run("aplay", ["-l"]),
        ]);
        warnings.push("pulseaudio_discovery_unavailable_using_alsa");
        return {
          inputs: parseAlsaHardwareList(capture, "input"),
          outputs: parseAlsaHardwareList(playback, "output"),
        };
      } catch {
        warnings.push("audio_discovery_unavailable");
        return { inputs: [], outputs: [] };
      }
    }
  }
}

function runCommand(executable: string, args: readonly string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      executable,
      [...args],
      {
        encoding: "utf8",
        timeout: 10_000,
        maxBuffer: 4 * 1_024 * 1_024,
        windowsHide: true,
        shell: false,
      },
      (error, stdout) => {
        if (error !== null) {
          reject(error);
          return;
        }
        resolve(stdout);
      },
    );
  });
}

async function readDirectoryNames(path: string): Promise<string[]> {
  return readdir(path);
}
