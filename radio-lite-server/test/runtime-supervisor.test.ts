import assert from "node:assert/strict";
import { test } from "node:test";

import {
  RigRuntimeSupervisor,
  type ManagedRigctldExit,
  type TransmitStartReservation,
} from "../src/rig/runtime-supervisor.ts";
import { SafetyEventHub, type SafetyEvent } from "../src/safety/safety-event-hub.ts";
import {
  TransmitInterlock,
  type TransmitDriver,
} from "../src/safety/transmit-interlock.ts";
import type { DeKeyOutcome, DeKeyTransport } from "../src/safety/dekey.ts";

test("startup observation starts the managed link once and never writes PTT OFF", async () => {
  const fixture = supervisorFixture();

  await Promise.all([
    fixture.supervisor.startupObserve(),
    fixture.supervisor.startupObserve(),
  ]);

  assert.equal(fixture.startCalls, 1);
  assert.equal(fixture.driver.offCalls, 0);
  await fixture.close();
});

test("close waits for in-flight startup and closes any late managed child", async () => {
  const startupEntered = deferred<void>();
  const allowStartup = deferred<void>();
  const fixture = supervisorFixture({
    startManaged: async () => {
      startupEntered.resolve();
      await allowStartup.promise;
    },
  });
  const starting = fixture.supervisor.startupObserve();
  await startupEntered.promise;

  const closing = fixture.supervisor.close();
  await immediate();
  assert.equal(fixture.closeCalls, 1);
  allowStartup.resolve();

  await assert.rejects(starting, /runtime_supervisor_closed/u);
  await closing;
  assert.equal(fixture.closeCalls, 2);
  assert.equal(fixture.driver.offCalls, 0);
});

test("unexpected managed rigctld exit starts one recovery generation", async () => {
  const fixture = supervisorFixture();
  await fixture.start();
  fixture.driver.readPttValue = true;
  fixture.driver.failOff = true;
  const exit = managedExit(1);
  const beforeGeneration = fixture.supervisor.recoveryGeneration;

  await Promise.all([
    fixture.supervisor.notifyManagedExit(exit),
    fixture.supervisor.notifyManagedExit(exit),
  ]);

  assert.equal(fixture.restartGenerations.length, 1);
  assert.equal(fixture.supervisor.recoveryGeneration, beforeGeneration + 1);
  assert.equal(fixture.supervisor.snapshot().dekeyRequired, true);
  await fixture.close();
});

test("managed exit still restarts when the first emergency OFF is immediately confirmed", async () => {
  const fixture = supervisorFixture();
  await fixture.start();

  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await immediate();

  assert.equal(fixture.restartGenerations.length, 1);
  assert.equal(fixture.supervisor.snapshot().dekeyRequired, false);
  assert.equal(fixture.hub.snapshot("main").alert, null);
  await fixture.close();
});

test("managed exit during a stuck CAT activation dekeys without waiting for its promise", async () => {
  const activation = deferred<void>();
  const activationStarted = deferred<void>();
  const fixture = supervisorFixture({ activation, activationStarted });
  const permit = await fixture.supervisor.reserveTransmitStart(reservation());
  const committing = fixture.supervisor.commitTransmitStart(permit, async () => undefined);
  await activationStarted.promise;

  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await immediate();

  assert.equal(fixture.restartGenerations.length, 1);
  assert.equal(fixture.driver.offCalls > 0, true);
  assert.equal(fixture.driver.readPttValue, false);
  assert.equal(fixture.supervisor.snapshot().lease, null);

  activation.resolve();
  await assert.rejects(committing, /transmit_start_invalidated/u);
  await fixture.supervisor.runDueRecovery();
  await fixture.close();
});

test("stale recovery readback cannot clear a newer latch", async () => {
  const oldRead = deferred<boolean>();
  let transportCalls = 0;
  let replacementPtt = true;
  const fixture = supervisorFixture({
    recoveryTransport: () => ++transportCalls === 1
      ? recoveryTransport(async () => oldRead.promise)
      : recoveryTransport(async () => replacementPtt),
  });
  await fixture.start();
  fixture.driver.readPttValue = true;
  fixture.driver.failOff = true;
  const beforeFirstExit = fixture.supervisor.recoveryGeneration;
  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await immediate();
  const stale = fixture.supervisor.runDueRecovery();

  await fixture.supervisor.notifyManagedExit(managedExit(2));
  assert.equal(fixture.supervisor.recoveryGeneration, beforeFirstExit + 2);
  oldRead.resolve(false);
  await stale;

  assert.equal(fixture.supervisor.snapshot().dekeyRequired, true);
  replacementPtt = false;
  await fixture.supervisor.runDueRecovery();
  await fixture.close();
});

