import assert from "node:assert/strict";
import { test } from "node:test";

import {
  SafetyEventHub,
  type SafetyAlert,
  type SafetyEvent,
  type SafetyStreamMessage,
} from "../src/safety/safety-event-hub.ts";

const activeAlert = (startedAtMs: number): SafetyAlert => ({
  kind: "active",
  startedAtMs,
  source: "software",
});

const dekeyRequiredAlert = (startedAtMs: number): SafetyAlert => ({
  kind: "dekey_required",
  startedAtMs,
  source: "software",
});

const dekeyEscalatedAlert = (startedAtMs: number): SafetyAlert => ({
  kind: "dekey_escalated",
  startedAtMs,
  source: "software",
});

const swrTripAlert = (startedAtMs: number): SafetyAlert => ({
  kind: "swr_trip_latched",
  startedAtMs,
  source: "software",
});

const swrRearmAlert = (startedAtMs: number): SafetyAlert => ({
  kind: "swr_rearm_pending",
  startedAtMs,
  source: "software",
});

const telemetryUncertainAlert = (startedAtMs: number): SafetyAlert => ({
  kind: "telemetry_uncertain",
  startedAtMs,
  source: "telemetry",
});

const externalPttAlert = (startedAtMs: number): SafetyAlert => ({
  kind: "external_ptt",
  startedAtMs,
  source: "external",
});

function safetyHub(...radioIds: string[]): SafetyEventHub {
  return new SafetyEventHub({
    safetyEpoch: "test-epoch",
    configuredRadioIds: () => radioIds,
  });
}

test("safety epoch is random unless the deterministic seam is supplied", () => {
  const first = new SafetyEventHub({ configuredRadioIds: () => [] });
  const second = new SafetyEventHub({ configuredRadioIds: () => [] });

  assert.notEqual(first.safetyEpoch, second.safetyEpoch);
  assert.notEqual(first.safetyEpoch, "");
  assert.equal(safetyHub("main").safetyEpoch, "test-epoch");
});

test("owner generation and revision form an exact compare-and-swap cursor", () => {
  const hub = safetyHub("main");
  const initial = hub.ownerVersion("main", "transmit");
  assert.deepEqual(initial, { generation: 0, ownerRevision: 0 });

  const generation = hub.beginOwnerGeneration("main", "transmit", initial)!;
  assert.deepEqual(generation, {
    radioId: "main",
    owner: "transmit",
    generation: 1,
    ownerRevision: 0,
  });
  assert.deepEqual(hub.ownerVersion("main", "transmit"), {
    generation: 1,
    ownerRevision: 0,
  });
  assert.equal(
    hub.beginOwnerGeneration("main", "transmit", initial),
    null,
  );

  const published = hub.publish(generation, activeAlert(1))!;
  assert.deepEqual(published.cursor, {
    ...generation,
    ownerRevision: 1,
  });
  assert.equal(published.event?.revision, 1);
  assert.deepEqual(hub.ownerVersion("main", "transmit"), {
    generation: 1,
    ownerRevision: 1,
  });
});

test("snapshot clear uses alert null and a recovered increment", () => {
  const hub = new SafetyEventHub({
    safetyEpoch: "test-epoch",
    configuredRadioIds: () => ["main"],
  });
  const alert = {
    kind: "dekey_required",
    startedAtMs: 100,
    source: "software",
  } as const;
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  tx = hub.publish(tx, activeAlert(99))!.cursor;
  const firstMutation = hub.publish(tx, alert)!;
  tx = firstMutation.cursor;
  const first = firstMutation.event!;
  assert.deepEqual(hub.snapshot("main"), {
    t: "safety.snapshot",
    safetyEpoch: hub.safetyEpoch,
    radioId: "main",
    revision: first.revision,
    alert,
  });

  const streamed: SafetyStreamMessage[] = [];
  hub.subscribeControl((value) => streamed.push(value));
  const recoveredMutation = hub.clear(tx, 102, {
    kind: "ptt_off_confirmed",
    generation: tx.generation,
  })!;
  const recovered = recoveredMutation.event!;
  assert.deepEqual(recovered, {
    t: "safety.event",
    safetyEpoch: hub.safetyEpoch,
    radioId: "main",
    revision: first.revision + 1,
    kind: "recovered",
    startedAtMs: 102,
    source: "software",
  });
  assert.deepEqual(streamed.at(-1), recovered);
  assert.deepEqual(hub.snapshot("main"), {
    t: "safety.snapshot",
    safetyEpoch: hub.safetyEpoch,
    radioId: "main",
    revision: recovered.revision,
    alert: null,
  });
});

