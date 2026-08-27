import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DeKeyUnconfirmedError,
  InterlockConflictError,
  InvalidLeaseError,
  TransmitInterlock,
  type TransmitDriver,
  type TransmitMode,
} from "../src/safety/transmit-interlock.ts";

class RecordingDriver implements TransmitDriver {
  readonly events: string[] = [];
  failActivate: Error | null = null;
  failDeactivate = false;
  failEmergencyOff = false;
  readPttError: Error | null = null;
  readPttValue = false;
  readPttHandler: (() => Promise<boolean>) | null = null;
  activateHandler: (() => Promise<void>) | null = null;

  async activate(mode: TransmitMode): Promise<void> {
    this.events.push(`on:${mode}`);
    if (this.failActivate !== null) {
      throw this.failActivate;
    }
    await this.activateHandler?.();
  }

  async deactivate(mode: TransmitMode): Promise<void> {
    this.events.push(`off:${mode}`);
    if (this.failDeactivate) {
      throw new Error("CAT unavailable");
    }
  }

  async emergencyOff(): Promise<void> {
    this.events.push("emergency-off");
    if (this.failEmergencyOff) {
      throw new Error("PTT OFF write failed");
    }
  }

  async readPtt(): Promise<boolean> {
    this.events.push("read-ptt");
    if (this.readPttHandler !== null) {
      return this.readPttHandler();
    }
    if (this.readPttError !== null) {
      throw this.readPttError;
    }
    return this.readPttValue;
  }
}

test("voice, digital and tuner transmission are mutually exclusive", async () => {
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, { tokenFactory: () => "lease-a" });
  const lease = await interlock.start("user-a", "voice");

  await assert.rejects(
    interlock.start("user-b", "digital"),
    InterlockConflictError,
  );
  await assert.rejects(interlock.stop("user-b", lease.leaseToken), InvalidLeaseError);
  await interlock.stop("user-a", lease.leaseToken);
  assert.equal(interlock.snapshot().state, "idle");
  assert.deepEqual(driver.events, [
    "on:voice",
    "off:voice",
    "emergency-off",
    "read-ptt",
  ]);
});

test("heartbeat extends only to the hard limit and timeout forces PTT off", async () => {
  let now = 1_000;
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, {
    now: () => now,
    tokenFactory: () => "lease-b",
    heartbeatTimeoutMs: 8_000,
    hardLimitsMs: { voice: 20_000 },
  });
  const lease = await interlock.start("user-a", "voice");
  now = 7_000;
  const renewed = await interlock.heartbeat("user-a", lease.leaseToken);
  assert.equal(renewed.heartbeatDeadlineMs, 15_000);
  now = 15_000;
  assert.equal(await interlock.checkDeadlines(), "heartbeat_timeout");
  assert.equal(interlock.snapshot().state, "idle");
  assert.deepEqual(driver.events, ["on:voice", "off:voice", "emergency-off", "read-ptt"]);
});

test("disconnect revokes only the matching owner's active transmission", async () => {
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, { tokenFactory: () => "lease-c" });
  await interlock.start("device-a", "tuning");

  assert.equal(await interlock.ownerDisconnected("device-b"), false);
  assert.equal(interlock.snapshot().state, "tuning");
  assert.equal(await interlock.ownerDisconnected("device-a"), true);
  assert.equal(interlock.snapshot().state, "idle");
});

test("a failed normal de-key attempts emergency off and latches fault", async () => {
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, { tokenFactory: () => "lease-d" });
  const lease = await interlock.start("device-a", "digital");
  driver.failDeactivate = true;

  await assert.rejects(interlock.stop("device-a", lease.leaseToken), /CAT unavailable/u);
  assert.equal(interlock.snapshot().state, "fault");
  assert.match(interlock.snapshot().faultReason ?? "", /PTT OFF failed/u);
  assert.deepEqual(driver.events, ["on:digital", "off:digital", "emergency-off", "read-ptt"]);
});

test("hard deadline wins even when heartbeats keep arriving", async () => {
  let now = 0;
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, {
    now: () => now,
    tokenFactory: () => "lease-e",
    heartbeatTimeoutMs: 8_000,
    hardLimitsMs: { tuning: 10_000 },
  });
  const lease = await interlock.start("device-a", "tuning");
  now = 6_000;
  const renewed = await interlock.heartbeat("device-a", lease.leaseToken);
  assert.equal(renewed.heartbeatDeadlineMs, 10_000);
  now = 10_000;
  assert.equal(await interlock.checkDeadlines(), "hard_limit");
  assert.equal(interlock.snapshot().state, "idle");
});

