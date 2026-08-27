# Radio Lite Safety and Reliability Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the confirmed Radio Lite safety, weak-network, administration, spectrum, CI, IPA, and Debian deployment design without allowing independent implementations to compete for the same radio or UI state.

**Architecture:** Execute four subsystem plans in a fixed dependency order. The TypeScript runtime establishes the sole hardware/recovery owner and protocol first; authentication/configuration then consumes that owner; the SwiftUI client consumes the finished protocol; release and deployment run only after every preceding verification gate is green.

**Tech Stack:** Node.js 24.7.0, TypeScript 5.9, Node test runner, Hamlib rigctld, Swift 5.9, SwiftUI/iOS 17, XCTest, XcodeGen, GitHub Actions, Debian 13.

**Spec:** `docs/superpowers/specs/2026-08-26-radio-lite-safety-reliability-design.md`

## Global Constraints

- `RigRuntimeSupervisor` is the only owner of link recovery, rigctld restart/backoff, recovery generations, and de-key retry scheduling.
- `TransmitInterlock` may perform one supplied-transport de-key attempt but must never reconnect, restart, sleep, or schedule itself.
- External/manual PTT is alert-only unless an authenticated user explicitly invokes emergency stop.
- Emergency stop always reaches the requested radio's supervisor de-key attempt even if media/digital cleanup fails or candidate preflight currently owns its serial claim; no fallback to `main`.
- Only real `get_ptt=false` may clear `dekeyRequired`, the transmit fault, and the start prohibition.
- HTTP resource timeout remains 300 seconds; ordinary WebSocket command timeout is 15 seconds.
- The server, not local iOS button state or `rig.state.ptt`, is authoritative when `safetyAlerts` is negotiated.
- Complete safety snapshots include every configured radio and use persistent kinds that exclude `recovered`. Every message and disconnect callback carries the generation captured by its physical WebSocket; iOS matches begin/end by epoch plus active connection generation before selected-radio filtering, and a delayed old disconnect cannot discard the new envelope or mark the new connection stale.
- Every SafetyEventHub owner slot has a monotonic owner generation. Same-owner publish/replace/clear is compare-and-swap against the captured generation; stale active/OFF/SWR completions cannot downgrade, clear, or overwrite a newer de-key or SWR latch even when display precedence would otherwise permit it.
- Passwords remain any non-empty Unicode string; do not add length or complexity minimums.
- JSONL audit and ADIF stay plaintext; do not introduce SQLite.
- Legacy TX profiles use empty ranges plus `configuration_required`; only an explicit administrator SWR selection can replace that sentinel.
- `require_swr` start/rearm state is durably `armed` before PTT ON and remains `armed` for the entire live transmission; only confirmed PTT OFF with no trip removes it. Before runtimes/reset are exposed, startup uses the process-wide store FIFO to durably normalize crash-left `armed` and `rearm_in_progress` records to `latched`; administrator reset can then grant exactly one rearm. All SWR-state read/modify/write is process-wide serialized so concurrent radios cannot lose one another's record.
- A latched SWR trip requires an administrator's explicit physical-inspection reset through `POST /api/v1/radios/:radioId/swr-trip/reset`; reset grants one monitored rearm attempt and never clears the fail-closed marker while PTT is ON.
- Spectrum display range remains 3000–4000 Hz, default 4000 Hz, step 100 Hz.
- Normal background CAT traffic averages at most 2 commands/second idle and 4 commands/second transmitting in every consecutive 10-second window.
- Normal PTT admission uses one configured monotonic 500 ms deadline, including a 250 ms durable intent-audit sub-budget and the durable SWR armed-marker transaction; deadline expiry refuses PTT ON. No unrun storage benchmark is treated as proof, and emergency OFF/readback never waits for either write.
- Keep HTTP/Tailscale testing available with a persistent unencrypted-connection warning.
- Do not restore retired clients, the retired Python server, or retired product names.
- GitHub access uses only `.codex-ssh/github_radio_deploy_ed25519`, strict `.codex-ssh/github_known_hosts`, and SSH port 443; never run `gh auth login` or device authorization.
- Debian changes are confined to `/opt/testradio`; never modify or delete anything outside that directory.
- Service/deployment identities and dialout/audio device permissions are pre-existing, user-provided host prerequisites. Plans may read and verify their numeric IDs and configured device-GID allowlist only; they never create or modify users, groups, memberships, ACLs, `/etc`, or device state.
- Formal server/IPA artifacts require `release-readiness`; Debian deployment uses the root-only Node orchestrator and matching Linux N-API addon preinstalled in root-owned, non-writable `/opt/testradio/launcher`, never deployment code or an addon loaded through `current`/the candidate archive. It reuses `/opt/testradio/config/runtime.env` plus `/opt/testradio/data`. The exact old process re-reads a fresh all-runtime safety snapshot in the held drain/safety serialization, atomically consumes proof, and registers shutdown; proof issuance alone never authorizes a later stop.
- Schema-3 server manifests and the online updater support only launcher contract 1 and bind wrapper/orchestrator/updater/addon SHA-256 values. Ordinary deploy/rollback verifies installed `launcher.json` and bytes before candidate/drain, exits 78 on mismatch, and has no launcher writer. Launcher changes within contract 1 require the separate reviewed administrator updater: deploy lock + safe unconsumed drain, all staging/writes inside `/opt/testradio/launcher`, deprivileged addon load, identity committed last, then exact drain cancel. An interrupted understood contract-1 transaction may be explicitly resumed; an unknown future contract always fails closed and requires a separately designed/reviewed offline bootstrap, never online re-bootstrap or automatic upgrade.
- `release-readiness` exclusively owns the root-euid native/orchestrator suites with positive nonroot `RADIO_LITE_TEST_*` fixture identities. The dependent ordinary-user `server-release` packager never reruns privileged tests or builds test hooks; it rebuilds the production addon and performs only a clean-load/ABI smoke test before archiving.
- `push.paths` retains `ios/**`, `radio-lite-server/**`, and the workflow path and adds `web/**`, `deploy/**`, `scripts/**`, and `.node-version`. The `pull_request` event has no `paths`/`paths-ignore` filter, and none of the five required jobs has an event/path `if`, so every PR—including docs-only changes—reports terminal `server-check`, `web-check`, `protocol-contract`, `xcode-build-and-test`, and `release-readiness` results instead of leaving required checks Pending.
- Debian 13 `openat2` is mandatory with no fallback. Every managed read/write/create/rename/log/instance/runtime/current operation is anchored to retained directory FDs with `RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS|RESOLVE_NO_MAGICLINKS`, `O_NOFOLLOW`, and FD-level owner/mode/type/link checks. Every mutation pins both direct parents and accepts basenames only; `current` is the literal relative `releases/<40-hex-commit>` from `readlinkat`.
- Exact Node 24.7.0 at `/usr/bin/node`, plus fixed `/usr/bin/tar` and `/usr/share/nodejs/npm/bin/npm-cli.js`, are pre-existing read-only host prerequisites. Native code verifies their fixed paths and root-owned non-writable metadata before managed work; the authenticated manifest's Node version must equal the running process before candidate execution or drain. Top-level npm work always executes the fixed CLI through absolute `/usr/bin/node`, never `/usr/bin/npm`, `/usr/bin/env`, or PATH lookup. Hosted CI obtains a positive prerequisite case only through an opaque test-addon/private-fixture probe accepted by injected `runRelease`; production addon, environment, CLI, and `RADIO_LITE_TEST_*` expose no override, and setup-node must make the production entry fail 70 before managed access.
- `run/deploy.lock` is a preinstalled root-owned mode-0600 single-link file under a root-owned non-writable parent and is opened without `O_CREAT`. Archive/hash/commit siblings come from one pinned `incoming` dirfd; hash, tar listing, and extraction consume one native role-tagged read-only `ArchiveFd`, never a lock/log/general handle. Temporary stage creation returns its pinned dirfd plus generated basename. Every child uses a reviewed absolute executable and replaces supplementary groups before dropping identity: archive/candidate/health get none, while service/rollback get only configured device GIDs excluding the deployment group. Candidate, health, service, and rollback children inherit no root/staging/parent/deploy-lock FD. New/rollback services receive their reviewed/pinned `RADIO_LITE_RELEASE_COMMIT` separately from runtime.env, and unique instance record, control reply, and cwd inode must agree with it. `run/control` is service-UID/deployment-GID mode `02750` with SGID verified; socket and same-directory instance-record creation inherit deployment GID, and the non-root service never calls `chgrp`/`fchown` to that excluded group.
- Independent `run/service.lock` is preinstalled service-UID/service-GID mode 0600 under the same root-owned non-writable parent, opened without `O_CREAT`, and held by native nonblocking flock from before radio initialization until shutdown releases it last. Startup is bind-first; `instance.json` is published only after bind while locked. A live/unverifiable endpoint is never unlinked, ordinary stale cleanup needs dead-owner proof plus socket/record same-inode recheck and one bind retry, and rollback waits for the failed process to release the service lock. Shutdown unlinks its same-inode socket, then record, then releases the lock. A crash between the two unlinks produces record-only state recoverable only through a lease-bound opaque dead-owner proof with old-record-inode and current-new-socket-identity rechecks; socket-only/missing-record remains fail closed/manual repair.
- Deployment drain synchronously invalidates transmit-start permits before any await. A pending durable intent audit is explicitly unsafe, and its late completion cannot key after the drain generation advances. Every later mode/admission/dekey/SWR/external-PTT/telemetry-freshness/runtime-availability change advances a separate deployment safety generation and invalidates unconsumed proof. `consumeProof` must re-enumerate all configured runtimes and obtain fresh PTT/safety snapshots in the same held drain and safety serialization, recheck that safety generation after awaits, then atomically consume and register shutdown.
- Lost `proof-consume` replies authorize SIGTERM only after an authenticated `consume-status` proves the same consume attempt registered shutdown for the same boot/process identity, drain generation, and socket inode; without that proof the deploy remains fail closed and never signals or switches. The fixed launcher updater also owns SIGKILL recovery: under `deploy.lock` it validates the pinned `.update-*` transaction and cancels only the unconsumed drain matching its full generation/boot/process/socket tuple, so an old transaction cannot cancel a restarted service's or concurrent transaction's drain.

