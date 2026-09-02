# Radio Lite Security and Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Radio Lite's configuration, authentication, WebSocket, audit, and hardware-preflight boundaries fail closed while preserving Dummy and explicitly permitted HTTP/Tailscale deployment.

**Architecture:** Extend the canonical radio profile with transmit-range and SWR-policy fields, then bind a passed, read-only preflight to the administrator and normalized hardware configuration with an in-memory HMAC proof. Build the managed-serial stop-and-preflight flow on Plan 1's per-radio `RigRuntimeSupervisor`, so its reconfiguration fence owns the runtime lifecycle, serial claim, and read-only PTT resume probe. Keep authorization decisions at the server boundary: rate-limit before Argon2, revalidate live credentials before privileged WebSocket commands, de-key before revocation closes sockets, and require durable audit intent before PTT activation.

**Tech Stack:** Node.js 24.7.0, TypeScript 5.9, `node:test`, `ws`, Node `fs/promises`, JSON files, JSONL audit records, HMAC-SHA-256.

**Spec:** `docs/superpowers/specs/2026-08-26-radio-lite-safety-reliability-design.md` (sections 8--12, 17, and implementation slices 5--6)

**Command convention:** Run every command from the repository root. Each focused command below puts its concrete `--test-name-pattern` before explicit files under `radio-lite-server/test`; full checks use `npm --prefix radio-lite-server run typecheck`, `npm --prefix radio-lite-server test`, and `npm --prefix radio-lite-server run check`.

## Global Constraints

- Keep only `admin` and `operator`; passwords remain any non-empty Unicode string.
- Do not re-enable historical Python services, old clients, or old protocol/brand strings.
- Dummy profiles remain exempt from real-hardware transmit-range and preflight-proof requirements.
- Legacy real profiles migrate to empty ranges plus persisted-only `configuration_required`; no parser or UI may silently select acknowledged internal SWR protection.
- Hardware preflight remains read-only and never writes PTT, tuner, frequency, or mode.
- A real profile with `hardwareTxEnabled: true` needs an unexpired same-admin proof for its exact canonical hardware fingerprint.
- Radio upsert has exactly three envelopes: Dummy or hardware-TX-disabled omits confirmation/proof/fence; enabled real hardware outside a fence sends exact profile-ID confirmation plus ordinary proof and no fence fields; enabled real hardware inside a fence sends confirmation, proof, and the complete matching ref.
- A managed-serial reconfiguration fence rejects control and new TX but always permits exact-radio emergency stop, including while candidate preflight owns the serial device.
- Resume and startup observation must never send PTT OFF unless the existing supervisor owns a `dekeyRequired` recovery latch.
- HTTP/Tailscale addresses remain allowed; `secureCookies` remains explicit and clients display their unencrypted-connection warning.
- JSONL audit rotation keeps `audit.jsonl` plus exactly `audit.1.jsonl` through `audit.4.jsonl`, at 8 MiB generations.
- A failed audit dependency can disarm new TX only; it must never delay emergency stop, revocation, deadline handling, or de-key recovery.
- Debian deployment changes stay under `/opt/testradio`; GitHub access uses only the repository deploy key over SSH port 443.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `radio-lite-server/src/server/errors.ts` | Explicit validation and HTTP error types; no error-message regex classification. |
| `radio-lite-server/src/config/types.ts` | Profile schema, defaults/migration of existing profile JSON, transmit ranges, and SWR policy. |
| `radio-lite-server/src/config/radio-config-store.ts` | Uses the persisted-profile migration parser while HTTP saves use strict parsing. |
| `radio-lite-server/src/config/preflight-proof.ts` | Versioned canonical JSON fingerprint and process-local HMAC proof issue/verify. |
| `radio-lite-server/src/config/hardware-preflight.ts` | Passed/warning/failed preflight result and policy-resolved SWR final-status calculation. |
| `radio-lite-server/src/rig/runtime-supervisor.ts` | Per-radio reconfiguration fence, own-runtime serial-claim release, read-only preflight, and safe resume. |
| `radio-lite-server/src/rig/radio-runtime.ts` | Registry delegation to its radio's `RigRuntimeSupervisor`. |
| `radio-lite-server/src/auth/login-rate-limiter.ts` | Username+source, source-wide, and pending-Argon2 admission gate. |
| `radio-lite-server/src/server/source-address.ts` | Canonical direct-peer source resolution with opt-in CIDR-scoped trusted-proxy handling. |
| `radio-lite-server/src/auth/user-store.ts` | Concurrent password verification with fresh auth-revision commit and explicit user lookup. |
| `radio-lite-server/src/auth/six-digit-codes.ts` | Source block preservation and per-code distributed-guess ceiling. |
| `radio-lite-server/src/server/startup-message.ts` | Testable first-administrator code warning used by the entrypoint. |
| `radio-lite-server/src/auth/audit-log.ts` | Persistent generation handle, priority queues, bounded paging, rotation recovery, and durable TX intent. |
| `radio-lite-server/src/server/authenticated-websocket-registry.ts` | Socket principal snapshots, live credential revalidation, and targeted closure; Server Safety Task 10 owns Origin, source budgets, and ping/pong. |
| `radio-lite-server/src/server/radio-lite-service.ts` | HTTP/WS routing, account/device APIs, revocation ordering, proof enforcement, redaction, health flags, and audit wiring. |
| `radio-lite-server/PROTOCOL.md` | Public health, profile, preflight/fence, administration, audit, and WebSocket contracts. |
| `radio-lite-server/test/{config,hardware-preflight,radio-runtime,auth-password-users,pairing-devices,session-audit,http-service}.test.ts` | Existing focused test homes and service contract coverage. |
| `radio-lite-server/test/{preflight-proof,login-rate-limiter,source-address,authenticated-websocket-registry,audit-log-rotation,reconfiguration-fence,startup-message}.test.ts` | New isolated unit test homes. |

## Interfaces

```ts
export type TransmitRangeHz = { lowerHz: number; upperHz: number };
export type ConfiguredSwrPolicy =
  | { mode: "require_swr"; trip: number; reset: number }
  | { mode: "acknowledged_internal_protection"; trip: number; reset: number };
export type SwrPolicy = ConfiguredSwrPolicy | { mode: "configuration_required" };
export type ReconfigurationFenceRef = {
  reconfigurationEpoch: string;
  reconfigurationGeneration: number;
};
export type PreflightProofClaims = {
  version: "preflight-proof-v1";
  administratorUserId: string;
  profileFingerprint: string;
  issuedAtMs: number;
  expiresAtMs: number;
  preflightPassed: true;
  fence?: ReconfigurationFenceRef;
};
export type IssuedPreflightProof = PreflightProofClaims & { proof: string };
export type ReconfigurationFenceState =
  | "draining"
  | "preflighting"
  | "preflight_passed"
  | "held_preflight_unresolved"
  | "cleanup_uncertain"
  | "held_external_ptt";
export type ReconfigurationFence = {
  ref: ReconfigurationFenceRef;
  expiresAtMs: number;
  state: ReconfigurationFenceState;
};
export type AuditRecord = AuditEvent & { id: string };
type StoredAuditRecord = AuditRecord & { generationId: string };
export type AuditPage = { records: AuditRecord[]; nextCursor: string | null };
export type PersistentSafetyAlertKind = "active" | "external_ptt" | "telemetry_uncertain" |
  "dekey_required" | "dekey_escalated" | "swr_trip_latched" | "swr_rearm_pending";
export type SwrSafetyStoredState = "armed" | "latched" | "rearm_pending" | "rearm_in_progress";
export type RadioLiteServerFeatures = {
  hardwarePreflight: true; preflightProof: true; emergencyStop: true;
  safetyAlerts: true; accountAdministration: true; spectrumDisplayWindow: true;
  swrTripReset: true;
};

export class ValidationError extends Error {}
export class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) { super(message); }
}
export class InvalidForwardedSourceError extends HttpError {
  constructor() { super(400, "invalid_forwarded_source", "Forwarded source is invalid"); }
}

export class PreflightProofService {
  fingerprint(profile: RadioProfile): string;
  issue(administratorUserId: string, profile: RadioProfile, fence?: ReconfigurationFenceRef): IssuedPreflightProof;
  verify(proof: string, administratorUserId: string, profile: RadioProfile): PreflightProofClaims;
}

export class LoginRateLimiter {
  admit(username: string, sourceAddress: string): { release(): void };
  recordFailure(username: string, sourceAddress: string): void;
  recordSuccess(username: string, sourceAddress: string): void;
}

export type SourceAddressInput = {
  socketPeerAddress: string;
  forwarded?: string | readonly string[];
  xForwardedFor?: string | readonly string[];
};
export class SourceAddressResolver {
  constructor(options: { trustedProxyCidrs: readonly string[] });
  resolve(input: SourceAddressInput): string;
}

export class AuditLog {
  append(event: AuditEvent): Promise<void>;
  appendSafetyIntent(event: AuditEvent, deadlineMs: number): Promise<void>;
  readPage(cursor: string | null, limit: number): Promise<AuditPage>;
  close(): Promise<void>;
}
```

Task 4 adds these concrete methods to `src/rig/runtime-supervisor.ts`; it does not defer fence ownership to Plan 1:

```ts
beginReconfiguration(profile: RadioProfile, expiresAtMs: number): Promise<ReconfigurationFence>;
runReadOnlyPreflight(profile: RadioProfile, signal: AbortSignal): Promise<HardwarePreflightResult>;
resumeReconfiguration(ref: ReconfigurationFenceRef, profile: RadioProfile): Promise<void>;
cancelReconfiguration(ref: ReconfigurationFenceRef): Promise<void>;
```

`resumeReconfiguration` performs a probe-only `get_ptt`; it creates `startupObserve` only after OFF and retains the fence on ON or uncertainty.

### Task 1: Explicit errors, profile safety schema, and migration

**Files:**
- Create: `radio-lite-server/src/server/errors.ts`
- Modify: `radio-lite-server/src/config/types.ts`
- Modify: `radio-lite-server/src/config/radio-config-store.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Test: `radio-lite-server/test/config.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`
- Test: `radio-lite-server/test/storage-rig.test.ts`

**Consumes:** Existing `RadioProfile`, `parseRadioProfile`, and `mapError`.

**Produces:** `ValidationError`, `HttpError`, strict `parseRadioProfile`, migration-only `parsePersistedRadioProfile`, `RadioProfile.allowedTransmitRangesHz`, and `RadioProfile.swrPolicy` for Tasks 2--9.

- [ ] **Step 1: Write the failing schema and error tests**

```ts
test("real hardware TX profile requires normalized transmit ranges and SWR policy", () => {
  assert.throws(() => parseRadioProfile({ ...realProfile(), hardwareTxEnabled: true }), ValidationError);
  assert.throws(() => parseRadioProfile({ ...realProfile(), hardwareTxEnabled: true,
    allowedTransmitRangesHz: [{ lowerHz: 14_350_000, upperHz: 14_000_000 }],
    swrPolicy: { mode: "require_swr", trip: 3, reset: 2 } }), ValidationError);
  const parsed = parseRadioProfile({ ...realProfile(), hardwareTxEnabled: true,
    allowedTransmitRangesHz: [{ lowerHz: 14_000_000, upperHz: 14_350_000 }],
    swrPolicy: { mode: "require_swr", trip: 3, reset: 2 } });
  assert.deepEqual(parsed.allowedTransmitRangesHz, [{ lowerHz: 14_000_000, upperHz: 14_350_000 }]);
});

test("unexpected errors never become client validation messages", async () => {
  assert.deepEqual(mapError(new Error("database password leaked")).code, "internal_error");
});

test("legacy enabled hardware profile remains loadable but safety-unconfigured", () => {
  const migrated = parsePersistedRadioProfile({
    ...realProfile(), hardwareTxEnabled: true,
    allowedTransmitRangesHz: undefined, swrPolicy: undefined,
  });
  assert.deepEqual(migrated.allowedTransmitRangesHz, []);
  assert.deepEqual(migrated.swrPolicy, { mode: "configuration_required" });
  assert.throws(() => parseRadioProfile({
    ...migrated,
    allowedTransmitRangesHz: [{ lowerHz: 14_000_000, upperHz: 14_350_000 }],
  }), /select.*SWR policy/u);
});

test("RadioConfigStore loads legacy enabled hardware through persisted migration", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "radio-lite-legacy-profile-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "radios.json");
  await writeFile(path, JSON.stringify({
    version: 1,
    radios: [{ ...profile("legacy"), hardwareTxEnabled: true }],
  }), "utf8");

  const loaded = await new RadioConfigStore(path).load();
  const legacy = loaded.config.radios[0];
  assert.ok(legacy);
  assert.equal(legacy.hardwareTxEnabled, true);
  assert.deepEqual(legacy.allowedTransmitRangesHz, []);
  assert.deepEqual(legacy.swrPolicy, { mode: "configuration_required" });
});
```

- [ ] **Step 2: Run the targeted tests to verify red**

Run: `node --experimental-strip-types --test --test-name-pattern="normalized transmit ranges|unexpected errors|legacy enabled hardware profile|RadioConfigStore loads legacy enabled hardware" radio-lite-server/test/config.test.ts radio-lite-server/test/http-service.test.ts radio-lite-server/test/storage-rig.test.ts`

Expected: FAIL because `allowedTransmitRangesHz`/`swrPolicy` and `ValidationError` do not exist, `mapError` still classifies messages with regular expressions, and the actual `RadioConfigStore.load()` path still passes legacy JSON through the strict parser instead of preserving an explicit unconfigured SWR state.

- [ ] **Step 3: Implement the minimal strict schema and typed mapping**

```ts
export type RadioProfile = {
  allowedTransmitRangesHz: readonly TransmitRangeHz[];
  swrPolicy: SwrPolicy;
};

export class ValidationError extends Error {}

function mapError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  if (error instanceof ValidationError) return new HttpError(400, "invalid_request", error.message);
  return new HttpError(500, "internal_error", "internal server error");
}
```

Keep two explicit entry points. `parsePersistedRadioProfile` migrates an already stored legacy profile, including a real profile whose `hardwareTxEnabled` is true, to `allowedTransmitRangesHz: []` and the internal sentinel `{ mode: "configuration_required" }`; these values keep TX fail-closed while preserving receive/control and let Server Safety Task 7 return `tx_safety_config_required`. `RadioConfigStore` uses only this persisted parser. Strict `parseRadioProfile`, used by HTTP create/update, rejects a real enabled profile with missing/empty ranges, the sentinel, overlap, non-integer values, `lowerHz >= upperHz`, `trip <= reset`, `trip > 10`, or `reset < 1`; it requires an administrator to explicitly submit `require_swr` or `acknowledged_internal_protection` and never silently confirms internal protection. Dummy and hardware-disabled inputs may normalize to safe non-transmitting defaults.

- [ ] **Step 4: Run the targeted tests to verify green**

Run: `node --experimental-strip-types --test --test-name-pattern="normalized transmit ranges|unexpected errors|legacy enabled hardware profile|RadioConfigStore loads legacy enabled hardware" radio-lite-server/test/config.test.ts radio-lite-server/test/http-service.test.ts radio-lite-server/test/storage-rig.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit the isolated schema change**

```bash
git add radio-lite-server/src/server/errors.ts radio-lite-server/src/config/types.ts radio-lite-server/src/config/radio-config-store.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/config.test.ts radio-lite-server/test/http-service.test.ts radio-lite-server/test/storage-rig.test.ts
git commit -m "feat: validate radio TX safety configuration"
```


### Task 2: Policy-resolved SWR preflight status

**Files:**
- Modify: `radio-lite-server/src/config/hardware-preflight.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Test: `radio-lite-server/test/hardware-preflight.test.ts`

**Consumes:** Task 1 `SwrPolicy` and parsed profiles.

**Produces:** A preflight result whose final `overallStatus: "passed"` is possible only when every warning is acknowledged by policy.

- [ ] **Step 1: Write the failing SWR status tests**

```ts
test("acknowledged internal SWR protection resolves only the unsupported-SWR warning", async () => {
  const result = await preflight.test(profile({
    swrPolicy: { mode: "acknowledged_internal_protection", trip: 3, reset: 2 },
  }));
  assert.equal(result.overallStatus, "passed");
  assert.deepEqual(result.checks.find((check) => check.id === "swr")?.status, "warning");
  assert.equal(result.acknowledgedWarnings.swrUnavailable, true);
});

test("require SWR leaves unavailable SWR as a failed preflight", async () => {
  const result = await preflight.test(profile({
    swrPolicy: { mode: "require_swr", trip: 3, reset: 2 },
  }));
  assert.equal(result.overallStatus, "failed");
});

test("unconfigured legacy SWR policy cannot pass preflight", async () => {
  const result = await preflight.test(profile({
    allowedTransmitRangesHz: [], swrPolicy: { mode: "configuration_required" },
  }));
  assert.equal(result.overallStatus, "failed");
  assert.equal(result.checks.some((check) => check.id === "tx_safety_config"), true);
});
```

- [ ] **Step 2: Run the targeted tests to verify red**

Run: `node --experimental-strip-types --test --test-name-pattern="acknowledged internal SWR|require SWR|unconfigured legacy SWR" radio-lite-server/test/hardware-preflight.test.ts`

Expected: FAIL because the result has no SWR check, acknowledged-warning projection, or explicit unconfigured-policy rejection.

- [ ] **Step 3: Implement policy-aware final status**

```ts
type HardwarePreflightResult = {
  acknowledgedWarnings: { swrUnavailable: boolean };
};

function overallStatus(checks: readonly HardwarePreflightCheck[], policy: SwrPolicy): HardwarePreflightStatus {
  if (checks.some((check) => check.status === "failed")) return "failed";
  if (checks.some((check) => check.status === "warning" && !(check.id === "swr" && policy.mode === "acknowledged_internal_protection"))) {
    return "warning";
  }
  return "passed";
}
```

Report the unsupported SWR condition as a structured `swr` warning. With `require_swr`, make it failed; with `acknowledged_internal_protection`, preserve the warning record and set `acknowledgedWarnings.swrUnavailable: true` while allowing final passed only if all other checks pass. The persisted-only `configuration_required` sentinel always produces a failed `tx_safety_config` check and is never interpreted as an acknowledged warning.

- [ ] **Step 4: Run the targeted tests to verify green**

Run: `node --experimental-strip-types --test --test-name-pattern="acknowledged internal SWR|require SWR|unconfigured legacy SWR" radio-lite-server/test/hardware-preflight.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit the preflight-policy change**