test("PTT OFF write without OFF readback retains the dekey latch", async () => {
  const driver = new RecordingDriver();
  driver.readPttValue = true;
  const interlock = new TransmitInterlock(driver, {
    now: () => 1_000,
    tokenFactory: () => "lease-readback",
  });
  const lease = await interlock.start("device-a", "voice");

  await assert.rejects(
    interlock.stop("device-a", lease.leaseToken),
    /read-back|unconfirmed/u,
  );
  assert.deepEqual(interlock.snapshot(), {
    state: "fault",
    lease: null,
    faultReason: "released by owner; PTT OFF unconfirmed",
    dekeyRequired: true,
    dekeyStartedAtMs: 1_000,
  });
  assert.deepEqual(driver.events, [
    "on:voice",
    "off:voice",
    "emergency-off",
    "read-ptt",
  ]);
});

test("automatic stop outcomes carry physical OFF evidence from the exact recovery generation", async () => {
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, {
    tokenFactory: () => "lease-outcome-confirmed",
  });
  interlock.advanceRecoveryGeneration(4);
  const lease = await interlock.start("device-a", "voice");

  assert.deepEqual(
    await interlock.stopOutcome("device-a", lease.leaseToken),
    { kind: "offConfirmed", generation: 4 },
  );
  assert.equal(interlock.snapshot().dekeyRequired, false);
});

test("automatic stop reports pending recovery and stale tokens cannot clear its latch", async () => {
  const driver = new RecordingDriver();
  driver.readPttValue = true;
  const interlock = new TransmitInterlock(driver, {
    tokenFactory: () => "lease-outcome-pending",
  });
  interlock.advanceRecoveryGeneration(5);
  const lease = await interlock.start("device-a", "digital");

  assert.deepEqual(
    await interlock.stopOutcome("device-a", lease.leaseToken),
    { kind: "recoveryPending", generation: 5 },
  );
  assert.deepEqual(
    await interlock.stopOutcome("device-a", lease.leaseToken),
    { kind: "recoveryPending", generation: 5 },
  );
  assert.equal(interlock.snapshot().dekeyRequired, true);

  const recovery = new RecordingDriver();
  interlock.advanceRecoveryGeneration(6);
  assert.deepEqual(await interlock.attemptDeKey(recovery, 6), {
    confirmed: true,
    generation: 6,
  });
  assert.deepEqual(
    await interlock.stopOutcome("device-a", lease.leaseToken),
    { kind: "notResponsible", generation: 6 },
  );
});

test("only same-generation OFF readback atomically recovers a latched interlock", async () => {
  const driver = new RecordingDriver();
  driver.readPttValue = true;
  const interlock = new TransmitInterlock(driver, {
    now: () => 2_000,
    tokenFactory: () => "lease-generation",
  });
  const lease = await interlock.start("device-a", "tuning");
  await assert.rejects(interlock.stop("device-a", lease.leaseToken), /read-back|unconfirmed/u);

  const oldRead = deferred<boolean>();
  const oldReadStarted = deferred<void>();
  const oldTransport = new RecordingDriver();
  oldTransport.readPttHandler = async () => {
    oldReadStarted.resolve();
    return oldRead.promise;
  };
  interlock.advanceRecoveryGeneration(7);
  const oldAttempt = interlock.attemptDeKey(oldTransport, 7);
  await oldReadStarted.promise;

  const currentRead = deferred<boolean>();
  const currentReadStarted = deferred<void>();
  const currentTransport = new RecordingDriver();
  currentTransport.readPttHandler = async () => {
    currentReadStarted.resolve();
    return currentRead.promise;
  };
  interlock.advanceRecoveryGeneration(8);
  const currentAttempt = interlock.attemptDeKey(currentTransport, 8);
  oldRead.resolve(false);

  const oldResult = await oldAttempt;
  assert.equal(oldResult.confirmed, false);
  assert.equal(oldResult.generation, 7);
  if (oldResult.confirmed) assert.fail("stale recovery unexpectedly confirmed OFF");
  assert.match(oldResult.reason, /\S/u);
  assert.equal(interlock.snapshot().dekeyRequired, true);
  assert.equal(interlock.snapshot().dekeyStartedAtMs, 2_000);
  assert.deepEqual(oldTransport.events, ["off:tuning", "emergency-off", "read-ptt"]);

  await currentReadStarted.promise;
  currentRead.resolve(false);
  assert.deepEqual(await currentAttempt, {
    confirmed: true,
    generation: 8,
  });
  assert.deepEqual(currentTransport.events, ["off:tuning", "emergency-off", "read-ptt"]);
  assert.deepEqual(interlock.snapshot(), {
    state: "idle",
    lease: null,
    faultReason: null,
    dekeyRequired: false,
    dekeyStartedAtMs: null,
  });

  const noLatchTransport = new RecordingDriver();
  const noLatch = await interlock.attemptDeKey(noLatchTransport, 8);
  assert.equal(noLatch.confirmed, false);
  if (noLatch.confirmed) assert.fail("missing latch unexpectedly confirmed OFF");
  assert.match(noLatch.reason, /\S/u);
  assert.notEqual(noLatch.reason, oldResult.reason);
  assert.deepEqual(noLatchTransport.events, []);
});