Unless a code block explicitly changes directory, every command in this roadmap and its four child plans runs from the repository worktree root. Server package commands therefore use `npm --prefix radio-lite-server`; focused server tests invoke Node with `--test-name-pattern` before the test-file glob so the filter is actually applied.

---

## Plan Set and Dependency Order

1. `2026-08-26-radio-lite-server-safety-runtime.md`
   - CI foundation, fault-injection seams, de-key latch, three-owner generation/CAS SafetyEventHub, media/digital stop propagation, unique runtime supervisor, managed rigctld restart, priority CAT transport, telemetry budget, frequency/SWR admission and persistent latch/rearm, shutdown order, lease split, WebSocket liveness, trusted source consumption, and emergency stop.
2. `2026-08-26-radio-lite-security-configuration.md`
   - Typed errors, explicit legacy safety sentinel, boot-unique preflight proof/fence refs, emergency preflight preemption, login and pairing limits, trusted-proxy source resolver, account/device revocation, audit generations and durable TX intent, role-aware profile redaction, seven feature flags, and protocol documentation.
3. `2026-08-26-radio-lite-ios-reliability.md`
   - Capability negotiation, timeouts, revision ownership, stop-pending retry, authoritative safety reducer/banner, SWR physical-inspection reset, settings/administration, per-row spectrum projection, accessibility, and haptics.