test("complete snapshot includes configured radio that never published an alert", () => {
  const hub = new SafetyEventHub({
    safetyEpoch: "complete-epoch",
    configuredRadioIds: () => ["main", "backup"],
  });
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  tx = hub.publish(tx, activeAlert(99))!.cursor;
  hub.publish(tx, dekeyRequiredAlert(100));

  const streamed: SafetyStreamMessage[] = [];
  hub.subscribeControl((value) => streamed.push(value));

  assert.deepEqual(streamed.map((value) => value.t), [
    "safety.snapshot.begin",
    "safety.snapshot",
    "safety.snapshot",
    "safety.snapshot.end",
  ]);
  assert.deepEqual(
    streamed.find(
      (value) => value.t === "safety.snapshot" && value.radioId === "backup",
    ),
    {
      t: "safety.snapshot",
      safetyEpoch: "complete-epoch",
      radioId: "backup",
      revision: 0,
      alert: null,
    },
  );
});

test("subscription flushes only per-radio revisions newer than its complete snapshot", () => {
  const hub = new SafetyEventHub({
    safetyEpoch: "stream-epoch",
    configuredRadioIds: () => ["main", "backup"],
  });
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  tx = hub.publish(tx, activeAlert(99))!.cursor;
  tx = hub.publish(tx, dekeyRequiredAlert(100))!.cursor;

  let backupTelemetry = hub.beginOwnerGeneration(
    "backup",
    "telemetry",
    hub.ownerVersion("backup", "telemetry"),
  )!;
  backupTelemetry = hub.publish(
    backupTelemetry,
    telemetryUncertainAlert(90),
  )!.cursor;
  backupTelemetry = hub.publish(backupTelemetry, externalPttAlert(91))!.cursor;
  backupTelemetry = hub.clear(backupTelemetry, 92, {
    kind: "telemetry_recovered",
    generation: backupTelemetry.generation,
  })!.cursor;
  backupTelemetry = hub.beginOwnerGeneration(
    "backup",
    "telemetry",
    backupTelemetry,
  )!;
  backupTelemetry = hub.publish(
    backupTelemetry,
    telemetryUncertainAlert(93),
  )!.cursor;

  const sent: SafetyStreamMessage[] = [];
  const snapshotRevision = new Map<string, number>();
  hub.subscribeControl((value) => {
    sent.push(value);
    if (value.t === "safety.snapshot") {
      snapshotRevision.set(value.radioId, value.revision);
      if (value.radioId === "main") {
        tx = hub.publish(tx, dekeyEscalatedAlert(101))!.cursor;
      }
    }
  });

  assert.deepEqual(sent.map((value) => value.t), [
    "safety.snapshot.begin",
    "safety.snapshot",
    "safety.snapshot",
    "safety.snapshot.end",
    "safety.event",
  ]);
  const increments = sent.filter(
    (value): value is SafetyEvent => value.t === "safety.event",
  );
  assert.equal(increments.length, 1);
  assert.equal(increments[0]?.radioId, "main");
  assert.equal(
    (increments[0]?.revision ?? 0) > (snapshotRevision.get("main") ?? 0),
    true,
  );
  assert.equal(
    (increments[0]?.revision ?? 0) < (snapshotRevision.get("backup") ?? 0),
    true,
  );
});