test("startup observation never writes PTT OFF", async () => {
  const driver = new RecordingDriver();
  driver.readPttValue = true;
  const interlock = new TransmitInterlock(driver);

  await interlock.startupObserve();

  assert.deepEqual(driver.events, ["read-ptt"]);
  assert.deepEqual(interlock.snapshot(), {
    state: "idle",
    lease: null,
    faultReason: null,
    dekeyRequired: false,
    dekeyStartedAtMs: null,
  });
});

test("deactivate failure still attempts emergency OFF and readback", async () => {
  const driver = new RecordingDriver();
  driver.failDeactivate = true;
  driver.readPttValue = false;
  const interlock = new TransmitInterlock(driver, {
    now: () => 3_000,
    tokenFactory: () => "lease-deactivate-failure",
  });
  const lease = await interlock.start("device-a", "digital");

  await assert.rejects(interlock.stop("device-a", lease.leaseToken), /CAT unavailable/u);
  assert.deepEqual(driver.events, [
    "on:digital",
    "off:digital",
    "emergency-off",
    "read-ptt",
  ]);
  assert.equal(interlock.snapshot().state, "fault");
  assert.equal(interlock.snapshot().dekeyRequired, true);
  assert.equal(interlock.snapshot().dekeyStartedAtMs, 3_000);
});

test("PTT ON and read errors retain the first dekey timestamp", async () => {
  let now = 4_000;
  const driver = new RecordingDriver();
  driver.readPttValue = true;
  const interlock = new TransmitInterlock(driver, {
    now: () => now,
    tokenFactory: () => "lease-first-timestamp",
  });
  const lease = await interlock.start("device-a", "voice");
  await assert.rejects(interlock.stop("device-a", lease.leaseToken), /read-back|unconfirmed/u);

  now = 8_000;
  const pttOn = new RecordingDriver();
  pttOn.readPttValue = true;
  interlock.advanceRecoveryGeneration(4);
  assert.equal((await interlock.attemptDeKey(pttOn, 4)).confirmed, false);
  assert.equal(interlock.snapshot().dekeyStartedAtMs, 4_000);

  now = 12_000;
  const readFailure = new RecordingDriver();
  readFailure.readPttError = new Error("PTT read failed");
  assert.equal((await interlock.attemptDeKey(readFailure, 4)).confirmed, false);
  assert.equal(interlock.snapshot().dekeyStartedAtMs, 4_000);
});

test("clearFault cannot release a dekey latch", async () => {
  const driver = new RecordingDriver();
  driver.readPttValue = true;
  const interlock = new TransmitInterlock(driver, {
    now: () => 5_000,
    tokenFactory: () => "lease-clear-fault",
  });
  const lease = await interlock.start("device-a", "voice");
  await assert.rejects(interlock.stop("device-a", lease.leaseToken), /read-back|unconfirmed/u);

  await interlock.clearFault();

  assert.equal(interlock.snapshot().state, "fault");
  assert.equal(interlock.snapshot().dekeyRequired, true);
  assert.equal(interlock.snapshot().dekeyStartedAtMs, 5_000);
  await assert.rejects(interlock.start("device-b", "digital"), InterlockConflictError);
});

test("attemptDeKey without a latch performs no hardware writes", async () => {
  const transport = new RecordingDriver();
  const interlock = new TransmitInterlock(new RecordingDriver());
  interlock.advanceRecoveryGeneration(1);

  const result = await interlock.attemptDeKey(transport, 1);

  assert.equal(result.confirmed, false);
  assert.equal(result.generation, 1);
  if (result.confirmed) assert.fail("missing latch unexpectedly confirmed OFF");
  assert.match(result.reason, /\S/u);
  assert.deepEqual(transport.events, []);
});