```bash
git add radio-lite-server/src/config/hardware-preflight.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/hardware-preflight.test.ts
git commit -m "feat: resolve acknowledged SWR preflight warnings"
```

### Task 3: Signed preflight proof and proof-gated save

**Files:**
- Create: `radio-lite-server/src/config/preflight-proof.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Test: `radio-lite-server/test/preflight-proof.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`

**Consumes:** Tasks 1--2 normalized profile and passed result.

**Produces:** `PreflightProofService`, `preflightProof` HTTP response field, and `preflight_proof_required` save denial for Task 4.

- [ ] **Step 1: Write failing proof tests**

```ts
test("proof accepts only the exact passed profile and issuing administrator", () => {
  const issued = proofs.issue("admin-a", profile());
  assert.equal(proofs.verify(issued.proof, "admin-a", profile()).profileFingerprint, issued.profileFingerprint);
  assert.throws(() => proofs.verify(issued.proof, "admin-b", profile()));
  assert.throws(() => proofs.verify(issued.proof, "admin-a", profile({ ptt: { method: "DTR", path: "/dev/ttyUSB1" } })));
});

test("enabled real hardware save requires exact confirmation and proof", async () => {
  assert.equal((await save(realHardwareProfile())).error.code, "preflight_proof_required");
  const profile = realHardwareProfile({ id: "main", hardwareTxEnabled: true });
  const issued = proofs.issue("admin-a", profile);
  assert.equal((await save({
    profile, hardwareTxConfirmation: "main", preflightProof: issued.proof,
  }, "admin-a")).status, 200);
  assert.equal((await save({
    profile, hardwareTxConfirmation: "wrong", preflightProof: issued.proof,
  }, "admin-a")).error.code, "hardware_tx_confirmation_required");
});

test("Dummy and hardware-disabled saves omit confirmation proof and fence", async () => {
  assert.equal((await save({ profile: dummyProfile() }, "admin-a")).status, 200);
  assert.equal((await save({
    profile: realHardwareProfile({ hardwareTxEnabled: false }),
  }, "admin-a")).status, 200);
});

test("raw radio upsert rejects stray missing and half-fence envelope fields", async () => {
  const writesBefore = configStore.upsertCalls;
  for (const profile of [
    dummyProfile(), realHardwareProfile({ hardwareTxEnabled: false }),
  ]) {
    for (const stray of [
      { hardwareTxConfirmation: profile.id },
      { preflightProof: "stray-proof" },
      { reconfigurationEpoch: "epoch-a", reconfigurationGeneration: 17 },
    ]) {
      const reply = await rawUpsert({ profile, ...stray }, "admin-a");
      assert.equal(reply.status, 400);
      assert.equal(reply.body.error.code, "invalid_request");
    }
  }

  const profile = realHardwareProfile({ id: "main", hardwareTxEnabled: true });
  const ordinary = proofs.issue("admin-a", profile);
  for (const body of [
    { profile, preflightProof: ordinary.proof },
    { profile, hardwareTxConfirmation: "main" },
  ]) {
    const reply = await rawUpsert(body, "admin-a");
    assert.equal(reply.status, 409);
    assert.match(reply.body.error.code,
      /hardware_tx_confirmation_required|preflight_proof_required/u);
  }
  for (const halfFence of [
    { reconfigurationEpoch: "epoch-a" },
    { reconfigurationGeneration: 17 },
  ]) {
    const reply = await rawUpsert({
      profile, hardwareTxConfirmation: "main", preflightProof: ordinary.proof,
      ...halfFence,
    }, "admin-a");
    assert.equal(reply.status, 400);
    assert.equal(reply.body.error.code, "invalid_request");
  }
  const fabricatedFence = await rawUpsert({
    profile, hardwareTxConfirmation: "main", preflightProof: ordinary.proof,
    reconfigurationEpoch: "epoch-a", reconfigurationGeneration: 17,
  }, "admin-a");
  assert.equal(fabricatedFence.status, 400);
  assert.equal(fabricatedFence.body.error.code, "invalid_request");
  assert.equal(configStore.upsertCalls, writesBefore);
});

test("fenced proof binds epoch and generation as one reference", () => {
  const fence = { reconfigurationEpoch: "epoch-a", reconfigurationGeneration: 17 };
  const issued = proofs.issue("admin-a", profile(), fence);
  assert.deepEqual(proofs.verify(issued.proof, "admin-a", profile()).fence, fence);
});
```

- [ ] **Step 2: Run the targeted tests to verify red**

Run: `node --experimental-strip-types --test --test-name-pattern="exact passed profile|requires exact confirmation|hardware-disabled saves omit|raw radio upsert rejects|binds epoch and generation" radio-lite-server/test/preflight-proof.test.ts radio-lite-server/test/http-service.test.ts`

Expected: FAIL because no proof service, response proof, fence reference, or save gate exists.

- [ ] **Step 3: Implement canonical signing and enforcement**

```ts
const canonical = canonicalJson({
  version: "preflight-proof-v1",
  id: profile.id, hamlibModelId: profile.hamlibModelId, connection: profile.connection,
  audioInput: pick(profile.audioInput, ["backend", "id"]),
  audioOutput: pick(profile.audioOutput, ["backend", "id"]),
  ptt: profile.ptt, hardwareTxEnabled: profile.hardwareTxEnabled,
  allowedTransmitRangesHz: profile.allowedTransmitRangesHz, swrPolicy: profile.swrPolicy,
});
const profileFingerprint = createHash("sha256").update(canonical, "utf8").digest("hex");
```

Use a random process-local 32-byte HMAC key and a 10-minute TTL. Canonical JSON recursively sorts keys and drops `undefined`; it includes no profile name, audio label, callsign, or grid. Construct the exact `PreflightProofClaims` fields frozen in Interfaces, sign their canonical JSON, and return `IssuedPreflightProof`; the HTTP preflight result attaches that complete object as `preflightProof`. A proof claim has an optional complete `fence: { reconfigurationEpoch, reconfigurationGeneration }`: ordinary `POST /api/v1/hardware/test` omits it, while Task 4's stop-and-preflight path requires and binds both fields. `POST /api/v1/hardware/test` attaches a proof only for a passed, explicitly configured real profile; `configuration_required` can never be signed. `POST /api/v1/radios` parses first. Dummy or hardware-disabled input rejects any stray confirmation/proof/fence field and saves without them. Enabled real hardware requires `hardwareTxConfirmation === profile.id` and verifies the ordinary or fenced proof against the authenticated administrator and normalized profile before `upsert`. Reject a half top-level fence pair and reject a complete top-level pair when the verified proof claim omits its fence, both before config writes. An ordinary save requires no held fence and omits both ref fields, while Task 4 rejects a held fence unless the request and proof carry the same complete ref.

- [ ] **Step 4: Run the targeted tests to verify green**

Run: `node --experimental-strip-types --test --test-name-pattern="exact passed profile|requires exact confirmation|hardware-disabled saves omit|raw radio upsert rejects|binds epoch and generation" radio-lite-server/test/preflight-proof.test.ts radio-lite-server/test/http-service.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit the proof boundary**

```bash
git add radio-lite-server/src/config/preflight-proof.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/preflight-proof.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: require signed hardware preflight proof"
```

### Task 4: Supervisor-owned stop-and-preflight fence

**Files:**
- Modify: `radio-lite-server/src/config/hardware-preflight.ts`
- Modify: `radio-lite-server/src/rig/runtime-supervisor.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Test: `radio-lite-server/test/reconfiguration-fence.test.ts`
- Test: `radio-lite-server/test/radio-runtime.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`

**Consumes:** Tasks 1--3 profile/proof types and Plan 1's shutdown/de-key primitives.

**Produces:** Explicit fence routes and one serial lifecycle owner. An enabled-real save without its valid proof always returns `preflight_proof_required`; only an ordinary hardware-preflight request whose candidate needs the live managed-serial runtime's canonical claim returns `preflight_requires_runtime_stop` and directs the administrator to the explicit stop-and-preflight route.

- [ ] **Step 1: Write failing fence tests using a fake monotonic clock**

```ts
test("stop-and-preflight releases its own canonical serial claim before opening candidate preflight", async () => {
  await supervisor.beginReconfiguration(current, clock.now() + 600_000);
  assert.deepEqual(events, ["fence", "dekey-confirmed", "runtime-closed", "serial-released", "preflight-opened"]);
});

test("resume keeps the same fence through ON and unknown then auto-recovers on OFF", async () => {
  const fixture = reconfigurationFixture({ resumePtt: [true, "unknown", false] });
  const fence = await fixture.begin();
  await fixture.resume(fence.ref);
  assert.equal(fixture.probe.setPttCalls, 0);
  assert.deepEqual(fixture.supervisor.fenceSnapshot()?.ref, fence.ref);
  assert.equal(fixture.supervisor.fenceSnapshot()?.state, "held_external_ptt");
  await fixture.runDueReadOnlyProbe();
  assert.deepEqual(fixture.supervisor.fenceSnapshot()?.ref, fence.ref);
  await fixture.runDueReadOnlyProbe();
  assert.equal(fixture.supervisor.fenceSnapshot(), null);
  assert.equal(fixture.runtime.startupObserveCalls, 1);
  assert.equal(fixture.probe.setPttCalls, 0);
});

