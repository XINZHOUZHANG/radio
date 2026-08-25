import type { PublicUser } from "../auth/user-store.ts";
import type { RadioConfigFile, RadioProfile } from "../config/types.ts";
import { ControlLeaseManager, type ControlAcquireResult } from "../control/control-lease.ts";
import {
  TransmitInterlock,
  type TransmitDriver,
  type TransmitLease,
  type TransmitMode,
} from "../safety/transmit-interlock.ts";
import {
  HamlibRig,
  isTransmitLockedRigControlId,
  type HamlibRigControl,
  type HamlibRigState,
} from "./hamlib-rig.ts";
import { ManagedRigctldProcess } from "./managed-process.ts";
import { rigctldTarget } from "./rigctld-command.ts";
import { RigctldTransport } from "./transport.ts";

export type RigControl = {
  readState(): Promise<HamlibRigState>;
  readControls(): Promise<HamlibRigControl[]>;
  setFrequency(frequencyHz: number): Promise<number>;
  setMode(mode: string, passbandHz?: number): Promise<{ mode: string; passbandHz: number }>;
  setControl(id: string, value: number): Promise<HamlibRigControl>;
  setPtt(enabled: boolean): Promise<boolean>;
  setInternalTuner(enabled: boolean): Promise<boolean>;
};

export class HardwareTransmitDisabledError extends Error {}
export class TransmitPermissionError extends Error {}
export class RigControlTransmitLockedError extends Error {}

export class RadioRuntime {
  readonly profile: RadioProfile;
  readonly control: ControlLeaseManager;
  readonly interlock: TransmitInterlock;
  readonly #rig: RigControl;
  readonly #closeDependencies: () => Promise<void>;
  readonly #safetyTimer: ReturnType<typeof setInterval>;
  #closed = false;
  #tail: Promise<void> = Promise.resolve();

  constructor(
    profile: RadioProfile,
    rig: RigControl,
    closeDependencies: () => Promise<void> = async () => undefined,
    now: () => number = Date.now,
  ) {
    this.profile = profile;
    this.#rig = rig;
    this.#closeDependencies = closeDependencies;
    this.control = new ControlLeaseManager({ now });
    const driver: TransmitDriver = {
      activate: async (mode) => {
        if (mode === "tuning") {
          await this.#rig.setInternalTuner(true);
        } else {
          await this.#rig.setPtt(true);
        }
      },
      deactivate: async (mode) => {
        if (mode === "tuning") {
          await this.#rig.setInternalTuner(false);
        }
        await this.#rig.setPtt(false);
      },
      emergencyOff: async () => {
        await this.#rig.setPtt(false);
      },
    };
    this.interlock = new TransmitInterlock(driver, { now });
    this.#safetyTimer = setInterval(() => {
      void this.#checkSafety();
    }, 250);
    this.#safetyTimer.unref();
  }

  async initialize(): Promise<void> {
    await this.interlock.startupSafe();
  }

  readState(): Promise<HamlibRigState> {
    return this.#rig.readState();
  }

  readControls(): Promise<HamlibRigControl[]> {
    return this.#rig.readControls();
  }

  async acquireControl(
    ownerId: string,
    user: PublicUser,
    force = false,
  ): Promise<ControlAcquireResult> {
    return this.#serialize(async () => {
      const result = this.control.acquire(ownerId, user.id, {
        administrator: user.role === "admin",
        force,
      });
      if (result.displacedOwnerId !== null) {
        await this.interlock.ownerDisconnected(result.displacedOwnerId);
      }
      return result;
    });
  }

  heartbeatControl(ownerId: string, token: string) {
    return this.control.heartbeat(ownerId, token);
  }

  async releaseControl(ownerId: string, token: string): Promise<boolean> {
    return this.#serialize(async () => {
      this.control.assertValid(ownerId, token);
      await this.interlock.ownerDisconnected(ownerId);
      return this.control.release(ownerId, token);
    });
  }

  async setFrequency(ownerId: string, controlToken: string, frequencyHz: number): Promise<number> {
    this.control.assertValid(ownerId, controlToken);
    return this.#rig.setFrequency(frequencyHz);
  }

  async setMode(
    ownerId: string,
    controlToken: string,
    mode: string,
    passbandHz = 0,
  ): Promise<{ mode: string; passbandHz: number }> {
    this.control.assertValid(ownerId, controlToken);
    return this.#rig.setMode(mode, passbandHz);
  }

  async setControl(
    ownerId: string,
    controlToken: string,
    controlId: string,
    value: number,
  ): Promise<HamlibRigControl> {
    return this.#serialize(async () => {
      this.control.assertValid(ownerId, controlToken);
      if (
        this.interlock.snapshot().lease !== null &&
        isTransmitLockedRigControlId(controlId)
      ) {
        throw new RigControlTransmitLockedError(
          "transmit-sensitive radio controls are locked while transmitting",
        );
      }
      return this.#rig.setControl(controlId, value);
    });
  }

  async startTransmit(
    ownerId: string,
    user: PublicUser,
    controlToken: string,
    mode: TransmitMode,
  ): Promise<TransmitLease> {
    return this.#serialize(async () => {
      const controlLease = this.control.assertValid(ownerId, controlToken);
      if (controlLease.userId !== user.id) {
        throw new TransmitPermissionError("control lease belongs to a different account");
      }
      if (!user.canTransmit) {
        throw new TransmitPermissionError("account is not permitted to transmit");
      }
      if (!this.profile.hardwareTxEnabled && this.profile.hamlibModelId !== 1) {
        throw new HardwareTransmitDisabledError("hardware transmission is disabled for this radio");
      }
      return this.interlock.start(ownerId, mode);
    });
  }

  async heartbeatTransmit(
    ownerId: string,
    controlToken: string,
    transmitToken: string,
  ): Promise<TransmitLease> {
    this.control.heartbeat(ownerId, controlToken);
    return this.interlock.heartbeat(ownerId, transmitToken);
  }

  async stopTransmit(ownerId: string, transmitToken: string): Promise<void> {
    await this.interlock.stop(ownerId, transmitToken);
  }

  async ownerDisconnected(ownerId: string): Promise<void> {
    await this.interlock.ownerDisconnected(ownerId);
    this.control.release(ownerId);
  }

  async close(): Promise<void> {
    if (this.#closed) {
      return;
    }
    this.#closed = true;
    clearInterval(this.#safetyTimer);
    await this.interlock.trip("radio runtime stopped").catch(() => undefined);
    await this.#closeDependencies();
  }

  async #checkSafety(): Promise<void> {
    await this.interlock.checkDeadlines().catch(() => undefined);
    const transmitOwner = this.interlock.snapshot().lease?.ownerId;
    const controlOwner = this.control.snapshot()?.ownerId;
    if (transmitOwner !== undefined && transmitOwner !== controlOwner) {
      await this.interlock.ownerDisconnected(transmitOwner).catch(() => undefined);
    }
  }

  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