4. `2026-08-26-radio-lite-release-deployment.md`
   - Consume-time fresh drain proof and authenticated consume status, SGID service-owned socket/CLI, single-service lock/bind-first instance ownership and orphan-state recovery, contract-1/manual identity-last updater with transaction-bound cancel recovery, openat2-dirfd N-API release/rollback workflow, mechanically gated version/server-archive/IPA publication, repository checks, final documentation, and acceptance.

Plans 1 and 2 deliberately interleave at explicit ownership boundaries and remain serial around their shared files:

1. Server Safety Tasks 1–6 establish CI, latch/supervisor/transport, the sampler, and safety events.
2. Security Task 1 freezes `allowedTransmitRangesHz`, `swrPolicy`, migration, and typed errors.
3. Server Safety Tasks 7–9 consume that schema for runtime admission, shutdown, and media/digital behavior.
4. Security Tasks 2–8 add preflight, authentication, live identity revalidation, account/device administration, and audit.
5. Server Safety Task 10 consumes the live identity boundary and owns Origin/liveness, atomic safety snapshots, and emergency-stop WS dispatch.
6. Security Task 9 publishes the final `features`/profile/protocol contract after the server wire behavior exists.

Do not execute all of Plan 1 before Security Task 1, and do not let the two plans edit the following files concurrently:

- `radio-lite-server/src/server/radio-lite-service.ts`
- `radio-lite-server/src/rig/radio-runtime.ts`
- `radio-lite-server/src/config/types.ts`
- `radio-lite-server/src/auth/audit-log.ts`
- `radio-lite-server/test/http-service.test.ts`

