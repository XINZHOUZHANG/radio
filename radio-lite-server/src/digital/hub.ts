import type { RadioConfigFile } from "../config/types.ts";
import type { AdifLogStore } from "../log/adif-log-store.ts";
import type { RadioRuntimeRegistry } from "../rig/radio-runtime.ts";
import {
  DigitalRadioController,
  type DigitalControllerEvent,
} from "./controller.ts";
import { DummyDigitalWorker } from "./dummy-worker.ts";
import type { DigitalWorkerFactory } from "./worker.ts";

export class DigitalWorkerUnavailableError extends Error {}

export type DigitalRadioHubOptions = {
  radios: () => RadioConfigFile;
  runtimes: RadioRuntimeRegistry;
  logStore: AdifLogStore;
  workerFactory?: DigitalWorkerFactory;
  now?: () => number;
  onEvent?: (event: DigitalControllerEvent) => void;
};

export class DigitalRadioHub {
  readonly #radios: () => RadioConfigFile;
  readonly #runtimes: RadioRuntimeRegistry;
  readonly #logStore: AdifLogStore;
  readonly #workerFactory: DigitalWorkerFactory;
  readonly #now: () => number;
  readonly #onEvent: (event: DigitalControllerEvent) => void;
  readonly #controllers = new Map<string, Promise<DigitalRadioController>>();
  #closed = false;

  constructor(options: DigitalRadioHubOptions) {
    this.#radios = options.radios;
    this.#runtimes = options.runtimes;
    this.#logStore = options.logStore;
    this.#workerFactory = options.workerFactory ?? ((profile) => {
      if (profile.connection.kind === "hamlib-dummy") {
        return new DummyDigitalWorker();
      }
      throw new DigitalWorkerUnavailableError(
        "native WSJT-X worker is not configured for this radio",
      );
    });
    this.#now = options.now ?? Date.now;
    this.#onEvent = options.onEvent ?? (() => undefined);
  }

  get(radioId: string): Promise<DigitalRadioController> {
    this.#assertOpen();
    const existing = this.#controllers.get(radioId);
    if (existing !== undefined) {
      return existing;
    }
    const profile = this.#radios().radios.find((candidate) => candidate.id === radioId);
    if (profile === undefined) {
      throw new Error("radio does not exist");
    }
    const creating = Promise.resolve(this.#workerFactory(profile)).then(async (worker) => {
      const controller = new DigitalRadioController({
        profile,
        runtime: () => this.#runtimes.get(profile.id),
        worker,
        logStore: this.#logStore,
        now: this.#now,
        onEvent: this.#onEvent,
      });
      try {
        await controller.initialize();
        return controller;
      } catch (error) {
        await controller.close().catch(() => undefined);
        throw error;
      }
    }).catch((error) => {
      this.#controllers.delete(radioId);
      if (error instanceof DigitalWorkerUnavailableError) {
        throw error;
      }
      throw new DigitalWorkerUnavailableError(
        error instanceof Error ? error.message : "native digital worker could not start",
      );
    });
    this.#controllers.set(radioId, creating);
    return creating;
  }

  async invalidate(radioId: string): Promise<void> {
    const controller = this.#controllers.get(radioId);
    this.#controllers.delete(radioId);
    if (controller !== undefined) {
      try {
        await (await controller).close();
      } catch {
        // A controller that failed while starting has no remaining live resources.
      }
    }
  }

  async ownerDisconnected(ownerId: string): Promise<void> {
    await Promise.all([...this.#controllers.values()].map(async (controller) => {
      try {
        await (await controller).ownerDisconnected(ownerId);
      } catch {
        // One unavailable radio must not prevent other radios from de-keying.
      }
    }));
  }

  async ownerStoppedWithProof(ownerId: string): Promise<void> {
    await Promise.all([...this.#controllers.values()].map(async (controller) => {
      try {
        await (await controller).ownerStoppedWithProof(ownerId);
      } catch {
        // A confirmed hardware stop remains authoritative if local DSP cleanup fails.
      }
    }));
  }

  async close(): Promise<void> {
    if (this.#closed) {
      return;
    }
    this.#closed = true;
    const controllers = [...this.#controllers.values()];
    this.#controllers.clear();
    await Promise.all(controllers.map(async (controller) => {
      try {
        await (await controller).close();
      } catch {
        // Shutdown continues across failed native workers.
      }
    }));
  }

  #assertOpen(): void {
    if (this.#closed) {
      throw new Error("digital radio hub is closed");
    }
  }
}
