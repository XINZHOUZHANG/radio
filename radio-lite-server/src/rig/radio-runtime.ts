import { realpathSync } from "node:fs";

import type { PublicUser } from "../auth/user-store.ts";
import type { RadioConfigFile, RadioProfile } from "../config/types.ts";
import { ControlLeaseManager, type ControlAcquireResult } from "../control/control-lease.ts";
import type { DeKeyOutcome } from "../safety/dekey.ts";
import { SafetyEventHub } from "../safety/safety-event-hub.ts";
import {
  DeKeyUnconfirmedError,
  InvalidLeaseError,
  TransmitInterlock,
  type TransmitDriver,
  type TransmitLease,
  type TransmitMode,
} from "../safety/transmit-interlock.ts";
import {
  HamlibRig,
  InternalTunerUnsupportedError,
  isTransmitLockedRigControlId,
  type HamlibRigControl,
  type HamlibRigState,
} from "./hamlib-rig.ts";
import { ManagedRigctldProcess } from "./managed-process.ts";
import { rigctldTarget } from "./rigctld-command.ts";
import {
  RigRuntimeSupervisor,
  RigRuntimeSupervisorCleanupUncertainError,
  type ManagedRigctldExit,
} from "./runtime-supervisor.ts";
import { RigctldTransport, RigReportError } from "./transport.ts";

export type RigControl = {
  readState(): Promise<HamlibRigState>;
  readControls(): Promise<HamlibRigControl[]>;
  setFrequency(frequencyHz: number): Promise<number>;
  setMode(mode: string, passbandHz?: number): Promise<{ mode: string; passbandHz: number }>;
  setControl(id: string, value: number): Promise<HamlibRigControl>;
  setPtt(enabled: boolean): Promise<boolean>;
  writePtt(enabled: boolean): Promise<void>;
  readPtt(): Promise<boolean>;
  supportsInternalTuner(): Promise<boolean>;
  startInternalTuner(): Promise<void>;
  writeInternalTuner(enabled: boolean): Promise<void>;
};

export class HardwareTransmitDisabledError extends Error {}
export class TransmitPermissionError extends Error {}
export class RigControlTransmitLockedError extends Error {}
export class ManagedSerialDeviceBusyError extends Error {}
export class RadioRuntimeRegistryClosedError extends Error {}
export class RadioRuntimeCleanupUncertainError extends Error {}

export type RadioRuntimeOptions = {
  safetyEvents?: SafetyEventHub;
  startManaged?: () => Promise<void>;
  restartManaged?: (
    recoveryGeneration: number,
    exit: ManagedRigctldExit,
  ) => Promise<void>;
};

export class RadioRuntime {
  readonly profile: RadioProfile;
  readonly control: ControlLeaseManager;
  readonly interlock: TransmitInterlock;
  readonly supervisor: RigRuntimeSupervisor;
  readonly #rig: RigControl;
  readonly #safetyTimer: ReturnType<typeof setInterval>;
  #closePromise: Promise<void> | null = null;
  #tail: Promise<void> = Promise.resolve();