The iOS plan starts only after Plans 1 and 2 freeze `PROTOCOL.md` fixtures. In the release/deployment plan execute Tasks 2→3→4 first, then Task 1 may enable the formal artifact jobs only after Plans 1–3 and those deployment tasks are green; `release-readiness` also fails mechanically when any required drain/socket/release source or test is absent. Task 5 follows artifact-contract verification.

## Specification Coverage Matrix

| Spec sections | Owning plan | Completion evidence |
| --- | --- | --- |
| §1–§3 | Roadmap global constraints + all four plans | Confirmed product decisions/non-goals are copied into plan constraints; no legacy stack, SQLite, forced TLS, or fictional hardware-watchdog work is introduced |
| §4–§7 | Server safety/runtime | Interlock, supervisor, transport, generation/CAS SafetyEventHub, media/digital, lease, WS, emergency tests |
| §8 runtime admission/SWR | Server safety/runtime | Profile-admission, cold-start/live sampler, durable armed/latch/rearm, serialized multi-radio store, trip/reset and crash tests |
| §8 persisted schema | Security/configuration | Strict profile parse/migration and proof-fingerprint tests |
| §9 | Security/configuration | Proof, stop-and-preflight fence, seven-feature flag and redaction tests |
| §10 | Server safety/runtime + security/configuration | Origin/liveness, trusted-proxy source resolution, and live identity revalidation/revocation tests |
| §11–§12 | Security/configuration | Login/pairing/account/device/audit tests |
| §13–§15 | iOS reliability | XCTest reducers, session ordering, UI policy and spectrum projection tests |
| §16 | Server safety/runtime + release/deployment | Required server/web jobs, reviewed server archive, and Debug/Release unsigned IPA artifacts |
| §17 | Every plan | Focused red/green tests plus final `npm run check`, Web, contract and XCTest runs |
| §18 | This roadmap | Ordered plan/task commits and review gates |
| §19 | Release/deployment | Consume-time all-runtime drain proof and registered-shutdown status, 02750 SGID control ownership, service.lock/bind-first/record-only recovery, contract-1 identity-last update plus transaction-bound cancel recovery, openat2/dirfd syscall-barrier release/rollback, and SSH policy verification |
| §20–§21 | Every plan | Final checklist and acceptance report with no deferred completion claim |

## Cross-Plan Interfaces That Must Not Drift

```ts
export type DeKeyOutcome =
  | { kind: "offConfirmed"; generation: number }
  | { kind: "recoveryPending"; generation: number }
  | { kind: "notResponsible"; generation: number };

export type SafetyAlertSnapshot = {
  t: "safety.snapshot";
  safetyEpoch: string;
  radioId: string;
  revision: number;
  alert: SafetyAlert | null;
};

export type ReconfigurationFenceRef = {
  reconfigurationEpoch: string;
  reconfigurationGeneration: number;
};

export type PersistentSafetyAlertKind = "active" | "external_ptt" |
  "telemetry_uncertain" | "swr_rearm_pending" | "swr_trip_latched" |
  "dekey_required" | "dekey_escalated";
export type SafetyEventKind = PersistentSafetyAlertKind | "recovered";

// Display precedence only; SafetyEventHub retains independent transmit, SWR, and telemetry slots.
// dekey_escalated > dekey_required > swr_trip_latched > swr_rearm_pending >
// active > external_ptt > telemetry_uncertain.
// Every owner slot also has a private monotonic ownerGeneration. publish/replace/clear must
// compare-and-swap the generation captured by that owner's state transition; stale same-owner
// completions do not mutate the slot or consume a radio revision.

export type RadioLiteFeatureFlags = {
  hardwarePreflight: boolean;
  preflightProof: boolean;
  emergencyStop: boolean;
  safetyAlerts: boolean;
  accountAdministration: boolean;
  spectrumDisplayWindow: boolean;
  swrTripReset: boolean;
};

export type RadioLiteHealthResponse = {
  status: "ok";
  service: "radio-lite";
  protocolVersion: 1;
  features: RadioLiteFeatureFlags;
};

export type ConfiguredSwrPolicy =
  | { mode: "require_swr"; trip: number; reset: number }
  | { mode: "acknowledged_internal_protection"; trip: number; reset: number };
export type PersistedSwrPolicy = ConfiguredSwrPolicy | { mode: "configuration_required" };

export type RadioProfileTransmitSafetyRead = {
  allowedTransmitRangesHz: readonly { lowerHz: number; upperHz: number }[];
  swrPolicy: PersistedSwrPolicy;
};

export type RadioProfileTransmitSafetyWrite = {
  allowedTransmitRangesHz: readonly { lowerHz: number; upperHz: number }[];
  swrPolicy: ConfiguredSwrPolicy;
};

export type SwrSafetyRecord = {
  radioId: string;
  state: "armed" | "latched" | "rearm_pending" | "rearm_in_progress";
  trippedAtMs: number | null;
};

export type DeploymentRadioState = {
  radioId: string;
  mode: "idle" | "voice" | "digital" | "tuning" | "fault";
  pendingTransmitAdmission: boolean;
  dekeyRequired: boolean;
  observedPtt: false | true | "unknown";
  observedAtMonotonicMs: number;
};
```