test("OFF readback from an earlier latch episode cannot clear a later latch", async () => {
  let now = 6_000;
  const driver = new RecordingDriver();
  driver.readPttValue = true;
  const interlock = new TransmitInterlock(driver, {
    now: () => now,
    tokenFactory: () => "lease-episode",
  });
  const firstLease = await interlock.start("device-a", "voice");
  await assert.rejects(
    interlock.stop("device-a", firstLease.leaseToken),
    /read-back|unconfirmed/u,
  );

  const staleRead = deferred<boolean>();
  const staleReadStarted = deferred<void>();
  const staleTransport = new RecordingDriver();
  staleTransport.readPttHandler = async () => {
    staleReadStarted.resolve();
    return staleRead.promise;
  };
  interlock.advanceRecoveryGeneration(10);
  const staleAttempt = interlock.attemptDeKey(staleTransport, 10);
  await staleReadStarted.promise;

  const currentTransport = new RecordingDriver();
  interlock.advanceRecoveryGeneration(11);
  assert.deepEqual(await interlock.attemptDeKey(currentTransport, 11), {
    confirmed: true,
    generation: 11,
  });

  now = 9_000;
  const secondLease = await interlock.start("device-b", "digital");
  await assert.rejects(
    interlock.stop("device-b", secondLease.leaseToken),
    /read-back|unconfirmed/u,
  );
  assert.equal(interlock.snapshot().dekeyStartedAtMs, 9_000);

  staleRead.resolve(false);
  const staleResult = await staleAttempt;
  assert.equal(staleResult.confirmed, false);
  if (staleResult.confirmed) assert.fail("old latch episode unexpectedly confirmed OFF");
  assert.match(staleResult.reason, /episode|superseded/u);
  assert.equal(interlock.snapshot().state, "fault");
  assert.equal(interlock.snapshot().dekeyRequired, true);
  assert.equal(interlock.snapshot().dekeyStartedAtMs, 9_000);

  const finalTransport = new RecordingDriver();
  interlock.advanceRecoveryGeneration(12);
  assert.deepEqual(await interlock.attemptDeKey(finalTransport, 12), {
    confirmed: true,
    generation: 12,
  });
});

test("token generation failure cannot key the transmitter", async () => {
  const driver = new RecordingDriver();
  const interlock = new TransmitInterlock(driver, {
    tokenFactory: () => {
      throw new Error("secure token source unavailable");
    },
  });

  await assert.rejects(
    interlock.start("device-a", "voice"),
    /secure token source unavailable/u,
  );
  assert.deepEqual(driver.events, []);
  assert.deepEqual(interlock.snapshot(), {
    state: "idle",
    lease: null,
    faultReason: null,
    dekeyRequired: false,
    dekeyStartedAtMs: null,
  });
});

test("replacement recovery can dekey while an old normal readback is stuck", async () => {
  const oldRead = deferred<boolean>();
  const oldReadStarted = deferred<void>();
  const driver = new RecordingDriver();
  driver.readPttHandler = async () => {
    oldReadStarted.resolve();
    return oldRead.promise;
  };
  const interlock = new TransmitInterlock(driver, {
    tokenFactory: () => "lease-stuck-read",
  });
  const lease = await interlock.start("device-a", "voice");
  const stopping = interlock.stop("device-a", lease.leaseToken);
  await oldReadStarted.promise;

  const replacement = new RecordingDriver();
  interlock.advanceRecoveryGeneration(20);
  const recovered = await withDeadline(
    interlock.attemptDeKey(replacement, 20),
    250,
  );

  assert.deepEqual(recovered, { confirmed: true, generation: 20 });
  assert.deepEqual(replacement.events, ["off:voice", "emergency-off", "read-ptt"]);
  oldRead.resolve(false);
  await assert.rejects(stopping, /episode|superseded/u);
});