  constructor(
    profile: RadioProfile,
    rig: RigControl,
    closeDependencies: () => Promise<void> = async () => undefined,
    now: () => number = Date.now,
    options: RadioRuntimeOptions = {},
  ) {
    this.profile = profile;
    this.#rig = rig;
    this.control = new ControlLeaseManager({ now });
    const driver: TransmitDriver = {
      activate: async (mode) => {
        if (mode === "tuning") {
          await this.#rig.startInternalTuner();
        } else {
          await this.#rig.setPtt(true);
        }
      },
      deactivate: async () => undefined,
      emergencyOff: async () => {
        await this.#rig.writePtt(false);
      },
      readPtt: async () => {
        return this.#rig.readPtt();
      },
    };
    this.interlock = new TransmitInterlock(driver, { now });
    const safetyEvents = options.safetyEvents ?? new SafetyEventHub({
      configuredRadioIds: () => [profile.id],
    });
    this.supervisor = new RigRuntimeSupervisor({
      radioId: profile.id,
      interlock: this.interlock,
      safetyEvents,
      recoveryTransport: () => driver,
      startManaged: options.startManaged,
      restartManaged: options.restartManaged,
      closeManaged: closeDependencies,
      now,
    });
    this.#safetyTimer = setInterval(() => {
      void this.#checkSafety();
    }, 250);
  }

  async initialize(): Promise<void> {
    try {
      await this.supervisor.startupObserve();
    } catch (error) {
      if (
        !this.profile.hardwareTxEnabled &&
        this.profile.ptt.method === "None" &&
        error instanceof RigReportError &&
        error.report === -11
      ) {
        return;
      }
      throw error;
    }
  }

  readState(): Promise<HamlibRigState> {
    return this.#rig.readState();
  }

  readControls(): Promise<HamlibRigControl[]> {
    return this.#rig.readControls();
  }

  supportsInternalTuner(): Promise<boolean> {
    return this.#rig.supportsInternalTuner();
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
        await this.supervisor.ownerDisconnected(
          result.displacedOwnerId,
          "control force takeover",
        );
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
      let released = false;
      try {
        await this.supervisor.ownerDisconnected(ownerId, "control released");
      } finally {
        released = this.control.release(ownerId, token);
      }
      return released;
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
        this.supervisor.snapshot().lease !== null &&
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
      const controlLease = this.#assertTransmitAdmission(ownerId, user, controlToken);
      if (mode === "tuning" && !(await this.#rig.supportsInternalTuner())) {
        throw new InternalTunerUnsupportedError(
          "radio does not support internal tuning via Hamlib TUNE",
        );
      }
      const permit = await this.supervisor.reserveTransmitStart({
        radioId: this.profile.id,
        ownerId,
        userId: user.id,
        mode,
        controlLeaseRevision: controlLease.acquiredAtMs,
        profileRevision: 1,
      });
      try {
        return await this.supervisor.commitTransmitStart(permit, () => {
          this.#assertTransmitAdmission(ownerId, user, controlToken);
        });
      } catch (error) {
        this.supervisor.abandonTransmitStart(permit, "transmit start failed");
        throw error;
      }
    });
  }

  async heartbeatTransmit(
    ownerId: string,
    controlToken: string,
    transmitToken: string,
  ): Promise<TransmitLease> {
    this.control.heartbeat(ownerId, controlToken);
    return this.supervisor.heartbeat(ownerId, transmitToken);
  }

  async stopTransmit(ownerId: string, transmitToken: string): Promise<void> {
    const outcome = await this.supervisor.stop(ownerId, transmitToken, "released by owner");
    if (outcome.kind === "offConfirmed") {
      return;
    }
    if (outcome.kind === "recoveryPending") {
      const fault = this.supervisor.snapshot().faultReason ?? "PTT OFF remains unconfirmed";
      throw new DeKeyUnconfirmedError({
        confirmed: false,
        generation: outcome.generation,
        reason: `${fault}; PTT OFF read-back remained ON or unavailable`,
      });
    }
    throw new InvalidLeaseError("invalid transmit lease");
  }

  stopTransmitOutcome(ownerId: string, transmitToken: string): Promise<DeKeyOutcome> {
    return this.supervisor.stop(ownerId, transmitToken, "automatic transmit stop");
  }

  async ownerDisconnected(ownerId: string): Promise<void> {
    try {
      await this.supervisor.ownerDisconnected(ownerId, "control owner disconnected");
    } finally {
      this.control.release(ownerId);
    }
  }

  async close(): Promise<void> {
    if (this.#closePromise !== null) {
      await this.#closePromise;
      return;
    }
    clearInterval(this.#safetyTimer);
    const closing = (async () => {
      try {
        await this.supervisor.close();
      } catch (error) {
        throw new RadioRuntimeCleanupUncertainError(
          "radio de-key or dependency cleanup could not be confirmed",
          {
            cause: error instanceof RigRuntimeSupervisorCleanupUncertainError
              ? error
              : new AggregateError([error]),
          },
        );
      }
    })();
    this.#closePromise = closing;
    await closing;
  }

  async #checkSafety(): Promise<void> {
    await this.supervisor.checkDeadlines().catch(() => undefined);
    const transmitOwner = this.supervisor.snapshot().lease?.ownerId;
    const controlOwner = this.control.snapshot()?.ownerId;
    if (transmitOwner !== undefined && transmitOwner !== controlOwner) {
      await this.supervisor.ownerDisconnected(
        transmitOwner,
        "transmit owner lost control authority",
      ).catch(() => undefined);
    }
  }

  #assertTransmitAdmission(
    ownerId: string,
    user: PublicUser,
    controlToken: string,
  ) {
    const controlLease = this.control.assertValid(ownerId, controlToken);
    if (!user.enabled || controlLease.userId !== user.id) {
      throw new TransmitPermissionError("control lease belongs to a disabled or different account");
    }
    if (!user.canTransmit) {
      throw new TransmitPermissionError("account is not permitted to transmit");
    }
    if (!this.profile.hardwareTxEnabled && this.profile.hamlibModelId !== 1) {
      throw new HardwareTransmitDisabledError("hardware transmission is disabled for this radio");
    }
    return controlLease;
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
  safetyEvents: SafetyEventHub,
) => Promise<RadioRuntime>;

