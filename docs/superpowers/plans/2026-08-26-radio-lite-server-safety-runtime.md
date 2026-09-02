# Radio Lite Server Safety Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every server-owned transmission fail safe through confirmed PTT-off recovery while adding bounded CAT transport, runtime supervision, WS liveness, and emergency stopping.

**Architecture:** Keep `TransmitInterlock` as the serialized per-radio state machine and make `RigRuntimeSupervisor` the sole owner of rigctld lifecycle, replacement, retry scheduling, recovery generations, and telemetry. `SafetyEventHub` publishes/audits state without hardware access; `RadioLiteService` is the sole integration owner for `radio-lite-service.ts` and wires HTTP/WS identity and media/digital cancellation into runtimes.

**Tech Stack:** Node 24.7.0, TypeScript 5.9, Node built-in test runner, `ws`, Hamlib rigctld, GitHub Actions Ubuntu.

**Spec:** `docs/superpowers/specs/2026-08-26-radio-lite-safety-reliability-design.md`

**Execution convention:** Run every command from repository root `D:\CodeX\remote radio\repo\.worktrees\public-dummy-web-integration`. Focused server commands put `--test-name-pattern` before `radio-lite-server/test/*.test.ts`; full package commands use `npm --prefix radio-lite-server`.

## Global Constraints

- Implement design §§4–8 runtime portions, §10 WS Origin/liveness portions, §16 server/web CI foundation, and §17 server fault tests in slices 1–4 only.
- `dekeyRequired` is the in-memory latch field; `dekey_required` is an event kind, never an independent state.
- Only a same-transaction real `get_ptt=false` clears a software-owned latch, fault, and start ban; `set_ptt 0`, cached telemetry, and last command are not evidence.
- A normal startup/reconnect/preflight resume without an existing latch is read-only and must never send PTT OFF; observed external PTT is an alert only.
- One `RigRuntimeSupervisor` per `radioId` owns retry, rigctld restart, transport replacement, recovery generation, and all automatic OFF attempts.
- The same supervisor owns a separate monotonic transmit-admission generation and at most one start permit; every stop, drain, close, reconfiguration, authority loss, or worker cancellation invalidates it synchronously before awaiting anything.
- `SafetyEventHub` keeps independent transmit, SWR, and telemetry slots and projects only the highest-severity effective alert. Every radio+owner slot has a Hub-issued monotonic generation and owner-local revision; `publish`/`clear` are exact-cursor CAS mutations, so a late same-owner clear/publish and a lower-severity cross-owner publish can never erase or downgrade a de-key/SWR latch.
- Safety commands use a high-priority FIFO, normal commands use a bounded FIFO of 32; one CAT command is in flight per connection.
- Safety OFF/readback commands use 1 s per-command deadlines; voice/digital recovery budget is 2 s; tuning recovery budget is 3 s; normal commands retain 10 s.
- Emergency stop requires the WS authentication boundary's valid, enabled identity result but no control lease, transmit token, transmit permission, grid, or hardware-TX setting. It always targets the requested `radioId`; target-runtime de-key is attempted even when digital/media cleanup fails, and no other radio is touched. Security Plan Task 7 owns identity/revocation implementation.
- Safety timers remain referenced; they must not call `unref()`.
- HTTP/Tailscale testing remains supported; browser cookie WS upgrades must pass the same Origin rule as HTTP, while origin-less device authentication remains supported.
- Add `.node-version` with exactly `24.7.0`; `server-check` runs `npm --prefix radio-lite-server ci` then `npm --prefix radio-lite-server run check`; `web-check` runs `npm --prefix web test`; do not change IPA/release work in this plan.
- No release/deployment, preflight-proof, reconfiguration-fence, account-management, password-rate-limit, or iOS artifact changes belong to this plan.

## File Structure

- Create: `.node-version` — the single authoritative Node version.
- Modify: `.github/workflows/ios.yml` — add independent `server-check` and `web-check` jobs and make existing release-artifact work depend on them only when that work is later changed.
- Create: `radio-lite-server/src/safety/dekey.ts` — evidence-bearing dekey result and outcome contracts.
- Create: `radio-lite-server/src/safety/safety-event-hub.ts` — revisioned owner-scoped per-radio alerts, deterministic severity projection, and subscriptions; no CAT imports.
- Create: `radio-lite-server/src/safety/swr-safety-store.ts` — atomic plaintext per-radio trip/rearm state under the configured data directory.
- Modify: `radio-lite-server/src/safety/transmit-interlock.ts` — latch, atomic recovery transition, one-shot dekey attempt, start admission.
- Create: `radio-lite-server/src/rig/runtime-supervisor.ts` — managed process lifecycle, transport generation, recovery backoff, startup observation, and close ordering.
- Create: `radio-lite-server/src/rig/telemetry-sampler.ts` — single-flight low-priority PTT/frequency/mode/SWR cache and CAT-budget trace.
- Modify: `radio-lite-server/src/rig/transport.ts` — priority queues, deadlines, queue bound, tracing, and socket-break safety escalation.
- Modify: `radio-lite-server/src/rig/managed-process.ts` — generation-tagged unexpected-exit notification only.
- Modify: `radio-lite-server/src/rig/hamlib-rig.ts` — targeted real PTT/frequency/SWR reads needed by the supervisor/sampler.
- Modify: `radio-lite-server/src/rig/radio-runtime.ts` — supervisor facade, safety-serialized writes/admission, control/transmit heartbeat split, shutdown delegation, and consumption of Security Plan Task 1's `allowedTransmitRangesHz`/SWR schema.
- Modify: `radio-lite-server/src/media/media-hub.ts` — `DeKeyOutcome` callback, radio cancellation, and referenced two-second audio-silence watchdog.
- Modify: `radio-lite-server/src/digital/controller.ts` and `radio-lite-server/src/digital/hub.ts` — transmit-only heartbeat and radio-wide emergency cancellation.
- Modify: `radio-lite-server/src/server/radio-lite-service.ts` — sole owner: WS upgrade/auth/liveness, runtime/media/digital integration, `tx.emergency-stop`, safety event broadcast, closing order.
- Modify tests: `radio-lite-server/test/{transmit-interlock,radio-runtime,rigctld-transport,managed-process,media-hub,digital-controller,control-lease,http-service}.test.ts` and create `radio-lite-server/test/{safety-event-hub,runtime-supervisor,telemetry-sampler,ws-safety}.test.ts`.

## Dependency Interfaces

```ts
// src/safety/dekey.ts
export type DeKeyOutcome =
  | { kind: "offConfirmed"; generation: number }
  | { kind: "recoveryPending"; generation: number }
  | { kind: "notResponsible"; generation: number };
export type DeKeyAttempt =
  | { confirmed: true; generation: number }
  | { confirmed: false; generation: number; reason: string };

// src/safety/transmit-interlock.ts
export type InterlockSnapshot = { state: InterlockState; lease: TransmitLease | null;
  faultReason: string | null; dekeyRequired: boolean; dekeyStartedAtMs: number | null };
attemptDeKey(transport: DeKeyTransport, generation: number): Promise<DeKeyAttempt>;
startupObserve(): Promise<void>;

// src/rig/runtime-supervisor.ts
export type TransmitStartReservation = Readonly<{
  radioId: string; ownerId: string; userId: string; mode: TransmitMode;
  controlLeaseRevision: number; profileRevision: number;
}>;
export type TransmitStartPermit = Readonly<TransmitStartReservation & {
  admissionGeneration: number; permitId: string;
}>;
export interface RigRuntimeSupervisor {
  startupObserve(): Promise<void>;
  reserveTransmitStart(input: TransmitStartReservation): Promise<TransmitStartPermit>;
  commitTransmitStart(permit: TransmitStartPermit,
    revalidate: () => void | Promise<void>): Promise<TransmitLease>;
  abandonTransmitStart(permit: TransmitStartPermit, reason: string): void;
  invalidateTransmitStarts(reason: string): void;
  stop(ownerId: string, token: string, reason: string): Promise<DeKeyOutcome>;
  emergencyStop(reason: string): Promise<DeKeyOutcome>;
  close(): Promise<void>;
}

// src/rig/transport.ts
export class RigQueueBusyError extends Error {}
export class RigTelemetryDroppedError extends Error {}
export type RigRequestOptions = { priority?: "safety" | "normal";
  source?: RigRequestSource; timeoutMs?: number };
request(command: string, options?: RigRequestOptions): Promise<RigResponse>;
commandTrace(): readonly RigCommandTrace[];

// src/safety/safety-event-hub.ts
export type PersistentSafetyAlertKind = "active" | "external_ptt" | "telemetry_uncertain" |
  "dekey_required" | "dekey_escalated" | "swr_trip_latched" | "swr_rearm_pending";
export type SafetyEventKind = PersistentSafetyAlertKind | "recovered";
export type SafetyAlertOwner = "transmit" | "swr" | "telemetry";
export type SafetyOwnerVersion = { generation: number; ownerRevision: number };
export type SafetyOwnerCursor = SafetyOwnerVersion & { radioId: string; owner: SafetyAlertOwner };
export type SafetyMutation = { cursor: SafetyOwnerCursor; event: SafetyEvent | null };
export type SafetyPublishProof =
  { kind: "swr_reset_persisted"; generation: number };
export type SafetyClearProof =
  { kind: "ptt_off_confirmed" | "swr_rearm_safe" | "telemetry_recovered"; generation: number };
export type SwrSafetyStoredState = "armed" | "latched" | "rearm_pending" | "rearm_in_progress";
export type SwrSafetyRecord = {
  radioId: string; state: SwrSafetyStoredState; trippedAtMs: number | null;
};
export type SafetyAlert = { kind: PersistentSafetyAlertKind; startedAtMs: number; source: "software" | "external" | "telemetry" };
export type SafetyAlertSnapshot = { t: "safety.snapshot"; safetyEpoch: string; radioId: string; revision: number; alert: SafetyAlert | null };
export type SafetyEvent = { t: "safety.event"; safetyEpoch: string; radioId: string; revision: number; kind: SafetyEventKind; startedAtMs: number; source: "software" | "external" | "telemetry" };
export type SafetyStreamMessage = SafetyAlertSnapshot | SafetyEvent |
  { t: "safety.snapshot.begin"; safetyEpoch: string } |
  { t: "safety.snapshot.end"; safetyEpoch: string };
ownerVersion(radioId: string, owner: SafetyAlertOwner): SafetyOwnerVersion;
beginOwnerGeneration(radioId: string, owner: SafetyAlertOwner,
  expected: SafetyOwnerVersion): SafetyOwnerCursor | null;
publish(expected: SafetyOwnerCursor, alert: SafetyAlert,
  proof?: SafetyPublishProof): SafetyMutation | null;
clear(expected: SafetyOwnerCursor, recoveredAtMs: number,
  proof: SafetyClearProof): SafetyMutation | null;
snapshot(radioId: string): SafetyAlertSnapshot;
subscribeControl(send: (value: SafetyStreamMessage) => void): () => void;
```