test("replacement OFF cannot clear the latch before a cancelled activation settles", async () => {
  const activationEntered = deferred<void>();
  const beforeOn = deferred<void>();
  const onWritten = deferred<void>();
  const afterOn = deferred<void>();
  let ptt = false;
  const events: string[] = [];
  const driver: TransmitDriver = {
    async activate(mode) {
      activationEntered.resolve();
      await beforeOn.promise;
      events.push(`on:${mode}`);
      ptt = true;
      onWritten.resolve();
      await afterOn.promise;
    },
    async deactivate(mode) {
      events.push(`off:${mode}`);
      ptt = false;
    },
    async emergencyOff() {
      events.push("emergency-off");
      ptt = false;
    },
    async readPtt() {
      events.push("read-ptt");
      return ptt;
    },
  };
  const interlock = new TransmitInterlock(driver, {
    tokenFactory: () => "lease-stuck-activation",
  });
  const starting = interlock.start("device-a", "voice");
  await activationEntered.promise;

  interlock.requireDeKey("managed link exited", "voice");
  interlock.advanceRecoveryGeneration(40);
  const replacement = new RecordingDriver();
  assert.deepEqual(await interlock.attemptDeKey(replacement, 40), {
    confirmed: false,
    generation: 40,
    reason: "transmit activation cancellation is still pending",
  });
  assert.equal(interlock.snapshot().dekeyRequired, true);

  // The cancelled CAT activation can still write ON after replacement OFF.
  // Its fence must keep the latch set until activation settles and the
  // original path performs another OFF plus real read-back.
  beforeOn.resolve();
  await onWritten.promise;
  assert.equal(ptt, true);
  assert.equal(interlock.snapshot().dekeyRequired, true);

  afterOn.resolve();
  await assert.rejects(starting, /cancelled|invalidated|superseded/u);
  assert.equal(ptt, false);
  assert.equal(interlock.snapshot().dekeyRequired, false);
  assert.deepEqual(events, [
    "on:voice",
    "off:voice",
    "emergency-off",
    "read-ptt",
  ]);
});

test("same-generation recovery attempts are single-flight", async () => {
  const driver = new RecordingDriver();
  driver.readPttValue = true;
  const interlock = new TransmitInterlock(driver, {
    tokenFactory: () => "lease-single-flight",
  });
  const lease = await interlock.start("device-a", "digital");
  await assert.rejects(interlock.stop("device-a", lease.leaseToken));

  const read = deferred<boolean>();
  const readStarted = deferred<void>();
  const transport = new RecordingDriver();
  transport.readPttHandler = async () => {
    readStarted.resolve();
    return read.promise;
  };
  interlock.advanceRecoveryGeneration(30);
  const first = interlock.attemptDeKey(transport, 30);
  const second = interlock.attemptDeKey(transport, 30);
  assert.equal(second, first);
  await readStarted.promise;
  assert.deepEqual(transport.events, ["off:digital", "emergency-off", "read-ptt"]);

  read.resolve(false);
  assert.deepEqual(await first, { confirmed: true, generation: 30 });
  assert.deepEqual(await second, { confirmed: true, generation: 30 });
});

test("activation failure reports unconfirmed dekey as the primary error", async () => {
  const activationError = new Error("activation read-back failed");
  const driver = new RecordingDriver();
  driver.failActivate = activationError;
  driver.failEmergencyOff = true;
  driver.readPttValue = true;
  const interlock = new TransmitInterlock(driver, {
    now: () => 10_000,
    tokenFactory: () => "lease-activation-failure",
  });

  await assert.rejects(
    interlock.start("device-a", "voice"),
    (error: unknown) =>
      error instanceof DeKeyUnconfirmedError && error.cause === activationError,
  );
  assert.deepEqual(driver.events, [
    "on:voice",
    "off:voice",
    "emergency-off",
    "read-ptt",
  ]);
  assert.equal(interlock.snapshot().state, "fault");
  assert.equal(interlock.snapshot().dekeyRequired, true);
  assert.equal(interlock.snapshot().dekeyStartedAtMs, 10_000);
});

test("OFF write failure retains the latch even when readback is OFF", async () => {
  const driver = new RecordingDriver();
  driver.failEmergencyOff = true;
  driver.readPttValue = false;
  const interlock = new TransmitInterlock(driver, {
    tokenFactory: () => "lease-off-write-failure",
  });
  const lease = await interlock.start("device-a", "voice");

  await assert.rejects(interlock.stop("device-a", lease.leaseToken), /off-write/u);
  assert.equal(interlock.snapshot().state, "fault");
  assert.equal(interlock.snapshot().dekeyRequired, true);
});

test("attemptDeKey accepts only positive safe integer generations", async () => {
  const invalidGenerations = [0, -1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1];
  for (const generation of invalidGenerations) {
    const transport = new RecordingDriver();
    const interlock = new TransmitInterlock(new RecordingDriver());
    assert.throws(() => interlock.advanceRecoveryGeneration(generation), /generation/u);
    await assert.rejects(interlock.attemptDeKey(transport, generation), /generation/u);
    assert.deepEqual(transport.events, []);
  }
});

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(error: unknown): void;
} {
  let resolvePromise!: (value: T) => void;
  let rejectPromise!: (error: unknown) => void;
  const promise = new Promise<T>((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  return { promise, resolve: resolvePromise, reject: rejectPromise };
}

async function withDeadline<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error("test operation timed out")), timeoutMs);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