export type ManagedSerialDeviceResolver = (devicePath: string) => string;

export type ManagedSerialDeviceReservation = {
  release(): void;
  quarantine(): void;
};

type RuntimeSerialDeviceClaim = {
  key: string;
  generation: symbol;
};

export class RadioRuntimeRegistry {
  readonly safetyEvents: SafetyEventHub;
  readonly #profiles: () => RadioConfigFile;
  readonly #factory: RadioRuntimeFactory;
  readonly #resolveSerialDevice: ManagedSerialDeviceResolver;
  readonly #runtimes = new Map<string, Promise<RadioRuntime>>();
  readonly #runtimeSerialDevices = new Map<string, RuntimeSerialDeviceClaim>();
  readonly #reservedSerialDevices = new Map<string, symbol>();
  readonly #quarantinedSerialDevices = new Set<string>();
  readonly #invalidations = new Map<string, Promise<void>>();
  #closed = false;
  #closePromise: Promise<void> | null = null;

  constructor(
    profiles: () => RadioConfigFile,
    factory?: RadioRuntimeFactory,
    resolveSerialDevice: ManagedSerialDeviceResolver = canonicalManagedSerialDevice,
  ) {
    this.#profiles = profiles;
    this.safetyEvents = new SafetyEventHub({
      configuredRadioIds: () => this.#profiles().radios.map((profile) => profile.id),
    });
    this.#factory = factory ?? ((profile, managedPort) =>
      createDefaultRadioRuntime(profile, managedPort, this.safetyEvents));
    this.#resolveSerialDevice = resolveSerialDevice;
  }

  get(radioId: string): Promise<RadioRuntime> {
    if (this.#closed) {
      throw new RadioRuntimeRegistryClosedError("radio runtime registry is closed");
    }
    const invalidation = this.#invalidations.get(radioId);
    if (invalidation !== undefined) {
      return invalidation.then(
        () => this.get(radioId),
        (error: unknown) => {
          if (this.#closed) {
            throw new RadioRuntimeRegistryClosedError("radio runtime registry is closed");
          }
          const profile = this.#profiles().radios.find((candidate) => candidate.id === radioId);
          if (
            profile?.connection.kind === "managed-serial" &&
            error instanceof RadioRuntimeCleanupUncertainError
          ) {
            throw new ManagedSerialDeviceBusyError(
              `managed serial device is quarantined after cleanup failure: ${profile.connection.devicePath}`,
            );
          }
          throw error;
        },
      );
    }
    const config = this.#profiles();
    const index = config.radios.findIndex((profile) => profile.id === radioId);
    if (index < 0) {
      throw new Error("radio does not exist");
    }
    const profile = config.radios[index];
    const serialDevice = profile.connection.kind === "managed-serial"
      ? profile.connection.devicePath
      : undefined;
    const serialDeviceKey = serialDevice === undefined
      ? undefined
      : this.#serialDeviceKey(serialDevice);
    const activeSerialDevice = this.#runtimeSerialDevices.get(radioId)?.key ?? serialDeviceKey;
    if (
      activeSerialDevice !== undefined &&
      (
        this.#reservedSerialDevices.has(activeSerialDevice) ||
        this.#quarantinedSerialDevices.has(activeSerialDevice)
      )
    ) {
      throw new ManagedSerialDeviceBusyError(
        `managed serial device is reserved for hardware preflight: ${serialDevice ?? activeSerialDevice}`,
      );
    }
    const existing = this.#runtimes.get(radioId);
    if (existing !== undefined) {
      return existing;
    }
    if (
      serialDevice !== undefined &&
      [...this.#runtimeSerialDevices.entries()].some(
        ([otherRadioId, claim]) => otherRadioId !== radioId && claim.key === serialDeviceKey,
      )
    ) {
      throw new ManagedSerialDeviceBusyError(
        `managed serial device is already in use: ${serialDevice}`,
      );
    }
    let runtime!: Promise<RadioRuntime>;
    const serialDeviceClaim = serialDeviceKey === undefined
      ? undefined
      : { key: serialDeviceKey, generation: Symbol(radioId) };
    if (serialDeviceClaim !== undefined) {
      this.#runtimeSerialDevices.set(radioId, serialDeviceClaim);
    }
    try {
      runtime = this.#factory(profile, 4_600 + index, this.safetyEvents)
        .catch((error) => {
          if (this.#runtimes.get(radioId) === runtime) {
            this.#runtimes.delete(radioId);
            if (error instanceof RadioRuntimeCleanupUncertainError) {
              this.#quarantine(serialDeviceClaim);
            }
            if (this.#runtimeSerialDevices.get(radioId) === serialDeviceClaim) {
              this.#runtimeSerialDevices.delete(radioId);
            }
          }
          throw error;
        });
    } catch (error) {
      if (error instanceof RadioRuntimeCleanupUncertainError) {
        this.#quarantine(serialDeviceClaim);
      }
      if (this.#runtimeSerialDevices.get(radioId) === serialDeviceClaim) {
        this.#runtimeSerialDevices.delete(radioId);
      }
      throw error;
    }
    this.#runtimes.set(radioId, runtime);
    return runtime;
  }

  reserveManagedSerialDevice(devicePath: string): ManagedSerialDeviceReservation {
    if (this.#closed) {
      throw new RadioRuntimeRegistryClosedError("radio runtime registry is closed");
    }
    const deviceKey = this.#serialDeviceKey(devicePath);
    if (
      this.#reservedSerialDevices.has(deviceKey) ||
      this.#quarantinedSerialDevices.has(deviceKey) ||
      [...this.#runtimeSerialDevices.values()].some((claim) => claim.key === deviceKey)
    ) {
      throw new ManagedSerialDeviceBusyError(
        `managed serial device is already in use: ${devicePath}`,
      );
    }
    const reservation = Symbol(devicePath);
    this.#reservedSerialDevices.set(deviceKey, reservation);
    return {
      release: () => {
        if (this.#reservedSerialDevices.get(deviceKey) === reservation) {
          this.#reservedSerialDevices.delete(deviceKey);
        }
      },
      quarantine: () => {
        if (this.#reservedSerialDevices.get(deviceKey) === reservation) {
          this.#quarantinedSerialDevices.add(deviceKey);
        }
      },
    };
  }

  #serialDeviceKey(devicePath: string): string {
    try {
      return this.#resolveSerialDevice(devicePath) || devicePath;
    } catch {
      return devicePath;
    }
  }

  #quarantine(claim: RuntimeSerialDeviceClaim | undefined): void {
    if (claim !== undefined) {
      this.#quarantinedSerialDevices.add(claim.key);
    }
  }

  async invalidate(radioId: string): Promise<void> {
    if (this.#closed) {
      throw new RadioRuntimeRegistryClosedError("radio runtime registry is closed");
    }
    const active = this.#invalidations.get(radioId);
    if (active !== undefined) {
      return active;
    }
    const runtime = this.#runtimes.get(radioId);
    const serialDeviceClaim = this.#runtimeSerialDevices.get(radioId);
    if (this.#runtimes.get(radioId) === runtime) {
      this.#runtimes.delete(radioId);
    }
    let cleanupUncertain = false;
    const work = (async () => {
      if (runtime !== undefined) {
        let initialized: RadioRuntime;
        try {
          initialized = await runtime;
        } catch (error) {
          if (error instanceof RadioRuntimeCleanupUncertainError) {
            cleanupUncertain = true;
            throw error;
          }
          return;
        }
        try {
          await initialized.close();
        } catch (error) {
          cleanupUncertain = true;
          throw cleanupUncertainError(error, "radio runtime cleanup could not be confirmed");
        }
      }
    })();
    let invalidation!: Promise<void>;
    invalidation = work.finally(() => {
      if (cleanupUncertain) {
        this.#quarantine(serialDeviceClaim);
      }
      if (this.#invalidations.get(radioId) === invalidation) {
        this.#invalidations.delete(radioId);
      }
      if (this.#runtimeSerialDevices.get(radioId) === serialDeviceClaim) {
        this.#runtimeSerialDevices.delete(radioId);
      }
    });
    this.#invalidations.set(radioId, invalidation);
    await invalidation;
  }

  async ownerDisconnected(ownerId: string): Promise<void> {
    await Promise.all(
      [...this.#runtimes.values()].map(async (runtime) => {
        await (await runtime).ownerDisconnected(ownerId);
      }),
    );
  }

  async close(): Promise<void> {
    if (this.#closePromise !== null) {
      await this.#closePromise;
      return;
    }
    this.#closed = true;
    const runtimes = [...this.#runtimes.entries()].map(([radioId, runtime]) => ({
      runtime,
      serialDeviceClaim: this.#runtimeSerialDevices.get(radioId),
    }));
    const invalidations = [...this.#invalidations.values()];
    this.#runtimes.clear();
    const closing = (async () => {
      const failures: unknown[] = [];
      await Promise.all(runtimes.map(async ({ runtime, serialDeviceClaim }) => {
        try {
          let initialized: RadioRuntime;
          try {
            initialized = await runtime;
          } catch (error) {
            if (error instanceof RadioRuntimeCleanupUncertainError) {
              this.#quarantine(serialDeviceClaim);
              failures.push(error);
            }
            return;
          }
          try {
            await initialized.close();
          } catch (error) {
            this.#quarantine(serialDeviceClaim);
            failures.push(cleanupUncertainError(
              error,
              "radio runtime cleanup could not be confirmed during shutdown",
            ));
          }
        } finally {
          const currentClaim = [...this.#runtimeSerialDevices.entries()]
            .find(([, claim]) => claim === serialDeviceClaim);
          if (currentClaim !== undefined) {
            this.#runtimeSerialDevices.delete(currentClaim[0]);
          }
        }
      }));
      const invalidationResults = await Promise.allSettled(invalidations);
      for (const result of invalidationResults) {
        if (result.status === "rejected") {
          failures.push(result.reason);
        }
      }
      if (
        this.#reservedSerialDevices.size > 0 ||
        this.#quarantinedSerialDevices.size > 0
      ) {
        failures.push(new RadioRuntimeCleanupUncertainError(
          "one or more managed serial devices remain reserved or quarantined",
        ));
      }
      if (failures.length > 0) {
        throw new RadioRuntimeCleanupUncertainError(
          "one or more radio runtimes could not be confirmed closed",
          { cause: new AggregateError(failures) },
        );
      }
    })();
    this.#closePromise = closing;
    await closing;
  }
}