test("snapshot buffering never emits an increment for a radio absent from its envelope", () => {
  const hub = safetyHub("main");
  let ghost = hub.beginOwnerGeneration(
    "ghost",
    "transmit",
    hub.ownerVersion("ghost", "transmit"),
  )!;
  const sent: SafetyStreamMessage[] = [];

  hub.subscribeControl((value) => {
    sent.push(value);
    if (value.t === "safety.snapshot" && value.radioId === "main") {
      ghost = hub.publish(ghost, activeAlert(1))!.cursor;
    }
  });

  assert.deepEqual(sent.map((value) => value.t), [
    "safety.snapshot.begin",
    "safety.snapshot",
    "safety.snapshot.end",
  ]);
  assert.equal(sent.some((value) => "radioId" in value && value.radioId === "ghost"), false);
});

test("projection follows the fixed safety severity order", () => {
  const hub = safetyHub("main");
  let telemetry = hub.beginOwnerGeneration(
    "main",
    "telemetry",
    hub.ownerVersion("main", "telemetry"),
  )!;
  telemetry = hub.publish(telemetry, telemetryUncertainAlert(1))!.cursor;
  assert.equal(hub.snapshot("main").alert?.kind, "telemetry_uncertain");
  telemetry = hub.publish(telemetry, externalPttAlert(2))!.cursor;
  assert.equal(hub.snapshot("main").alert?.kind, "external_ptt");

  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  tx = hub.publish(tx, activeAlert(3))!.cursor;
  assert.equal(hub.snapshot("main").alert?.kind, "active");

  let swr = hub.beginOwnerGeneration(
    "main",
    "swr",
    hub.ownerVersion("main", "swr"),
  )!;
  swr = hub.publish(swr, swrTripAlert(4))!.cursor;
  assert.equal(hub.snapshot("main").alert?.kind, "swr_trip_latched");
  let rearm = hub.beginOwnerGeneration("main", "swr", swr)!;
  rearm = hub.publish(rearm, swrRearmAlert(5), {
    kind: "swr_reset_persisted",
    generation: rearm.generation,
  })!.cursor;
  assert.equal(hub.snapshot("main").alert?.kind, "swr_rearm_pending");

  tx = hub.publish(tx, dekeyRequiredAlert(6))!.cursor;
  assert.equal(hub.snapshot("main").alert?.kind, "dekey_required");
  tx = hub.publish(tx, dekeyEscalatedAlert(7))!.cursor;
  assert.equal(hub.snapshot("main").alert?.kind, "dekey_escalated");

  const afterOff = hub.clear(tx, 8, {
    kind: "ptt_off_confirmed",
    generation: tx.generation,
  })!;
  assert.equal(afterOff.event?.kind, "swr_rearm_pending");
  assert.equal(hub.snapshot("main").alert?.kind, "swr_rearm_pending");
});

test("lower severity telemetry cannot downgrade a dekey escalation", () => {
  const hub = safetyHub("main");
  let telemetry = hub.beginOwnerGeneration(
    "main",
    "telemetry",
    hub.ownerVersion("main", "telemetry"),
  )!;
  telemetry = hub.publish(telemetry, externalPttAlert(1))!.cursor;
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  tx = hub.publish(tx, activeAlert(2))!.cursor;
  tx = hub.publish(tx, dekeyRequiredAlert(3))!.cursor;
  tx = hub.publish(tx, dekeyEscalatedAlert(4))!.cursor;
  const publicRevision = hub.snapshot("main").revision;

  const telemetryClear = hub.clear(telemetry, 5, {
    kind: "telemetry_recovered",
    generation: telemetry.generation,
  })!;
  assert.equal(telemetryClear.event, null);
  assert.equal(telemetryClear.cursor.ownerRevision, telemetry.ownerRevision + 1);
  telemetry = hub.beginOwnerGeneration(
    "main",
    "telemetry",
    telemetryClear.cursor,
  )!;
  const maskedTelemetry = hub.publish(
    telemetry,
    telemetryUncertainAlert(6),
  )!;

  assert.equal(maskedTelemetry.event, null);
  assert.equal(maskedTelemetry.cursor.ownerRevision, telemetry.ownerRevision + 1);
  assert.equal(hub.snapshot("main").revision, publicRevision);
  assert.equal(hub.snapshot("main").alert?.kind, "dekey_escalated");
});