Persisted/read models may expose `configuration_required` only for migrated legacy hardware.
Strict HTTP upsert/write models never accept that sentinel; they require one explicit configured
policy. A redacted or legacy read model cannot be encoded directly as a write model.

```swift
struct RadioLiteSafetyAlertSnapshot: Codable, Equatable, Sendable {
    let safetyEpoch: String
    let radioId: String
    let revision: UInt64
    let alert: RadioLiteSafetyAlert?
}

struct SpectrumHistoryRow: Equatable, Sendable {
    let bins: [UInt8]
    let frameSpanHz: UInt32
    let centerFrequencyHz: UInt64
}

struct RadioLiteReconfigurationFenceRef: Codable, Equatable, Sendable {
    let reconfigurationEpoch: String
    let reconfigurationGeneration: UInt64
}
```

Any task that needs a different spelling or payload must first update the design, protocol contract, both language models, and this roadmap in one reviewed commit.

The stop-and-preflight wire contract is also frozen: `POST /api/v1/radios/:radioId/reconfiguration/preflight` returns both `reconfigurationEpoch` and `reconfigurationGeneration`; proof, fenced upsert, cancel, and resume carry the identical pair. Either field missing/stale fails before config/fence mutation, and a new process/supervisor epoch prevents numeric reuse. Dummy/TX-disabled upsert carries neither confirmation, proof, nor fence; enabled real-hardware ordinary upsert carries `hardwareTxConfirmation=profile.id` plus a valid ordinary proof but no fence; a stopped/reconfiguration-fenced upsert carries confirmation, proof, and the complete epoch/generation pair. Dummy/TX-disabled stray transmit fields, enabled-real missing confirmation/proof, and ordinary proof with a half or complete fence all fail before config writes. `tx.emergency-stop` requests and accepted replies both carry the captured current `radioId` and `commandId`; no implementation may hard-code `main`, and cleanup failure or a candidate-preflight serial claim cannot block the target supervisor's OFF/readback attempt. `POST /api/v1/radios/:radioId/swr-trip/reset` is administrator-only, requires the negotiated `swrTripReset` feature, records physical inspection, and grants exactly one monitored rearm without clearing an armed marker during PTT ON.

All request-source policy consumes one `resolveRequestSource(socketPeer, headers, trustedProxyCidrs)` result. With an empty allowlist, Forwarded/X-Forwarded-For are ignored. Only a peer inside an explicit IPv4/IPv6 CIDR may supply exactly one canonical forwarded IP; malformed or multiple forwarded values are rejected rather than guessed. IPv6 textual aliases are canonicalized and IPv4-mapped IPv6 collapses to the same dotted-quad identity before CIDR matching or bucket selection, so login and WS cannot split one client by spelling. Rate limiting, audit, and security decisions never read those headers directly.

## Execution and Review Gates

- [ ] **Gate 1: Record the clean baseline**

```powershell
git status --short
git rev-parse --short HEAD
npm --prefix radio-lite-server run check
npm --prefix web test
node scripts/check-ios-radio-lite-contract.mjs
```

Required evidence before implementation: only the pre-existing untracked `.superpowers/` may appear and all three commands must exit 0. If any command fails, record and repair that baseline in a separate reviewed commit before introducing the first planned red test; this gate does not claim the unchecked baseline is currently green.

- [ ] **Gate 2: Execute each task red → green → focused review → commit**

Every implementation task in the four plans has its own failing test, minimal implementation, focused green command, and explicit commit. Do not combine tasks merely because they touch the same large file.