test("active dekey external or unknown PTT refuses before opening preflight", async () => {
  for (const unsafe of ["voice", "digital", "tuning", "dekey_required", "external_ptt", "ptt_unknown"] as const) {
    const fixture = reconfigurationFixture({ unsafe });
    await assert.rejects(fixture.begin(), /transmit|dekey|external|uncertain/u);
    assert.equal(fixture.issuedProofs, 0);
    assert.equal(fixture.supervisor.fenceSnapshot(), null);
  }
});

test("missing save proof stays proof required even when the live serial is occupied", async () => {
  const fixture = reconfigurationFixture({ liveManagedSerial: true });
  const reply = await fixture.saveEnabledRealProfile({ preflightProof: undefined });
  assert.equal(reply.status, 409);
  assert.equal(reply.body.error.code, "preflight_proof_required");
});

test("only ordinary preflight against the live managed serial asks for runtime stop", async () => {
  const occupied = reconfigurationFixture({ liveManagedSerial: true });
  assert.equal((await occupied.ordinaryPreflight()).body.error.code,
    "preflight_requires_runtime_stop");
  for (const candidate of ["network-rigctld", "unoccupied-serial"] as const) {
    const fixture = reconfigurationFixture({ candidate });
    assert.notEqual((await fixture.ordinaryPreflight()).body.error?.code,
      "preflight_requires_runtime_stop");
  }
});

test("warning failed and cleanup uncertainty retain the exact fence without proof", async () => {
  for (const unresolved of ["warning", "failed", "cleanup_uncertain"] as const) {
    const fixture = reconfigurationFixture({ unsafe: unresolved });
    await fixture.begin().catch(() => undefined);
    const snapshot = fixture.supervisor.fenceSnapshot();
    assert.ok(snapshot);
    assert.deepEqual(snapshot.ref, {
      reconfigurationEpoch: fixture.epoch, reconfigurationGeneration: 1,
    });
    assert.equal(
      snapshot.state,
      unresolved === "cleanup_uncertain" ? "cleanup_uncertain" : "held_preflight_unresolved",
    );
    assert.equal(fixture.issuedProofs, 0);
  }
});

test("save cancel and expiry use a write-free OFF probe before resuming", async () => {
  for (const completion of ["save", "cancel", "expiry"] as const) {
    const fixture = reconfigurationFixture();
    const fence = await fixture.begin();
    await fixture.complete(completion, fence.ref);
    assert.equal(fixture.probe.setPttCalls, 0);
    assert.equal(fixture.probe.readPttCalls, 1);
    assert.equal(fixture.supervisor.fenceSnapshot(), null);
  }
});

test("old epoch or generation cannot affect a replacement fence", async () => {
  const firstOwner = reconfigurationFixture({ epoch: "epoch-old" });
  const old = await firstOwner.begin();
  await firstOwner.cancel(old.ref);
  const replacementOwner = reconfigurationFixture({ epoch: "epoch-new" });
  const replacement = await replacementOwner.begin();
  assert.equal(old.ref.reconfigurationGeneration, replacement.ref.reconfigurationGeneration);
  await assert.rejects(replacementOwner.cancel(old.ref), /stale.*generation/u);
  await assert.rejects(replacementOwner.resume(old.ref), /stale.*generation/u);
  assert.deepEqual(replacementOwner.supervisor.fenceSnapshot()?.ref, replacement.ref);
});

test("missing or stale fenced save fails before proof verification or config write", async () => {
  const fixture = reconfigurationFixture({ epoch: "epoch-current" });
  const currentFence = await fixture.begin();
  const oldRef = { reconfigurationEpoch: "epoch-old", reconfigurationGeneration: 1 };
  await assert.rejects(fixture.save({ proof: currentFence.proof }), /stale_reconfiguration_generation/u);
  await assert.rejects(fixture.save({ proof: currentFence.proof, fence: oldRef }), /stale_reconfiguration_generation/u);
  assert.equal(fixture.proofVerifyCalls, 0);
  assert.equal(fixture.configWriteCalls, 0);
  assert.deepEqual(fixture.supervisor.fenceSnapshot()?.ref, currentFence.ref);
});

test("emergency stop preempts candidate preflight and reaches OFF on its canonical serial", async () => {
  const fixture = reconfigurationFixture({ candidatePreflight: "blocked" });
  const pending = fixture.begin();
  await fixture.candidateOpened;
  await fixture.supervisor.emergencyStop("emergency_stop");
  assert.deepEqual(fixture.events.slice(-5), [
    "candidate-aborted", "candidate-cleaned", "serial-reclaimed", "ptt-off", "ptt-readback-off",
  ]);
  await assert.rejects(pending, /preflight.*aborted/u);
  assert.equal(fixture.issuedProofs, 0);
  assert.equal(fixture.supervisor.fenceSnapshot()?.state, "held_preflight_unresolved");
  assert.equal(fixture.otherRadioOffCalls, 0);
});

