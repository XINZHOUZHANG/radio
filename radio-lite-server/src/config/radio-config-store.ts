import { dirname } from "node:path";

import { readJsonWithBackup, writeJsonAtomic } from "../storage/atomic-json.ts";
import {
  RADIO_CONFIG_VERSION,
  parseRadioConfig,
  parseRadioProfile,
  type RadioConfigFile,
  type RadioProfile,
} from "./types.ts";

export class RadioConfigStore {
  readonly #path: string;
  #snapshot: RadioConfigFile = { version: RADIO_CONFIG_VERSION, radios: [] };
  #loaded = false;
  #tail: Promise<void> = Promise.resolve();

  constructor(path: string) {
    if (!path || !dirname(path)) {
      throw new Error("configuration path is required");
    }
    this.#path = path;
  }

  async load(): Promise<{ config: RadioConfigFile; recoveredFromBackup: boolean }> {
    return this.#serialize(async () => {
      const result = await readJsonWithBackup(
        this.#path,
        parseRadioConfig,
        () => ({ version: RADIO_CONFIG_VERSION, radios: [] }),
      );
      this.#snapshot = result.value;
      this.#loaded = true;
      return {
        config: structuredClone(this.#snapshot),
        recoveredFromBackup: result.source === "backup",
      };
    });
  }

  snapshot(): RadioConfigFile {
    this.#assertLoaded();
    return structuredClone(this.#snapshot);
  }

  async replace(value: unknown): Promise<RadioConfigFile> {
    const parsed = parseRadioConfig(value);
    return this.#serialize(async () => {
      await writeJsonAtomic(this.#path, parsed);
      this.#snapshot = parsed;
      this.#loaded = true;
      return structuredClone(parsed);
    });
  }

  async upsert(value: unknown): Promise<RadioProfile> {
    const profile = parseRadioProfile(value);
    return this.#serialize(async () => {
      this.#assertLoaded();
      const radios = this.#snapshot.radios.filter((radio) => radio.id !== profile.id);
      radios.push(profile);
      radios.sort((left, right) => left.id.localeCompare(right.id));
      const next: RadioConfigFile = { version: RADIO_CONFIG_VERSION, radios };
      await writeJsonAtomic(this.#path, next);
      this.#snapshot = next;
      return structuredClone(profile);
    });
  }

  async remove(radioId: string): Promise<boolean> {
    return this.#serialize(async () => {
      this.#assertLoaded();
      const radios = this.#snapshot.radios.filter((radio) => radio.id !== radioId);
      if (radios.length === this.#snapshot.radios.length) {
        return false;
      }
      const next: RadioConfigFile = { version: RADIO_CONFIG_VERSION, radios };
      await writeJsonAtomic(this.#path, next);
      this.#snapshot = next;
      return true;
    });
  }

  #assertLoaded(): void {
    if (!this.#loaded) {
      throw new Error("radio configuration store has not been loaded");
    }
  }

  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }
}