export type RadioRuntimeFactory = (
  profile: RadioProfile,
  managedPort: number,
) => Promise<RadioRuntime>;

export class RadioRuntimeRegistry {
  readonly #profiles: () => RadioConfigFile;
  readonly #factory: RadioRuntimeFactory;
  readonly #runtimes = new Map<string, Promise<RadioRuntime>>();
  readonly #invalidations = new Map<string, Promise<void>>();

  constructor(
    profiles: () => RadioConfigFile,
    factory: RadioRuntimeFactory = createDefaultRadioRuntime,
  ) {
    this.#profiles = profiles;
    this.#factory = factory;
  }

  get(radioId: string): Promise<RadioRuntime> {
    const invalidation = this.#invalidations.get(radioId);
    if (invalidation !== undefined) {
      return invalidation.then(() => this.get(radioId));
    }
    const existing = this.#runtimes.get(radioId);
    if (existing !== undefined) {
      return existing;
    }
    const config = this.#profiles();
    const index = config.radios.findIndex((profile) => profile.id === radioId);
    if (index < 0) {
      throw new Error("radio does not exist");
    }
    let runtime!: Promise<RadioRuntime>;
    runtime = this.#factory(config.radios[index], 4_600 + index)
      .catch((error) => {
        if (this.#runtimes.get(radioId) === runtime) {
          this.#runtimes.delete(radioId);
        }
        throw error;
      });
    this.#runtimes.set(radioId, runtime);
    return runtime;
  }

  async invalidate(radioId: string): Promise<void> {
    const active = this.#invalidations.get(radioId);
    if (active !== undefined) {
      return active;
    }
    const runtime = this.#runtimes.get(radioId);
    if (this.#runtimes.get(radioId) === runtime) {
      this.#runtimes.delete(radioId);
    }
    const invalidation = (async () => {
      if (runtime !== undefined) {
        try {
          await (await runtime).close();
        } catch {
          // A failed initialization is already removed; there is no live runtime to close.
        }
      }
    })();
    this.#invalidations.set(radioId, invalidation);
    try {
      await invalidation;
    } finally {
      if (this.#invalidations.get(radioId) === invalidation) {
        this.#invalidations.delete(radioId);
      }
    }
  }

  async ownerDisconnected(ownerId: string): Promise<void> {
    await Promise.all(
      [...this.#runtimes.values()].map(async (runtime) => {
        await (await runtime).ownerDisconnected(ownerId);
      }),
    );
  }

  async close(): Promise<void> {
    const runtimes = [...this.#runtimes.values()];
    this.#runtimes.clear();
    await Promise.all(runtimes.map(async (runtime) => {
      try {
        await (await runtime).close();
      } catch {
        // Shutdown continues so one failed radio cannot prevent other PTT paths closing.
      }
    }));
  }
}

async function createDefaultRadioRuntime(
  profile: RadioProfile,
  managedPort: number,
): Promise<RadioRuntime> {
  const target = rigctldTarget(profile, managedPort);
  const managed = target.command === undefined ? null : new ManagedRigctldProcess(target.command);
  if (managed !== null) {
    await managed.start();
  }
  const transport = new RigctldTransport(target.host, target.port);
  const runtime = new RadioRuntime(
    profile,
    new HamlibRig(transport, {
      pttMethod: profile.ptt.method,
    }),
    async () => {
      await transport.close();
      await managed?.close();
    },
  );
  try {
    await runtime.initialize();
    return runtime;
  } catch (error) {
    await runtime.close().catch(() => undefined);
    throw error;
  }
}