test("beginning reconfiguration invalidates an already reserved transmit permit", async () => {
  const fixture = reconfigurationFixture();
  const permit = await fixture.supervisor.reserveTransmitStart(fixture.startReservation());
  await fixture.begin();
  await assert.rejects(
    fixture.supervisor.commitTransmitStart(permit, async () => undefined),
    /transmit_start_invalidated/u,
  );
  assert.equal(fixture.rig.setPttOnCalls, 0);
});
```

- [ ] **Step 2: Run the targeted tests to verify red**

Run: `node --experimental-strip-types --test --test-name-pattern="releases its own canonical|same fence through ON|refuses before opening preflight|missing save proof|only ordinary preflight|retain the exact fence|save cancel and expiry|old epoch or generation|stale fenced save|preempts candidate preflight|invalidates an already reserved" radio-lite-server/test/reconfiguration-fence.test.ts radio-lite-server/test/radio-runtime.test.ts radio-lite-server/test/http-service.test.ts`

Expected: FAIL because the existing `RigRuntimeSupervisor` has no reconfiguration-fence API.

- [ ] **Step 3: Implement the fence on the existing supervisor owner**

```ts
if (this.#fence !== null) throw new ReconfigurationFenceError("radio is reconfiguring");
this.#fence = {
  ref: {
    reconfigurationEpoch: this.#reconfigurationEpoch,
    reconfigurationGeneration: ++this.#generation,
  },
  expiresAtMs,
  state: "draining",
};
await this.recoverDeKeyIfResponsible();
await this.closeManagedRuntimeAndReleaseSerialClaim();
this.#fence.state = "preflighting";
const result = await this.runReadOnlyPreflight(candidate, this.#candidateAbort.signal);
```

Generate a random 128-bit `reconfigurationEpoch` whenever a per-radio supervisor is constructed and increment its numeric generation only inside that epoch. Before any await in `beginReconfiguration`, synchronously call the Server Safety Task 4 `invalidateTransmitStarts("reconfiguration")`; this advances the independent transmit-admission generation and makes a permit reserved before the fence permanently uncommittable. The stored object uses the exact `ReconfigurationFence` shape from Interfaces; a passed result changes only its state to `preflight_passed` before proof issuance, while warning/failure states follow the rules below. Implement these methods on that supervisor, then expose `POST /api/v1/radios/:radioId/reconfiguration/preflight`, `POST /api/v1/radios/:radioId/reconfiguration/cancel`, and `POST /api/v1/radios/:radioId/reconfiguration/resume`. The preflight reply includes both `reconfigurationEpoch` and `reconfigurationGeneration`; cancel/resume bodies, fenced save envelope, and proof claim carry the identical pair. A missing/mismatched field returns `stale_reconfiguration_generation` before proof verification, config writes, cancel, resume, runtime replacement, or fence mutation. A new process/supervisor epoch makes an old request stale even when its number is reused.

Reject control acquire and new TX while fenced. Route `tx.emergency-stop` to this supervisor even after the ordinary runtime has closed: abort its owned candidate preflight, await candidate cleanup, reclaim the same canonical serial claim, then issue safety-priority OFF/readback. This path cannot use the closed runtime or a second owner; it issues no proof, maps confirmed cleanup/OFF to `held_preflight_unresolved`, maps uncertain cleanup to `cleanup_uncertain`, and leaves other radios untouched. Refuse to enter preflight while voice/digital/tuning, `dekeyRequired`, external PTT ON, or PTT uncertainty remains. Warning and failed preflight results issue no proof and transition the exact fence to `held_preflight_unresolved`; uncertain cleanup issues no proof and transitions it to `cleanup_uncertain`. A stale completion cannot mutate the fence.

On exact-ref save, cancel, fake-clock expiry, and resume, probe PTT with a write-free transport. ON/unknown retains the same ref and starts one referenced low-frequency read-only probe owned by the supervisor; a later OFF automatically resumes `startupObserve` and releases the fence without any PTT write. Quarantine uncertain cleanup and never issue proof or release the fence in that case.

- [ ] **Step 4: Run the targeted tests to verify green**

Run: `node --experimental-strip-types --test --test-name-pattern="releases its own canonical|same fence through ON|refuses before opening preflight|missing save proof|only ordinary preflight|retain the exact fence|save cancel and expiry|old epoch or generation|stale fenced save|preempts candidate preflight|invalidates an already reserved" radio-lite-server/test/reconfiguration-fence.test.ts radio-lite-server/test/radio-runtime.test.ts radio-lite-server/test/http-service.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit the fence lifecycle**

```bash
git add radio-lite-server/src/config/hardware-preflight.ts radio-lite-server/src/rig/runtime-supervisor.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/reconfiguration-fence.test.ts radio-lite-server/test/radio-runtime.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: fence managed serial preflight reconfiguration"
```


### Task 5: Canonical request source, login admission, and fresh authorization after Argon2

**Files:**
- Create: `radio-lite-server/src/auth/login-rate-limiter.ts`
- Create: `radio-lite-server/src/server/source-address.ts`
- Modify: `radio-lite-server/src/auth/user-store.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Test: `radio-lite-server/test/login-rate-limiter.test.ts`
- Test: `radio-lite-server/test/source-address.test.ts`
- Test: `radio-lite-server/test/auth-password-users.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`

**Consumes:** Task 1 typed `HttpError`.

**Produces:** `SourceAddressResolver`, typed `InvalidForwardedSourceError`, `LoginRateLimitError`, 429 plus `Retry-After`, and a session issued only from an unchanged enabled user revision. Server Safety Task 10 consumes the same resolver for WebSocket connection budgets.

- [ ] **Step 1: Write the failing admission and race tests**

~~~ts
type Deferred<T> = {
  promise: Promise<T>;
  resolve(value: T | PromiseLike<T>): void;
  reject(reason?: unknown): void;
};

function deferred<T>(): Deferred<T> {
  let resolve!: Deferred<T>["resolve"];
  let reject!: Deferred<T>["reject"];
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

test("login admission rejects account-source and source buckets before Argon2", () => {
  limiter.recordFailure("operator", "192.0.2.9");
  assert.throws(() => limiter.admit("operator", "192.0.2.9"), LoginRateLimitError);
  assert.equal(verifyCalls, 0);
});

test("username aliases share the same normalized admission and reset bucket", () => {
  const limiter = loginLimiterFixture({ accountSourceFailureLimit: 1 });
  limiter.recordFailure(" Operator ", "192.0.2.9");
  assert.throws(() => limiter.admit("operator", "192.0.2.9"), LoginRateLimitError);
  limiter.recordSuccess("OPERATOR", "192.0.2.9");
  assert.doesNotThrow(() => limiter.admit(" operator ", "192.0.2.9").release());
});

test("untrusted X-Forwarded-For is ignored in favor of the socket peer", () => {
  const resolver = new SourceAddressResolver({ trustedProxyCidrs: ["10.0.0.0/8"] });
  assert.equal(resolver.resolve({
    socketPeerAddress: "192.0.2.9",
    xForwardedFor: "198.51.100.44",
    forwarded: "for=203.0.113.7",
  }), "192.0.2.9");
});

test("default source resolver ignores even malformed forwarding headers", () => {
  const resolver = new SourceAddressResolver({ trustedProxyCidrs: [] });
  assert.equal(resolver.resolve({
    socketPeerAddress: "192.0.2.9",
    xForwardedFor: ["not-an-ip", "198.51.100.44"],
    forwarded: "for=unknown, for=203.0.113.7",
  }), "192.0.2.9");
});

test("trusted proxy accepts exactly one normalized forwarded IP", () => {
  const resolver = new SourceAddressResolver({ trustedProxyCidrs: ["10.0.0.0/8"] });
  assert.equal(resolver.resolve({
    socketPeerAddress: "10.0.0.4",
    xForwardedFor: "198.51.100.44",
  }), "198.51.100.44");
});

test("trusted proxy rejects malformed ambiguous or multiple forwarded values", () => {
  const resolver = new SourceAddressResolver({ trustedProxyCidrs: ["10.0.0.0/8"] });
  for (const input of [
    { socketPeerAddress: "10.0.0.4", xForwardedFor: "198.51.100.44, 203.0.113.7" },
    { socketPeerAddress: "10.0.0.4", forwarded: "for=unknown" },
    { socketPeerAddress: "10.0.0.4", forwarded: "for=198.51.100.44", xForwardedFor: "198.51.100.44" },
  ]) assert.throws(() => resolver.resolve(input), InvalidForwardedSourceError);
});

test("trusted proxy clients receive independent login source buckets", async () => {
  const fixture = httpLoginFixture({
    trustedProxyCidrs: ["10.0.0.0/8"], accountSourceFailureLimit: 1,
  });
  const viaProxy = (forwardedIp: string) => ({
    socketPeerAddress: "10.0.0.4", xForwardedFor: forwardedIp,
  });
  assert.equal((await fixture.login(viaProxy("198.51.100.41"), "operator", "wrong")).status, 401);
  assert.equal((await fixture.login(viaProxy("198.51.100.41"), "operator", "wrong")).status, 429);
  assert.equal((await fixture.login(viaProxy("198.51.100.42"), "operator", "wrong")).status, 401);
});

test("IPv6 trusted CIDR accepts and canonicalizes one IPv6 client", () => {
  const resolver = new SourceAddressResolver({ trustedProxyCidrs: ["2001:db8:42::/48"] });
  assert.equal(resolver.resolve({
    socketPeerAddress: "2001:0db8:0042::10",
    xForwardedFor: "2001:0db8:0007:0000:0000:0000:0000:0009",
  }), "2001:db8:7::9");
});

test("IPv4 and mapped IPv6 aliases share one normalized login bucket", async () => {
  const fixture = httpLoginFixture({
    trustedProxyCidrs: ["10.0.0.0/8"], accountSourceFailureLimit: 1,
  });
  const forwarded = (value: string, peer = "10.0.0.4") => ({
    socketPeerAddress: peer, xForwardedFor: value,
  });
  assert.equal((await fixture.login(
    forwarded("192.0.2.9"), "operator", "wrong",
  )).status, 401);
  assert.equal((await fixture.login(
    forwarded("::ffff:192.0.2.9", "::ffff:10.0.0.4"), "operator", "wrong",
  )).status, 429);
  assert.equal(fixture.resolve(forwarded("192.0.2.9")), "192.0.2.9");
  assert.equal(fixture.resolve(
    forwarded("::ffff:192.0.2.9", "::ffff:10.0.0.4"),
  ), "192.0.2.9");
});

test("password mutation during Argon2 verification cannot issue a stale login", async () => {
  const verifierStarted = deferred<void>();
  const verifierMayFinish = deferred<boolean>();
  const users = userStoreFixture({
    verifyPassword: async () => {
      verifierStarted.resolve(undefined);
      return verifierMayFinish.promise;
    },
  });
  const pending = users.authenticate("operator", "old-password");
  await verifierStarted.promise;
  await users.changePassword("user-1", "new-password");
  verifierMayFinish.resolve(true);
  assert.equal(await pending, null);
});
~~~

- [ ] **Step 2: Run the targeted tests to verify red**

Run: `node --experimental-strip-types --test --test-name-pattern="login admission|username aliases|untrusted X-Forwarded-For|default source resolver|trusted proxy|IPv6 trusted CIDR|mapped IPv6 aliases|stale login" radio-lite-server/test/login-rate-limiter.test.ts radio-lite-server/test/source-address.test.ts radio-lite-server/test/auth-password-users.test.ts radio-lite-server/test/http-service.test.ts`

Expected: FAIL because there is no canonical source resolver or limiter and `authenticate` holds the user-store serialization lock through verification.

- [ ] **Step 3: Implement bounded admission and two-phase authentication**

~~~ts
const normalizedUsername = normalizeUsername(username);
const admission = this.#loginLimiter.admit(normalizedUsername, source);
try {
  const user = await this.#users.authenticate(username, password);
  user === null
    ? this.#loginLimiter.recordFailure(normalizedUsername, source)
    : this.#loginLimiter.recordSuccess(normalizedUsername, source);
  return user;
} finally {
  admission.release();
}
~~~

Implement one shared `SourceAddressResolver` and inject it at the HTTP and WebSocket boundaries. With the default empty `trustedProxyCidrs`, canonicalize and use only the TCP socket peer, ignoring every `Forwarded` and `X-Forwarded-For` value even when malformed. A forwarded address is eligible only when the configured allowlist is non-empty and the canonical peer matches one of its explicit IPv4/IPv6 CIDRs. A trusted peer with neither supported header still resolves to its canonical peer; once either header is present, accept exactly one syntactically valid IP from exactly one supported header, normalize it to the canonical address representation, and collapse IPv4-mapped IPv6 to the same dotted-quad identity as native IPv4 before CIDR checks or budget keys. Reject an array, comma-separated chain, duplicate/conflicting headers, an obfuscated/unknown token, a port-bearing value, or malformed IP with `invalid_forwarded_source`; never fall back to a header after a trusted-peer parse failure. Login, pairing, HTTP source limits, audit `sourceAddress`, and Server Safety Task 10's pending/active WS budgets must receive only this resolver result and must not read forwarding headers directly. The HTTP integration tests prove two clients behind one trusted peer do not collapse back into the peer bucket, while textual IPv6 aliases and IPv4/mapped-IPv6 aliases cannot split one client into multiple buckets.

Snapshot the candidate user and its `authRevision` under the store lock, perform Argon2 verification outside that lock, then reacquire it and require the same enabled user, password hash, and revision before updating `lastLoginAtMs` or returning. The test fixture injects the shown deferred password verifier; `verifierStarted` proves the old snapshot and Argon2 phase are active before the password mutation, and `verifierMayFinish` releases only afterward. Compute `normalizedUsername` exactly once per request and use that same value for `admit`, `recordFailure`, and `recordSuccess`; raw case/whitespace aliases must not create or leave distinct buckets. Enforce username+source and source-wide blocks plus a small pending verification cap. Map every limit denial to 429, set integer-ceiling seconds in `Retry-After`, and use the same invalid-login body for unknown accounts.

- [ ] **Step 4: Run the targeted tests to verify green**

Run: `node --experimental-strip-types --test --test-name-pattern="login admission|username aliases|untrusted X-Forwarded-For|default source resolver|trusted proxy|IPv6 trusted CIDR|mapped IPv6 aliases|stale login" radio-lite-server/test/login-rate-limiter.test.ts radio-lite-server/test/source-address.test.ts radio-lite-server/test/auth-password-users.test.ts radio-lite-server/test/http-service.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit the login boundary**

~~~bash
git add radio-lite-server/src/auth/login-rate-limiter.ts radio-lite-server/src/server/source-address.ts radio-lite-server/src/auth/user-store.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/login-rate-limiter.test.ts radio-lite-server/test/source-address.test.ts radio-lite-server/test/auth-password-users.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: rate limit login before Argon2"
~~~

### Task 6: Six-digit code source and distributed-guess limits

**Files:**
- Modify: `radio-lite-server/src/auth/six-digit-codes.ts`
- Create: `radio-lite-server/src/server/startup-message.ts`
- Modify: `radio-lite-server/src/index.ts`
- Test: `radio-lite-server/test/pairing-devices.test.ts`
- Test: `radio-lite-server/test/startup-message.test.ts`

**Consumes:** Existing code HMAC records and Task 5's single canonical `SourceAddressResolver` result.

**Produces:** Blocked buckets that survive the failure window and a per-code global failure maximum.

- [ ] **Step 1: Write the failing code-limit tests**

~~~ts
test("blocked source remains blocked after its failure window until blockedUntil", () => {
  assert.throws(() => vault.redeem("000000", "device_pairing", "198.51.100.1"));
  assert.throws(() => vault.redeem("000000", "device_pairing", "198.51.100.1"));
  now += failureWindowMs + 1;
  assert.throws(() => vault.redeem("123456", "device_pairing", "198.51.100.1"), CodeRateLimitError);
});

test("every invalid same-purpose attempt invalidates all active codes at the global cap", () => {
  vault.issue("user-a", "device_pairing", 60_000);
  vault.issue("user-b", "device_pairing", 60_000);
  for (const source of ["a", "b", "c", "d", "e"]) assert.throws(() => vault.redeem("000000", "device_pairing", source));
  assert.equal(vault.activeCount, 0);
});

test("initial setup log warns that journald may retain the short-lived code", () => {
  assert.match(formatInitialSetupCode("123456"), /systemd\/journald may retain this code/u);
});
~~~

- [ ] **Step 2: Run the targeted tests to verify red**

Run: `node --experimental-strip-types --test --test-name-pattern="blocked source remains|same-purpose|journald" radio-lite-server/test/pairing-devices.test.ts radio-lite-server/test/startup-message.test.ts`

Expected: FAIL because `#activeBucket` clears a blocked bucket after the window and records have no global same-purpose failure count, and startup logging claims the code never reaches persistent logs.

- [ ] **Step 3: Implement non-resetting block and record failure count**

~~~ts
if (existing?.blockedUntilMs > now) return existing;
if (existing === undefined || now - existing.windowStartedAtMs >= this.#failureWindowMs) {
  return { failures: 0, windowStartedAtMs: now, blockedUntilMs: 0 };
}
~~~

Add `failureCount` to each `CodeRecord`. For every invalid redemption attempt, increment every active record with the same `purpose`; delete each record that reaches `maxFailuresPerCode` before throwing `InvalidOrExpiredCodeError`. Keep normal successful redemption single-use and clear only the successful source bucket. Implement `formatInitialSetupCode(code)` in `src/server/startup-message.ts`; `src/index.ts` writes its result, which states that the code is short-lived and single-use but systemd/journald may retain it.

- [ ] **Step 4: Run the targeted tests to verify green**

Run: `node --experimental-strip-types --test --test-name-pattern="blocked source remains|same-purpose|journald" radio-lite-server/test/pairing-devices.test.ts radio-lite-server/test/startup-message.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit pairing limits**

~~~bash
git add radio-lite-server/src/auth/six-digit-codes.ts radio-lite-server/src/server/startup-message.ts radio-lite-server/src/index.ts radio-lite-server/test/pairing-devices.test.ts radio-lite-server/test/startup-message.test.ts
git commit -m "fix: preserve pairing blocks and cap distributed guesses"
~~~

### Task 7: Account/device APIs, WebSocket revalidation, and revocation ordering

**Files:**
- Create: `radio-lite-server/src/server/authenticated-websocket-registry.ts`
- Modify: `radio-lite-server/src/auth/user-store.ts`
- Modify: `radio-lite-server/src/auth/device-store.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Test: `radio-lite-server/test/authenticated-websocket-registry.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`

**Consumes:** Tasks 1 and 5 typed errors and user revision guarantee; Plan 1 emergency de-key API.

**Produces:** Live credential checks, targeted socket closure, user/device administration routes, and de-key-before-revocation behavior.

- [ ] **Step 1: Write the failing WS and account-operation tests**

~~~ts
test("changed role, transmit permission, disabled user, and revoked device fail the next privileged WS command", async () => {
  await mutateAccount();
  await send(controlSocket, { t: "tx.start", radioId: "main", controlToken, mode: "voice" });
  assert.equal((await receive(controlSocket)).code, "authentication_revoked");
});

test("device revocation dekeys first and closes only that device sockets", async () => {
  await revokeDevice(deviceId);
  assert.deepEqual(events.slice(0, 2), ["emergency-stop", "socket-close"]);
});

test("emergency stop remains allowed after a live privilege downgrade", async () => {
  fixture.setCurrentUserForRevalidation({ role: "operator", canTransmit: false, enabled: true });
  await send(controlSocket, { t: "tx.emergency-stop", radioId: "main", commandId: "stop-1" });
  assert.deepEqual(await receive(controlSocket), {
    t: "tx.emergency-stop.accepted", radioId: "main", commandId: "stop-1",
  });
});

test("revocation invalidates a reserved transmit permit before socket close", async () => {
  const permit = await fixture.supervisor.reserveTransmitStart(fixture.startReservation(deviceId));
  await revokeDevice(deviceId);
  await assert.rejects(
    fixture.supervisor.commitTransmitStart(permit, async () => undefined),
    /transmit_start_invalidated/u,
  );
  assert.deepEqual(events.slice(0, 3), ["transmit-start-invalidated", "emergency-stop", "socket-close"]);
  assert.equal(fixture.rig.setPttOnCalls, 0);
});
~~~

- [ ] **Step 2: Run the targeted tests to verify red**

Run: `node --experimental-strip-types --test --test-name-pattern="next privileged WS|dekeys first|emergency stop remains|revocation invalidates" radio-lite-server/test/authenticated-websocket-registry.test.ts radio-lite-server/test/http-service.test.ts`

Expected: FAIL because WebSockets retain the login-time user object and revocation only changes stores.

- [ ] **Step 3: Implement revalidation and administration endpoints**

~~~ts
type WebSocketPrincipalSnapshot = {
  kind: "session" | "device"; credentialId: string; userId: string;
  authRevision: number; role: UserRole; canTransmit: boolean;
};
~~~

Before every ordinary control command other than `ping`, resolve the current session/device and compare enabled user ID, `authRevision`, role, and `canTransmit` to the snapshot. Give `tx.emergency-stop` a separate revalidation path: resolve the credential and current user, require only that both still exist and the user is enabled, then allow the stop even when `authRevision`, role, or `canTransmit` changed since socket authentication. It still requires no transmit privilege, control lease, transmit lease, hardware TX, or grid. A deleted/revoked credential or disabled user remains invalid; the mutation path must already invoke supervisor/media/digital stop ownership before closing that socket. Keep existing `GET /api/v1/users`, `POST /api/v1/users`, and `POST /api/v1/session/logout`; add `PATCH /api/v1/users/:userId` for admin role/canTransmit/enabled, `POST /api/v1/session/password` for the authenticated user's own password, `GET /api/v1/devices`, `PATCH /api/v1/devices/:deviceId` for its display name, and `DELETE /api/v1/devices/:deviceId`. Accept only `admin` and `operator` role values. For any lower privilege, password change, logout, disablement, or device revocation, synchronously invalidate each affected supervisor's outstanding transmit permit before the first await, then invoke supervisor/media/digital stop ownership, revoke the credential when required by that mutation, and close matching sockets. Audit success and denial actions after those safety actions; audit can never delay invalidation or de-key.

- [ ] **Step 4: Run the targeted tests to verify green**

Run: `node --experimental-strip-types --test --test-name-pattern="next privileged WS|dekeys first|emergency stop remains|revocation invalidates" radio-lite-server/test/authenticated-websocket-registry.test.ts radio-lite-server/test/http-service.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit account administration and live revocation**

~~~bash
git add radio-lite-server/src/server/authenticated-websocket-registry.ts radio-lite-server/src/auth/user-store.ts radio-lite-server/src/auth/device-store.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/authenticated-websocket-registry.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: revoke live radio credentials safely"
~~~


### Task 8: Rotating audit generations and durable TX-intent admission

**Files:**
- Modify: `radio-lite-server/src/auth/audit-log.ts`
- Modify: `radio-lite-server/src/rig/runtime-supervisor.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Test: `radio-lite-server/test/audit-log-rotation.test.ts`
- Test: `radio-lite-server/test/session-audit.test.ts`
- Test: `radio-lite-server/test/radio-runtime.test.ts`

**Consumes:** Plan 1 Task 4's transmit-start permit/generation and de-key ownership plus Task 7 audit event producers and revocation invalidation.

**Produces:** Durable audit handle generations, stable-ID cross-generation cursor paging, and a 250ms start-admission barrier that cannot outlive any stop/revocation/lifecycle generation.

- [ ] **Step 1: Write failing rotation and TX-admission tests**

~~~ts
test("rotation closes current handle before rename and preserves five generations", async () => {
  await appendUntilRotation(log);
  assert.deepEqual(await names(directory), ["audit.1.jsonl", "audit.2.jsonl", "audit.3.jsonl", "audit.4.jsonl", "audit.jsonl"]);
  assert.equal(await readNewestAction(directory), "radio.ptt-start.requested");
});

test("late durable intent completion cannot rearm an expired transmit attempt", async () => {
  const result = runtime.startTransmit(owner, user, controlToken, "voice");
  await assert.rejects(result, /tx_audit_unavailable/);
  deferredSync.resolve();
  assert.equal(fakeRig.setPttOnCalls, 0);
  assert.equal(media.bindingCount, 0);
});

test("rotation crash points reopen one valid current generation without record loss", async () => {
  for (const crashPoint of ["after-sync", "after-close", "after-unlink-4", "after-rename", "after-create-current"] as const) {
    const fixture = await auditCrashFixture(crashPoint);
    await assert.rejects(fixture.triggerRotation(), SimulatedCrash);
    const reopened = await fixture.reopen();
    assert.deepEqual(await reopened.recordIds(), fixture.expectedCompleteRecordIds);
    assert.equal(await reopened.openCurrentHandleCount(), 1);
  }
});

test("startup ignores only a damaged final JSONL line", async () => {
  await writeFile(join(directory, "audit.jsonl"), validLine("a") + validLine("b") + "{broken");
  const repaired = await AuditLog.open(directory);
  assert.deepEqual((await repaired.readPage(null, 10)).records.map((record) => record.id), ["b", "a"]);
  assert.equal(repaired.diagnostics().includes("audit_tail_incomplete"), true);
  await repaired.append(event("c"));
  assert.deepEqual((await repaired.readPage(null, 10)).records.map((record) => record.id), ["c", "b", "a"]);
  await repaired.close();
  const reopened = await AuditLog.open(directory);
  assert.deepEqual((await reopened.readPage(null, 10)).records.map((record) => record.id), ["c", "b", "a"]);
});

test("cursor expires after its referenced generation rotates away", async () => {
  const first = await log.readPage(null, 1);
  await rotatePastRetention(log);
  await assert.rejects(log.readPage(first.nextCursor, 1), /audit_cursor_expired/u);
});

test("cursor follows an immutable generation after its file slot is renamed", async () => {
  await appendRecords(log, [event("a"), event("b"), event("c")]);
  const first = await log.readPage(null, 1);
  await rotateOnce(log); // the referenced current generation is now audit.1.jsonl
  const second = await log.readPage(first.nextCursor, 1);
  assert.equal(second.records[0].action, "b");
});

test("intent queue full write failure and sync timeout all keep PTT off", async () => {
  for (const failure of ["queue-full", "write-failed", "sync-timeout"] as const) {
    const fixture = transmitAuditFailureFixture(failure);
    await assert.rejects(fixture.startTransmit(), /tx_audit_unavailable/u);
    assert.equal(fixture.rig.setPttOnCalls, 0);
    assert.equal(fixture.runtime.interlock.snapshot().lease, null);
    assert.equal(fixture.media.bindingCount, 0);
  }
});

test("only one pending audit intent reservation exists per radio", async () => {
  const first = audit.appendSafetyIntent(intent("main"), now() + 250);
  await assert.rejects(audit.appendSafetyIntent(intent("main"), now() + 250), /tx_audit_unavailable/);
  await first;
});

test("emergency stop invalidates a start waiting on durable audit", async () => {
  const fixture = transmitAuditBarrierFixture();
  const pending = fixture.startTransmit();
  await fixture.permitReserved;
  await fixture.emergencyStop();
  fixture.auditSync.resolve();
  await assert.rejects(pending, /transmit_start_invalidated/u);
  assert.equal(fixture.rig.setPttOnCalls, 0);
  assert.equal(fixture.runtime.interlock.snapshot().lease, null);
  assert.equal(fixture.media.bindingCount, 0);
});

test("credential revocation invalidates a start waiting on durable audit", async () => {
  const fixture = transmitAuditBarrierFixture();
  const pending = fixture.startTransmit();
  await fixture.permitReserved;
  await fixture.revokeCredential();
  fixture.auditSync.resolve();
  await assert.rejects(pending, /transmit_start_invalidated/u);
  assert.equal(fixture.rig.setPttOnCalls, 0);
});

test("deployment drain invalidates a start waiting on durable audit before its first await", async () => {
  const fixture = transmitAuditBarrierFixture();
  const pending = fixture.startTransmit();
  await fixture.permitReserved;
  const drain = (async () => {
    fixture.supervisor.invalidateTransmitStarts("deployment");
    fixture.events.push("drain-first-await");
    await fixture.finishDrain.promise;
  })();
  assert.deepEqual(fixture.events.slice(0, 2), [
    "transmit-start-invalidated", "drain-first-await",
  ]);
  fixture.auditSync.resolve();
  await assert.rejects(pending, /transmit_start_invalidated/u);
  assert.equal(fixture.rig.setPttOnCalls, 0);
  assert.equal(fixture.media.bindingCount, 0);
  fixture.finishDrain.resolve();
  await drain;
});

test("production PTT ON path is reserve durable audit then commit only", async () => {
  const runtimeSource = await readFile(new URL("../src/rig/radio-runtime.ts", import.meta.url), "utf8");
  const supervisorSource = await readFile(new URL("../src/rig/runtime-supervisor.ts", import.meta.url), "utf8");
  const outsideCoordinator = (await Promise.all([
    "../src/server/radio-lite-service.ts", "../src/media/media-hub.ts",
    "../src/digital/controller.ts",
  ].map((path) => readFile(new URL(path, import.meta.url), "utf8")))).join("\n");
  assert.match(runtimeSource, /reserveTransmitStart[\s\S]+appendSafetyIntent[\s\S]+commitTransmitStart/u);
  assert.doesNotMatch(supervisorSource,
    /^\s*(?:public\s+)?(?:async\s+)?(?:start|activate|activateTransmit)\s*(?:\(|=\s*(?:async\s*)?\()/mu);
  assert.doesNotMatch(outsideCoordinator,
    /\.(?:reserveTransmitStart|commitTransmitStart|setPttOn|activate|activateTransmit)\s*\(/u);
  assert.doesNotMatch(outsideCoordinator, /\.setPtt\s*\(\s*(?:true|1)\b/u);
  assert.equal((runtimeSource.match(/commitTransmitStart\s*\(/gu) ?? []).length, 1);
  assert.equal((runtimeSource.match(/\bstartTransmit\s*\(/gu) ?? []).length, 1);
});

test("administrator audit page returns a cursor while an operator is forbidden", async () => {
  const page = await getAsAdmin("/api/v1/audit?limit=2");
  assert.equal(page.records.length, 2);
  assert.equal(typeof page.nextCursor, "string");
  assert.equal((await getAsOperator("/api/v1/audit?limit=2")).status, 403);
});
~~~

- [ ] **Step 2: Run the targeted tests to verify red**

Run: `node --experimental-strip-types --test --test-name-pattern="preserves five generations|cannot rearm|rotation crash points|damaged final JSONL|cursor expires|immutable generation|queue full write failure|one pending audit|waiting on durable audit|deployment drain invalidates|PTT ON path is reserve|administrator audit page" radio-lite-server/test/audit-log-rotation.test.ts radio-lite-server/test/session-audit.test.ts radio-lite-server/test/radio-runtime.test.ts radio-lite-server/test/http-service.test.ts`

Expected: FAIL because audit opens a new file for each append, reads the complete file, and transmit starts before any durable intent.

- [ ] **Step 3: Implement generation barrier and admission**

~~~ts
const permit = await supervisor.reserveTransmitStart({
  radioId, ownerId, userId: user.id, mode,
  controlLeaseRevision, profileRevision,
});
try {
  await this.#audit.appendSafetyIntent({
    occurredAtMs: now(), action: "radio.ptt-start.requested", result: "success",
    actorUserId: user.id, targetId: radioId, metadata: { mode },
  }, now() + 250);
  return await supervisor.commitTransmitStart(permit, () =>
    this.#revalidateTransmitAuthorization(ownerId, user.id, controlToken));
} catch (error) {
  supervisor.abandonTransmitStart(permit, "audit_or_revalidation_failed");
  throw error;
}
~~~

Add administrator-only `GET /api/v1/audit`; its optional `limit` is an integer from 1 through 1000 and its optional `cursor` is the opaque string returned by the prior page. Return newest-first `AuditRecord` values plus `nextCursor`. `append(AuditEvent)` generates a unique record `id`; the stored JSONL value is `StoredAuditRecord` and also carries the current process-random immutable `generationId`, while the HTTP projection removes only `generationId`. Keep one opened current `FileHandle`, with safety FIFO 32 and ordinary FIFO 1024 but a single write at once; reserve at most one pending safety intent per `radioId` before enqueuing. Rotate at 8 MiB by sync, close, unlink `.4`, descending rename `.3→.4`, `.2→.3`, `.1→.2`, `current→.1`, create/open current with a new immutable generation ID, and directory fsync after affected Debian entries. Startup scans all five names, requires every complete record in a file to share one generation ID, and preserves complete records. A numbered immutable generation may ignore only its final incomplete line. Before reopening current for append, truncate an incomplete tail to the byte immediately after its last complete newline through the already opened current handle and fsync that file; then report in-memory/stderr `audit_tail_incomplete`. Never append a warning into the damaged log and never merely add a newline, which would turn the broken fragment into a permanent middle record. The reopen/append/reopen test must retain `c,b,a` across both reads. Encode paging cursor as immutable generation ID plus byte offset and locate that ID across all retained filenames, so one rotation/rename does not change the page target; return `audit_cursor_expired` only after retention removes it.

`RadioRuntime.startTransmit` is the only exported production voice/digital/tuning coordinator and every service/media/digital caller uses it; the supervisor exposes no direct `start`, `activate`, `activateTransmit`, raw PTT-ON, or equivalent activation surface. Reserve the supervisor's exact `TransmitStartPermit` before awaiting audit, but never hold the supervisor safety transaction across file I/O. Queue/full/write/sync/deadline failure abandons that exact permit. Audit success calls only `commitTransmitStart`: under the same per-radio safety transaction it verifies permit identity and `transmitAdmissionGeneration`, then revalidates lifecycle, fence/dekey/SWR state, profile revision, live user/auth revision/role/canTransmit, control lease, frequency and SWR. It repeats the permit-generation check after every awaited revalidation and immediately before activation. Emergency stop, deployment drain, service/runtime close, reconfiguration, owner/control loss, media/digital cancellation, logout, password/role/canTransmit/enable changes, and device revocation synchronously call `invalidateTransmitStarts` before any await; that method increments the independent generation and clears the one pending permit. Deployment drain must do this before awaiting a radio-state snapshot, OFF proof, audit completion, or cleanup; its snapshot therefore cannot report a pending admission as safe. If invalidation occurs while activation itself is awaiting CAT, the commit cannot return a lease or media binding and must enter the same supervisor OFF/readback recovery. A late durable write may remain recorded but can never call commit again or rearm the attempt, including after drain proceeds to fresh OFF verification. The static regression freezes the single `RadioRuntime.startTransmit -> reserve -> durable audit -> commitTransmitStart` path and scans service/media/digital callers for direct reservation, commit, activation, or PTT-ON bypasses.

- [ ] **Step 4: Run the targeted tests to verify green**

Run: `node --experimental-strip-types --test --test-name-pattern="preserves five generations|cannot rearm|rotation crash points|damaged final JSONL|cursor expires|immutable generation|queue full write failure|one pending audit|waiting on durable audit|deployment drain invalidates|PTT ON path is reserve|administrator audit page" radio-lite-server/test/audit-log-rotation.test.ts radio-lite-server/test/session-audit.test.ts radio-lite-server/test/radio-runtime.test.ts radio-lite-server/test/http-service.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit durable audit admission**

~~~bash
git add radio-lite-server/src/auth/audit-log.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/audit-log-rotation.test.ts radio-lite-server/test/session-audit.test.ts radio-lite-server/test/http-service.test.ts radio-lite-server/test/radio-runtime.test.ts
git commit -m "feat: require durable audit intent for transmit"
~~~

### Task 9: Profile redaction, health flags, and protocol contract

**Files:**
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/PROTOCOL.md`
- Test: `radio-lite-server/test/http-service.test.ts`

**Consumes:** Tasks 1--8.

**Produces:** Stable capability discovery and fully documented public contract.

- [ ] **Step 1: Write failing contract tests**

~~~ts
test("health returns stable feature flags", async () => {
  assert.deepEqual((await get("/healthz")).features, {
    hardwarePreflight: true, preflightProof: true, emergencyStop: true,
    safetyAlerts: true, accountAdministration: true, spectrumDisplayWindow: true,
    swrTripReset: true,
  });
});

test("operator profile projection omits raw hardware identifiers", async () => {
  const radio = (await getAsOperator("/api/v1/radios")).radios[0];
  assert.equal("devicePath" in radio.connection, false);
  assert.equal("path" in radio.ptt, false);
  assert.equal("id" in radio.audioInput, false);
  assert.deepEqual(radio.connection, { kind: "managed-serial" });
  assert.deepEqual(radio.ptt, { method: "RIG" });
  assert.deepEqual(radio.audioInput, { backend: "alsa" });
  assert.deepEqual(radio.audioOutput, { backend: "alsa" });
  assert.deepEqual(radio.allowedTransmitRangesHz, [{ lowerHz: 14_000_000, upperHz: 14_350_000 }]);
});
~~~

- [ ] **Step 2: Run the targeted tests to verify red**

Run: `node --experimental-strip-types --test --test-name-pattern="stable feature flags|omits raw hardware" radio-lite-server/test/http-service.test.ts`

Expected: FAIL because health has only protocolVersion and all authenticated callers receive stored profiles.

- [ ] **Step 3: Implement projection and document exact payloads**

~~~ts
function publicRadioProfile(profile: RadioProfile, administrator: boolean): unknown {
  if (administrator) return profile;
  const { connection, ptt, audioInput, audioOutput, ...safe } = profile;
  return { ...safe, connection: { kind: connection.kind },
    ptt: { method: ptt.method },
    audioInput: { backend: audioInput.backend },
    audioOutput: { backend: audioOutput.backend } };
}
~~~

Add the seven feature flags under the exact health key `features` to `GET /healthz`; the seventh is exact key `swrTripReset: true`. Freeze two role-aware read shapes: administrators receive complete editable hardware identifiers; operators receive the exact projection above, where connection/PTT/audio identifiers are intentionally absent but common radio/safety fields remain. A redacted read object is never accepted as an upsert profile. Update `PROTOCOL.md` with proof response/request fields and the three exact upsert envelopes; exact fence routes/states and the paired `reconfigurationEpoch`/`reconfigurationGeneration` rules for proof, save, cancel, and resume; range/SWR schema including persisted-only `configuration_required`, legacy safety-unconfigured behavior, acknowledged-warning semantics, and the administrator-only `POST /api/v1/radios/:radioId/swr-trip/reset` body `{ acknowledgePhysicalInspection: true }` from Server Safety Task 7. Freeze persistent safety kinds `swr_trip_latched` and `swr_rearm_pending`, and document `SwrSafetyStore` states `armed | latched | rearm_pending | rearm_in_progress`: a safe rearm sample durably returns to `armed`, never deletes the marker while RF may still be active, and only confirmed real PTT OFF with no intervening trip removes it; startup after a crash in `armed` or `rearm_in_progress` is latched. Also document both profile read shapes; the default direct-peer and explicit trusted-proxy-CIDR source policy; account/device/audit API authorization and `AuditRecord.id` plus opaque stable-generation cursor semantics; `Retry-After`; live revocation behavior; and stable error codes `invalid_forwarded_source`, `preflight_proof_required`, `preflight_requires_runtime_stop`, `stale_reconfiguration_generation`, `tx_safety_config_required`, `tx_audit_unavailable`, `audit_cursor_expired`, and `server_feature_unavailable`.

- [ ] **Step 4: Run the targeted tests to verify green**

Run: `node --experimental-strip-types --test --test-name-pattern="stable feature flags|omits raw hardware" radio-lite-server/test/http-service.test.ts`

Expected: PASS.

- [ ] **Step 5: Commit the public contract**

~~~bash
git add radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/PROTOCOL.md radio-lite-server/test/http-service.test.ts
git commit -m "docs: publish Radio Lite security capabilities"
~~~

## Final Verification

- [ ] **Step 1: Run type checking**

Run: `npm --prefix radio-lite-server run typecheck`

Expected: PASS with no TypeScript diagnostics.

- [ ] **Step 2: Run the complete server test suite**

Run: `npm --prefix radio-lite-server test`

Expected: PASS, including all existing tests and every new focused suite listed above.

- [ ] **Step 3: Run the combined package check**

Run: `npm --prefix radio-lite-server run check`

Expected: PASS; it runs type checking followed by the full `node:test` suite.

- [ ] **Step 4: Commit verification-only adjustments if any were required**

~~~bash
git status --short
git diff --check
~~~