- [ ] **Gate 3: Run a plan-level regression suite**

At the end of each plan, run every command listed in that plan and request a read-only review against the plan's starting commit. Critical and Important findings block the next plan.

- [ ] **Gate 4: Freeze the protocol before iOS integration**

```powershell
node scripts/check-ios-radio-lite-contract.mjs
git diff --check
```

Expected: the contract script verifies all seven feature flags including legacy-default-false `swrTripReset`, exact-radio emergency stop request/reply identity, persistent/event safety-kind split including SWR latch/rearm, complete snapshot begin/end handling, paired fence epoch/generation and all three upsert envelopes, SWR reset route, role-aware profile fixtures, timeout constants, and 4 kHz spectrum semantics.

- [ ] **Gate 5: Publish only after complete local and CI verification**

Run `check-radio-lite-release-readiness.mjs` and its deployment suites, then use the repository deploy key once. Formal artifacts must depend on the passing `release-readiness` job. If SSH push is unavailable, keep commits local and refresh the Git bundle; do not start another GitHub authorization flow.

- [ ] **Gate 6: Drain before every Debian replacement or rollback**

The deployment CLI must return a fresh safe-to-stop proof bound to the drain generation, deployment safety generation, exact process identity, and control-socket inode. Drain first invalidates transmit-start permits; an unresolved audited admission is unsafe, and its late audit completion cannot key. Any later mode/admission/dekey/SWR/external-PTT/telemetry-freshness/runtime-availability transition advances the safety generation. Before consume, any identity mismatch cancels that drain. Inside the exact old process and the same held drain/safety serialization, consume re-enumerates every configured runtime, obtains fresh PTT and complete safety snapshots, rechecks the safety generation after awaits, then atomically consumes the proof and records the consume attempt as registered with the idempotent shutdown owner. Active/unknown/external PTT, `dekeyRequired`, pending admission, stale proof, unavailable service, concurrent start, or changed safety generation aborts with zero shutdown, signal, release, or `current` mutation.

If the consume reply is lost, the runner must first obtain authenticated `consume-status` from the same control endpoint proving that exact attempt, boot/process identity, drain generation, and socket inode already registered shutdown; it may not infer success from process exit. Only after that proof may it wait for the exact old process, and only after a bounded wait plus a fresh `/proc` identity check may it issue limited SIGTERM. An unprocessed, expired, rejected, unreachable, mismatched, or pre-status-disappeared attempt remains fail closed and is never waited on, signalled, or followed by a `current` switch. Tests must cover both post-registration reply loss and request-not-processed/rejected-without-reply, with the latter asserting zero wait, signal, and `current` mutation.

The control directory must be service UID/deployment GID mode `02750` with SGID verified; its `0660` socket and same-directory mode-`0640` instance-record creation inherit deployment GID, and the non-root service never `chgrp`s to a group excluded from its supplementary groups. A second service fails before radio initialization and leaves a live endpoint/record untouched. Startup remains bind-first. Shutdown removes its same-inode socket, then instance record, then releases `service.lock`; a crash between unlinks is recovered only by a lease-bound opaque dead-owner proof that rechecks the stale record inode and currently bound new socket identity. Socket-only or `EADDRINUSE` with a missing record remains fail closed/manual repair. Rollback waits for the failed process to release the lock.

Schema-3 artifacts and the installed online updater accept only launcher contract 1. Mismatch or an unknown future contract exits 78 before candidate/drain/current mutation; future contracts require a separately reviewed offline bootstrap, never online re-bootstrap. A contract-1 launcher update uses the explicit updater, safe unconsumed drain, in-launcher staging, deprivileged addon load, and `launcher.json`-last commit. Before its first write it fsyncs a pinned `.update-*` transaction containing the drain generation, boot/process identity, socket inode, and target digests. After SIGKILL, only that fixed updater under `deploy.lock` may validate the complete transaction and request cancel with the full generation/boot/process/socket tuple; stale or mismatched transactions cannot cancel another drain.

Missing runtime env, socket/instance UID/GID/mode/inode mismatch, unavailable `openat2`, addon/architecture mismatch, or a lost deploy/service FD lock also aborts without replacing an unrelated process or managed inode. Every normal, rollback, orphan-endpoint, launcher-recovery, and filesystem-race test must exercise the real addon before/after-open barriers; source-text readiness assertions are only anti-regression guards, not the security proof.