test("late telemetry clear cannot clear a runtime dekey alert", () => {
  const hub = safetyHub("main");
  let telemetry = hub.beginOwnerGeneration(
    "main",
    "telemetry",
    hub.ownerVersion("main", "telemetry"),
  )!;
  telemetry = hub.publish(telemetry, telemetryUncertainAlert(1))!.cursor;
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  tx = hub.publish(tx, activeAlert(2))!.cursor;
  tx = hub.publish(tx, dekeyRequiredAlert(3))!.cursor;
  const before = hub.snapshot("main");

  const clear = hub.clear(telemetry, 4, {
    kind: "telemetry_recovered",
    generation: telemetry.generation,
  })!;

  assert.equal(clear.event, null);
  assert.deepEqual(hub.snapshot("main"), before);
});

test("OFF recovery reveals a latched SWR alert before final recovered", () => {
  const hub = new SafetyEventHub({
    safetyEpoch: "swr-epoch",
    configuredRadioIds: () => ["main"],
  });
  let swr = hub.beginOwnerGeneration(
    "main",
    "swr",
    hub.ownerVersion("main", "swr"),
  )!;
  swr = hub.publish(swr, swrTripAlert(1))!.cursor;
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  tx = hub.publish(tx, activeAlert(2))!.cursor;
  tx = hub.publish(tx, dekeyRequiredAlert(2))!.cursor;

  const afterOff = hub.clear(tx, 3, {
    kind: "ptt_off_confirmed",
    generation: tx.generation,
  })!.event!;
  assert.equal(afterOff.kind, "swr_trip_latched");
  assert.equal(hub.snapshot("main").alert?.kind, "swr_trip_latched");

  let rearm = hub.beginOwnerGeneration("main", "swr", swr)!;
  rearm = hub.publish(rearm, swrRearmAlert(4), {
    kind: "swr_reset_persisted",
    generation: rearm.generation,
  })!.cursor;
  const finalRecovery = hub.clear(rearm, 5, {
    kind: "swr_rearm_safe",
    generation: rearm.generation,
  })!.event!;
  assert.equal(finalRecovery.kind, "recovered");
  assert.equal(hub.snapshot("main").alert, null);
});

test("stale same-owner publish leaves the newer latch and both revisions unchanged", () => {
  const hub = safetyHub("main");
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  tx = hub.publish(tx, activeAlert(1))!.cursor;
  const stale = tx;
  tx = hub.publish(tx, dekeyRequiredAlert(2))!.cursor;
  const beforeVersion = hub.ownerVersion("main", "transmit");
  const beforeSnapshot = hub.snapshot("main");

  assert.equal(hub.publish(stale, dekeyEscalatedAlert(3)), null);
  assert.deepEqual(hub.ownerVersion("main", "transmit"), beforeVersion);
  assert.deepEqual(hub.snapshot("main"), beforeSnapshot);
});

test("stale same-owner clear cannot clear a newer latch", () => {
  const hub = safetyHub("main");
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  tx = hub.publish(tx, activeAlert(1))!.cursor;
  const staleClear = hub.publish(tx, dekeyRequiredAlert(2))!.cursor;
  tx = hub.publish(staleClear, dekeyEscalatedAlert(3))!.cursor;
  const beforeVersion = hub.ownerVersion("main", "transmit");
  const beforeSnapshot = hub.snapshot("main");

  assert.equal(
    hub.clear(staleClear, 4, {
      kind: "ptt_off_confirmed",
      generation: staleClear.generation,
    }),
    null,
  );
  assert.deepEqual(hub.ownerVersion("main", "transmit"), beforeVersion);
  assert.deepEqual(hub.snapshot("main"), beforeSnapshot);
});