test("supervisor publishes active dekey and recovered revisions", async () => {
  const fixture = supervisorFixture();
  const events: SafetyEvent[] = [];
  fixture.hub.subscribeControl((value) => {
    if (value.t === "safety.event") events.push(value);
  });
  const lease = await fixture.start();
  fixture.driver.readPttValue = true;
  fixture.driver.failOff = true;
  const pending = await fixture.supervisor.stop(lease.ownerId, lease.leaseToken, "test_stop");
  assert.equal(pending.kind, "recoveryPending");
  fixture.driver.readPttValue = false;
  fixture.driver.failOff = false;
  await fixture.supervisor.runDueRecovery();

  assert.deepEqual(events.map((event) => event.kind), [
    "active",
    "dekey_required",
    "recovered",
  ]);
  assert.equal(fixture.hub.snapshot("main").alert, null);
  await fixture.close();
});

test("late heartbeat with unconfirmed OFF schedules supervisor recovery", async () => {
  let now = 1_000;
  const fixture = supervisorFixture({ now: () => now });
  const lease = await fixture.start();
  fixture.driver.readPttValue = true;
  fixture.driver.failOff = true;
  now = 10_000;

  await assert.rejects(
    fixture.supervisor.heartbeat(lease.ownerId, lease.leaseToken),
    /read-back|off-write|unconfirmed/u,
  );

  assert.equal(fixture.supervisor.snapshot().dekeyRequired, true);
  assert.equal(fixture.supervisor.hasScheduledRecovery, true);
  assert.equal(fixture.hub.snapshot("main").alert?.kind, "dekey_required");
  await fixture.close();
});

test("deadline timeout clears the active alert only after confirmed OFF", async () => {
  let now = 1_000;
  const fixture = supervisorFixture({ now: () => now });
  await fixture.start();
  now = 10_000;

  assert.equal(await fixture.supervisor.checkDeadlines(), "heartbeat_timeout");

  assert.equal(fixture.supervisor.snapshot().dekeyRequired, false);
  assert.equal(fixture.hub.snapshot("main").alert, null);
  await fixture.close();
});

test("InvalidLease after expiry leaves supervisor dekey retry latched", async () => {
  const fixture = supervisorFixture();
  const lease = await fixture.start();
  fixture.driver.readPttValue = true;
  fixture.driver.failOff = true;
  await fixture.interlock.ownerDisconnected(lease.ownerId).catch(() => undefined);

  const outcome = await fixture.supervisor.stop(lease.ownerId, lease.leaseToken, "expired");

  assert.equal(outcome.kind, "recoveryPending");
  assert.equal(fixture.supervisor.snapshot().dekeyRequired, true);
  assert.equal(fixture.supervisor.hasScheduledRecovery, true);
  await fixture.close();
});

test("dekey recovery escalates after thirty seconds and continues retries", async () => {
  let now = 1_000;
  const fixture = supervisorFixture({ now: () => now });
  const events: SafetyEvent[] = [];
  fixture.hub.subscribeControl((value) => {
    if (value.t === "safety.event") events.push(value);
  });
  const lease = await fixture.start();
  fixture.driver.readPttValue = true;
  fixture.driver.failOff = true;
  await fixture.supervisor.stop(lease.ownerId, lease.leaseToken, "stuck");
  const attemptsBefore = fixture.recoveryAttempts;
  now = 31_000;
  await fixture.supervisor.runDueRecovery();
  await fixture.supervisor.runDueRecovery();

  assert.equal(events.filter((event) => event.kind === "dekey_escalated").length, 1);
  assert.equal(fixture.recoveryAttempts >= attemptsBefore + 2, true);
  assert.equal(fixture.supervisor.hasScheduledRecovery, true);
  await fixture.close();
});