`SafetyEventHub` takes `configuredRadioIds: () => readonly string[]` and optional
`safetyEpoch` only as a deterministic test seam; production supplies the registry callback and
generates a process-random epoch. Every configured ID, including one never passed to `publish`,
has a revision-0 `alert:null` snapshot. An unseen owner starts at `{ generation: 0,
ownerRevision: 0 }`; beginning a generation compares that complete version, increments only the
owner generation, preserves the current alert, and consumes neither owner nor global revision.

---

### Task 1: Server CI and deterministic fault-test foundation

**Files:**
- Create: `.node-version`
- Create: `radio-lite-server/test/ci-contract.test.ts`
- Modify: `.github/workflows/ios.yml`
- Modify: `radio-lite-server/test/rigctld-transport.test.ts`

**Interfaces:** Produces Node 24.7.0 CI and reusable fake-clock/deferred-socket fixture helpers local to tests; consumes no runtime interfaces.

- [ ] **Step 1: Write the failing CI contract test and transport fixture assertions**

Add exact tests named `"Node version contract is pinned to 24.7.0"` in the new small CI file and `"unfinished ordinary request remains observable in DeferredSocket"` in the transport file. The latter keeps the request pending until the test explicitly resolves it.

```ts
test("Node version contract is pinned to 24.7.0", async () => {
  assert.equal(
    await readFile(join(import.meta.dirname, "../../.node-version"), "utf8"),
    "24.7.0\n",
  );
});

test("unfinished ordinary request remains observable in DeferredSocket", async () => {
  const fixture = deferredTransportFixture();
  const pending = fixture.transport.request("\\get_freq", { source: "telemetry" });
  assert.equal(fixture.socket.pendingCommands(), 1);
  fixture.socket.reply("Frequency: 14074000");
  await pending;
});
```

- [ ] **Step 2: Run the red test**

Run: `node --experimental-strip-types --test radio-lite-server/test/ci-contract.test.ts radio-lite-server/test/rigctld-transport.test.ts`

Expected: FAIL because `.node-version` and the fixture assertion do not exist.

- [ ] **Step 3: Add the minimal CI files and fixture**

Create `.node-version` containing `24.7.0`. In `.github/workflows/ios.yml`, add Ubuntu jobs named and keyed `server-check` and `web-check`; both use `node-version-file: .node-version`; `server-check` runs `npm --prefix radio-lite-server ci && npm --prefix radio-lite-server run check`; `web-check` runs `npm --prefix web test`. Add the local `DeferredSocket` test helper without production imports.

- [ ] **Step 4: Run focused green checks**