test("old SWR rearm completion cannot clear a newer trip generation", () => {
  const hub = safetyHub("main");
  let swr = hub.beginOwnerGeneration(
    "main",
    "swr",
    hub.ownerVersion("main", "swr"),
  )!;
  swr = hub.publish(swr, swrTripAlert(1))!.cursor;
  let rearm = hub.beginOwnerGeneration("main", "swr", swr)!;
  rearm = hub.publish(rearm, swrRearmAlert(2), {
    kind: "swr_reset_persisted",
    generation: rearm.generation,
  })!.cursor;
  const oldSafeCompletion = rearm;
  let retrip = hub.beginOwnerGeneration("main", "swr", rearm)!;
  retrip = hub.publish(retrip, swrTripAlert(3))!.cursor;
  const beforeVersion = hub.ownerVersion("main", "swr");
  const beforeSnapshot = hub.snapshot("main");

  assert.equal(
    hub.clear(oldSafeCompletion, 4, {
      kind: "swr_rearm_safe",
      generation: oldSafeCompletion.generation,
    }),
    null,
  );
  assert.deepEqual(hub.ownerVersion("main", "swr"), beforeVersion);
  assert.deepEqual(hub.snapshot("main"), beforeSnapshot);
});

test("out-of-order telemetry completion cannot replace or clear the latest observation", () => {
  const hub = safetyHub("main");
  let oldTick = hub.beginOwnerGeneration(
    "main",
    "telemetry",
    hub.ownerVersion("main", "telemetry"),
  )!;
  oldTick = hub.publish(oldTick, telemetryUncertainAlert(1))!.cursor;
  let latestTick = hub.beginOwnerGeneration("main", "telemetry", oldTick)!;
  latestTick = hub.publish(latestTick, externalPttAlert(2))!.cursor;
  const beforeVersion = hub.ownerVersion("main", "telemetry");
  const beforeSnapshot = hub.snapshot("main");

  assert.equal(hub.publish(oldTick, telemetryUncertainAlert(3)), null);
  assert.equal(
    hub.clear(oldTick, 4, {
      kind: "telemetry_recovered",
      generation: oldTick.generation,
    }),
    null,
  );
  assert.deepEqual(hub.ownerVersion("main", "telemetry"), beforeVersion);
  assert.deepEqual(hub.snapshot("main"), beforeSnapshot);
});

test("owner transitions and proofs are enforced without consuming revisions", () => {
  const hub = safetyHub("main");
  let swr = hub.beginOwnerGeneration(
    "main",
    "swr",
    hub.ownerVersion("main", "swr"),
  )!;
  const beforeInvalid = hub.snapshot("main");
  assert.equal(hub.publish(swr, swrRearmAlert(1)), null);
  assert.deepEqual(hub.ownerVersion("main", "swr"), {
    generation: 1,
    ownerRevision: 0,
  });
  assert.deepEqual(hub.snapshot("main"), beforeInvalid);

  swr = hub.publish(swr, swrTripAlert(2))!.cursor;
  const tripSnapshot = hub.snapshot("main");
  assert.equal(
    hub.publish(swr, swrRearmAlert(3), {
      kind: "swr_reset_persisted",
      generation: swr.generation,
    }),
    null,
  );
  assert.deepEqual(hub.snapshot("main"), tripSnapshot);
  assert.equal(
    hub.clear(swr, 4, {
      kind: "swr_rearm_safe",
      generation: swr.generation,
    }),
    null,
  );
  assert.deepEqual(hub.snapshot("main"), tripSnapshot);

  let telemetry = hub.beginOwnerGeneration(
    "main",
    "telemetry",
    hub.ownerVersion("main", "telemetry"),
  )!;
  telemetry = hub.publish(telemetry, externalPttAlert(5))!.cursor;
  const beforeDowngrade = hub.ownerVersion("main", "telemetry");
  assert.equal(hub.publish(telemetry, telemetryUncertainAlert(6)), null);
  assert.deepEqual(hub.ownerVersion("main", "telemetry"), beforeDowngrade);
});