test("invalidated transmit permit cannot commit", async () => {
  const fixture = supervisorFixture();
  const permit = await fixture.supervisor.reserveTransmitStart(reservation());
  fixture.supervisor.invalidateTransmitStarts("owner_disconnected");

  await assert.rejects(
    fixture.supervisor.commitTransmitStart(permit, async () => undefined),
    /transmit_start_invalidated/u,
  );
  assert.equal(fixture.driver.activateCalls, 0);
  await fixture.close();
});

test("every stop request synchronously invalidates a pending transmit permit", async () => {
  const fixture = supervisorFixture();
  const permit = await fixture.supervisor.reserveTransmitStart(reservation());

  const outcome = await fixture.supervisor.stop("stale-owner", "stale-token", "operator_stop");

  assert.equal(outcome.kind, "notResponsible");
  await assert.rejects(
    fixture.supervisor.commitTransmitStart(permit, async () => undefined),
    /transmit_start_invalidated/u,
  );
  assert.equal(fixture.driver.activateCalls, 0);
  await fixture.close();
});

test("owner disconnect during activation cannot return a lease and runs OFF", async () => {
  const activation = deferred<void>();
  const activationStarted = deferred<void>();
  const fixture = supervisorFixture({ activation, activationStarted });
  const permit = await fixture.supervisor.reserveTransmitStart(reservation());
  const committing = fixture.supervisor.commitTransmitStart(permit, async () => undefined);
  await activationStarted.promise;

  const disconnecting = fixture.supervisor.ownerDisconnected("owner-a", "connection_closed");
  activation.resolve();

  await assert.rejects(committing, /transmit_start_invalidated/u);
  assert.equal((await disconnecting).kind, "offConfirmed");
  assert.equal(fixture.driver.offCalls > 0, true);
  await fixture.close();
});

test("owner disconnect never attributes newer OFF proof to an older generation", async () => {
  const activation = deferred<void>();
  const activationStarted = deferred<void>();
  const oldRead = deferred<boolean>();
  const oldReadStarted = deferred<void>();
  let transportCalls = 0;
  const fixture = supervisorFixture({
    activation,
    activationStarted,
    recoveryTransport: () => {
      transportCalls += 1;
      return transportCalls === 1
        ? recoveryTransport(async () => {
            oldReadStarted.resolve();
            return oldRead.promise;
          })
        : recoveryTransport(async () => false);
    },
  });
  const permit = await fixture.supervisor.reserveTransmitStart(reservation());
  const committing = fixture.supervisor.commitTransmitStart(permit, async () => undefined);
  await activationStarted.promise;
  const firstGeneration = fixture.supervisor.recoveryGeneration;

  const disconnecting = fixture.supervisor.ownerDisconnected("owner-a", "connection_closed");
  await oldReadStarted.promise;
  await fixture.supervisor.notifyManagedExit(managedExit(1));
  assert.equal(fixture.supervisor.recoveryGeneration, firstGeneration + 1);

  activation.resolve();
  await assert.rejects(committing, /transmit_start_invalidated/u);
  assert.equal(fixture.supervisor.snapshot().dekeyRequired, false);
  oldRead.resolve(false);
  const outcome = await disconnecting;

  assert.deepEqual(outcome, {
    kind: "notResponsible",
    generation: fixture.supervisor.recoveryGeneration,
  });
  await fixture.close();
});

test("owner disconnect never stops another owner's transmission", async () => {
  const fixture = supervisorFixture();
  const lease = await fixture.start();

  const outcome = await fixture.supervisor.ownerDisconnected("owner-b", "connection_closed");

  assert.equal(outcome.kind, "notResponsible");
  assert.equal(fixture.supervisor.snapshot().lease?.leaseToken, lease.leaseToken);
  assert.equal(fixture.driver.offCalls, 0);
  await fixture.close();
});

test("pre-activation invalidation is not reported as confirmed PTT OFF", async () => {
  const validation = deferred<void>();
  const validationStarted = deferred<void>();
  const fixture = supervisorFixture();
  const permit = await fixture.supervisor.reserveTransmitStart(reservation());
  const committing = fixture.supervisor.commitTransmitStart(permit, async () => {
    validationStarted.resolve();
    await validation.promise;
  });
  await validationStarted.promise;

  fixture.supervisor.invalidateTransmitStarts("emergency_stop");
  const emergency = fixture.supervisor.emergencyStop("emergency_stop");
  validation.resolve();

  await assert.rejects(committing, /transmit_start_invalidated/u);
  assert.equal((await emergency).kind, "notResponsible");
  assert.equal(fixture.driver.activateCalls, 0);
  assert.equal(fixture.driver.offCalls, 0);
  await fixture.close();
});