function canonicalManagedSerialDevice(devicePath: string): string {
  try {
    return realpathSync.native(devicePath);
  } catch {
    return devicePath;
  }
}

function cleanupUncertainError(error: unknown, message: string): RadioRuntimeCleanupUncertainError {
  return error instanceof RadioRuntimeCleanupUncertainError
    ? error
    : new RadioRuntimeCleanupUncertainError(message, { cause: error });
}

async function createDefaultRadioRuntime(
  profile: RadioProfile,
  managedPort: number,
  safetyEvents: SafetyEventHub,
): Promise<RadioRuntime> {
  const target = rigctldTarget(profile, managedPort);
  const transport = new RigctldTransport(target.host, target.port);
  let runtime: RadioRuntime | null = null;
  const managed = target.command === undefined
    ? null
    : new ManagedRigctldProcess(target.command, {
        onUnexpectedExit: (exit) => {
          const activeRuntime = runtime;
          if (activeRuntime !== null) {
            void activeRuntime.supervisor.notifyManagedExit(exit).catch(() => undefined);
          }
        },
      });
  runtime = new RadioRuntime(
    profile,
    new HamlibRig(transport, {
      pttMethod: profile.ptt.method,
    }),
    async () => {
      const failures: unknown[] = [];
      try {
        await transport.close();
      } catch (error) {
        failures.push(error);
      }
      try {
        await managed?.close();
      } catch (error) {
        failures.push(error);
      }
      if (failures.length > 0) {
        throw new RadioRuntimeCleanupUncertainError(
          "radio runtime dependency cleanup could not be confirmed",
          { cause: new AggregateError(failures) },
        );
      }
    },
    Date.now,
    {
      safetyEvents,
      startManaged: async () => { await managed?.start(); },
      restartManaged: async () => { await managed?.start(); },
    },
  );
  try {
    await runtime.initialize();
    return runtime;
  } catch (error) {
    try {
      await runtime.close();
    } catch (cleanupError) {
      throw new RadioRuntimeCleanupUncertainError(
        "radio runtime cleanup could not be confirmed after initialization failure",
        { cause: new AggregateError([error, cleanupError]) },
      );
    }
    throw error;
  }
}