test("reentrant subscriber delivery remains FIFO for every listener", () => {
  const hub = safetyHub("main");
  const first: SafetyStreamMessage[] = [];
  const second: SafetyStreamMessage[] = [];
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  let swr = hub.beginOwnerGeneration(
    "main",
    "swr",
    hub.ownerVersion("main", "swr"),
  )!;

  hub.subscribeControl((value) => {
    first.push(value);
    if (value.t === "safety.event" && value.kind === "active") {
      swr = hub.publish(swr, swrTripAlert(2))!.cursor;
    }
  });
  hub.subscribeControl((value) => second.push(value));
  tx = hub.publish(tx, activeAlert(1))!.cursor;

  const firstEvents = first.filter(
    (value): value is SafetyEvent => value.t === "safety.event",
  );
  const secondEvents = second.filter(
    (value): value is SafetyEvent => value.t === "safety.event",
  );
  assert.deepEqual(
    firstEvents.map((event) => event.revision),
    [1, 2],
  );
  assert.deepEqual(
    secondEvents.map((event) => event.revision),
    [1, 2],
  );
});

test("a throwing subscriber is detached without escaping the publish path", () => {
  const hub = safetyHub("main");
  let sends = 0;
  hub.subscribeControl((value) => {
    if (value.t === "safety.event") {
      sends += 1;
      throw new Error("socket closed");
    }
  });
  let tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;

  assert.doesNotThrow(() => {
    tx = hub.publish(tx, activeAlert(1))!.cursor;
  });
  assert.doesNotThrow(() => {
    tx = hub.publish(tx, dekeyRequiredAlert(2))!.cursor;
  });
  assert.equal(sends, 1);
});

test("external PTT recovery preserves the external event source", () => {
  const hub = safetyHub("main");
  let telemetry = hub.beginOwnerGeneration(
    "main",
    "telemetry",
    hub.ownerVersion("main", "telemetry"),
  )!;
  telemetry = hub.publish(telemetry, externalPttAlert(10))!.cursor;

  const recovered = hub.clear(telemetry, 11, {
    kind: "telemetry_recovered",
    generation: telemetry.generation,
  })!.event!;

  assert.equal(recovered.kind, "recovered");
  assert.equal(recovered.source, "external");
});

test("invalid alert provenance and timestamps consume no revisions", () => {
  const hub = safetyHub("main");
  const tx = hub.beginOwnerGeneration(
    "main",
    "transmit",
    hub.ownerVersion("main", "transmit"),
  )!;
  const beforeVersion = hub.ownerVersion("main", "transmit");
  const beforeSnapshot = hub.snapshot("main");

  assert.equal(hub.publish(tx, {
    kind: "active",
    startedAtMs: -1,
    source: "software",
  }), null);
  assert.equal(hub.publish(tx, {
    kind: "active",
    startedAtMs: 1,
    source: "external",
  }), null);
  assert.deepEqual(hub.ownerVersion("main", "transmit"), beforeVersion);
  assert.deepEqual(hub.snapshot("main"), beforeSnapshot);

  let telemetry = hub.beginOwnerGeneration(
    "main",
    "telemetry",
    hub.ownerVersion("main", "telemetry"),
  )!;
  telemetry = hub.publish(telemetry, externalPttAlert(2))!.cursor;
  const beforeClear = hub.snapshot("main");
  assert.equal(hub.clear(telemetry, Number.NaN, {
    kind: "telemetry_recovered",
    generation: telemetry.generation,
  }), null);
  assert.deepEqual(hub.snapshot("main"), beforeClear);
});