test("synchronous active-event emergency stop fences CAT activation", async () => {
  const fixture = supervisorFixture();
  const emergency = deferred<DeKeyOutcome>();
  let emergencyStarted = false;
  const unsubscribe = fixture.hub.subscribeControl((message) => {
    if (
      message.t === "safety.event" &&
      message.kind === "active" &&
      !emergencyStarted
    ) {
      emergencyStarted = true;
      void fixture.supervisor.emergencyStop("active_event_emergency").then(
        emergency.resolve,
        emergency.reject,
      );
    }
  });
  const permit = await fixture.supervisor.reserveTransmitStart(reservation());

  await assert.rejects(
    fixture.supervisor.commitTransmitStart(permit, async () => undefined),
    /transmit_start_invalidated/u,
  );
  const outcome = await emergency.promise;

  assert.equal(outcome.kind, "offConfirmed");
  assert.equal(fixture.driver.activateCalls, 0);
  assert.equal(fixture.driver.offCalls > 0, true);
  assert.equal(fixture.supervisor.snapshot().dekeyRequired, false);
  assert.equal(fixture.hub.snapshot("main").alert, null);
  unsubscribe();
  await fixture.close();
});

test("invalidation during CAT activation never returns a lease and runs OFF recovery", async () => {
  const activation = deferred<void>();
  const activationStarted = deferred<void>();
  const fixture = supervisorFixture({ activation, activationStarted });
  const permit = await fixture.supervisor.reserveTransmitStart(reservation());
  const committing = fixture.supervisor.commitTransmitStart(permit, async () => undefined);
  await activationStarted.promise;

  fixture.supervisor.invalidateTransmitStarts("emergency_stop");
  const emergency = fixture.supervisor.emergencyStop("emergency_stop");
  activation.resolve();

  await assert.rejects(committing, /transmit_start_invalidated/u);
  assert.equal((await emergency).kind, "offConfirmed");
  assert.equal(fixture.driver.offCalls > 0, true);
  assert.equal(fixture.supervisor.snapshot().lease, null);
  await fixture.close();
});

test("managed close exit never restarts rigctld", async () => {
  const fixture = supervisorFixture();
  await fixture.supervisor.close();

  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await fixture.supervisor.notifyManagedExit(managedExit(2));

  assert.equal(fixture.restartGenerations.length, 0);
  assert.equal(fixture.closeCalls, 1);
});

test("close waits for an in-flight managed restart and closes again afterward", async () => {
  const restartStarted = deferred<void>();
  const allowRestart = deferred<void>();
  const fixture = supervisorFixture({
    restartManaged: async () => {
      restartStarted.resolve();
      await allowRestart.promise;
    },
  });
  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await restartStarted.promise;

  const closing = fixture.supervisor.close();
  let closeSettled = false;
  void closing.finally(() => { closeSettled = true; });
  await immediate();
  assert.equal(closeSettled, false);
  assert.equal(fixture.closeCalls, 1);

  allowRestart.resolve();
  await closing;
  assert.equal(fixture.closeCalls, 2);
});

test("close retains a restart that settles while the first managed close is pending", async () => {
  const restartStarted = deferred<void>();
  const allowRestart = deferred<void>();
  const firstCloseStarted = deferred<void>();
  const allowFirstClose = deferred<void>();
  let closeInvocation = 0;
  const fixture = supervisorFixture({
    restartManaged: async () => {
      restartStarted.resolve();
      await allowRestart.promise;
    },
    closeManaged: async () => {
      closeInvocation += 1;
      if (closeInvocation === 1) {
        firstCloseStarted.resolve();
        await allowFirstClose.promise;
      }
    },
  });
  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await restartStarted.promise;

  const closing = fixture.supervisor.close();
  await firstCloseStarted.promise;
  allowRestart.resolve();
  await immediate();
  allowFirstClose.resolve();

  await closing;
  assert.equal(fixture.closeCalls, 2);
});