Run: `node --experimental-strip-types --test radio-lite-server/test/ci-contract.test.ts radio-lite-server/test/rigctld-transport.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit the task**

```bash
git add .node-version .github/workflows/ios.yml radio-lite-server/test/ci-contract.test.ts radio-lite-server/test/rigctld-transport.test.ts
git commit -m "ci: add server and web checks"
```

### Task 2: Evidence-only interlock latch

**Files:**
- Create: `radio-lite-server/src/safety/dekey.ts`
- Modify: `radio-lite-server/src/safety/transmit-interlock.ts`
- Modify: `radio-lite-server/test/transmit-interlock.test.ts`

**Interfaces:** Produces `DeKeyOutcome`, `DeKeyAttempt`, `InterlockSnapshot.dekeyRequired`, `startupObserve()`, and `attemptDeKey(transport,generation)` for Tasks 3–10. Consumes the existing `TransmitDriver` activate/deactivate contract.

- [ ] **Step 1: Write failing latch tests**

Add exact tests named `"PTT OFF write without OFF readback retains the dekey latch"`, `"only same-generation OFF readback atomically recovers a latched interlock"`, and `"startup observation never writes PTT OFF"`.

```ts
await assert.rejects(interlock.stop("device-a", lease.leaseToken), /read-back/u);
assert.deepEqual(interlock.snapshot(), {
  state: "fault", lease: null, faultReason: "released by owner; PTT OFF unconfirmed",
  dekeyRequired: true, dekeyStartedAtMs: 1_000,
});
await interlock.attemptDeKey({ deactivate, emergencyOff, readPtt: async () => false }, 7);
assert.equal(interlock.snapshot().dekeyRequired, false);
```

- [ ] **Step 2: Run the red tests**

Run: `node --experimental-strip-types --test --test-name-pattern="PTT OFF write without OFF readback|same-generation OFF readback|startup observation" radio-lite-server/test/*.test.ts`

Expected: FAIL because `dekeyRequired`, `attemptDeKey`, and `startupObserve` are absent; existing startup writes OFF and `stop` treats write success as sufficient.

- [ ] **Step 3: Implement the smallest evidence-bearing state machine**

Define `DeKeyTransport` with `deactivate(mode)`, `emergencyOff()`, and `readPtt()`. On any stop/deadline/trip failure set `{ state: "fault", lease: null, dekeyRequired: true, dekeyStartedAtMs: now }`; never clear it in `clearFault`. `attemptDeKey` must run deactivate when a previous lease mode requires it, then OFF then `readPtt`; only `false` atomically sets idle, clears fault/latch, and returns `{ confirmed: true, generation }`. `startupObserve` only reads PTT and changes no driver state.

- [ ] **Step 4: Run the interlock suite green**

Run: `node --experimental-strip-types --test --test-name-pattern="voice, digital|heartbeat|disconnect|de-key|hard deadline|readback|startup observation" radio-lite-server/test/*.test.ts`

Expected: PASS; no test observes a startup OFF write or an unlocked start before OFF evidence.

- [ ] **Step 5: Commit the task**

```bash
git add radio-lite-server/src/safety/dekey.ts radio-lite-server/src/safety/transmit-interlock.ts radio-lite-server/test/transmit-interlock.test.ts
git commit -m "feat: latch unconfirmed transmit dekey"
```

### Task 3: Revisioned safety events and outcome-aware automatic stops

**Files:**
- Create: `radio-lite-server/src/safety/safety-event-hub.ts`
- Create: `radio-lite-server/test/safety-event-hub.test.ts`
- Modify: `radio-lite-server/src/media/media-hub.ts`
- Modify: `radio-lite-server/src/digital/controller.ts`
- Modify: `radio-lite-server/test/media-hub.test.ts`
- Modify: `radio-lite-server/test/digital-controller.test.ts`

**Interfaces:** Consumes Task 2 `DeKeyOutcome`. Produces owner-scoped `SafetyEventHub` and changes `MediaHubOptions.stopVoiceTransmit` to `(request) => Promise<DeKeyOutcome>` for Task 10. No hardware-operation method may be added to `SafetyEventHub`.

- [ ] **Step 1: Write failing event and propagation tests**

Add `"media automatic stop reports ptt_stop_failed when recovery is not confirmed"`, `"media stop accepts recoveryPending without ending the safety event"`, `"digital stop reports unconfirmed dekey rather than swallowing InvalidLease"`, `"late telemetry clear cannot clear a runtime dekey alert"`, `"lower severity telemetry cannot downgrade a dekey escalation"`, `"OFF recovery reveals a latched SWR alert before final recovered"`, `"stale same-owner publish leaves the newer latch and both revisions unchanged"`, `"stale same-owner clear cannot clear a newer latch"`, `"old SWR rearm completion cannot clear a newer trip generation"`, and `"out-of-order telemetry completion cannot replace or clear the latest observation"`.

```ts
stopVoiceTransmit: async () => ({ kind: "recoveryPending", generation: 3 }),
await fixture.hub.disconnect("media-a");
assert.equal(transport.json.at(-1)?.code, "ptt_stop_failed");
```

In `radio-lite-server/test/safety-event-hub.test.ts`, add the exact tests `"snapshot clear uses alert null and a recovered increment"`, `"complete snapshot includes configured radio that never published an alert"`, and `"subscription flushes only per-radio revisions newer than its complete snapshot"`:

```ts
const hub = new SafetyEventHub({
  safetyEpoch: "test-epoch", configuredRadioIds: () => ["main"],
});
const alert = { kind: "dekey_required", startedAtMs: 100, source: "software" } as const;
let tx = hub.beginOwnerGeneration("main", "transmit", hub.ownerVersion("main", "transmit"))!;
tx = hub.publish(tx, { kind: "active", startedAtMs: 99, source: "software" })!.cursor;
const firstMutation = hub.publish(tx, alert)!;
tx = firstMutation.cursor;
const first = firstMutation.event!;
assert.deepEqual(hub.snapshot("main"), {
  t: "safety.snapshot", safetyEpoch: hub.safetyEpoch,
  radioId: "main", revision: first.revision, alert,
});
const streamed: SafetyStreamMessage[] = [];
hub.subscribeControl((value) => streamed.push(value));
const recoveredMutation = hub.clear(tx, 102, {
  kind: "ptt_off_confirmed", generation: tx.generation,
})!;
const recovered = recoveredMutation.event!;
assert.deepEqual(recovered, {
  t: "safety.event", safetyEpoch: hub.safetyEpoch, radioId: "main",
  revision: first.revision + 1, kind: "recovered", startedAtMs: 102, source: "software",
});
assert.deepEqual(streamed.at(-1), recovered);
assert.deepEqual(hub.snapshot("main"), {
  t: "safety.snapshot", safetyEpoch: hub.safetyEpoch,
  radioId: "main", revision: recovered.revision, alert: null,
});

const complete = new SafetyEventHub({
  safetyEpoch: "complete-epoch", configuredRadioIds: () => ["main", "backup"],
});
let completeTx = complete.beginOwnerGeneration(
  "main", "transmit", complete.ownerVersion("main", "transmit"),
)!;
completeTx = complete.publish(completeTx, {
  kind: "active", startedAtMs: 99, source: "software",
})!.cursor;
complete.publish(completeTx, alert);
const completeStream: SafetyStreamMessage[] = [];
complete.subscribeControl((value) => completeStream.push(value));
assert.deepEqual(completeStream.find((value) => value.t === "safety.snapshot" && value.radioId === "backup"), {
  t: "safety.snapshot", safetyEpoch: "complete-epoch",
  radioId: "backup", revision: 0, alert: null,
});
```

The atomic subscription test stores the revision of every radio snapshot, publishes the legal
same-generation `dekey_required -> dekey_escalated` upgrade from inside the snapshot callback, and
asserts ordering plus per-radio filtering even though backup's captured revision is numerically
higher than the concurrent main-radio event:

```ts
const streamHub = new SafetyEventHub({
  safetyEpoch: "stream-epoch", configuredRadioIds: () => ["main", "backup"],
});
let streamTx = streamHub.beginOwnerGeneration(
  "main", "transmit", streamHub.ownerVersion("main", "transmit"),
)!;
streamTx = streamHub.publish(streamTx, {
  kind: "active", startedAtMs: 99, source: "software",
})!.cursor;
streamTx = streamHub.publish(streamTx, {
  kind: "dekey_required", startedAtMs: 100, source: "software",
})!.cursor;
let backupTelemetry = streamHub.beginOwnerGeneration(
  "backup", "telemetry", streamHub.ownerVersion("backup", "telemetry"),
)!;
backupTelemetry = streamHub.publish(backupTelemetry, {
  kind: "telemetry_uncertain", startedAtMs: 90, source: "telemetry",
})!.cursor;
backupTelemetry = streamHub.publish(backupTelemetry, {
  kind: "external_ptt", startedAtMs: 91, source: "external",
})!.cursor;
backupTelemetry = streamHub.clear(backupTelemetry, 92, {
  kind: "telemetry_recovered", generation: backupTelemetry.generation,
})!.cursor;
backupTelemetry = streamHub.beginOwnerGeneration(
  "backup", "telemetry", backupTelemetry,
)!;
backupTelemetry = streamHub.publish(backupTelemetry, {
  kind: "telemetry_uncertain", startedAtMs: 93, source: "telemetry",
})!.cursor;
const sent: SafetyStreamMessage[] = [];
const snapshotRevision = new Map<string, number>();
streamHub.subscribeControl((value) => {
  sent.push(value);
  if (value.t === "safety.snapshot") {
    snapshotRevision.set(value.radioId, value.revision);
    if (value.radioId === "main") {
      streamTx = streamHub.publish(streamTx, {
        kind: "dekey_escalated", startedAtMs: 101, source: "software",
      })!.cursor;
    }
  }
});
assert.deepEqual(sent.map((value) => value.t), ["safety.snapshot.begin", "safety.snapshot", "safety.snapshot", "safety.snapshot.end", "safety.event"]);
const increments = sent.filter((value): value is SafetyEvent => value.t === "safety.event");
assert.equal(increments.length, 1);
assert.equal(increments[0].radioId, "main");
assert.equal(increments[0].revision > (snapshotRevision.get("main") ?? 0), true);
assert.equal(increments[0].revision < (snapshotRevision.get("backup") ?? 0), true);

const priorityHub = new SafetyEventHub({
  safetyEpoch: "priority-epoch", configuredRadioIds: () => ["main"],
});
let priorityTelemetry = priorityHub.beginOwnerGeneration(
  "main", "telemetry", priorityHub.ownerVersion("main", "telemetry"),
)!;
priorityTelemetry = priorityHub.publish(priorityTelemetry, {
  kind: "external_ptt", startedAtMs: 1, source: "external",
})!.cursor;
let priorityTx = priorityHub.beginOwnerGeneration(
  "main", "transmit", priorityHub.ownerVersion("main", "transmit"),
)!;
priorityTx = priorityHub.publish(priorityTx, {
  kind: "active", startedAtMs: 2, source: "software",
})!.cursor;
priorityTx = priorityHub.publish(priorityTx, {
  kind: "dekey_required", startedAtMs: 3, source: "software",
})!.cursor;
priorityTx = priorityHub.publish(priorityTx, {
  kind: "dekey_escalated", startedAtMs: 4, source: "software",
})!.cursor;
const telemetryClear = priorityHub.clear(priorityTelemetry, 5, {
  kind: "telemetry_recovered", generation: priorityTelemetry.generation,
})!;
assert.equal(telemetryClear.event, null);
priorityTelemetry = priorityHub.beginOwnerGeneration(
  "main", "telemetry", telemetryClear.cursor,
)!;
const maskedTelemetry = priorityHub.publish(priorityTelemetry, {
  kind: "telemetry_uncertain", startedAtMs: 6, source: "telemetry",
})!;
assert.equal(maskedTelemetry.event, null);
assert.equal(priorityHub.snapshot("main").alert?.kind, "dekey_escalated");

const swrHub = new SafetyEventHub({
  safetyEpoch: "swr-epoch", configuredRadioIds: () => ["main"],
});
let swr = swrHub.beginOwnerGeneration("main", "swr", swrHub.ownerVersion("main", "swr"))!;
swr = swrHub.publish(swr, {
  kind: "swr_trip_latched", startedAtMs: 1, source: "software",
})!.cursor;
let swrTx = swrHub.beginOwnerGeneration(
  "main", "transmit", swrHub.ownerVersion("main", "transmit"),
)!;
swrTx = swrHub.publish(swrTx, {
  kind: "active", startedAtMs: 2, source: "software",
})!.cursor;
swrTx = swrHub.publish(swrTx, {
  kind: "dekey_required", startedAtMs: 2, source: "software",
})!.cursor;
const afterOff = swrHub.clear(swrTx, 3, {
  kind: "ptt_off_confirmed", generation: swrTx.generation,
})!.event!;
assert.equal(afterOff.kind, "swr_trip_latched");
assert.equal(swrHub.snapshot("main").alert?.kind, "swr_trip_latched");
let rearm = swrHub.beginOwnerGeneration("main", "swr", swr)!;
rearm = swrHub.publish(rearm, {
  kind: "swr_rearm_pending", startedAtMs: 4, source: "software",
}, { kind: "swr_reset_persisted", generation: rearm.generation })!.cursor;
const finalRecovery = swrHub.clear(rearm, 5, {
  kind: "swr_rearm_safe", generation: rearm.generation,
})!.event!;
assert.equal(finalRecovery.kind, "recovered");
```

The same-owner CAS regressions assert both the owner-local cursor and public radio revision remain
unchanged after rejection, rather than merely checking the projected alert:

```ts
test("stale same-owner publish leaves the newer latch and both revisions unchanged", () => {
  const hub = safetyHub("main");
  let tx = hub.beginOwnerGeneration("main", "transmit", hub.ownerVersion("main", "transmit"))!;
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
  let tx = hub.beginOwnerGeneration("main", "transmit", hub.ownerVersion("main", "transmit"))!;
  tx = hub.publish(tx, activeAlert(1))!.cursor;
  const staleClear = hub.publish(tx, dekeyRequiredAlert(2))!.cursor;
  tx = hub.publish(staleClear, dekeyEscalatedAlert(3))!.cursor;
  const beforeVersion = hub.ownerVersion("main", "transmit");
  const beforeSnapshot = hub.snapshot("main");
  assert.equal(hub.clear(staleClear, 4, {
    kind: "ptt_off_confirmed", generation: staleClear.generation,
  }), null);
  assert.deepEqual(hub.ownerVersion("main", "transmit"), beforeVersion);
  assert.deepEqual(hub.snapshot("main"), beforeSnapshot);
});

test("old SWR rearm completion cannot clear a newer trip generation", () => {
  const hub = safetyHub("main");
  let swr = hub.beginOwnerGeneration("main", "swr", hub.ownerVersion("main", "swr"))!;
  swr = hub.publish(swr, swrTripAlert(1))!.cursor;
  let rearm = hub.beginOwnerGeneration("main", "swr", swr)!;
  rearm = hub.publish(rearm, swrRearmAlert(2), {
    kind: "swr_reset_persisted", generation: rearm.generation,
  })!.cursor;
  const oldSafeCompletion = rearm;
  let retrip = hub.beginOwnerGeneration("main", "swr", rearm)!;
  retrip = hub.publish(retrip, swrTripAlert(3))!.cursor;
  const beforeVersion = hub.ownerVersion("main", "swr");
  const beforeSnapshot = hub.snapshot("main");
  assert.equal(hub.clear(oldSafeCompletion, 4, {
    kind: "swr_rearm_safe", generation: oldSafeCompletion.generation,
  }), null);
  assert.deepEqual(hub.ownerVersion("main", "swr"), beforeVersion);
  assert.deepEqual(hub.snapshot("main"), beforeSnapshot);
});

test("out-of-order telemetry completion cannot replace or clear the latest observation", () => {
  const hub = safetyHub("main");
  let oldTick = hub.beginOwnerGeneration("main", "telemetry", hub.ownerVersion("main", "telemetry"))!;
  oldTick = hub.publish(oldTick, telemetryUncertainAlert(1))!.cursor;
  let latestTick = hub.beginOwnerGeneration("main", "telemetry", oldTick)!;
  latestTick = hub.publish(latestTick, externalPttAlert(2))!.cursor;
  const beforeVersion = hub.ownerVersion("main", "telemetry");
  const beforeSnapshot = hub.snapshot("main");
  assert.equal(hub.publish(oldTick, telemetryUncertainAlert(3)), null);
  assert.equal(hub.clear(oldTick, 4, {
    kind: "telemetry_recovered", generation: oldTick.generation,
  }), null);
  assert.deepEqual(hub.ownerVersion("main", "telemetry"), beforeVersion);
  assert.deepEqual(hub.snapshot("main"), beforeSnapshot);
});
```

- [ ] **Step 2: Run the red tests**

Run: `node --experimental-strip-types --test --test-name-pattern="automatic stop reports|recoveryPending|digital stop reports|snapshot clear|configured radio|subscription flushes|late telemetry clear|lower severity telemetry|OFF recovery reveals|stale same-owner publish|stale same-owner clear|old SWR rearm completion|out-of-order telemetry completion" radio-lite-server/test/safety-event-hub.test.ts radio-lite-server/test/media-hub.test.ts radio-lite-server/test/digital-controller.test.ts`

Expected: FAIL because the media callback returns `void`, `SafetyEventHub` and its owner-cursor CAS are absent, and controller suppresses `InvalidLeaseError`.

- [ ] **Step 3: Implement explicit outcome propagation**

Implement a process-random `safetyEpoch`, per-radio monotonic public revision, and three independent slots keyed by `SafetyAlertOwner`. Each slot stores `{ generation, ownerRevision, alert }`. `ownerVersion` is read-only. `beginOwnerGeneration` is an exact `{ generation, ownerRevision }` CAS: on success it increments only that slot's generation, preserves its alert and both revisions, and returns the Hub-issued cursor; on mismatch it returns `null` without mutation. `publish` and `clear` require an exact current cursor. Every accepted slot mutation increments `ownerRevision` and returns `SafetyMutation`, even when a higher-priority owner masks it and `event` is `null`; a stale generation/revision returns `null` and changes neither the slot nor public radio revision. This return shape makes an accepted masked mutation distinguishable from rejected stale work.

Enforce owner-specific transitions after the cursor check. Transmit permits only same-kind refresh or `empty -> active -> dekey_required -> dekey_escalated`; clearing any transmit state requires `ptt_off_confirmed` whose generation equals the current transmit cursor, so an old OFF completion cannot clear a newer latch. SWR permits `empty -> swr_trip_latched`, same-kind refresh, `swr_trip_latched -> swr_rearm_pending` only in a newer generation with matching `swr_reset_persisted` proof, and `swr_rearm_pending -> swr_trip_latched` as a same- or newer-generation safety upgrade. Only an exact-current `swr_rearm_safe` completion may clear `swr_rearm_pending`; it may never clear `swr_trip_latched`. Telemetry permits `empty -> telemetry_uncertain | external_ptt`, same-kind refresh, and `telemetry_uncertain -> external_ptt`; a fresh observation may clear only through exact-current `telemetry_recovered`. `external_ptt -> telemetry_uncertain`, every transmit downgrade, and every other unlisted transition are rejected without consuming either revision. Starting a newer generation never clears or downgrades the existing alert by itself.

Project the effective alert by the fixed order `dekey_escalated > dekey_required > swr_trip_latched > swr_rearm_pending > active > external_ptt > telemetry_uncertain`. Only an accepted slot mutation that changes this projection consumes the public radio revision and emits an event. Clearing one owner either reveals the next effective owner alert or emits exact `recovered` with stored `alert:null` when all three slots are empty. Thus OFF confirmation can clear the transmit de-key slot and reveal the still-latched SWR alert instead of falsely emitting recovered. `subscribeControl` must atomically register the listener before capturing the complete configured-radio snapshot set; enqueue `safety.snapshot.begin`, one `SafetyAlertSnapshot` for every ID returned by `configuredRadioIds()` (revision 0 and `alert:null` when never published), and `safety.snapshot.end`, then flush only buffered same-epoch events whose revision is greater than that radio's own captured snapshot revision.

In `MediaHub`, retain the binding until callback resolution, call `#notifyStopFailure` for every outcome except `offConfirmed`, and make `revokeOwner` asynchronous so it requests a stop instead of only deleting tokens. In the controller, report every unconfirmed dekey and stop its worker; it may only suppress an error after receiving `offConfirmed` or `recoveryPending` from its runtime adapter. `InvalidLeaseError` is never OFF evidence: the runtime/interlock latch remains authoritative after the caller token expires.

- [ ] **Step 4: Run focused green suites**

Run: `node --experimental-strip-types --test --test-name-pattern="media|digital|snapshot clear|configured radio|subscription flushes|late telemetry clear|lower severity telemetry|OFF recovery reveals|stale same-owner publish|stale same-owner clear|old SWR rearm completion|out-of-order telemetry completion" radio-lite-server/test/safety-event-hub.test.ts radio-lite-server/test/media-hub.test.ts radio-lite-server/test/digital-controller.test.ts`

Expected: PASS; an automatic stop has an explicit outcome, failures reach `ptt_stop_failed`, and rejected stale owner work changes no slot or revision.

- [ ] **Step 5: Commit the task**

```bash
git add radio-lite-server/src/safety/safety-event-hub.ts radio-lite-server/src/media/media-hub.ts radio-lite-server/src/digital/controller.ts radio-lite-server/test/safety-event-hub.test.ts radio-lite-server/test/media-hub.test.ts radio-lite-server/test/digital-controller.test.ts
git commit -m "feat: publish safety state and propagate dekey outcomes"
```

### Task 4: Managed rigctld exit observation and supervisor ownership

**Files:**
- Create: `radio-lite-server/src/rig/runtime-supervisor.ts`
- Modify: `radio-lite-server/src/rig/managed-process.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/test/managed-process.test.ts`
- Create: `radio-lite-server/test/runtime-supervisor.test.ts`

**Interfaces:** Consumes Tasks 2–3 latch/event contracts. Produces `RigRuntimeSupervisor`, the independent transmit-start permit API frozen above, and `ManagedRigctldProcessOptions.onUnexpectedExit?: (exit: ManagedRigctldExit) => void`; later tasks use supervisor transport replacement, recovery generation, and admission invalidation.

- [ ] **Step 1: Write failing supervisor tests**

Add exact tests `"unexpected managed rigctld exit starts one recovery generation"`, `"stale recovery readback cannot clear a newer latch"`, `"supervisor publishes active dekey and recovered revisions"`, `"InvalidLease after expiry leaves supervisor dekey retry latched"`, `"dekey recovery escalates after thirty seconds and continues retries"`, `"invalidated transmit permit cannot commit"`, `"invalidation during CAT activation never returns a lease and runs OFF recovery"`, and `"managed close exit never restarts rigctld"`.

```ts
process.emitExit({ generation: 1, expected: false });
process.emitExit({ generation: 1, expected: false });
assert.equal(factory.startCalls, 1);
await staleAttempt.resolve({ confirmed: true, generation: 1 });
assert.equal(supervisor.snapshot().dekeyRequired, true);
await fixture.expireTransmitLeaseWhilePttRemainsOn();
assert.equal((await fixture.stopWithExpiredToken()).kind, "recoveryPending");
assert.equal(supervisor.snapshot().dekeyRequired, true);
assert.equal(fixture.recoveryAttemptCount > 0, true);
clock.advance(30_000);
await supervisor.runDueRecovery();
assert.equal(events.at(-1)?.kind, "dekey_escalated");
assert.equal(factory.offAttempts > 1, true);

const permit = await supervisor.reserveTransmitStart(startReservation({ ownerId: "owner-a" }));
supervisor.invalidateTransmitStarts("owner_disconnected");
await assert.rejects(
  supervisor.commitTransmitStart(permit, async () => undefined),
  /transmit_start_invalidated/u,
);
assert.equal(factory.pttOnAttempts, 0);

const activating = activationBarrierFixture();
const activePermit = await activating.supervisor.reserveTransmitStart(activating.reservation);
const pendingCommit = activating.supervisor.commitTransmitStart(activePermit, async () => undefined);
await activating.pttOnWriteStarted;
activating.supervisor.invalidateTransmitStarts("emergency_stop");
const emergency = activating.supervisor.emergencyStop("emergency_stop");
activating.finishLatePttOnWrite();
await activating.finishOffWriteAndReadback(false);
await assert.rejects(pendingCommit, /transmit_start_invalidated/u);
assert.equal((await emergency).kind, "offConfirmed");
assert.equal(activating.supervisor.snapshot().lease, null);
assert.equal(activating.pttOffCalls > 0, true);
```

- [ ] **Step 2: Run red tests**

Run: `node --experimental-strip-types --test --test-name-pattern="unexpected managed rigctld|stale recovery|active dekey and recovered|InvalidLease after expiry|dekey recovery escalates|invalidated transmit permit|invalidation during CAT activation|managed close exit" radio-lite-server/test/*.test.ts`

Expected: FAIL because the managed process has no exit observer, no supervisor/recovery generation, no referenced 30-second escalation timer, and no continuing retry loop.

- [ ] **Step 3: Implement supervisor ownership**

Attach a permanent child `exit` listener in `ManagedRigctldProcess`; tag each start generation and mark active `close()` expected before signaling. In `RigRuntimeSupervisor`, serialize all recovery triggers under one `recoveryGeneration`, set the interlock latch immediately if transmitting, schedule first attempt immediately then capped-at-2s backoff, reject delayed callbacks whose generation differs, and stop scheduling after `close()`. Keep `transmitAdmissionGeneration` entirely separate from recovery. `reserveTransmitStart` admits at most one exact permit for the current generation; `invalidateTransmitStarts` synchronously increments the generation and drops the pending permit without waiting for CAT, audit, or cleanup. `commitTransmitStart` is the supervisor's only activation entry point, runs in the same per-radio safety transaction as its private PTT-ON operation, checks exact permit/generation before and after every awaited revalidation, and abandons rather than keys on any mismatch. There is no public direct `start` or `activate` bypass. `RadioRuntime.startTransmit` is the only production coordinator used by service, voice, digital, and tuning callers; its tests inject the intent-admission dependency, and Security Task 8 replaces that seam with mandatory durable audit between reserve and commit. A deployment-drain adapter is another strict consumer: it synchronously calls `invalidateTransmitStarts("deployment")` before its first snapshot, audit, cleanup, or OFF-proof await, so a late audit completion cannot commit or key after drain begins. If invalidation occurs while activation is already awaiting CAT, commit cannot return a lease and must immediately enter normal OFF/readback recovery.

At admission, claim one Hub transmit-owner generation from an exact `ownerVersion`, publish `active`, and retain the returned cursor for the entire active/de-key episode. Every `dekey_required`/`dekey_escalated` publish consumes the last returned cursor and stores the replacement cursor; retries never reconstruct a cursor from a snapshot. Clear only with that exact cursor and a `ptt_off_confirmed` proof carrying the same safety generation after same-transaction OFF readback atomically clears latch/fault. A delayed attempt with an older recovery generation or Hub cursor returns `null` and cannot clear or rewrite a newer latch. An expired/invalid caller lease changes only the caller outcome to `recoveryPending`; it cannot cancel the retry generation, clear the latch/fault/alert, or count as OFF evidence. Keep the recovery timer referenced. Once `dekeyStartedAtMs` is 30,000 ms old, publish exactly one transmit-owner `dekey_escalated` event with the field shutdown/power instruction, but continue the same retry schedule until OFF readback. `RadioRuntime.initialize()` delegates only to `supervisor.startupObserve()`.

- [ ] **Step 4: Run focused green suites**

Run: `node --experimental-strip-types --test --test-name-pattern="managed rigctld|unexpected managed rigctld|stale recovery|active dekey and recovered|InvalidLease after expiry|dekey recovery escalates|invalidated transmit permit|invalidation during CAT activation|managed close exit|startup observation" radio-lite-server/test/*.test.ts`

Expected: PASS; exactly one recovery loop exists per radio and normal startup causes no CAT OFF.

- [ ] **Step 5: Commit the task**

```bash
git add radio-lite-server/src/rig/runtime-supervisor.ts radio-lite-server/src/rig/managed-process.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/test/managed-process.test.ts radio-lite-server/test/runtime-supervisor.test.ts
git commit -m "feat: supervise managed rigctld recovery"
```

### Task 5: CAT safety priority and bounded normal FIFO

**Files:**
- Modify: `radio-lite-server/src/rig/transport.ts`
- Modify: `radio-lite-server/test/rigctld-transport.test.ts`

**Interfaces:** Consumes Task 4 supervisor request calls. Produces Task 6 sampler-compatible `RigRequestSource`, `RigCommandTrace`, `RigQueueBusyError`, `RigTelemetryDroppedError`, and the Dependency Interfaces `request(command: string, options?: RigRequestOptions): Promise<RigResponse>` signature. Omitted options preserve existing calls and mean normal-priority `source: "control"` with the normal default timeout; explicit `timeoutMs` remains supported. A full normal queue rejects explicit control with `RigQueueBusyError` and telemetry with `RigTelemetryDroppedError`, which the sampler treats as a coalesced/dropped refresh.

- [ ] **Step 1: Write failing transport-order tests**

Add exact tests `"safety OFF runs before queued telemetry while preserving normal FIFO"`, `"a stuck ordinary command destroys the socket after 250 ms before recovery OFF"`, and `"normal queue rejects explicit control at 32 entries and drops telemetry"`.

```ts
const ordinary = transport.request("\\get_freq", { source: "telemetry" });
const queued = transport.request("\\get_mode", { source: "telemetry" });
const off = transport.request("\\set_ptt 0", { priority: "safety", source: "ptt-off" });
fake.replyActive();
await fake.waitForWrite("\\set_ptt 0\n");
await ordinary;
assert.equal(fake.writes.at(-1), "\\set_ptt 0\n");
fake.replyActive(); await off;
await fake.waitForWrite("\\get_mode\n");
fake.replyActive(); await queued;

const blocker = transport.request("\\get_freq", { source: "telemetry" });
const queuedControls = Array.from({ length: 32 }, (_, index) =>
  transport.request(`\\set_freq ${7_074_000 + index}`, { source: "control" }).catch(() => undefined));
await assert.rejects(
  transport.request("\\set_freq 14074000", { source: "control" }), RigQueueBusyError);
await assert.rejects(
  transport.request("\\get_mode", { source: "telemetry" }), RigTelemetryDroppedError);
const blockerRejected = assert.rejects(blocker);
await transport.close();
await blockerRejected;
await Promise.all(queuedControls);
```

Extend the local fake transport with `replyActive()` and
`waitForWrite(expected): Promise<void>`. `waitForWrite` resolves only after the socket write callback
has observed the exact command, so the priority assertion cannot race a Promise continuation. Every
request Promise created by these tests is awaited or explicitly caught before teardown.

- [ ] **Step 2: Run red tests**

Run: `node --experimental-strip-types --test --test-name-pattern="safety OFF runs|stuck ordinary|normal queue rejects" radio-lite-server/test/*.test.ts`

Expected: FAIL because `request` has one promise tail, no priority/options, no 32-entry normal queue, and no trace.

- [ ] **Step 3: Implement the two FIFOs**

Replace `#tail` with `#safetyQueue`, `#normalQueue`, and exactly one active command. Choose safety first only between commands; never claim preemption. Normal telemetry over capacity rejects with `RigTelemetryDroppedError("rig_telemetry_dropped")`, explicit normal control throws `RigQueueBusyError("rig_queue_busy")`, and safety is unbounded. Assign 1,000 ms default timeout to safety, 10,000 ms normal; record `{ command, source, priority, startedAtMs, finishedAtMs }`. When safety has waited 250 ms behind a normal in-flight command, destroy the socket so the supervisor reconnects and sends safety first. `close()` rejects the active request and every queued Promise exactly once before resolving.

- [ ] **Step 4: Run focused green suite**

Run: `node --experimental-strip-types --test --test-name-pattern="persistent rigctld|safety OFF runs|stuck ordinary|normal queue rejects" radio-lite-server/test/*.test.ts`

Expected: PASS; safety passes queued normal work, ordinary FIFO ordering remains stable, and safety never pretends to interrupt the active command.

- [ ] **Step 5: Commit the task**

```bash
git add radio-lite-server/src/rig/transport.ts radio-lite-server/test/rigctld-transport.test.ts
git commit -m "feat: prioritize CAT safety commands"
```

### Task 6: Telemetry sampler, external PTT, and CAT budget

**Files:**
- Create: `radio-lite-server/src/rig/telemetry-sampler.ts`
- Modify: `radio-lite-server/src/rig/hamlib-rig.ts`
- Modify: `radio-lite-server/src/rig/runtime-supervisor.ts`
- Create: `radio-lite-server/test/telemetry-sampler.test.ts`
- Modify: `radio-lite-server/test/radio-runtime.test.ts`

**Interfaces:** Consumes Task 5 priority requests/traces and Task 3 event hub. Produces `RigTelemetrySampler.snapshot(maxAgeMs)`, `frequencyForTransmitAdmission(maxAgeMs)`, and `RigTelemetrySnapshot` for Task 7.

- [ ] **Step 1: Write failing sampler tests**

Add exact tests `"idle telemetry reports external PTT without sending OFF"`, `"external PTT ON to OFF emits exact recovered wire event without CAT OFF"`, `"telemetry recovery cannot clear a concurrent runtime dekey"`, `"multiple state readers share one stale refresh"`, and `"ten-second CAT budgets stay within idle two per second and transmitting four per second"`.

```ts
await sampler.tick();
assert.deepEqual(fake.commands, ["\\get_freq", "\\get_mode", "\\get_ptt"]);
assert.equal(fake.commands.includes("\\set_ptt 0"), false);
fake.ptt = false;
await sampler.tickPtt();
assert.deepEqual(events.at(-1), {
  t: "safety.event", safetyEpoch: hub.safetyEpoch, radioId: "main",
  revision: 2, kind: "recovered", startedAtMs: now, source: "external",
});
assert.equal(fake.commands.includes("\\set_ptt 0"), false);
await Promise.all([sampler.snapshot(0), sampler.snapshot(0), sampler.snapshot(0)]);
assert.equal(fake.count("\\get_freq"), 2);
```

- [ ] **Step 2: Run red tests**

Run: `node --experimental-strip-types --test --test-name-pattern="external PTT|ON to OFF|telemetry recovery cannot clear|share one stale refresh|ten-second CAT budgets" radio-lite-server/test/*.test.ts`

Expected: FAIL because no sampler/cache exists and `RadioRuntime.readState()` directly multiplies CAT requests per caller.

- [ ] **Step 3: Implement targeted reads and sampler**

Expose `HamlibRig.readPtt()`, `readFrequency()`, and optional `readSwr()`; malformed/unavailable real-rig PTT remains uncertainty. Sampler runs full frequency/mode/PTT sample every two seconds, PTT-only between them, and SWR near 1 Hz only while transmitting and supported. It sends telemetry normal-priority and coalesces refreshes. Before dispatching each logical refresh, it begins one telemetry-owner generation by exact `ownerVersion`; every completion publishes `external_ptt`/`telemetry_uncertain` or clears with `telemetry_recovered` through that cursor, and stores the returned cursor only after an accepted mutation. A completion from an older refresh generation or owner revision is a rejected no-op, so it cannot replace or clear the latest observation; a telemetry recovery also cannot clear a concurrent transmit-owner de-key or SWR-owner trip alert and emits recovered only when all owner slots are empty. It does not send OFF unless its supervisor has a latch. Use transport trace in tests to enforce rolling 10-second limits.

- [ ] **Step 4: Run focused green suite**

Run: `node --experimental-strip-types --test --test-name-pattern="external PTT|ON to OFF|telemetry recovery cannot clear|share one stale refresh|ten-second CAT budgets|real rigs" radio-lite-server/test/*.test.ts`

Expected: PASS; cached state prevents subscriber multiplication and external PTT remains observational.

- [ ] **Step 5: Commit the task**

```bash
git add radio-lite-server/src/rig/telemetry-sampler.ts radio-lite-server/src/rig/hamlib-rig.ts radio-lite-server/src/rig/runtime-supervisor.ts radio-lite-server/test/telemetry-sampler.test.ts radio-lite-server/test/radio-runtime.test.ts
git commit -m "feat: sample rig telemetry within CAT budget"
```

### Task 7: Frequency-range and SWR transmit admission

**Files:**
- Create: `radio-lite-server/src/safety/swr-safety-store.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/src/rig/runtime-supervisor.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/test/radio-runtime.test.ts`
- Modify: `radio-lite-server/test/http-service.test.ts`
- Create: `radio-lite-server/test/swr-safety-store.test.ts`

**Interfaces:** Consumes Task 6 `frequencyForTransmitAdmission` and Security Plan Task 1's parsed `RadioProfile.allowedTransmitRangesHz: readonly { lowerHz: number; upperHz: number }[]` and SWR policy fields. Produces runtime admission plus administrator-only `POST /api/v1/radios/:radioId/swr-trip/reset` with body `{ acknowledgePhysicalInspection: true }`, persistent safety kinds `swr_trip_latched`/`swr_rearm_pending`, stored states `armed | latched | rearm_pending | rearm_in_progress`, and health capability `swrTripReset: true`; Security Plan Task 1 owns `src/config/types.ts` and `test/config.test.ts`, while Security Task 9 freezes the seven-flag health envelope and public protocol.

- [ ] **Step 1: Write failing runtime admission tests**

Add `"fresh in-range frequency starts without an extra CAT read"`, `"unknown or out-of-range frequency leaves PTT off"`, `"cold require SWR start acquires its first live reading without a seeded cache"`, `"missing first live SWR reading dekeys within one second"`, `"SWR trip stays locked through OFF until explicit reset and safe rearm"`, `"pre-TX armed marker closes the trip persistence crash window"`, `"safe rearm retains an armed marker until confirmed OFF"`, `"retrip after safe rearm survives restart as latched"`, `"SWR trip survives process restart and rearm remains single use"`, `"crash marker normalization permits one administrator rearm"`, `"concurrent radio SWR updates preserve both records after reopen"`, `"SWR reset HTTP requires exact administrator acknowledgement"`, `"SWR reset rejects unsafe PTT dekey and fence states"`, `"SWR reset success enters rearm pending without clearing the alert"`, `"corrupt or unreadable SWR store poisons transmit admission"`, `"SWR store mutation failure stays fail closed"`, `"SWR persistence failure while PTT is on immediately dekeys"`, `"audit plus SWR persistence respects the total start-admission deadline"`, `"dekey recovery reveals SWR latch instead of recovered"`, and `"require SWR runtime loss dekeys after a passed preflight"`. Security Plan Task 1 already tests schema rejection and legacy migration.

```ts
await assert.rejects(runtime.startTransmit("owner", user, token, "voice"), /tx_safety_config_required/u);
sampler.seed({ frequencyHz: 7_074_000, observedAtMs: now });
await runtime.startTransmit("owner", user, token, "voice");
assert.equal(fake.count("\\get_freq"), 0);
await runtime.startTransmit("owner", user, token, "digital");
assert.equal(runtime.snapshot().swrState, "acquiring");
sampler.resolveLiveSwr(1.4);
await fixture.firstSwrDecision;
assert.equal(runtime.snapshot().swrState, "monitoring");
sampler.failNextSwr(new Error("SWR unavailable"));
await sampler.tickTransmitSafety();
assert.equal(supervisor.snapshot().dekeyRequired, true);
assert.equal(fake.ptt, false);

await assert.rejects(runtime.startTransmit("owner", user, token, "digital"), /swr_trip_latched/u);
await resetSwrTrip("main", admin, { acknowledgePhysicalInspection: true });
await runtime.startTransmit("owner", user, token, "digital");
sampler.resolveLiveSwr(1.8); // configured reset is 2.0
await fixture.firstSwrDecision;
assert.equal(runtime.snapshot().swrTripLatched, false);

const crash = swrCrashBarrierFixture();
const startBeforeCrash = crash.runtime.startTransmit("owner", user, token, "digital");
await crash.store.armedMarkerDurable;
crash.allowPttOn();
await crash.highSwrObserved;
crash.simulateProcessCrashBeforeLatchedRewrite();
const restarted = await crash.reopenRuntime();
await assert.rejects(restarted.startTransmit("owner", user, token, "digital"), /swr_trip_latched/u);
await assert.rejects(startBeforeCrash, /simulated crash/u);

const rearm = swrRearmBarrierFixture();
await rearm.resetTripAsAdmin();
const rearmStart = rearm.runtime.startTransmit("owner", user, token, "digital");
rearm.resolveLiveSwr(1.8);
await rearm.firstSafeSample;
assert.equal((await rearm.store.read("main"))?.state, "armed");
rearm.simulateProcessCrashWhilePttOn();
const restartedRearm = await rearm.reopenRuntime();
await assert.rejects(restartedRearm.startTransmit("owner", user, token, "digital"), /swr_trip_latched/u);
await assert.rejects(rearmStart, /simulated crash/u);

const cleanRearm = swrRearmBarrierFixture();
await cleanRearm.resetTripAsAdmin();
await cleanRearm.runtime.startTransmit("owner", user, token, "digital");
cleanRearm.resolveLiveSwr(1.8);
await cleanRearm.firstSafeSample;
assert.equal((await cleanRearm.store.read("main"))?.state, "armed");
await cleanRearm.stopWithConfirmedRealPttOff();
assert.equal(await cleanRearm.store.read("main"), null);

const retrip = swrRearmBarrierFixture();
await retrip.resetTripAsAdmin();
await retrip.runtime.startTransmit("owner", user, token, "digital");
retrip.resolveLiveSwr(1.8);
await retrip.firstSafeSample;
assert.equal((await retrip.store.read("main"))?.state, "armed");
retrip.observeHighSwrAndCrashBeforeLatchedRewrite();
const restartedRetrip = await retrip.reopenRuntime();
await assert.rejects(restartedRetrip.startTransmit("owner", user, token, "digital"), /swr_trip_latched/u);

test("crash marker normalization permits one administrator rearm", async () => {
  for (const persistedState of ["armed", "rearm_in_progress"] as const) {
    const restarted = await swrRestartFixture({
      persistedState, pttReadback: false,
    }).openRuntime();
    assert.equal((await restarted.store.read("main"))?.state, "latched");
    assert.equal(restarted.safety.snapshot("main").alert?.kind, "swr_trip_latched");
    assert.equal((await restarted.resetAsAdmin({
      acknowledgePhysicalInspection: true,
    })).status, 200);
    assert.equal((await restarted.store.read("main"))?.state, "rearm_pending");
    const first = restarted.startRearmAtBarrier();
    await restarted.rearmInProgressDurable;
    assert.equal((await restarted.store.read("main"))?.state, "rearm_in_progress");
    await assert.rejects(restarted.startTransmit(), /rearm|transmit.*active/u);
    restarted.abortBarrier();
    await assert.rejects(first, /aborted/u);
  }
});

const multi = swrStoreFixture();
await Promise.all([
  multi.store.write({ radioId: "main", state: "armed", trippedAtMs: null }),
  multi.store.write({ radioId: "backup", state: "latched", trippedAtMs: 42 }),
]);
const reopenedMulti = await multi.reopenStore();
assert.deepEqual(await reopenedMulti.readAll(), [
  { radioId: "backup", state: "latched", trippedAtMs: 42 },
  { radioId: "main", state: "armed", trippedAtMs: null },
]);

test("SWR reset HTTP requires exact administrator acknowledgement", async () => {
  const reset = swrResetFixture({ pttReadback: false, storedState: "latched" });
  for (const body of [undefined, {}, { acknowledgePhysicalInspection: false },
    { acknowledgePhysicalInspection: true, unexpected: true }]) {
    const reply = await reset.rawPost(admin, body);
    assert.equal(reply.status, 400);
    assert.equal(reply.body.error.code, "invalid_request");
  }
  const forbidden = await reset.rawPost(operator, {
    acknowledgePhysicalInspection: true,
  });
  assert.equal(forbidden.status, 403);
  assert.equal((await reset.store.read("main"))?.state, "latched");
});

test("SWR reset rejects unsafe PTT dekey and fence states", async () => {
  for (const unsafe of ["ptt_on", "ptt_unknown", "dekey_required", "fenced"] as const) {
    const reset = swrResetFixture({ unsafe, storedState: "latched" });
    const reply = await reset.postAsAdmin({ acknowledgePhysicalInspection: true });
    assert.equal(reply.status, 409);
    assert.equal((await reset.store.read("main"))?.state, "latched");
    assert.equal(reset.safety.snapshot("main").alert?.kind, "swr_trip_latched");
    assert.equal(reset.rig.setPttCalls, 0);
  }
});

test("SWR reset success enters rearm pending without clearing the alert", async () => {
  const reset = swrResetFixture({ pttReadback: false, storedState: "latched" });
  const reply = await reset.postAsAdmin({ acknowledgePhysicalInspection: true });
  assert.equal(reply.status, 200);
  assert.equal((await reset.store.read("main"))?.state, "rearm_pending");
  assert.equal(reset.safety.snapshot("main").alert?.kind, "swr_rearm_pending");
  assert.notEqual(reset.safety.snapshot("main").alert, null);
});

test("corrupt or unreadable SWR store poisons transmit admission", async () => {
  for (const initialFailure of ["corrupt_json", "read_denied"] as const) {
    const poisoned = await swrStoreFailureFixture({ initialFailure }).openRuntime();
    await assert.rejects(poisoned.startTransmit(), /swr.*unavailable|safety.*uncertain/u);
    assert.equal(poisoned.rig.setPttOnCalls, 0);
  }
});

test("SWR store mutation failure stays fail closed", async () => {
  for (const mutationFailure of [
    "temp_rewrite", "file_fsync", "rename", "directory_fsync", "remove_rewrite",
  ] as const) {
    const failed = swrStoreFailureFixture({ mutationFailure });
    await assert.rejects(failed.persistArmedOrRemove(), /persist|sync|rename/u);
    await assert.rejects(failed.runtime.startTransmit(), /swr.*unavailable|safety.*uncertain/u);
    assert.equal(failed.rig.setPttOnCalls, 0);
  }
});

test("SWR persistence failure while PTT is on immediately dekeys", async () => {
  for (const mutationFailure of ["latched_rewrite", "armed_remove"] as const) {
    const failed = swrStoreFailureFixture({ mutationFailure, pttInitiallyOn: true });
    failed.triggerPersistenceMutation();
    await failed.dekeyConfirmed;
    assert.equal(failed.rig.ptt, false);
    assert.equal(failed.supervisor.snapshot().dekeyRequired, false);
    await assert.rejects(failed.runtime.startTransmit(), /swr.*unavailable|safety.*uncertain/u);
  }
});
```

- [ ] **Step 2: Run red tests**

Run: `node --experimental-strip-types --test --test-name-pattern="fresh in-range|unknown or out-of-range|cold require SWR|missing first live SWR|SWR trip stays locked|armed marker closes|safe rearm retains|retrip after safe rearm|trip survives process restart|crash marker normalization|concurrent radio SWR|SWR reset HTTP|SWR reset rejects unsafe|SWR reset success|corrupt or unreadable SWR|store mutation failure|persistence failure while PTT|audit plus SWR persistence|reveals SWR latch|require SWR runtime loss" radio-lite-server/test/*.test.ts`

Expected: FAIL because sampler-backed activation admission and the separate SWR lock do not exist.

- [ ] **Step 3: Implement normalized profile and serial admission**

Inside the same per-radio safety serialization used by activation, reject absent/older-than-2s/failed/outside `allowedTransmitRangesHz` frequency before activation; invalidate sampler frequency on `setFrequency` and refresh after confirmed write. A read-only preflight can prove SWR meter capability but cannot produce a physical SWR value without RF, so `require_swr` must not demand a seeded pre-TX reading. Admit a cold start only when the meter capability and policy are valid, mark the lease `swrState: "acquiring"`, start a referenced one-second first-reading deadline, and begin media/digital modulation normally; this is an unavoidable bounded live-RF measurement window and the protocol/UI must say so. The first live transmitting sample must be finite and below `trip`; missing, stale, malformed, failed, or `>= trip` immediately latches `swrTripLatched` and enters the same de-key recovery. Continue near-1-Hz live monitoring afterward with the same fail-closed rule.

Confirmed PTT OFF clears `dekeyRequired` and transmit fault but not the independent SWR safety state. `RadioRuntimeRegistry` owns exactly one shared `SwrSafetyStore` for every configured radio. The store keeps plaintext `/configured-data-dir/safety/swr-state.json` entries `{ radioId, state: "armed" | "latched" | "rearm_pending" | "rearm_in_progress", trippedAtMs: number | null }`; every write/remove enters one process-wide FIFO that covers reading the current map, applying the one-radio mutation, temp-file write, file fsync, atomic rename, and directory fsync. No per-radio lock or caller-side read/modify/write may bypass that transaction, so concurrent radio changes survive reopen. A cold marker uses null until a trip timestamp exists, and malformed or unreadable state fails closed. Before exposing runtimes or the reset route at startup, that same store FIFO durably normalizes every recovered `armed` or `rearm_in_progress` record to `latched`, preserving `trippedAtMs`; normalization failure poisons the store and leaves all starts/reset fail closed. Thus administrator reset consumes only a durable `latched` record, including after either crash marker, rather than depending on an in-memory reinterpretation. Before every `require_swr` PTT ON, a cold/normal start must durably write `armed` after audit admission and before calling the private activation. A clean normal stop removes `armed` only after confirmed real PTT OFF and no trip; removal failure remains fail-closed. A trip sets the in-memory SWR slot immediately and starts de-key without waiting for the `armed -> latched` rewrite; because `armed` is already durable, a crash during that rewrite still restarts latched. Any persistence failure marks SWR state uncertain and prohibits every later start. The administrator-only reset endpoint requires the literal acknowledgement, synchronously invalidates pending starts, runs a fresh real PTT read in the supervisor safety transaction, and succeeds only for confirmed OFF with no dekey/fence; it must durably write `rearm_pending` before replying and publish SWR-owner `swr_rearm_pending`, rather than claiming a zero-RF SWR measurement. Exactly one monitored rearm start is allowed: before PTT ON it durably changes that state to `rearm_in_progress`; after an interrupted attempt, startup normalizes that marker back to `latched`. Its first live sample must be `<= reset` within one second; otherwise it immediately dekeys and durably restores `latched`. A safe sample durably rewrites `rearm_in_progress -> armed`, then clears the visible SWR-owner alert and resumes the normal `< trip` rule while keeping that `armed` marker for the entire remaining PTT-ON interval. Only a later confirmed real PTT OFF with no intervening trip may durably remove `armed`; a crash before that OFF therefore normalizes to latched on restart. A later trip immediately restores the visible SWR latch and starts de-key without waiting for `armed -> latched`, so a crash during that rewrite also normalizes to latched; any rewrite/removal failure immediately dekeys and remains fail-closed. OFF confirmation clears only the transmit owner, revealing any still-visible SWR alert rather than emitting recovered. `acknowledged_internal_protection` continues to rely on the explicitly selected radio protection and does not use this server meter state.

Mirror every durable SWR episode in one Hub SWR-owner generation. After the reset transaction has durably written `rearm_pending`, begin a newer exact-cursor generation and publish `swr_rearm_pending` with matching `swr_reset_persisted` proof. The monitored attempt retains that returned cursor. A new/high SWR trip first begins a newer generation when it represents a new durable trip episode (or uses the exact current cursor for the in-flight `rearm_pending -> swr_trip_latched` upgrade), publishes the latch, and stores the returned cursor before any safe-completion continuation can run. The safe-rearm continuation clears only with its original exact cursor and matching `swr_rearm_safe` generation; if a trip has advanced either generation or owner revision, the clear returns `null` and the trip plus both revisions remain unchanged. Never reconstruct a SWR cursor from the public snapshot.

Start admission has one configurable monotonic end-to-end deadline, default 500 ms, measured before the durable TX-intent audit and ending immediately before CAT PTT ON. The audit keeps its 250 ms sub-deadline; `require_swr` then spends only the remaining total budget on the atomic `armed`/`rearm_in_progress` transaction. A fake-clock test covers ordinary and rearm starts, injects independent audit/store fsync delays, asserts that PTT ON occurs within the total deadline when both finish in time, and asserts that deadline expiry abandons the exact transmit permit with PTT still OFF. This bounds the additive audit plus temp-file/fsync/rename/directory-fsync cost without merging their recovery semantics.

- [ ] **Step 4: Run focused green suite**

Run: `node --experimental-strip-types --test --test-name-pattern="transmit range|fresh in-range|unknown or out-of-range|cold require SWR|missing first live SWR|SWR trip stays locked|armed marker closes|safe rearm retains|retrip after safe rearm|trip survives process restart|crash marker normalization|concurrent radio SWR|SWR reset HTTP|SWR reset rejects unsafe|SWR reset success|corrupt or unreadable SWR|store mutation failure|persistence failure while PTT|audit plus SWR persistence|reveals SWR latch|require SWR runtime loss" radio-lite-server/test/*.test.ts`

Expected: PASS; normal fresh-cache starts have zero added CAT round trip and unsafe state never keys PTT.

- [ ] **Step 5: Commit the task**

```bash
git add radio-lite-server/src/safety/swr-safety-store.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/src/rig/runtime-supervisor.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/swr-safety-store.test.ts radio-lite-server/test/radio-runtime.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: enforce transmit frequency and SWR safety"
```

### Task 8: Runtime-first service shutdown

**Files:**
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/test/http-service.test.ts`
- Modify: `radio-lite-server/test/radio-runtime.test.ts`

**Interfaces:** Consumes Task 4 `RigRuntimeSupervisor.close()`. Produces service closing guard used by Task 10. `radio-lite-service.ts` changes in this and Task 10 are owned by one designated integrator; no other task edits this file.

- [ ] **Step 1: Write failing close-order tests**

Add exact tests named `"service close invokes runtime close before blocked media close"`, `"closing rejects a new control command while runtime dekey is pending"`, and `"service close invalidates a reserved transmit permit before cleanup awaits"`.

```ts
const closing = service.close();
await runtimeCloseStarted.promise;
assert.equal(mediaCloseStarted.settled, false);
await assert.rejects(sendControl("rig.state.get"), /service_closing/u);
mediaCloseGate.resolve();
await closing;

const permit = await supervisor.reserveTransmitStart(startReservation());
const closeWithPermit = service.close();
await assert.rejects(supervisor.commitTransmitStart(permit, async () => undefined), /transmit_start_invalidated/u);
assert.equal(rig.setPttOnCalls, 0);
await closeWithPermit;
```

- [ ] **Step 2: Run red tests**

Run: `node --experimental-strip-types --test --test-name-pattern="runtime close before blocked media|closing rejects a new control|close invalidates a reserved" radio-lite-server/test/*.test.ts`

Expected: FAIL because `RadioLiteService.close()` terminates sockets and closes digital/media before `#runtimes.close()` and exposes no closing admission guard.

- [ ] **Step 3: Implement close ordering**

Add an idempotent service-level closing promise/flag. At close entry set it and synchronously invalidate every supervisor's transmit-start generation before any asynchronous action; upgrade and control dispatch reject new work. Await `#runtimes.close()` first, then `#digital.close()` and `#media.close()`, then terminate WebSockets and close WS/HTTP listeners, accumulating cleanup failures into `RadioRuntimeCleanupUncertainError`. Keep emergency-stop dispatch eligible until runtime close begins; never let media shutdown or a durable-audit wait block permit invalidation or initial runtime dekey.

- [ ] **Step 4: Run focused green suite**

Run: `node --experimental-strip-types --test --test-name-pattern="shutdown|runtime close before blocked media|closing rejects a new control|close invalidates a reserved" radio-lite-server/test/*.test.ts`

Expected: PASS; runtime shutdown begins before workers/listeners and failures remain aggregated.

- [ ] **Step 5: Commit the task**

```bash
git add radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/test/http-service.test.ts radio-lite-server/test/radio-runtime.test.ts
git commit -m "fix: close radio runtimes before media services"
```

### Task 9: Control/transmit lease separation and voice silence stop

**Files:**
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/src/digital/controller.ts`
- Modify: `radio-lite-server/src/media/media-hub.ts`
- Modify: `radio-lite-server/test/control-lease.test.ts`
- Modify: `radio-lite-server/test/digital-controller.test.ts`
- Modify: `radio-lite-server/test/media-hub.test.ts`

**Interfaces:** Consumes Task 3 `DeKeyOutcome`; produces `heartbeatTransmit(ownerId, transmitToken)` without a control token and media `cancelRadio(radioId, reason): Promise<DeKeyOutcome[]>` for Task 10.

- [ ] **Step 1: Write failing lease/silence tests**

Add exact tests `"transmit heartbeat does not renew control lease"`, `"digital heartbeat cannot retain expired control lease"`, `"two seconds without valid bound audio stops voice transmit"`, and `"continuous valid audio does not stop voice transmit"`.

```ts
runtime.heartbeatTransmit("owner", transmitToken);
now = controlLease.expiresAtMs;
assert.throws(() => runtime.heartbeatControl("owner", controlToken), InvalidControlLeaseError);
await fixture.advance(2_001);
assert.equal(fixture.stops.at(-1)?.reason, "audio_uplink_silent");
```

- [ ] **Step 2: Run red tests**

Run: `node --experimental-strip-types --test --test-name-pattern="does not renew control|cannot retain expired|without valid bound audio|continuous valid audio" radio-lite-server/test/*.test.ts`

Expected: FAIL because `heartbeatTransmit` currently calls `control.heartbeat`, and `MediaHub` has no last-audio watchdog.

- [ ] **Step 3: Implement the split and watchdog**

Remove `controlToken` and `this.control.heartbeat()` from `RadioRuntime.heartbeatTransmit`; update controller call sites. Store `lastValidAudioAtMs` per bound voice transmit; schedule a referenced timer using the configurable default 2,000 ms and replace it after each accepted `audioUplink` frame. On expiry call the Task 3 outcome-aware stop callback once with reason `audio_uplink_silent`; clear timer on dekey, unbind, disconnect, invalidation, and hub close. Implement `cancelRadio` by cancelling voice bindings before runtime emergency recovery.

- [ ] **Step 4: Run focused green suite**

Run: `node --experimental-strip-types --test --test-name-pattern="control lease|digital|audio|microphone" radio-lite-server/test/*.test.ts`

Expected: PASS; only a true `control.heartbeat` extends control authority and audio silence stops active voice even when control traffic continues.

- [ ] **Step 5: Commit the task**

```bash
git add radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/src/digital/controller.ts radio-lite-server/src/media/media-hub.ts radio-lite-server/test/control-lease.test.ts radio-lite-server/test/digital-controller.test.ts radio-lite-server/test/media-hub.test.ts
git commit -m "fix: separate control leases from transmit heartbeats"
```

### Task 10: WS Origin, liveness, safety snapshots, and emergency stop

**Files:**
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/src/digital/hub.ts`
- Create: `radio-lite-server/test/ws-safety.test.ts`
- Modify: `radio-lite-server/test/http-service.test.ts`

**Interfaces:** Consumes Tasks 3, 4, 8, and 9 plus Security Plan Task 5's shared `SourceAddressResolver` and Task 7's authentication/revocation boundary. Produces the slice-4 WS Origin/liveness/safety-stream/emergency-stop contract after Security Tasks 2–8 are complete. The designated service integrator owns all `radio-lite-service.ts` edits in this plan.

- [ ] **Step 1: Write failing WS/emergency tests**

Add exact tests `"cookie WS upgrade rejects missing or foreign Origin"`, `"origin-less device WS authenticates within fifteen seconds"`, `"untrusted X-Forwarded-For cannot split a direct peer WS budget"`, `"trusted proxy clients receive independent WS source budgets"`, `"IPv4 and mapped IPv6 aliases share one WS source budget"`, `"trusted malformed forwarded source is rejected before upgrade"`, `"two missed ping rounds close the socket and reject pending commands"`, `"safety snapshot buffers a concurrent event after snapshot end"`, `"authenticated snapshot includes null state for never-alerted backup"`, `"emergency stop targets only the requested backup radio"`, `"emergency stop invalidates pending transmit admission before cleanup awaits"`, and `"emergency stop reaches runtime dekey when digital or media cleanup throws"`.

```ts
const denied = await connectWs({ Cookie: cookie });
assert.equal(denied.closeCode, 4403);
const stop = await sendJsonAndReceive(ws, { t: "tx.emergency-stop", radioId: "backup", commandId: "e2" });
assert.deepEqual(stop, { t: "tx.emergency-stop.accepted", radioId: "backup", commandId: "e2" });
assert.deepEqual(fixture.callsFor("backup"), { runtime: 1, digital: 1, media: 1 });
assert.deepEqual(fixture.callsFor("main"), { runtime: 0, digital: 0, media: 0 });

for (const failure of ["digital", "media"] as const) {
  const failedCleanup = twoRadioEmergencyFixture({ rejectCleanup: failure });
  await failedCleanup.send({ t: "tx.emergency-stop", radioId: "backup", commandId: failure });
  assert.equal(failedCleanup.runtimeCalls("backup"), 1);
  assert.equal(failedCleanup.runtimeCalls("main"), 0);
}

const sources = wsSourceBudgetFixture({
  trustedProxyCidrs: ["10.0.0.0/8"], maximumPendingPerSource: 1,
});
await sources.openPending({ socketPeerAddress: "10.0.0.4", xForwardedFor: "198.51.100.41" });
assert.equal((await sources.tryOpenPending({
  socketPeerAddress: "10.0.0.4", xForwardedFor: "198.51.100.41",
})).accepted, false);
assert.equal((await sources.tryOpenPending({
  socketPeerAddress: "10.0.0.4", xForwardedFor: "198.51.100.42",
})).accepted, true);

const aliases = wsSourceBudgetFixture({
  trustedProxyCidrs: ["10.0.0.0/8"], maximumPendingPerSource: 1,
});
await aliases.openPending({
  socketPeerAddress: "10.0.0.4", xForwardedFor: "192.0.2.9",
});
assert.equal((await aliases.tryOpenPending({
  socketPeerAddress: "::ffff:10.0.0.4", xForwardedFor: "::ffff:192.0.2.9",
})).accepted, false);
```

```ts
assert.deepEqual(messages.slice(0, 5).map((value) => value.t), [
  "safety.snapshot.begin", "safety.snapshot", "safety.snapshot",
  "safety.snapshot.end", "safety.event",
]);
assert.equal(messages[4].revision > messages[1].revision, true);
assert.deepEqual(messages.find((value) => value.t === "safety.snapshot" && value.radioId === "backup"), {
  t: "safety.snapshot", safetyEpoch: expectedEpoch,
  radioId: "backup", revision: 0, alert: null,
});
```

- [ ] **Step 2: Run red tests**

Run: `node --experimental-strip-types --test --test-name-pattern="cookie WS upgrade|origin-less device|untrusted X-Forwarded-For|trusted proxy clients receive independent WS|mapped IPv6 aliases share one WS|trusted malformed forwarded|two missed ping|safety snapshot buffers|never-alerted backup|targets only the requested backup|invalidates pending transmit|reaches runtime dekey" radio-lite-server/test/*.test.ts`

Expected: FAIL because upgrades skip Origin validation, auth timeout is 300,000 ms, there is no trusted-source/global connection budget, heartbeat/pending rejection, snapshot stream, or `tx.emergency-stop` dispatch.

- [ ] **Step 3: Implement one per-socket safety lifecycle**

Before `handleUpgrade`, apply `validateOrigin` to cookie-bearing browser requests; allow origin-less no-cookie device handshakes. Invoke Security Task 5's configured `SourceAddressResolver` exactly once from the TCP socket peer plus raw forwarding-header inputs, and give only its canonical result to global/per-source pending and active connection budgets, the authenticated socket context, and later audit `sourceAddress`; `radio-lite-service.ts` must never interpret, split, fall back to, or directly trust `Forwarded`/`X-Forwarded-For`. With no trusted-proxy CIDR match, differently spoofed headers from one peer therefore share one source budget; with a matching trusted peer, two canonical forwarded client IPs receive independent source budgets rather than collapsing back to the proxy peer. A trusted-peer malformed/ambiguous forwarded value rejects before budget allocation and `handleUpgrade`, rather than falling back to either the peer or attacker text. Then start a referenced 15,000-ms auth deadline. Send WS ping every 15,000 ms, count missing pong responses, close after two misses, and reject/clear each pending command callback. On authenticated control connection and reconnect, wire `SafetyEventHub.subscribeControl` into the socket outbound queue using the registry's complete configured radio ID set, so begin/one snapshot per radio/end precede buffered increments even when backup never had an alert. Security Plan Task 7 supplies all identity/revocation revalidation and its stop-before-close behavior.

Add `tx.emergency-stop` with exact request fields `{ t: "tx.emergency-stop", radioId, commandId }`. After the Security Plan boundary returns an enabled identity, resolve that exact radio from the runtime registry or return `radio_not_found`. Synchronously invalidate that supervisor's transmit-start generation before any cleanup/audit await, then start target runtime de-key and target-only digital/media cancellation as separate async operations under `Promise.allSettled`, with the runtime operation first; wrap every call in an async closure so a synchronous cleanup throw cannot prevent the hardware attempt. A start held at Security Task 8's durable-audit barrier must reject after the barrier releases and must never key or bind media. No `main` fallback is allowed. Record cleanup failures and the runtime `DeKeyOutcome` in safety audit/events, then reply exactly `{ t: "tx.emergency-stop.accepted", radioId, commandId }` as transient dispatch feedback; the reply never asserts physical OFF. Idempotent repeats may add audit attempts but cannot start TX or touch another radio.

- [ ] **Step 4: Run focused green suites**

Run: `node --experimental-strip-types --test --test-name-pattern="cookie WS upgrade|origin-less device|untrusted X-Forwarded-For|trusted proxy clients receive independent WS|mapped IPv6 aliases share one WS|trusted malformed forwarded|two missed ping|safety snapshot buffers|never-alerted backup|targets only the requested backup|invalidates pending transmit|reaches runtime dekey|voice PTT" radio-lite-server/test/*.test.ts`

Expected: PASS; liveness closure is bounded to two intervals, snapshots are atomic and complete for all configured radios, and cleanup faults cannot block exact-radio emergency de-key.

- [ ] **Step 5: Commit the task**

```bash
git add radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/src/digital/hub.ts radio-lite-server/test/ws-safety.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: harden control websocket safety"
```

## Final Verification and Review Gates

- [ ] **Step 1: Run all server tests and type checks**

Run: `npm --prefix radio-lite-server run check`

Expected: PASS with `tsc --noEmit` followed by every `test/*.test.ts` case.

- [ ] **Step 2: Run exact safety regression set**

Run: `node --experimental-strip-types --test --test-name-pattern="dekey|recovery|external PTT|CAT budget|SWR|stale same-owner|out-of-order telemetry|audio|emergency|WS upgrade|ping|shutdown" radio-lite-server/test/*.test.ts`

Expected: PASS; no test observes startup OFF, a latch clear without physical OFF evidence, stale owner work changing either revision, duplicate supervisor recovery, or a WS emergency-stop authorization failure due to a missing lease.

- [ ] **Step 3: Review invariants before integration**

Verify by inspection: only `RigRuntimeSupervisor` schedules retry/restart; only `SafetyEventHub` owns persistent alert revisions; all timers performing safety work are referenced; `RadioLiteService.close` starts runtime closure first; every `radio-lite-service.ts` hunk was authored/reviewed by the designated integrator.

- [ ] **Step 4: Confirm the plan ends at a clean task boundary**

Run: `git status --short`

Expected: no uncommitted production or test changes after Tasks 1–10. If verification required a code adjustment, return to the owning task, add a failing regression first, rerun its green command, and commit the explicit files there; do not create a catch-all verification commit, release, IPA, or deployment from this plan.