test("close clears the active transmit safety episode after confirmed OFF", async () => {
  const fixture = supervisorFixture();
  await fixture.start();
  assert.equal(fixture.hub.snapshot("main").alert?.kind, "active");

  await fixture.supervisor.close();

  assert.equal(fixture.driver.offCalls > 0, true);
  assert.equal(fixture.hub.snapshot("main").alert, null);
});

test("idle managed exit retries failed restarts until the link is available", async () => {
  const fixture = supervisorFixture({ restartFailures: 2 });

  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await immediate();
  assert.equal(fixture.supervisor.hasScheduledRecovery, true);
  await fixture.supervisor.runDueRecovery();
  await fixture.supervisor.runDueRecovery();

  assert.equal(fixture.restartGenerations.length, 3);
  assert.equal(fixture.supervisor.hasScheduledRecovery, false);
  await fixture.close();
});

test("managed link unavailability rejects transmit reservation before CAT activation", async () => {
  const restart = deferred<void>();
  const fixture = supervisorFixture({
    restartManaged: async () => restart.promise,
  });
  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await immediate();

  await assert.rejects(
    fixture.supervisor.reserveTransmitStart(reservation()),
    /link.*unavailable/u,
  );
  assert.equal(fixture.driver.activateCalls, 0);

  restart.resolve();
  await immediate();
  await fixture.close();
});

test("stale restart failure cannot mark a newer recovered link unavailable", async () => {
  const firstRestart = deferred<void>();
  const restartCalls: number[] = [];
  const fixture = supervisorFixture({
    restartManaged: async (generation) => {
      restartCalls.push(generation);
      if (restartCalls.length === 1) await firstRestart.promise;
    },
  });

  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await immediate();
  await fixture.supervisor.notifyManagedExit(managedExit(2));
  await immediate();
  assert.equal(restartCalls.length, 2);

  firstRestart.reject(new Error("stale restart failed"));
  await immediate();
  await fixture.supervisor.runDueRecovery();

  assert.equal(restartCalls.length, 2, "stale failure must not schedule a new current-generation retry");
  await fixture.close();
});

test("an old recovery timer cannot suppress the newer generation retry", async () => {
  const callbacks: Array<() => void> = [];
  const cancelled = new Set<object>();
  const fixture = supervisorFixture({
    restartFailures: 1,
    schedule: (callback) => {
      callbacks.push(callback);
      return { callback } as unknown as ReturnType<typeof setTimeout>;
    },
    cancelScheduled: (handle) => { cancelled.add(handle as unknown as object); },
  });
  const lease = await fixture.start();
  fixture.driver.readPttValue = true;
  fixture.driver.failOff = true;
  await fixture.supervisor.stop(lease.ownerId, lease.leaseToken, "stuck");
  const oldCallback = callbacks[0]!;

  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await immediate();
  assert.equal(fixture.supervisor.hasScheduledRecovery, true);
  oldCallback();
  await immediate();

  assert.equal(fixture.supervisor.hasScheduledRecovery, true);
  assert.equal(cancelled.size > 0, true);
  fixture.driver.readPttValue = false;
  fixture.driver.failOff = false;
  await fixture.supervisor.runDueRecovery();
  await fixture.close();
});

test("transmit after idle link recovery keeps Hub and OFF evidence generations aligned", async () => {
  const fixture = supervisorFixture();
  await fixture.supervisor.notifyManagedExit(managedExit(1));
  await immediate();
  const lease = await fixture.start();

  const outcome = await fixture.supervisor.stop(lease.ownerId, lease.leaseToken, "normal_stop");

  assert.equal(outcome.kind, "offConfirmed");
  assert.equal(fixture.hub.snapshot("main").alert, null);
  await fixture.close();
});

test("conflicting second start cannot replace an active safety generation", async () => {
  const fixture = supervisorFixture();
  await fixture.start();
  const before = fixture.hub.ownerVersion("main", "transmit");

  await assert.rejects(
    fixture.supervisor.reserveTransmitStart(reservation({ ownerId: "owner-b" })),
    /transmit_start_busy/u,
  );

  assert.deepEqual(fixture.hub.ownerVersion("main", "transmit"), before);
  assert.equal(fixture.driver.activateCalls, 1);
  await fixture.close();
});

function reservation(
  overrides: Partial<TransmitStartReservation> = {},
): TransmitStartReservation {
  return {
    radioId: "main",
    ownerId: "owner-a",
    userId: "user-a",
    mode: "voice",
    controlLeaseRevision: 1,
    profileRevision: 1,
    ...overrides,
  };
}

function managedExit(generation: number): ManagedRigctldExit {
  return { generation, exitCode: 1, signalCode: null, stderr: "rigctld exited" };
}

function supervisorFixture(options: {
  now?: () => number;
  recoveryTransport?: (generation: number) => DeKeyTransport;
  activation?: ReturnType<typeof deferred<void>>;
  activationStarted?: ReturnType<typeof deferred<void>>;
  startManaged?: () => Promise<void>;
  restartFailures?: number;
  restartManaged?: (generation: number, exit: ManagedRigctldExit) => Promise<void>;
  closeManaged?: () => Promise<void>;
  schedule?: (callback: () => void, delayMs: number) => ReturnType<typeof setTimeout>;
  cancelScheduled?: (handle: ReturnType<typeof setTimeout>) => void;
} = {}) {
  const driver = new FakeDriver(options.activation, options.activationStarted);
  const interlock = new TransmitInterlock(driver, {
    now: options.now,
    tokenFactory: () => "lease-token",
  });
  const hub = new SafetyEventHub({
    safetyEpoch: "runtime-test",
    configuredRadioIds: () => ["main"],
  });
  const restartGenerations: number[] = [];
  let recoveryAttempts = 0;
  let closeCalls = 0;
  let startCalls = 0;
  let restartFailures = options.restartFailures ?? 0;
  const supervisor = new RigRuntimeSupervisor({
    radioId: "main",
    interlock,
    safetyEvents: hub,
    now: options.now,
    recoveryTransport: (generation) => {
      recoveryAttempts += 1;
      return options.recoveryTransport?.(generation) ?? driver;
    },
    startManaged: async () => {
      startCalls += 1;
      await options.startManaged?.();
    },
    restartManaged: options.restartManaged ?? (async (generation) => {
      restartGenerations.push(generation);
      if (restartFailures > 0) {
        restartFailures -= 1;
        throw new Error("managed restart failed");
      }
    }),
    closeManaged: async () => {
      closeCalls += 1;
      await options.closeManaged?.();
    },
    schedule: options.schedule ?? (() => ({}) as ReturnType<typeof setTimeout>),
    cancelScheduled: options.cancelScheduled ?? (() => undefined),
  });
  const start = async () => {
    const permit = await supervisor.reserveTransmitStart(reservation());
    return supervisor.commitTransmitStart(permit, async () => undefined);
  };
  const close = async () => {
    driver.readPttValue = false;
    driver.failOff = false;
    await supervisor.close();
  };
  return {
    driver,
    interlock,
    hub,
    supervisor,
    restartGenerations,
    get recoveryAttempts() { return recoveryAttempts; },
    get closeCalls() { return closeCalls; },
    get startCalls() { return startCalls; },
    start,
    close,
  };
}

class FakeDriver implements TransmitDriver {
  readonly activation: ReturnType<typeof deferred<void>> | undefined;
  readonly activationStarted: ReturnType<typeof deferred<void>> | undefined;
  readPttValue = false;
  failOff = false;
  activateCalls = 0;
  offCalls = 0;

  constructor(
    activation?: ReturnType<typeof deferred<void>>,
    activationStarted?: ReturnType<typeof deferred<void>>,
  ) {
    this.activation = activation;
    this.activationStarted = activationStarted;
  }

  async activate(): Promise<void> {
    this.activateCalls += 1;
    this.readPttValue = true;
    this.activationStarted?.resolve();
    await this.activation?.promise;
  }
  async deactivate(): Promise<void> {}
  async emergencyOff(): Promise<void> {
    this.offCalls += 1;
    if (this.failOff) throw new Error("rigctld unavailable");
    this.readPttValue = false;
  }
  async readPtt(): Promise<boolean> { return this.readPttValue; }
}

function recoveryTransport(readPtt: () => Promise<boolean>): DeKeyTransport {
  return {
    deactivate: async () => undefined,
    emergencyOff: async () => undefined,
    readPtt,
  };
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

async function immediate(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
}
