# Radio Lite Release and Safe Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce verified Debug and Release unsigned IPAs and deploy or roll back the Radio Lite server only after the running process proves every radio is safely stopped.

**Architecture:** CI reads one pinned Node version and permits formal artifacts only through a `release-readiness` job that mechanically proves the drain/socket/release workflow exists and passes alongside server/Web/protocol/XCTest. A process-local drain controller issues five-second, boot-bound safe-to-stop proofs; a service-owned Unix socket exposes an atomic consume-and-shutdown operation, while a separate lifetime `service.lock` prevents another process from deleting its live endpoint or replacing its unique instance record. A root-only Node release orchestrator owns one native Linux N-API secure-filesystem addon: every managed filesystem side effect is anchored to an already-open `/opt/testradio` directory FD with `openat2`, `fstat`, and `*at` operations. Root is the trusted deployment boundary; every child replaces inherited supplementary groups before dropping to the configured service UID/GID—archive/candidate/health children receive none, while only the long-running service receives the configured device-group allowlist. The orchestrator holds one close-on-exec deployment-lock FD, verifies the three downloaded artifact companions and tests a candidate before drain, then asks the exact old process to shut itself down before an FD-confined switch, health check, or rollback. The fixed `/bin/bash` shell entrypoint does nothing except `exec /usr/bin/node /opt/testradio/launcher/radio-lite-release.mjs "$@"`.

**Tech Stack:** GitHub Actions, Node.js 24.7.0, TypeScript 5.9, Node test runner, Swift 5.9, Xcode 16/XcodeGen, Bash exec wrapper, Linux N-API C addon, `openat2(2)`, Debian 13.

**Spec:** `docs/superpowers/specs/2026-08-26-radio-lite-safety-reliability-design.md`

## Global Constraints

- Execute this document in dependency order **Task 2 → Task 3 → Task 4 → Task 1 → Task 5**. Task 1 may enable formal artifact jobs only after Tasks 2–4 and all server/security/iOS plans are committed and green; its `release-readiness` job is an additional mechanical gate, not a substitute for that order.
- `server-check` and `web-check` are exact GitHub job IDs and display names and must gate both unsigned IPA configurations.
- Node's exact version is read from repository `.node-version`, initially `24.7.0`; do not duplicate a floating `24` in workflow jobs.
- Preserve Debug unsigned IPA and add Release unsigned IPA; neither artifact is signed.
- Publish `Radio-Lite-Server.tar.gz`, `Radio-Lite-Server.tar.gz.sha256`, and `Radio-Lite-Server.tar.gz.commit` from the reviewed CI commit only after `release-readiness`; deployment opens all three fixed sibling files through one pinned `incoming` directory FD, strictly parses both companions, and requires companion values, explicit reviewed arguments, the archive's actual digest, and `release.json` to agree.
- Bundle versions come only from `ios/RadioLite/project.yml` and the built Info.plist; do not hard-code `0.2.3` or `9` in packaging.
- A deployment proof is valid for at most five seconds and is bound to process boot ID plus one drain generation. `proof-consume` is not a proof-only state flip: while that drain generation is still held it re-enters the service safety serialization, obtains a second fresh all-radio PTT/SWR/de-key/pending-admission snapshot, and only then atomically consumes the proof and registers the existing shutdown owner. Any dynamic unsafe/unknown state leaves the request unconsumed and cannot request shutdown, signal a process, or switch `current`.
- Active transmission, a pending transmit admission/audit, `dekeyRequired`, external PTT ON, uncertain/stale PTT, service unavailability, stale proof, or concurrent start must stop deployment with no process or release switch.
- The drain fence survives CLI disconnect and continues to permit emergency stop.
- `enterDeploymentDrain` synchronously invalidates all outstanding transmit-start permits before any await. A durable TX-intent audit that completes afterward cannot commit PTT ON, and a still-pending admission makes the safety snapshot unsafe.
- One non-blocking `flock` on an `O_CLOEXEC` FD under `/opt/testradio/run` owns the entire deploy/rollback transaction; a concurrent invocation exits before drain and no child inherits the FD.
- Every release uses `/opt/testradio/config/runtime.env` and `/opt/testradio/data`; no start may fall back to `./data`, host `127.0.0.1`, or port `8787` accidentally. The changing `RADIO_LITE_RELEASE_COMMIT` is never stored in `runtime.env`: the orchestrator injects the reviewed new commit or pinned rollback commit separately into that service child only.
- All Debian files, sockets, releases, backups, logs, PID files, and rollback material remain under `/opt/testradio`.
- Debian must provide `openat2(2)`. `ENOSYS`, an unavailable/mismatched native addon, or any violated resolver/owner/mode/type/link constraint exits 70 before drain; there is no `lstat`/`realpath` fallback.
- The production release runner must start with effective UID 0 and rejects any non-root production invocation with exit 77 before opening a managed descendant, acquiring the deploy lock, or requesting drain. This root runner is the trusted deployment identity; the non-root deployment-group member is only a control-CLI/operator identity. Root privilege does not authorize the orchestrator to create, unlink, rename, or replace anything under service-owned `run/control`.
- Every child calls checked `setgroups` before checked `setresgid`/`setresuid` and `execve`. Archive listing/extraction, candidate tools, and health helpers receive `[]`; only new/rollback long-running services receive the strictly parsed `RADIO_LITE_SERVICE_DEVICE_GIDS` allowlist, which excludes 0, duplicates, the primary service GID, and the deployment GID. Any identity transition failure exits 77 and never runs the command; the program never edits group membership or ACLs.
- Service/deployment identities and dialout/audio device permissions are pre-existing, user-provided host prerequisites. This plan may read and verify their numeric IDs and configured device-GID allowlist only; it never creates or edits users/groups, memberships, ACLs, `/etc`, or device state.
- `/usr/bin/node`, `/usr/bin/tar`, and `/usr/share/nodejs/npm/bin/npm-cli.js` are pre-existing read-only host prerequisites. Native code verifies their literal paths, root-owned non-writable ancestors, owner/mode/type/link metadata, and requires `process.execPath === "/usr/bin/node"`; after authenticating the archive manifest but before candidate execution or drain, `process.versions.node` must exactly equal its `.node-version` (initially `24.7.0`). No deployment action installs or updates these host tools.
- Hosted `release-readiness` runners are not assumed to satisfy that Debian layout. The test addon alone may mint an opaque test-host-tool probe over a private root-owned fixture containing fake fixed-path Node/tar/npm-cli files and a reported exact `24.7.0`; injected `runRelease` may consume it only together with that test-addon brand. The production addon, environment, CLI, and `RADIO_LITE_TEST_*` variables expose no path/version override. The same suite separately invokes the production entry under setup-node and requires exit 70 for the real executable-path mismatch before `openRoot`, lock, or drain.
- Native spawn APIs directly `execve` only reviewed absolute executable constants (`/usr/bin/node` or `/usr/bin/tar`). Npm work uses a dedicated API that always executes `/usr/bin/node` with fixed first argument `/usr/share/nodejs/npm/bin/npm-cli.js`; `/usr/bin/npm`, relative/PATH-resolved, or any other executable is rejected before spawn.
- After opening the root, every descendant read, write, create, rename, link, unlink, lock, log redirection, instance/runtime read, release execution, and `current` switch goes through the native addon relative to retained directory FDs. Mutation APIs first pin each source and destination parent with `openat2`, then pass basenames only to `mkdirat`, `unlinkat`, `symlinkat`, `renameat`, or `renameat2`; Node and Bash never reopen a managed descendant by pathname.
- `/opt/testradio/launcher` is the explicit bootstrap trust boundary: the initial administrator bootstrap places the reviewed wrapper, orchestrator, updater, identity manifest, and matching addon there as root-owned and non-writable. The wrapper uses absolute `/usr/bin/node` and `/opt/testradio/launcher/radio-lite-release.mjs`, performs no managed data I/O, and production never starts deployment code through `current`. Code already loaded at bootstrap cannot claim to validate its own pathname retroactively.
- Initial bootstrap installs `launcher.json` plus the reviewed updater alongside that boundary. Every schema-3 `release.json` declares one exact launcher contract version and SHA-256 digests for the release wrapper, release orchestrator, updater, and secure-fs addon. After archive authentication but before candidate commands or drain, ordinary deploy/rollback compares the installed root-owned single-link files and `launcher.json` with that requirement; mismatch exits 78 `launcher_update_required` with zero candidate/drain/current mutation. Ordinary deploy/rollback contains no launcher writer. A launcher change requires the separately reviewed, explicit administrator updater, which holds `deploy.lock`, obtains but never consumes a safe drain, confines staging/mutations to `/opt/testradio/launcher`, commits `launcher.json` last, and cancels through its persisted exact-process transaction. Contract 1 updater transactions are recoverable through its installed `recover-cancel` command; an unknown, newer, or unparseable launcher contract fails closed before launcher/drain writes. Offline re-bootstrap for a future incompatible contract is a non-goal of this plan and requires a separately reviewed design.
- `run/deploy.lock` is preinstalled root-owned mode `0600` below root-owned, non-group-writable `run`. The addon opens it without `O_CREAT`; missing, replaced, wrong-owner/mode/type, or multi-link state exits 70. An untrusted identity therefore cannot swap the pathname and give a later contender a different lock inode.
- `run/service.lock` is independently preinstalled as a service-UID/service-GID mode-`0600`, single-link regular file below that same root-owned non-writable `run` parent. The non-root service opens it without `O_CREAT`, obtains a native non-blocking `flock`, and retains the close-on-exec lease for its complete lifetime. It acquires this guard before radio initialization and any control socket/instance-record mutation; a second/manual service exits without unlinking a live socket or replacing a live record. Clean shutdown removes only its same-inode socket/record and releases this lock last.
- The archive, `.sha256`, and `.commit` companions are opened once from the pinned `incoming` parent. SHA-256 uses `pread` on that retained archive FD, and tar listing/extraction receive the same FD at a fixed child descriptor through `/proc/self/fd/<N>`; a later pathname replacement cannot change the bytes listed or extracted.
- `current` is read with `readlinkat(rootFd, "current")`, accepts only the literal relative value `releases/<40-lowercase-hex-commit>`, and pins that release directory FD before process inspection. Switching uses `symlinkat` plus `renameat` under the same root FD.
- The service alone owns and may mutate `/opt/testradio/run/control`; bootstrap sets it to service UID/deployment GID exact mode `02750` (SGID set, group-write clear). The service is not a member of the deployment supplementary group: new socket and instance-record inodes inherit deployment GID from the SGID directory, and native code verifies that inheritance instead of attempting a non-root `chgrp`. The deployment-group CLI identity has traverse/read/connect but no directory-write permission. The root release runner is trusted but its addon API exposes only inspection/connect operations for this subtree. Socket identity still requires the boot-bound HMAC/process proof because Linux has no `connectat(2)`.
- A missing `proof-consume` reply is never shutdown evidence. The orchestrator may wait for or send a bounded signal to the exact process only after a read-only `consume-status` response for the identical `ConsumeAttemptRef`—attempt ID, drain generation, complete process identity, and socket device/inode—proves both one-time consumption and synchronous shutdown-owner registration. An unprocessed, expired, dynamically rejected, handler-rejected, unavailable, mismatched, or unverifiable request fails closed with zero signal and zero `current` mutation.
- Never delete `/opt/testradio`; never write, move, or delete anything outside it.
- Use only the repository SSH deploy key on port 443; never invoke GitHub CLI login or device authorization.
- Unless a block explicitly changes directory, run commands from the repository worktree root. Server commands use `npm --prefix radio-lite-server` or invoke Node against `radio-lite-server/test/*.test.ts`.

## File Structure

### Create

- `scripts/check-radio-lite-release-contract.mjs` — dependency-free CI/version/artifact drift check.
- `scripts/check-radio-lite-release-readiness.mjs` — verifies final drain/socket/release sources and tests exist on the artifact commit.
- `scripts/package-radio-lite-ipa.sh` — configuration-parameterized unsigned IPA packager.
- `scripts/package-radio-lite-server-release.sh` — deterministic commit archive, manifest, checksum, and reviewed-commit metadata packager.
- `radio-lite-server/src/deploy/drain-controller.ts` — drain generation, safety proof and rejection mapping.
- `radio-lite-server/src/deploy/deployment-safety-port.ts` — service/runtime adapter that fences admission and obtains same-generation fresh supervisor state.
- `radio-lite-server/src/deploy/control-socket.ts` — bounded local JSON-line Unix socket.
- `radio-lite-server/src/deploy/service-instance-guard.ts` — injectable single-service lease/stale-endpoint contract; Task 4 supplies its fixed-path native adapter.
- `radio-lite-server/src/deploy/deploy-cli.ts` — `drain`, `proof-consume`, read-only `consume-status`, and complete-owner-bound `drain-cancel` client with stable exit codes.
- `radio-lite-server/test/deployment-drain.test.ts` — fake-clock drain/proof/concurrency tests.
- `radio-lite-server/test/deployment-safety-port.test.ts` — service fence, fresh PTT, and emergency-stop integration tests.
- `radio-lite-server/test/deployment-control-socket.test.ts` — protocol, permission and disconnect tests.
- `deploy/native/radio_lite_secure_fs.c` — Linux N-API implementation of the root-FD/openat2/fstat/flock/spawn contract.
- `deploy/secure-fs.mjs` — narrow JavaScript loader and typed validation boundary for the packaged `.node` addon.
- `deploy/radio-lite-release.mjs` — scoped stage/start/health/rollback orchestrator; the only deployment workflow owner.
- `deploy/radio-lite-release.sh` — constant exec-only compatibility entrypoint; it performs no managed filesystem I/O.
- `deploy/launcher-contract.json` — strict launcher manifest/ABI version source shared by packaging, bootstrap, updater, and deploy compatibility checks.
- `deploy/radio-lite-launcher-update.mjs` — explicit root-only, drain-safe launcher updater; ordinary deploy never calls it.
- `deploy/test-secure-fs-linux.mjs` — deterministic syscall-barrier, owner/mode, FD, lock, and child-inheritance tests.
- `deploy/test-radio-lite-release.mjs` — temporary-root command-fake tests for the Node workflow.
- `scripts/build-radio-lite-secure-fs.sh` — builds the N-API addon for the release runner's Linux architecture.
- `docs/DEPLOYMENT.md` — repository ruleset, artifact, drain and `/opt/testradio` operator contract.

### Modify

- `.github/workflows/ios.yml` — Release gating, version file, Web/server jobs, dual IPA builds.
- `scripts/check-ios-radio-lite-contract.mjs` — include the release-contract check.
- `radio-lite-server/package.json` — local deploy CLI script.
- `radio-lite-server/src/index.ts` — acquire the native service-instance lease, then own and close the local control socket with the service.
- `radio-lite-server/src/server/radio-lite-service.ts` — expose the already-tested lifecycle drain port.
- `radio-lite-server/src/rig/runtime-supervisor.ts`, `radio-lite-server/src/rig/radio-runtime.ts` — expose a safety-serialized same-generation fresh deployment snapshot without a parallel transport.
- `radio-lite-server/test/http-service.test.ts` — one process-boundary drain integration case.
- `README.md`, `ios/README.md`, `docs/SAFETY.md`, `docs/HAMLIB.md`, `radio-lite-server/PROTOCOL.md` — current stack and release instructions.

## Consumed Interfaces

Task 2 in this plan creates a radio-safe lifecycle adapter over the completed runtime supervisors; it does not create another CAT transport or recovery loop:

```ts
export type DeploymentRadioState = {
  radioId: string;
  mode: "idle" | "voice" | "digital" | "tuning" | "fault";
  pendingTransmitAdmission: boolean;
  dekeyRequired: boolean;
  swrSafetyState: "clear" | "latched" | "rearm_pending" | "unknown";
  observedPtt: false | true | "unknown";
  observedAtMonotonicMs: number;
};

export type DeploymentProcessIdentity = {
  bootId: string;
  pid: number;
  processStartToken: string;
  cwd: string;
  releaseCommit: string;
};

export type DeploymentControlEndpointIdentity = {
  device: string;
  inode: string;
};

export type DrainOwnerRef = {
  drainGeneration: number;
  process: DeploymentProcessIdentity;
  socket: DeploymentControlEndpointIdentity;
};

export type ConsumeAttemptRef = DrainOwnerRef & {
  consumeAttemptId: string;
};

export type DeploymentSafetySnapshot = {
  deploymentSafetyGeneration: number;
  radios: readonly DeploymentRadioState[];
};

export interface DeploymentSafetyPort {
  enterDeploymentDrain(generation: number): void;
  confirmDeploymentSafe(generation: number): Promise<DeploymentSafetySnapshot>;
  recommitDeploymentSafe<T>(generation: number, expectedSafetyGeneration: number,
    commit: (snapshot: DeploymentSafetySnapshot) => T): Promise<T>;
  cancelDeploymentDrain(generation: number): void;
}

export interface DeploymentSafetySnapshotSource {
  deploymentSafetySnapshot(drainGeneration: number): Promise<DeploymentRadioState>;
}
```

`RigRuntimeSupervisor` implements `DeploymentSafetySnapshotSource` on its existing per-radio safety serialization. `RadioRuntimeRegistry.deploymentSafetySnapshots(drainGeneration)` enumerates every configured profile, reuses its already-managed supervisor, and returns `observedPtt: "unknown"` plus `swrSafetyState: "unknown"` for a missing, initializing, failed, stale-generation, or unavailable supervisor; it never silently omits a configured radio or creates a second transport. The service owns a monotonic `deploymentSafetyGeneration` advanced whenever any configured radio's mode, pending-admission, de-key, SWR, external-PTT, telemetry-freshness, or runtime-availability safety projection changes. `enterDeploymentDrain` first advances the service transmit-admission generation and calls `invalidateTransmitStarts("deployment")` synchronously, then fences new upgrade, control, and TX admission before any PTT read. It must not close media, digital, sockets, listeners, or processes. `pendingTransmitAdmission` remains true while a reserved intent audit or permit commit is unresolved; such a state cannot produce a proof. `confirmDeploymentSafe` accepts only results produced for its still-held generation and returns the complete radio array plus the post-await `deploymentSafetyGeneration`, which is signed into the proof. At consume time `recommitDeploymentSafe` re-enters that same held-generation service serialization, obtains a new snapshot from every configured runtime through its per-radio safety serialization, and after every await rechecks both the held drain generation and the proof's expected safety generation before invoking its non-async `commit` callback. A generation change, fresh PTT ON/unknown, de-key requirement, pending admission, fault/unavailable state, or unknown SWR state rejects without invoking `commit`; an already-persisted `latched`/`rearm_pending` SWR state may survive a safe service stop only when fresh PTT is OFF and no de-key/admission is pending. The callback marks the proof consumed and synchronously registers the existing idempotent shutdown owner as one indivisible transition. The control plane captures `DeploymentProcessIdentity` from the running service; no external process signal substitutes for this consume registration.

---

### Task 1: Define and satisfy the server and dual-IPA release contract

**Files:**
- Create: `scripts/check-radio-lite-release-contract.mjs`
- Create: `scripts/check-radio-lite-release-readiness.mjs`
- Create: `scripts/package-radio-lite-ipa.sh`
- Create: `scripts/package-radio-lite-server-release.sh`
- Modify: `scripts/check-ios-radio-lite-contract.mjs`
- Modify: `.github/workflows/ios.yml`

**Interfaces:**
- Consumes: `.node-version`, `.github/workflows/ios.yml`, `ios/RadioLite/project.yml`, and completed Tasks 2–4 drain/socket/release/launcher-contract files and tests.
- Produces: a zero-exit drift check required by `protocol-contract`; a `release-readiness` job that depends on `server-check`, `web-check`, `protocol-contract`, and `xcode-build-and-test` and runs the deployment suites; a schema-3 `Radio-Lite-Server.tar.gz` whose manifest binds the launcher contract/component digests plus companions; and both unsigned IPAs. Formal artifact jobs depend only on the successful `release-readiness` job, so an intermediate commit missing Tasks 2–4 cannot publish them.

- [ ] **Step 1: Create the exact static contract checker**

```js
#!/usr/bin/env node
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const nodeVersion = read(".node-version").trim();
const workflow = read(".github/workflows/ios.yml").replace(/\r\n/gu, "\n");
const project = read("ios/RadioLite/project.yml");
const serverPackager = read("scripts/package-radio-lite-server-release.sh");
const launcherContract = JSON.parse(read("deploy/launcher-contract.json"));
const jobBlock = (id) => {
  const marker = `  ${id}:\n`;
  const start = workflow.indexOf(marker);
  assert.notEqual(start, -1, `missing job: ${id}`);
  const tail = workflow.slice(start + marker.length);
  const next = tail.search(/^  [A-Za-z0-9_-]+:\n/mu);
  return next === -1 ? tail : tail.slice(0, next);
};
const eventBlock = (id) => {
  const onMarker = "on:\n";
  const onStart = workflow.indexOf(onMarker);
  const jobsStart = workflow.indexOf("\njobs:\n", onStart + onMarker.length);
  assert.notEqual(onStart, -1, "missing workflow triggers");
  assert.notEqual(jobsStart, -1, "missing jobs after workflow triggers");
  const events = workflow.slice(onStart + onMarker.length, jobsStart + 1);
  const marker = `  ${id}:\n`;
  const start = events.indexOf(marker);
  assert.notEqual(start, -1, `missing workflow event: ${id}`);
  const tail = events.slice(start + marker.length);
  const next = tail.search(/^  [A-Za-z0-9_-]+:\n/mu);
  return next === -1 ? tail : tail.slice(0, next);
};

assert.equal(nodeVersion, "24.7.0");
assert.deepEqual(launcherContract, { schemaVersion: 1, contractVersion: 1 });
for (const path of ["ios/**", "radio-lite-server/**", "web/**", "deploy/**",
  "scripts/**", ".node-version", ".github/workflows/ios.yml"]) {
  assert.equal(eventBlock("push").split("\n")
    .filter((line) => line.trim() === `- ${path}`).length,
    1, `push must include ${path}`);
}
assert.doesNotMatch(eventBlock("pull_request"), /^\s+(?:paths|paths-ignore):/mu,
  "pull_request must be unfiltered so every required check reports");
assert.match(workflow, /server-check:\n\s+name: server-check/u);
assert.match(workflow, /web-check:\n\s+name: web-check/u);
assert.match(workflow, /node-version-file:\s*\.node-version/u);
assert.match(workflow, /configuration:\s*\[Debug, Release\]/u);
assert.match(workflow, /server-release:\n\s+name: server-release/u);
assert.match(jobBlock("release-readiness"), /needs:\s*\[server-check, web-check, protocol-contract, xcode-build-and-test\]/u);
assert.match(jobBlock("release-readiness"), /check-radio-lite-release-readiness\.mjs/u);
assert.match(jobBlock("release-readiness"), /test-radio-lite-release\.mjs/u);
assert.match(jobBlock("release-readiness"), /test-secure-fs-linux\.mjs/u);
assert.match(jobBlock("release-readiness"), /radio-lite-launcher-update\.mjs/u);
assert.match(jobBlock("release-readiness"), /--test-hooks/u);
assert.match(jobBlock("release-readiness"), /sudo env/u);
for (const token of ["RADIO_LITE_SECURE_FS_TEST_ADDON", "RADIO_LITE_TEST_SERVICE_UID",
  "RADIO_LITE_TEST_SERVICE_GID", "RADIO_LITE_TEST_DEPLOY_GID",
  "RADIO_LITE_TEST_DEVICE_GIDS"]) {
  assert.match(jobBlock("release-readiness"), new RegExp(token, "u"), token);
}
const normalizedReadinessJob = jobBlock("release-readiness")
  .split("\n").map((line) => line.trim()).join("\n");
const privilegedSuiteChain = [
  "sudo env \\",
  'RADIO_LITE_SECURE_FS_TEST_ADDON="$PWD/deploy/native/radio_lite_secure_fs.test.node" \\',
  'RADIO_LITE_TEST_SERVICE_UID="$test_uid" \\',
  'RADIO_LITE_TEST_SERVICE_GID="$test_gid" \\',
  'RADIO_LITE_TEST_DEPLOY_GID="$((test_gid + 1))" \\',
  'RADIO_LITE_TEST_DEVICE_GIDS="$((test_gid + 2)),$((test_gid + 3))" \\',
  '"$node_bin" --test deploy/test-secure-fs-linux.mjs deploy/test-radio-lite-release.mjs',
].join("\n");
assert.equal(normalizedReadinessJob.includes(privilegedSuiteChain), true,
  "both privileged suites must run under the same sudo fixture chain");
assert.match(jobBlock("server-release"), /needs:\s*\[release-readiness\]/u);
assert.doesNotMatch(jobBlock("server-release"),
  /(?:\bsudo\b|RADIO_LITE_(?:SECURE_FS_TEST_ADDON|TEST_)|--test-hooks|radio_lite_secure_fs\.test\.node|test-(?:secure-fs-linux|radio-lite-release)\.mjs)/u);
assert.match(jobBlock("unsigned-device-ipa"), /needs:\s*\[release-readiness\]/u);
for (const id of ["server-check", "web-check", "protocol-contract",
  "xcode-build-and-test", "release-readiness"]) {
  assert.doesNotMatch(jobBlock(id), /^    if:/mu,
    `${id} must report for every pull request`);
}
assert.match(workflow, /package-radio-lite-server-release\.sh/u);
assert.match(workflow, /Radio-Lite-Server\.tar\.gz\.sha256/u);
assert.match(workflow, /Radio-Lite-Server\.tar\.gz\.commit/u);
assert.match(serverPackager, /build-radio-lite-secure-fs\.sh[\s\S]*radio_lite_secure_fs\.node/u);
assert.match(serverPackager, /node -e ['"]require\(process\.argv\[1\]\)['"]/u);
assert.match(serverPackager, /schemaVersion[^\n]*3/u);
for (const field of ["contractVersion", "releaseWrapperSha256",
  "releaseOrchestratorSha256", "updaterSha256", "secureFsAddonSha256"]) {
  assert.match(serverPackager, new RegExp(field, "u"), field);
}
assert.doesNotMatch(serverPackager,
  /(?:\bsudo\b|RADIO_LITE_(?:SECURE_FS_TEST_ADDON|TEST_)|--test-hooks|radio_lite_secure_fs\.test\.node|test-(?:secure-fs-linux|radio-lite-release)\.mjs)/u);
assert(!workflow.includes('= "0.2.3"'));
assert(!workflow.includes('= "9"'));
assert.match(project, /MARKETING_VERSION:\s*\S+/u);
assert.match(project, /CURRENT_PROJECT_VERSION:\s*\S+/u);
```

`check-radio-lite-release-readiness.mjs` must fail unless the reviewed tree contains the exact
drain controller/safety port/control socket/CLI/native addon/Node orchestrator and their five test files, and unless
`radio-lite-server/package.json` exposes the deploy CLI. It reads source text only; the CI job then
executes those tests, so adding empty files cannot satisfy readiness.

```js
#!/usr/bin/env node
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const required = [
  "radio-lite-server/src/deploy/drain-controller.ts",
  "radio-lite-server/src/deploy/deployment-safety-port.ts",
  "radio-lite-server/src/deploy/control-socket.ts",
  "radio-lite-server/src/deploy/deploy-cli.ts",
  "radio-lite-server/src/deploy/service-instance-guard.ts",
  "radio-lite-server/test/deployment-drain.test.ts",
  "radio-lite-server/test/deployment-safety-port.test.ts",
  "radio-lite-server/test/deployment-control-socket.test.ts",
  "deploy/native/radio_lite_secure_fs.c",
  "deploy/secure-fs.mjs",
  "deploy/radio-lite-release.mjs",
  "deploy/radio-lite-release.sh",
  "deploy/launcher-contract.json",
  "deploy/radio-lite-launcher-update.mjs",
  "deploy/test-secure-fs-linux.mjs",
  "deploy/test-radio-lite-release.mjs",
  "scripts/build-radio-lite-secure-fs.sh",
];
for (const path of required) assert.equal(existsSync(new URL(`../${path}`, import.meta.url)), true, path);
assert.match(read("radio-lite-server/src/deploy/drain-controller.ts"), /class DeploymentDrainController/u);
const controlSource = read("radio-lite-server/src/deploy/control-socket.ts");
const deployCliSource = read("radio-lite-server/src/deploy/deploy-cli.ts");
const serviceGuardSource = read("radio-lite-server/src/deploy/service-instance-guard.ts");
assert.match(controlSource, /class DeploymentControlSocket/u);
assert.match(controlSource, /consumeAttemptId/u);
assert.match(controlSource, /deploymentSafetyGeneration/u);
assert.match(deployCliSource, /deploymentSafetyGeneration/u);
assert.match(read("radio-lite-server/src/deploy/drain-controller.ts"),
  /deploymentSafetyGeneration/u);
assert.match(serviceGuardSource, /acquireServiceInstanceGuard/u);
assert.match(serviceGuardSource, /0o2750/u);
assert.doesNotMatch(controlSource + serviceGuardSource, /\b(?:chgrp|chown|fchown)\b/u,
  "non-root control startup must rely on SGID inheritance, not ownership changes");
assert.match(read("radio-lite-server/src/index.ts"), /startControlPlaneWithGuard/u);
const nativeSource = read("deploy/native/radio_lite_secure_fs.c");
for (const token of ["SYS_openat2", "RESOLVE_BENEATH", "RESOLVE_NO_SYMLINKS",
  "RESOLVE_NO_MAGICLINKS", "fstat", "flock", "LOCK_EX", "LOCK_NB", "FD_CLOEXEC", "S_ISGID", "setgroups",
  "setresgid", "setresuid", "renameat", "F_GETFL", "execve"]) {
  assert.match(nativeSource, new RegExp(token, "u"), token);
}
assert.match(nativeSource, /\/usr\/share\/nodejs\/npm\/bin\/npm-cli\.js/u);
assert.doesNotMatch(nativeSource, /\/usr\/bin\/npm/u);
assert.match(nativeSource, /service\.lock/u);
assert.match(nativeSource, /acquireServiceInstanceGuard/u);
const releaseSource = read("deploy/radio-lite-release.mjs");
assert.match(releaseSource, /proof-consume/u);
assert.match(releaseSource, /consume-status/u);
assert.match(releaseSource, /verifyHostToolPrerequisites/u);
assert.match(releaseSource, /launcher_update_required/u);
assert.doesNotMatch(releaseSource, /updateLauncherComponents/u);
assert.match(releaseSource, /openRoot/u);
assert.match(releaseSource, /RADIO_LITE_RELEASE_COMMIT/u);
assert.match(releaseSource, /RADIO_LITE_SERVICE_DEVICE_GIDS/u);
const wrapper = read("deploy/radio-lite-release.sh");
assert.match(wrapper,
  /^#!\/bin\/bash\nset -euo pipefail\nexec \/usr\/bin\/node \/opt\/testradio\/launcher\/radio-lite-release\.mjs /u);
assert.doesNotMatch(wrapper, /(?:realpath|lstat|ensure_managed_|exec\s+[0-9]+>>|[<>].*testradio)/u);
assert.match(read("radio-lite-server/test/deployment-drain.test.ts"),
  /test\(\s*["'`]drain fences starts before reading every radio/u);
assert.match(read("radio-lite-server/test/deployment-drain.test.ts"),
  /test\(\s*["'`]consume rejects a changed deployment safety generation after awaited reread/u);
assert.match(read("radio-lite-server/test/deployment-safety-port.test.ts"),
  /test\(\s*["'`]deployment adapter fences transmit before fresh reads/u);
const controlTests = read("radio-lite-server/test/deployment-control-socket.test.ts");
assert.match(controlTests,
  /test\(\s*["'`]proof consume atomically requests shutdown/u);
assert.match(controlTests,
  /test\(\s*["'`]consume rechecks every radio before registering shutdown/u);
assert.match(controlTests,
  /test\(\s*["'`]consume status is read-only, binds to, and echoes the identical ConsumeAttemptRef/u);
assert.match(controlTests,
  /test\(\s*["'`]drain cancel rejects every mismatched owner field and echoes the identical DrainOwnerRef/u);
assert.match(controlTests,
  /test\(\s*["'`]instance record matches the control response/u);
assert.match(controlTests,
  /test\(\s*["'`]startup rejects release commit mismatch/u);
assert.match(controlTests,
  /test\(\s*["'`]second service cannot unlink a live control socket/u);
assert.match(controlTests,
  /test\(\s*["'`]instance probe binds the nonce to the serving process identity/u);
assert.match(controlTests,
  /test\(\s*["'`]control socket binds first and stale recovery requires same-inode/u);
assert.match(controlTests,
  /test\(\s*["'`]service lock is acquired before bind record or radio initialization/u);
assert.match(controlTests,
  /test\(\s*["'`]control directory SGID supplies deployment gid without service group membership/u);
assert.match(controlTests,
  /test\(\s*["'`]bound socket removes only a proven dead orphan record/u);
assert.match(controlTests,
  /test\(\s*["'`]shutdown cleanup orders listener socket record and service lock/u);
assert.match(controlTests,
  /test\(\s*["'`]record swap at cleanup cannot unlink the replacement/u);
assert.match(controlTests,
  /test\(\s*["'`]socket-only orphan without a record requires manual repair/u);
assert.match(read("deploy/test-radio-lite-release.mjs"),
  /test\(\s*["'`]concurrent deployment loses the lock before drain/u);
assert.match(read("deploy/test-secure-fs-linux.mjs"),
  /test\(\s*["'`]openat2 rejects symlink substituted at pre-open barrier without external mutation/u);
const releaseTests = read("deploy/test-secure-fs-linux.mjs") +
  read("deploy/test-radio-lite-release.mjs");
assert.match(releaseTests,
  /test\(\s*["'`]opened log FD remains safe when its pathname is swapped after open/u);
assert.match(releaseTests,
  /test\(\s*["'`]preinstalled lock inode cannot be substituted/u);
assert.match(releaseTests,
  /test\(\s*["'`]service lock is close-on-exec held for process lifetime/u);
assert.match(releaseTests,
  /test\(\s*["'`]stale control socket requires dead owner proof and same-inode recheck/u);
assert.match(releaseTests,
  /test\(\s*["'`]bound socket removes only a proven dead orphan record/u);
assert.match(releaseTests,
  /test\(\s*["'`]shutdown cleanup orders listener socket record and service lock/u);
assert.match(releaseTests,
  /test\(\s*["'`]socket-only orphan without a record requires manual repair/u);
assert.match(releaseTests,
  /test\(\s*["'`]rollback waits for the failed service to release service lock/u);
assert.match(releaseTests,
  /test\(\s*["'`]service-owned stage seals to a root-owned traversable release/u);
assert.match(releaseTests,
  /test\(\s*["'`]zero or invalid service identity is rejected before child execution/u);
assert.match(releaseTests,
  /test\(\s*["'`]runtime environment exact key set rejects injected commit/u);
assert.match(releaseTests,
  /test\(\s*["'`]companion files are mandatory strict and cross-checked/u);
assert.match(releaseTests,
  /test\(\s*["'`]archive pathname replacement after hash cannot change listed or extracted bytes/u);
assert.match(releaseTests,
  /test\(\s*["'`]archive spawn rejects every non-ArchiveFd handle/u);
assert.match(releaseTests,
  /test\(\s*["'`]temporary stage returns its generated basename/u);
assert.match(releaseTests,
  /test\(\s*["'`]spawn rejects relative PATH and unreviewed absolute executables/u);
assert.match(releaseTests,
  /test\(\s*["'`]host Node and npm CLI prerequisites fail before drain/u);
assert.match(read("deploy/test-radio-lite-release.mjs"),
  /test\(\s*["'`]setup-node production entry rejects before managed access/u);
assert.match(releaseTests,
  /test\(\s*["'`]release manifest binds the launcher contract and component digests/u);
assert.match(releaseTests,
  /test\(\s*["'`]installed launcher bytes must match launcher identity before candidate/u);
assert.match(releaseTests,
  /test\(\s*["'`]incompatible launcher rejects before candidate drain or current mutation/u);
assert.match(releaseTests,
  /test\(\s*["'`]compatible launcher permits deployment without rewriting launcher/u);
const launcherUpdaterSource = read("deploy/radio-lite-launcher-update.mjs");
assert.match(launcherUpdaterSource, /updateLauncherComponents/u);
assert.match(launcherUpdaterSource, /recover-cancel/u);
assert.match(releaseTests,
  /test\(\s*["'`]explicit launcher update is confined to launcher and commits identity last/u);
assert.match(releaseTests,
  /test\(\s*["'`]interrupted launcher update fails closed/u);
assert.match(releaseTests,
  /test\(\s*["'`]unknown launcher contract fails closed without writes/u);
assert.match(releaseTests,
  /test\(\s*["'`]recover cancel after SIGKILL targets only the recorded live drain owner/u);
assert.match(releaseTests,
  /test\(\s*["'`]old launcher transaction cannot cancel a replacement process or newer drain/u);
assert.match(releaseTests,
  /test\(\s*["'`]normal install and failed-health rollback pin mutation parents/u);
assert.match(read("deploy/test-secure-fs-linux.mjs"),
  /test\(\s*["'`]current read pins release directory FD across current swap/u);
assert.match(read("deploy/test-secure-fs-linux.mjs"),
  /test\(\s*["'`]control directory SGID supplies deployment gid without service group membership/u);
assert.match(releaseTests,
  /test\(\s*["'`]children inherit no deploy root staging parent or lock FDs/u);
assert.match(releaseTests,
  /test\(\s*["'`]child supplementary groups are scoped by role/u);
assert.match(releaseTests,
  /test\(\s*["'`]privileged harness preserves a nonroot service identity/u);
assert.match(releaseTests,
  /test\(\s*["'`]release start reuses config and injects the matching/u);
assert.match(releaseTests,
  /test\(\s*["'`]ordinary deploy and rollback never mutate launcher/u);
assert.match(releaseTests,
  /test\(\s*["'`]launcher update rejects active transmission and cancels its held drain/u);
assert.match(releaseTests,
  /test\(\s*["'`]consume fresh reread rejects a changed safety generation even when final state is safe/u);
assert.match(releaseTests,
  /test\(\s*["'`]lost consume reply requires authoritative registered status/u);
assert.match(releaseTests,
  /test\(\s*["'`]unprocessed expired dynamic-invalid and rejected consume never signal or switch current/u);
assert.match(read("deploy/test-secure-fs-linux.mjs"),
  /test\(\s*["'`]production addon exposes no test root or barrier symbols/u);
assert.match(read("deploy/test-radio-lite-release.mjs"),
  /test\(\s*["'`]current symlink outside releases is rejected before process inspection/u);
assert.match(read("deploy/test-radio-lite-release.mjs"),
  /test\(\s*["'`]successful deployment releases the lock for the next deployment/u);
assert.equal(JSON.parse(read("radio-lite-server/package.json")).scripts.deploy,
  "node --experimental-strip-types src/deploy/deploy-cli.ts");
```

Append this to the existing contract script:

```js
await import("./check-radio-lite-release-contract.mjs");
```

- [ ] **Step 2: Run the checker and verify the red state**

```powershell
node scripts/check-radio-lite-release-contract.mjs
```

Expected: FAIL because the workflow still floats Node 24, lacks named server/Web jobs, an anchored `release-readiness` gate, the commit-bound server archive, and Release configuration, and contains literal bundle versions.

- [ ] **Step 3: Write the configuration-parameterized packager**

```bash
#!/usr/bin/env bash
set -euo pipefail

configuration=${1:?configuration is required}
derived_data=${2:?derived data path is required}
output_dir=${3:?output directory is required}
case "$configuration" in Debug|Release) ;; *) exit 64 ;; esac
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)

app="$derived_data/Build/Products/${configuration}-iphoneos/RadioLite.app"
test -d "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)?$ ]]
[[ "$build" =~ ^[1-9][0-9]*$ ]]
test "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$app/Info.plist")" = true
if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' "$app/Info.plist" >/dev/null 2>&1; then
  exit 65
fi

stage=$(mktemp -d "$RUNNER_TEMP/RadioLite-${configuration}.XXXXXX")
mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/RadioLite.app"
(cd "$stage" && /usr/bin/zip -qry "$output_dir/Radio-Lite-${configuration}-unsigned.ipa" Payload)
(cd "$output_dir" && shasum -a 256 "Radio-Lite-${configuration}-unsigned.ipa" \
  > "Radio-Lite-${configuration}-unsigned.ipa.sha256")
```

- [ ] **Step 4: Write the deterministic reviewed server archive packager**

```bash
#!/usr/bin/env bash
set -euo pipefail

commit=${1:?reviewed 40-hex commit is required}
output_dir=${2:?output directory is required}
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || exit 64
git cat-file -e "${commit}^{commit}"
mkdir -p -- "$output_dir"
stage=$(mktemp -d "${RUNNER_TEMP:?}/Radio-Lite-Server.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
git archive --format=tar "$commit" | tar -xf - -C "$stage"
node_version=$(tr -d '\r\n' < "$stage/.node-version")
[[ "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 65
linux_arch=$(node -p 'process.arch')
napi_version=$(node -p 'process.versions.napi')
bash "$stage/scripts/build-radio-lite-secure-fs.sh" \
  "$stage/deploy/native/radio_lite_secure_fs.node"
node -e 'require(process.argv[1])' \
  "$stage/deploy/native/radio_lite_secure_fs.node"
launcher_contract_version=$(node -p \
  'const c=require(process.argv[1]); if(c.schemaVersion!==1||c.contractVersion!==1) process.exit(65); c.contractVersion' \
  "$stage/deploy/launcher-contract.json")
release_wrapper_sha=$(sha256sum "$stage/deploy/radio-lite-release.sh" | cut -d' ' -f1)
release_orchestrator_sha=$(sha256sum "$stage/deploy/radio-lite-release.mjs" | cut -d' ' -f1)
updater_sha=$(sha256sum "$stage/deploy/radio-lite-launcher-update.mjs" | cut -d' ' -f1)
secure_fs_addon_sha=$(sha256sum "$stage/deploy/native/radio_lite_secure_fs.node" | cut -d' ' -f1)
node -e '
  const fs = require("node:fs");
  const [out, commit, nodeVersion, arch, napiVersion, contractVersion,
    releaseWrapperSha256, releaseOrchestratorSha256, updaterSha256,
    secureFsAddonSha256] = process.argv.slice(1);
  const manifest = { schemaVersion: 3, commit, nodeVersion, platform: "linux", arch,
    napiVersion: Number(napiVersion), launcher: { contractVersion: Number(contractVersion),
      releaseWrapperSha256, releaseOrchestratorSha256, updaterSha256,
      secureFsAddonSha256 } };
  fs.writeFileSync(out, `${JSON.stringify(manifest)}\n`, { flag: "wx", mode: 0o600 });
' "$stage/release.json" "$commit" "$node_version" "$linux_arch" "$napi_version" \
  "$launcher_contract_version" "$release_wrapper_sha" "$release_orchestrator_sha" \
  "$updater_sha" "$secure_fs_addon_sha"
archive="$output_dir/Radio-Lite-Server.tar.gz"
tar --sort=name --mtime="@${SOURCE_DATE_EPOCH:-0}" --owner=0 --group=0 --numeric-owner \
  -czf "$archive" -C "$stage" .
(cd "$output_dir" && sha256sum Radio-Lite-Server.tar.gz > Radio-Lite-Server.tar.gz.sha256)
printf '%s\n' "$commit" > "$archive.commit"
```

The workflow calls this script with the exact checked-out `${{ github.sha }}` after checkout verifies that SHA. The three server files are uploaded together under an artifact name containing the same commit and Linux architecture; the archive's schema-3 `release.json`, companion `.commit`, workflow artifact label, host `process.arch`, packaged addon's N-API contract, launcher contract version, and four component digests must all agree. `deploy/launcher-contract.json` contains exactly `{ "schemaVersion": 1, "contractVersion": 1 }`; it is the single version source, while digests are always calculated from the reviewed staged bytes. This plan publishes the Ubuntu runner architecture only; a different Debian architecture requires a separately reviewed matrix artifact rather than compiling native deployment code on the target host.

`build-radio-lite-secure-fs.sh` locates `node_api.h` only in the exact setup-node runtime adjacent to `process.execPath`, invokes the configured C compiler with `-fPIC -shared`, disables linker build IDs/timestamps, writes through a runner-temporary output, loads the resulting addon in a clean Node process, and atomically installs it at the requested stage path. The packager then clean-loads that staged production binary in a second Node process as its only addon check. `--test-hooks`, `RADIO_LITE_TEST_*`, and the complete root/setgroups/setresuid/filesystem suites belong exclusively to the already-passing `release-readiness` job; `server-release` runs as the ordinary runner, never builds a test binary, and never reruns a privileged suite. The default production build does not define or export test-root/barrier controls. Missing headers/compiler or a load/ABI mismatch fails the artifact job; the Debian deployment host never compiles or downloads native code.

- [ ] **Step 5: Replace duplicated setup-node values and add artifact dependencies**

Use this shape for each Node job:

```yaml
  server-check:
    name: server-check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version-file: .node-version
          cache: npm
          cache-dependency-path: radio-lite-server/package-lock.json
      - run: npm ci
        working-directory: radio-lite-server
      - run: npm run check
        working-directory: radio-lite-server

  web-check:
    name: web-check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version-file: .node-version
      - run: npm test
        working-directory: web
```

Preserve `ios/**`, `radio-lite-server/**`, and `.github/workflows/ios.yml`, and add `web/**`,
`deploy/**`, `scripts/**`, and `.node-version` to the `push.paths` list: `scripts/**` covers the new
readiness/contract/packaging/addon-build scripts, while the existing `radio-lite-server/**` covers
deployment sources and tests. Do **not** configure `paths` or `paths-ignore` under `pull_request`:
`server-check`, `web-check`, `protocol-contract`, `xcode-build-and-test`, and `release-readiness`
are repository-required checks and therefore must all report for docs-only and every other pull
request rather than leaving skipped workflows permanently Pending. None of those five jobs may have
an event/path `if`; only non-required artifact publication jobs use the non-PR guard. Give
protocol-contract the same node-version file. Add this mechanical gate after Tasks 2–4 exist:

```yaml
  release-readiness:
    name: release-readiness
    needs: [server-check, web-check, protocol-contract, xcode-build-and-test]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version-file: .node-version
      - run: npm ci
        working-directory: radio-lite-server
      - run: bash scripts/build-radio-lite-secure-fs.sh deploy/native/radio_lite_secure_fs.node
      - run: bash scripts/build-radio-lite-secure-fs.sh --test-hooks deploy/native/radio_lite_secure_fs.test.node
      - run: node scripts/check-radio-lite-release-readiness.mjs
      - run: node --experimental-strip-types --test radio-lite-server/test/deployment-drain.test.ts radio-lite-server/test/deployment-safety-port.test.ts radio-lite-server/test/deployment-control-socket.test.ts
      - run: bash -n deploy/radio-lite-release.sh
      - run: node --check deploy/radio-lite-launcher-update.mjs
      - name: privileged release filesystem and orchestration suites
        shell: bash
        run: |
          test_uid="$(id -u)"
          test_gid="$(id -g)"
          node_bin="$(command -v node)"
          sudo env \
            RADIO_LITE_SECURE_FS_TEST_ADDON="$PWD/deploy/native/radio_lite_secure_fs.test.node" \
            RADIO_LITE_TEST_SERVICE_UID="$test_uid" \
            RADIO_LITE_TEST_SERVICE_GID="$test_gid" \
            RADIO_LITE_TEST_DEPLOY_GID="$((test_gid + 1))" \
            RADIO_LITE_TEST_DEVICE_GIDS="$((test_gid + 2)),$((test_gid + 3))" \
            "$node_bin" --test deploy/test-secure-fs-linux.mjs deploy/test-radio-lite-release.mjs
```

Add an Ubuntu `server-release` job named `server-release`, gated only by `[release-readiness]` and `if: github.event_name != 'pull_request'`, that runs `scripts/package-radio-lite-server-release.sh "${GITHUB_SHA}" "$RUNNER_TEMP/server-release"` as the ordinary runner and uploads all three `Radio-Lite-Server.tar.gz*` files as one commit-labelled artifact. It must not use `sudo`, pass `RADIO_LITE_TEST_*`, or duplicate the privileged suites: the dependency is the authoritative proof, while packaging performs only the production-addon clean-load/ABI smoke test above. The static checker extracts each YAML job block by its exact two-space key before testing `needs`; a dependency string in another job cannot satisfy it.

- [ ] **Step 6: Replace the one Debug-only job with a matrix**

```yaml
  unsigned-device-ipa:
    needs: [release-readiness]
    if: github.event_name != 'pull_request'
    strategy:
      fail-fast: false
      matrix:
        configuration: [Debug, Release]
    runs-on: macos-15
```

Build using `${{ matrix.configuration }}`, call `scripts/package-radio-lite-ipa.sh`, and upload an artifact whose name includes the configuration and `${{ github.sha }}`.

- [ ] **Step 7: Run the release and protocol checks**

```powershell
node scripts/check-radio-lite-release-contract.mjs
node scripts/check-ios-radio-lite-contract.mjs
```

Expected: PASS; the workflow contains the reviewed server archive plus both iOS configurations, no literal application version assertion, and every formal artifact waits for the anchored readiness job that transitively and directly verifies server/Web/protocol/XCTest plus deployment code.

- [ ] **Step 8: Commit the checker, workflow, and packagers together**

```powershell
git add .github/workflows/ios.yml scripts/check-radio-lite-release-contract.mjs scripts/check-radio-lite-release-readiness.mjs scripts/check-ios-radio-lite-contract.mjs scripts/package-radio-lite-ipa.sh scripts/package-radio-lite-server-release.sh
git commit -m "ci: publish reviewed server and unsigned IPA artifacts"
```

### Task 2: Implement a boot-bound deployment drain controller

**Files:**
- Create: `radio-lite-server/src/deploy/drain-controller.ts`
- Create: `radio-lite-server/src/deploy/deployment-safety-port.ts`
- Create: `radio-lite-server/test/deployment-drain.test.ts`
- Create: `radio-lite-server/test/deployment-safety-port.test.ts`
- Modify: `radio-lite-server/src/rig/runtime-supervisor.ts`
- Modify: `radio-lite-server/src/rig/radio-runtime.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/test/http-service.test.ts`

**Interfaces:**
- Consumes: `RigRuntimeSupervisor.deploymentSafetySnapshot(drainGeneration: number): Promise<DeploymentRadioState>` and `RadioRuntimeRegistry.deploymentSafetySnapshots(drainGeneration: number): Promise<DeploymentSafetySnapshot>` as frozen in Consumed Interfaces.
- Produces: the `DeploymentSafetyPort` service adapter plus `DeploymentDrainController.begin(): Promise<DrainResult>`, `consumeProofAndRegisterShutdown(proof: SafeToStopProof, attempt: ConsumeAttemptRef, registerShutdown: () => ShutdownRegistration): Promise<ConsumeResult>`, `consumeStatus(attempt: ConsumeAttemptRef): ConsumeStatus`, the internal-only `cancel(generation: number): void`, and stable rejection codes. The caller generates one 128-bit lowercase-hex `consumeAttemptId`; the control layer requires its generation, complete process identity, and socket device/inode to equal the currently authenticated endpoint before invoking the controller. `ShutdownRegistration` is an opaque token returned only after the existing idempotent owner has synchronously stored its shutdown promise. `consumeStatus` is read-only, and `cancel` can release only the exact unconsumed held generation. That generation-only method is never exposed to the CLI or orchestrator: the control socket authenticates an identical `DrainOwnerRef` before it may call the method.

- [ ] **Step 1: Write the failing controller tests**

```ts
test("drain fences starts before reading every radio and issues a five-second proof", async () => {
  const clock = new FakeMonotonicClock(1_000);
  const port = new FakeDeploymentSafetyPort([
    { radioId: "main", mode: "idle", pendingTransmitAdmission: false, dekeyRequired: false,
      swrSafetyState: "clear",
      observedPtt: false, observedAtMonotonicMs: 1_000 },
  ]);
  const controller = new DeploymentDrainController(port, { clock, bootId: "boot-a", key: Buffer.alloc(32, 7) });

  const result = await controller.begin();

  assert.equal(port.events[0], "enter:1");
  assert.equal(port.events[1], "confirm:1");
  assert.equal(result.kind, "safe");
  assert.equal(result.proof.expiresAtMonotonicMs, 6_000);
  assert.equal(result.proof.deploymentSafetyGeneration, port.deploymentSafetyGeneration);
});

test("active, external, uncertain, stale and dekey states reject without a proof", async () => {
  for (const state of unsafeDeploymentStates()) {
    const result = await controllerFor(state).begin();
    assert.equal(result.kind, "rejected");
    assert.equal("proof" in result, false);
  }
});

test("pending transmit admission rejects and its late durable audit cannot key", async () => {
  const fixture = deploymentFixture({ configuredRadioIds: ["main"], existingRadioIds: ["main"] });
  const start = fixture.startTransmitWithDeferredIntentAudit("main");
  await fixture.intentAuditReserved;

  const drained = await fixture.controller.begin();
  assert.deepEqual(drained, {
    kind: "rejected", code: "active_transmission", drainGeneration: 1,
  });
  assert.equal(fixture.invalidateTransmitStartsCalls, 1);
  assert.equal(fixture.snapshotStates[0].pendingTransmitAdmission, true);

  fixture.resolveDurableIntentAudit();
  await assert.rejects(start, /deployment_draining|stale_transmit_permit/u);
  assert.equal(fixture.pttOnCalls, 0);
});

test("proof rejects a different boot, generation, expiry and second consumption", async () => {
  const sharedKey = Buffer.alloc(32, 9);
  const bootA = safeController({ bootId: "boot-a", key: sharedKey });
  const bootProof = expectSafe(await bootA.controller.begin()).proof;
  const bootB = safeController({ bootId: "boot-b", key: sharedKey });
  await bootB.controller.begin();
  await assert.rejects(bootB.controller.consumeProofAndRegisterShutdown(
    bootProof, bootB.consumeAttempt(bootProof), () => bootB.registerShutdown()), /boot/u);
  assert.equal(bootB.shutdownRegistrations, 0);

  const wrongGeneration = safeController();
  const generationProof = expectSafe(await wrongGeneration.controller.begin()).proof;
  wrongGeneration.controller.cancel(generationProof.drainGeneration);
  await wrongGeneration.controller.begin();
  await assert.rejects(wrongGeneration.controller.consumeProofAndRegisterShutdown(
    generationProof, wrongGeneration.consumeAttempt(generationProof),
    () => wrongGeneration.registerShutdown()), /generation/u);
  assert.equal(wrongGeneration.shutdownRegistrations, 0);

  const expired = safeController();
  const expiredProof = expectSafe(await expired.controller.begin()).proof;
  expired.clock.advance(5_001);
  await assert.rejects(expired.controller.consumeProofAndRegisterShutdown(
    expiredProof, expired.consumeAttempt(expiredProof),
    () => expired.registerShutdown()), /expired/u);
  assert.equal(expired.shutdownRegistrations, 0);

  const replay = safeController();
  const replayProof = expectSafe(await replay.controller.begin()).proof;
  const replayAttempt = replay.consumeAttempt(replayProof);
  await replay.controller.consumeProofAndRegisterShutdown(replayProof, replayAttempt,
    () => replay.registerShutdown());
  await assert.rejects(replay.controller.consumeProofAndRegisterShutdown(replayProof, replayAttempt,
    () => replay.registerShutdown()), /consumed/u);
});

test("consume rechecks every radio before registering shutdown", async () => {
  for (const change of ["ptt-on", "ptt-unknown", "dekey", "swr-unknown", "pending"] as const) {
    const fixture = safeController();
    const proof = expectSafe(await fixture.controller.begin()).proof;
    fixture.port.setConsumeChange(change);

    const attempt = fixture.consumeAttempt(proof);
    const result = await fixture.controller.consumeProofAndRegisterShutdown(proof, attempt,
      () => fixture.registerShutdown());

    assert.equal(result.kind, "rejected");
    assert.equal(fixture.port.consumeSnapshotCalls, 1);
    assert.equal(fixture.shutdownRegistrations, 0);
    assert.equal(fixture.controller.consumeStatus(attempt).kind, "rejected");
  }
});

test("consume commits proof and shutdown registration inside the held serialization", async () => {
  const fixture = safeController();
  const proof = expectSafe(await fixture.controller.begin()).proof;

  const attempt = fixture.consumeAttempt(proof);
  const result = await fixture.controller.consumeProofAndRegisterShutdown(proof, attempt,
    () => fixture.registerShutdown());

  assert.deepEqual(fixture.events.slice(-4), [
    "consume-serialization-enter", "fresh-all-radio-snapshot",
    "shutdown-owner-registered", "consume-serialization-exit",
  ]);
  assert.equal(result.kind, "consumed");
  assert.equal(fixture.controller.consumeStatus(attempt).kind,
    "consumed_shutdown_registered");
});

test("consume rejects a changed deployment safety generation after awaited reread", async () => {
  const fixture = safeController();
  const proof = expectSafe(await fixture.controller.begin()).proof;
  const attempt = fixture.consumeAttempt(proof);
  const consuming = fixture.controller.consumeProofAndRegisterShutdown(
    proof, attempt, () => fixture.registerShutdown());
  await fixture.port.consumeFreshReadStarted;
  fixture.port.setExternalPtt(true);
  fixture.port.setExternalPtt(false);
  fixture.port.resolveConsumeFreshReadWithSafeSnapshot();

  const result = await consuming;

  assert.equal(result.kind, "rejected");
  assert.equal(result.code, "stale_proof");
  assert.equal(fixture.port.resolvedConsumeSnapshotWasSafe, true);
  assert.equal(fixture.port.consumeSnapshotCalls, 1);
  assert.notEqual(fixture.port.deploymentSafetyGeneration,
    proof.deploymentSafetyGeneration);
  assert.equal(fixture.shutdownRegistrations, 0);
  assert.equal(fixture.controller.consumeStatus(attempt).kind, "rejected");
});
```

In `deployment-safety-port.test.ts`, define `deploymentFixture` with two configured profiles, only one existing supervisor, a deferred real PTT read, and a control-dispatch spy. Add these exact integration cases before implementation:

```ts
test("deployment adapter fences transmit before fresh reads and reports every configured radio", async () => {
  const fixture = deploymentFixture({ configuredRadioIds: ["main", "backup"], existingRadioIds: ["main"] });
  fixture.port.enterDeploymentDrain(4);
  const confirmation = fixture.port.confirmDeploymentSafe(4);

  await assert.rejects(fixture.startTransmit("main"), /deployment_draining/u);
  fixture.resolveFreshPtt("main", false, 4);

  assert.deepEqual(await confirmation, {
    deploymentSafetyGeneration: fixture.deploymentSafetyGeneration,
    radios: [
      { radioId: "main", mode: "idle", pendingTransmitAdmission: false, dekeyRequired: false,
        swrSafetyState: "clear",
        observedPtt: false, observedAtMonotonicMs: fixture.now },
      { radioId: "backup", mode: "fault", pendingTransmitAdmission: false, dekeyRequired: false,
        swrSafetyState: "unknown",
        observedPtt: "unknown", observedAtMonotonicMs: 0 },
    ],
  });
  assert.deepEqual(fixture.snapshotCalls, [{ radioId: "main", drainGeneration: 4 }]);
});

test("emergency stop remains admitted while deployment drain is held", async () => {
  const fixture = deploymentFixture({ configuredRadioIds: ["main"], existingRadioIds: ["main"] });
  fixture.port.enterDeploymentDrain(9);
  await fixture.emergencyStop("main");
  assert.equal(fixture.emergencyStopCalls, 1);
});
```

Add an `http-service.test.ts` case named `"deployment drain rejects concurrent tx.start before PTT read resolves"`; hold the supervisor read deferred, dispatch `tx.start`, assert `deployment_draining`, then resolve the read. Add `"deployment invalidates a pending audited start before drain awaits"`; pause after intent-audit reservation, enter drain, resolve the durable audit, and prove commit rejects without one PTT ON. These prove the service fence and permit-generation invalidation are synchronous rather than controller-only fakes.

- [ ] **Step 2: Run the focused tests and verify the red state**

```powershell
node --experimental-strip-types --test --test-name-pattern="drain fences|active, external|proof rejects|pending transmit admission|consume rechecks|consume commits|changed deployment safety generation|deployment adapter|emergency stop remains|deployment drain rejects concurrent|deployment invalidates a pending" radio-lite-server/test/deployment-drain.test.ts radio-lite-server/test/deployment-safety-port.test.ts radio-lite-server/test/http-service.test.ts
```

Expected: FAIL because the controller, adapter, snapshot source, and lifecycle fence do not exist.

- [ ] **Step 3: Implement discriminated results and HMAC proof validation**

```ts
export type DrainRejectionCode =
  | "active_transmission"
  | "dekey_or_external_ptt"
  | "telemetry_uncertain"
  | "service_unavailable";

export type SafeToStopProof = {
  bootId: string;
  drainGeneration: number;
  deploymentSafetyGeneration: number;
  issuedAtMonotonicMs: number;
  expiresAtMonotonicMs: number;
  signature: string;
};

export type DrainResult =
  | { kind: "safe"; proof: SafeToStopProof }
  | { kind: "rejected"; code: DrainRejectionCode; drainGeneration: number };

export type ShutdownRegistration = {
  readonly opaqueShutdownRegistration: unique symbol;
};
export type ConsumeRejectionCode = DrainRejectionCode | "stale_proof" | "proof_expired";
export type ConsumeResult =
  | { kind: "consumed"; attempt: ConsumeAttemptRef }
  | { kind: "rejected"; code: ConsumeRejectionCode; attempt: ConsumeAttemptRef };
export type ConsumeStatus =
  | { kind: "consumed_shutdown_registered"; attempt: ConsumeAttemptRef }
  | { kind: "held_unconsumed"; attempt: ConsumeAttemptRef }
  | { kind: "rejected"; attempt: ConsumeAttemptRef; code: ConsumeRejectionCode }
  | { kind: "unknown"; attempt: ConsumeAttemptRef };
```

`begin()` increments one monotonic drain generation, calls `enterDeploymentDrain()` synchronously, then calls `confirmDeploymentSafe()` in that generation. It must classify any voice/digital/tuning state or `pendingTransmitAdmission=true` as active, any latch/true PTT as dekey/external, any unknown PTT/SWR state or PTT read older than the configured freshness threshold as uncertain, and exceptions as unavailable. Sign the returned post-await `deploymentSafetyGeneration` together with the other proof fields in canonical JSON using a process-random HMAC key. `consumeProofAndRegisterShutdown()` first verifies signature, boot ID, current held drain generation, expected safety generation, five-second monotonic expiry, one-time use, and the complete consume-attempt/process/socket tuple, then delegates to `recommitDeploymentSafe`. That port re-reads every runtime while the same drain-generation/service safety serialization is held and, after the awaits, again compares the live safety generation with the signed one before invoking the non-async callback; the callback obtains `ShutdownRegistration` and sets controller status to `consumed_shutdown_registered` before the serialization is released. A changed generation or rejected recheck stores its exact status without consuming or registering shutdown. `consumeStatus()` requires the identical attempt tuple and performs no recheck, cancellation, registration, or other mutation.

- [ ] **Step 4: Implement and expose the lifecycle port without adding an HTTP route**

```ts
deploymentSafetyPort(): DeploymentSafetyPort {
  return this.#lifecycleGate;
}
```

`DeploymentSafetyPortAdapter.enterDeploymentDrain(generation)` first calls the service's synchronous `invalidateTransmitStarts("deployment")`, then advances the lifecycle generation and fences new upgrades, ordinary control, and every transmit start before it starts an asynchronous read. A start that already reserved intent audit remains counted in `pendingTransmitAdmission`; its late durable audit completion observes the invalid permit generation and cannot call `commitTransmitStart`. `confirmDeploymentSafe(generation)` verifies the same held generation and calls `RadioRuntimeRegistry.deploymentSafetySnapshots(generation)`. The registry enumerates every configured profile in stable profile order: each existing `RigRuntimeSupervisor` performs a same-generation, safety-serialized fresh PTT read plus current SWR/de-key/admission projection through its managed sampler/transport; a profile with no available supervisor contributes the explicit `fault/unknown/observedAt=0` state shown above instead of being omitted or causing construction of a parallel transport. `recommitDeploymentSafe(generation, expectedSafetyGeneration, commit)` repeats that complete read under the service's same held-generation safety serialization and, after every awaited runtime read, rechecks both generations before invoking the synchronous callback; it never reuses the proof-time array or cached PTT. Mode, pending-admission, de-key, SWR, external-PTT, telemetry-freshness, and runtime-availability transitions all advance `deploymentSafetyGeneration`, so even an ON→OFF or unavailable→available transition that looks safe at the end rejects a proof signed before that transition. A pending admission, generation change, unsafe/unknown result, callback omission, or a result/exception from an old generation cannot consume or register shutdown. The adapter's internal `cancelDeploymentDrain(generation)` can release only that still-held unconsumed lifecycle generation; the control socket must first authenticate the complete `DrainOwnerRef`, so no external cancel is authorized by a bare generation or can target a replacement process/socket. Add service integration tests proving the pending-audit race cannot key, a concurrent `tx.start` is rejected before radio reads resolve, external/unknown PTT rejects proof and consume, dynamic PTT/SWR/de-key/admission changes produce zero shutdown registration, and `tx.emergency-stop` remains accepted throughout the fence.

- [ ] **Step 5: Run focused and server checks**

```powershell
node --experimental-strip-types --test --test-name-pattern="drain fences|active, external|proof rejects|pending transmit admission|consume rechecks|consume commits|changed deployment safety generation|deployment adapter|emergency stop remains|deployment drain rejects concurrent|deployment invalidates a pending" radio-lite-server/test/deployment-drain.test.ts radio-lite-server/test/deployment-safety-port.test.ts radio-lite-server/test/http-service.test.ts
npm --prefix radio-lite-server run typecheck
```

Expected: PASS.

- [ ] **Step 6: Commit the drain controller**

```powershell
git add radio-lite-server/src/deploy/drain-controller.ts radio-lite-server/src/deploy/deployment-safety-port.ts radio-lite-server/src/rig/runtime-supervisor.ts radio-lite-server/src/rig/radio-runtime.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/deployment-drain.test.ts radio-lite-server/test/deployment-safety-port.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: gate deployment on confirmed PTT off"
```

### Task 3: Expose drain over a local Unix socket and stable CLI

**Files:**
- Create: `radio-lite-server/src/deploy/control-socket.ts`
- Create: `radio-lite-server/src/deploy/deploy-cli.ts`
- Create: `radio-lite-server/src/deploy/service-instance-guard.ts`
- Create: `radio-lite-server/test/deployment-control-socket.test.ts`
- Modify: `radio-lite-server/package.json`

**Interfaces:**
- Consumes: `DeploymentDrainController` from Task 2 and an injected `ServiceInstanceGuardPort`. Task 3's tests use a fake guard; Task 4 implements the production native adapter and performs final `src/index.ts` wiring, so this task can go green before the addon exists without creating an unsafe fallback.
- Produces: newline-delimited local commands and CLI exit codes 0, 10, 11, 12, 13; a safe drain response containing the complete `DrainOwnerRef` and a proof whose `deploymentSafetyGeneration` is preserved verbatim by the CLI; held-generation `proof-consume` with a second fresh all-runtime safety read; read-only `consume-status` bound to the identical `ConsumeAttemptRef`; `drain-cancel` bound to and echoing the identical `DrainOwnerRef`; separate opaque stale-socket and stale-record proofs; and `createShutdownOwner({ closeService, closeListener, unlinkOwnedSocket, unlinkOwnedRecord, releaseInstanceLease })`, whose returned idempotent function uses that exact cleanup order for every signal, fatal-process, and deployment trigger.

```ts
export type DeploymentShutdownReason = "SIGINT" | "SIGTERM" | "SIGHUP" |
  "uncaughtException" | "unhandledRejection" | "deployment";
export type ProvenStaleControlEndpoint = {
  readonly opaqueProvenStaleControlEndpoint: unique symbol;
};
export type ProvenStaleInstanceRecord = {
  readonly opaqueProvenStaleInstanceRecord: unique symbol;
};
export interface ServiceInstanceGuardPort {
  acquire(expected: { serviceUid: number; serviceGid: number;
    deploymentGroupId: number; releaseCommit: string;
    nodeVersion: "24.7.0" }): Promise<ServiceInstanceLease>;
}
export interface ServiceInstanceLease {
  readonly controlSocketBindPath: string;
  classifyAddressInUse(nonce: string): Promise<
    | { kind: "live"; process: DeploymentProcessIdentity }
    | { kind: "stale"; proof: ProvenStaleControlEndpoint }
    | { kind: "unverifiable" }
  >;
  unlinkProvenStaleAndRecheck(proof: ProvenStaleControlEndpoint): Promise<void>;
  classifyRecordAfterBind(process: DeploymentProcessIdentity): Promise<
    | { kind: "absent" }
    | { kind: "stale"; proof: ProvenStaleInstanceRecord }
    | { kind: "live" | "unverifiable" }
  >;
  unlinkProvenStaleRecordAndRecheck(proof: ProvenStaleInstanceRecord): Promise<void>;
  verifyBoundSocketAndPublishExclusive(process: DeploymentProcessIdentity): Promise<void>;
  closeListener(): Promise<void>;
  unlinkOwnedSocketAndRecheck(): Promise<void>;
  unlinkOwnedRecordAndRecheck(): Promise<void>;
  release(): Promise<void>;
}
export function createShutdownOwner(options: {
  closeService: () => Promise<void>;
  closeListener: () => Promise<void>;
  unlinkOwnedSocket: () => Promise<void>;
  unlinkOwnedRecord: () => Promise<void>;
  releaseInstanceLease: () => Promise<void>;
}): (reason: DeploymentShutdownReason) => Promise<void>;
```

- [ ] **Step 1: Write pure protocol and ownership tests**

```ts
test("drain command maps safe and rejected results to stable exit codes", async () => {
  const result = await handler(safeController(), { command: "drain" });
  assert.deepEqual(result, {
    ok: true, exitCode: 0, proof: expectedProof,
    owner: expectedDrainOwner,
  });
  assert.equal(result.proof.deploymentSafetyGeneration,
    expectedProof.deploymentSafetyGeneration);
  assert.equal((await handler(activeController(), { command: "drain" })).exitCode, 10);
  assert.equal((await handler(dekeyController(), { command: "drain" })).exitCode, 11);
  assert.equal((await handler(uncertainController(), { command: "drain" })).exitCode, 12);
  assert.equal((await handler(unavailableController(), { command: "drain" })).exitCode, 13);
});

test("client disconnect does not cancel a held drain generation", async () => {
  const fixture = controlSocketFixture();
  await fixture.sendAndDisconnect({ command: "drain" });
  assert.equal(fixture.controller.snapshot()?.state, "held");
});

test("proof consume atomically requests shutdown for the exact serving process", async () => {
  const fixture = controlSocketFixture({ processIdentity: expectedProcess });
  const drained = await fixture.send({ command: "drain" });
  assert.deepEqual(drained.owner, expectedDrainOwner);
  assert.equal(drained.owner.drainGeneration, drained.proof.drainGeneration);
  const attempt = fixture.consumeAttempt(drained);
  const consumed = await fixture.send({ command: "proof-consume",
    proof: drained.proof, attempt });
  assert.deepEqual(consumed.attempt, attempt);
  assert.equal(consumed.shutdownRegistered, true);
  assert.equal(fixture.shutdownRequests, 1);
});

test("consume rechecks every radio before registering shutdown", async () => {
  const fixture = controlSocketFixture({ consumeState: "external-ptt-on" });
  const drained = await fixture.send({ command: "drain" });
  const attempt = fixture.consumeAttempt(drained);
  const result = await fixture.send({ command: "proof-consume",
    proof: drained.proof, attempt });
  assert.deepEqual(result, {
    ok: false, exitCode: 11, code: "dekey_or_external_ptt",
    attempt,
  });
  assert.equal(fixture.consumeFreshSnapshotCalls, 1);
  assert.equal(fixture.shutdownRequests, 0);
});

test("consume status is read-only, binds to, and echoes the identical ConsumeAttemptRef", async () => {
  const fixture = controlSocketFixture({ processIdentity: expectedProcess });
  const drained = await fixture.send({ command: "drain" });
  const attempt = fixture.consumeAttempt(drained);
  const before = fixture.mutationCount;
  const held = await fixture.send({ command: "consume-status", attempt });
  assert.equal(held.status, "held_unconsumed");
  assert.deepEqual(held.attempt, attempt);
  assert.equal(fixture.mutationCount, before);
  const mismatches = [
    { ...attempt, consumeAttemptId:
      attempt.consumeAttemptId === "f".repeat(32) ? "e".repeat(32) : "f".repeat(32) },
    { ...attempt, drainGeneration: attempt.drainGeneration + 1 },
    { ...attempt, process: { ...attempt.process, bootId: "different-boot" } },
    { ...attempt, process: { ...attempt.process, pid: attempt.process.pid + 1 } },
    { ...attempt, process: { ...attempt.process, processStartToken: "different-start" } },
    { ...attempt, process: { ...attempt.process, cwd: "/opt/testradio/releases/" + "e".repeat(40) } },
    { ...attempt, process: { ...attempt.process, releaseCommit:
      attempt.process.releaseCommit === "f".repeat(40) ? "e".repeat(40) : "f".repeat(40) } },
    { ...attempt, socket: { ...attempt.socket, device: "different-device" } },
    { ...attempt, socket: { ...attempt.socket, inode: "different-inode" } },
  ];
  for (const mismatchedAttempt of mismatches) {
    const mutationCount = fixture.mutationCount;
    await assert.rejects(fixture.send({ command: "consume-status",
      attempt: mismatchedAttempt }), /attempt|generation|identity|socket/u);
    assert.equal(fixture.mutationCount, mutationCount);
  }
});

test("drain cancel rejects every mismatched owner field and echoes the identical DrainOwnerRef", async () => {
  const fixture = controlSocketFixture({ processIdentity: expectedProcess });
  const drained = await fixture.send({ command: "drain" });
  const owner = drained.owner;
  const mismatches = [
    { ...owner, drainGeneration: owner.drainGeneration + 1 },
    { ...owner, process: { ...owner.process, bootId: "different-boot" } },
    { ...owner, process: { ...owner.process, pid: owner.process.pid + 1 } },
    { ...owner, process: { ...owner.process, processStartToken: "different-start" } },
    { ...owner, process: { ...owner.process, cwd: "/opt/testradio/releases/" + "e".repeat(40) } },
    { ...owner, process: { ...owner.process, releaseCommit:
      owner.process.releaseCommit === "f".repeat(40) ? "e".repeat(40) : "f".repeat(40) } },
    { ...owner, socket: { ...owner.socket, device: "different-device" } },
    { ...owner, socket: { ...owner.socket, inode: "different-inode" } },
  ];
  for (const mismatchedOwner of mismatches) {
    await assert.rejects(fixture.send({ command: "drain-cancel",
      owner: mismatchedOwner }), /generation|identity|socket/u);
    assert.equal(fixture.cancelCalls, 0);
  }
  const cancelled = await fixture.send({ command: "drain-cancel", owner });
  assert.equal(cancelled.status, "cancelled");
  assert.deepEqual(cancelled.owner, owner);
  const retried = await fixture.send({ command: "drain-cancel", owner });
  assert.equal(retried.status, "already_cancelled");
  assert.deepEqual(retried.owner, owner);
});

test("lost proof consume reply requires authoritative registered status", async () => {
  const fixture = controlSocketFixture();
  const drained = await fixture.send({ command: "drain" });
  const attempt = fixture.consumeAttempt(drained);
  await fixture.sendAndDisconnect({ command: "proof-consume",
    proof: drained.proof, attempt });
  assert.equal(fixture.shutdownRequests, 1);
  const status = await fixture.send({ command: "consume-status", attempt });
  assert.equal(status.status, "consumed_shutdown_registered");
  assert.deepEqual(status.attempt, attempt);
});

test("instance probe binds the nonce to the serving process identity", async () => {
  const nonce = "a".repeat(64);
  assert.deepEqual(await handler(safeController(), {
    command: "instance-probe", nonce,
  }), { ok: true, nonce, process: expectedProcess });
  await assert.rejects(handler(safeController(), {
    command: "instance-probe", nonce: "short",
  }), /nonce/u);
});

test("control directory SGID supplies deployment gid without service group membership",
  { skip: process.platform === "win32" }, async () => {
  if (!process.getgid) throw new Error("getgid unavailable on a Unix test host");
  const deploymentGroupId = process.getgid();
  const fixture = unixSocketFixture({ deploymentGroupId,
    serviceSupplementaryGids: [] });
  await fixture.listen();
  const parent = await stat(fixture.parentPath);
  const socketInfo = await stat(fixture.path);
  const recordInfo = await stat(fixture.instanceRecordPath);
  assert.equal(parent.uid, fixture.serviceUid);
  assert.equal(parent.gid, deploymentGroupId);
  assert.equal(parent.mode & 0o7777, 0o2750);
  assert.equal(parent.mode & 0o020, 0);
  assert.equal(fixture.serviceSupplementaryGids.includes(deploymentGroupId), false);
  assert.equal(socketInfo.mode & 0o777, 0o660);
  assert.equal(socketInfo.gid, deploymentGroupId);
  assert.equal(recordInfo.mode & 0o777, 0o640);
  assert.equal(recordInfo.gid, deploymentGroupId);
  assert.equal(fixture.nonRootChgrpCalls, 0);
});

test("instance record matches the control response and is group readable only",
  { skip: process.platform === "win32" }, async () => {
  const fixture = unixSocketFixture({ processIdentity: expectedProcess });
  await fixture.listen();
  const record = JSON.parse(await readFile(fixture.instanceRecordPath, "utf8"));
  const info = await stat(fixture.instanceRecordPath);
  assert.deepEqual(record.process, expectedProcess);
  assert.deepEqual(record.socket, fixture.boundSocketIdentity);
  assert.equal(record.process.releaseCommit, fixture.commit);
  assert.equal(info.mode & 0o777, 0o640);
  assert.equal(info.nlink, 1);
});

test("second service cannot unlink a live control socket or replace its instance record", async () => {
  const fixture = singleInstanceFixture();
  const first = await fixture.start();
  const socketBefore = await fixture.socketIdentity();
  const recordBefore = await fixture.instanceRecordBytes();
  await assert.rejects(fixture.startSecond(), /service instance lock is held/u);
  assert.deepEqual(await fixture.socketIdentity(), socketBefore);
  assert.deepEqual(await fixture.instanceRecordBytes(), recordBefore);
  assert.equal(fixture.unlinkCalls, 0);
  await first.close();
});

test("control socket binds first and stale recovery requires same-inode dead-owner proof", async () => {
  const fixture = staleEndpointFixture({ owner: "dead" });
  await fixture.listen();
  assert.deepEqual(fixture.events, [
    "lock", "bind:EADDRINUSE", "probe", "same-inode-recheck",
    "unlink-stale", "bind:retry", "publish-instance",
  ]);
  assert.equal(fixture.bindCalls, 2);
});

test("missing or unverifiable stale owner fails closed", async () => {
  for (const owner of ["live", "identity-mismatch", "probe-timeout"] as const) {
    const fixture = staleEndpointFixture({ owner });
    await assert.rejects(fixture.listen(), /live|unverifiable|manual repair/u);
    assert.equal(fixture.unlinkCalls, 0);
    assert.equal(fixture.recordWrites, 0);
  }
});

test("socket-only orphan without a record requires manual repair", async () => {
  const fixture = staleEndpointFixture({
    crashPoint: "after-bind-before-instance-publish",
  });
  await fixture.crashFirstProcess();
  await assert.rejects(fixture.listen(), /manual repair/u);
  assert.deepEqual(fixture.events, [
    "first:lock", "first:bind:success", "first:verify-owned-socket",
    "first:crash-before-instance-publish", "replacement:lock",
    "replacement:bind:EADDRINUSE", "replacement:manual-repair",
  ]);
  assert.equal(fixture.socketUnlinkCalls, 0);
  assert.equal(fixture.recordUnlinkCalls, 0);
  assert.equal(fixture.bindCalls, 2);
  assert.equal(fixture.replacementInitialBindCalls, 1);
  assert.equal(fixture.replacementBindRetryCalls, 0);
});

test("bound socket removes only a proven dead orphan record", async () => {
  const fixture = orphanRecordFixture({ owner: "dead" });
  await fixture.listen();
  assert.deepEqual(fixture.events, [
    "lock", "bind:success", "verify-owned-socket", "classify-old-record",
    "record-inode-recheck", "unlink-old-record", "publish-exclusive",
  ]);
  assert.equal(fixture.socketUnlinkCalls, 0);
  assert.equal(fixture.publishedRecord.socket.inode, fixture.ownedSocket.inode);
});

test("live or swapped orphan record blocks exclusive publication", async () => {
  for (const owner of ["live", "record-swapped", "identity-unverifiable"] as const) {
    const fixture = orphanRecordFixture({ owner });
    await assert.rejects(fixture.listen(), /live|inode|unverifiable/u);
    assert.equal(fixture.oldRecordUnlinkCalls, 0);
    assert.equal(fixture.recordWrites, 0);
    assert.equal(fixture.socketWasOwnedByLease, true);
  }
});

test("startup rejects release commit mismatch across environment cwd and manifest", async () => {
  for (const mismatch of ["environment", "cwd", "manifest"] as const) {
    const fixture = unixSocketFixture({ releaseMismatch: mismatch });
    await assert.rejects(fixture.listen(), /release.*commit|cwd/u);
    assert.equal(fixture.recordWrites, 0);
    assert.equal(fixture.socketBindCalls, 0);
  }
});

test("shutdown cleanup orders listener socket record and service lock", async () => {
  const events: string[] = [];
  const shutdown = createShutdownOwner({
    closeService: async () => { events.push("service-close"); },
    closeListener: async () => { events.push("listener-close"); },
    unlinkOwnedSocket: async () => { events.push("socket-unlink"); },
    unlinkOwnedRecord: async () => { events.push("record-unlink"); },
    releaseInstanceLease: async () => { events.push("instance-lock-release"); },
  });
  const reasons: DeploymentShutdownReason[] = [
    "SIGINT", "SIGTERM", "SIGHUP", "uncaughtException",
    "unhandledRejection", "deployment",
  ];
  await Promise.all(reasons.map((reason) => shutdown(reason)));
  assert.deepEqual(events, ["service-close", "listener-close", "socket-unlink",
    "record-unlink", "instance-lock-release"]);
});

test("record swap at cleanup cannot unlink the replacement", async () => {
  const fixture = ownedEndpointFixture();
  await fixture.start();
  const replacement = await fixture.swapRecordAfterListenerClose();
  await fixture.shutdown();
  assert.deepEqual(await fixture.recordIdentity(), replacement);
  assert.equal(fixture.recordUnlinkCalls, 0);
  assert.equal(fixture.lockReleased, true);
});
```

Add exact fake-guard cases `"service lock is acquired before bind record or radio initialization"`,
`"stale recovery retries bind exactly once"`, and
`"instance record is published only while locked and after bind"`. Add
`"cleanup crash points preserve recoverable ownership evidence"`, which terminates after each of
listener close, socket unlink, record unlink, and lock release, then proves the next guarded startup
either recovers through the matching opaque proof or fails closed without deleting a replacement.
The fake records an ordered event log and opaque socket/record inode identities; neither stale-socket
nor record-only proof may be represented as a plain object.

- [ ] **Step 2: Run the test and verify the red state**

```powershell
node --experimental-strip-types --test --test-name-pattern="drain command|client disconnect|atomically requests shutdown|consume rechecks every radio|consume status|drain cancel|lost proof consume|instance probe|SGID supplies|instance record|second service|binds first|stale owner|socket-only orphan|dead orphan record|swapped orphan|service lock is acquired|stale recovery retries|published only while locked|cleanup orders|cleanup crash points|record swap|release commit mismatch" radio-lite-server/test/deployment-control-socket.test.ts
```

Expected: FAIL because the socket handler, CLI, injected service-instance guard contract, bind-first
stale-proof state machine, and lock-last shutdown owner do not exist.

- [ ] **Step 3: Implement a bounded JSON-line socket**

```ts
export const DEPLOY_CONTROL_DIRECTORY = "/opt/testradio/run/control";
export const DEPLOY_SOCKET_PATH = "/opt/testradio/run/control/control.sock";

export class DeploymentControlSocket {
  constructor(
    private readonly controller: DeploymentDrainController,
    private readonly options: {
      instanceLease: ServiceInstanceLease;
      deploymentGroupId: number;
      processIdentity: DeploymentProcessIdentity;
      requestShutdown: (reason: "deployment") => void;
    },
  ) {}
  async listen(): Promise<void>;
  async close(): Promise<void>;
}
```

Accept one UTF-8 JSON object no larger than 4 KiB, reject unknown fields/commands, write one JSON response plus newline, and close the connection. Besides drain/consume/status/cancel, accept only the internal `{command:"instance-probe",nonce:<64-lowercase-hex>}` request and echo that exact nonce plus the serving `DeploymentProcessIdentity`; it is strictly read-only and never enters/cancels drain, consumes proof, registers shutdown, or changes endpoint state. Bootstrap creates `/opt/testradio/run/control` as service UID/deployment GID mode `02750`: group write stays clear, SGID is mandatory, and the service's primary/supplementary groups exclude deployment GID. Consequently both `control.sock` and `instance.json` inherit deployment GID. The non-root service may chmod its newly created socket to `0660` and record to `0640`, but must never call `chgrp`/`chown`; native verification rejects missing SGID or a non-inherited GID.

Never pre-delete or pre-stat a socket as a reason to unlink it. While holding the injected instance lease, first bind `instanceLease.controlSocketBindPath`. On `EADDRINUSE`, send one read-only nonce-bound probe and cross-check its response with the fixed instance record, boot ID, PID/start token, `/proc/<pid>/cwd` inode, release commit, and socket inode; this kernel/process/record agreement authenticates the local endpoint identity. A live or inconsistent/timed-out/missing record is `live`/`unverifiable` and fails closed without unlink. Only a lease-bound native opaque endpoint proof that the recorded owner is dead may reach `unlinkProvenStaleAndRecheck`; that method rechecks the same socket and record inodes immediately before basename-only unlink. Retry bind exactly once, and never publish after a second `EADDRINUSE`. In particular, a socket-only orphan with no complete record is not recoverable automatically and requires a separately reviewed manual repair.

A successful bind first records and verifies the socket as owned by the current lease, then classifies any pre-existing `instance.json`. No record permits exclusive publication. A live/unverifiable record rejects without overwrite. A dead old process may produce a distinct lease-bound opaque **record-only** proof containing the old record inode plus the current lease/socket identity; immediately before removing only that record, recheck the old record inode and that the currently bound socket is still the lease-owned inode. Never use record-only proof to unlink a socket. After removal, create the new record exclusively—an unexpected record wins the race and aborts. Linux has no `connectat(2)`, so Task 4 uses a pinned control-directory FD and `/proc/self/fd/<controlDirFd>/control.sock`; the HMAC drain proof plus `{bootId,pid,processStartToken,cwd,releaseCommit}` remains deployment authority after connection.

A client disconnect during `drain` must not call `cancel()`. `proof-consume` validates the proof and, in the same held-generation service safety serialization, re-reads every runtime's fresh PTT/SWR/de-key/pending-admission state before its synchronous consume-plus-shutdown-registration callback. A dynamic unsafe/unknown result replies with the matching rejection and records zero shutdown requests. `consume-status` takes the identical `ConsumeAttemptRef`—the same 128-bit attempt ID, drain generation, complete process identity, and socket device/inode—returns `held_unconsumed`, `rejected`, `consumed_shutdown_registered`, or `unknown`, echoes that complete attempt, and performs no mutation. Lost response never manufactures a second shutdown path.

- [ ] **Step 4: Implement CLI result handling**

```ts
const exitCodes = {
  active_transmission: 10,
  dekey_or_external_ptt: 11,
  telemetry_uncertain: 12,
  service_unavailable: 13,
} as const;
```

Support `drain`, `proof-consume --proof $PROOF_FROM_DRAIN_JSON --attempt-json $CONSUME_ATTEMPT_JSON`, read-only
`consume-status --attempt-json $CONSUME_ATTEMPT_JSON`, and
`drain-cancel --owner-json $DRAIN_OWNER_JSON`. `DrainOwnerRef` contains generation, complete
`{bootId,pid,processStartToken,cwd,releaseCommit}`, and socket device/inode—not only a PID/commit.
A safe
`drain` JSON and the CLI's single stdout JSON line include the proof, complete `DrainOwnerRef`, and
the signed `proof.deploymentSafetyGeneration` without dropping or rewriting it. Before consume,
the caller adds one random 128-bit lowercase-hex `consumeAttemptId` to that owner ref; the resulting
attempt JSON freezes the full tuple. Successful consume echoes the
complete attempt plus `shutdownRegistered:true`. Every status response echoes the identical complete
`ConsumeAttemptRef`; every cancel or `already_cancelled` response echoes the identical complete
`DrainOwnerRef`. Status/cancel reject a replacement process or
different generation before controller mutation; an idempotent retry for the same already-cancelled
generation may report `already_cancelled` but must not touch a newer held generation. Print exactly
one JSON line to stdout, diagnostic text to stderr, and return the response exit code. Add package script:

```json
"deploy": "node --experimental-strip-types src/deploy/deploy-cli.ts"
```

- [ ] **Step 5: Implement the guard-bound lifecycle with an injected adapter**

Implement a `startControlPlaneWithGuard` coordinator whose guard, radio-service initializer, and socket factory are all injected. Parse `RADIO_LITE_SERVICE_UID`, `RADIO_LITE_SERVICE_GID`, `RADIO_LITE_DEPLOY_GID`, `RADIO_LITE_SERVICE_DEVICE_GIDS`, and the separately injected `RADIO_LITE_RELEASE_COMMIT`; require the release commit to be 40 lowercase hex, running UID/GID/supplementary groups to equal the configured service identity, `process.cwd()` to be the matching `/opt/testradio/releases/<commit>`, and sealed `release.json` to agree. Acquire `ServiceInstanceGuardPort` before radio initialization, socket bind, or record access. If initialization/listen/publish fails, close any initialized service and owned endpoint, then release the lease without announcing readiness.

Capture boot ID, PID, `/proc/self/stat` start token, cwd, and commit once as `DeploymentProcessIdentity`. Publish only the unique `run/control/instance.json`; no per-release PID record is created. Its inherited deployment GID, mode-`0640`, single-link envelope contains that process identity plus the bound socket device/inode. Publication is exclusive, fsyncs file and directory, and is legal only while the lease is held and bind succeeded. An existing record is never overwritten merely because the new commit matches: live/unverifiable owners refuse startup; a dead record is removable only with the record-only proof and current lease-owned socket recheck above, followed by a fresh exclusive publish. Drain responses echo the complete owner, consume/status responses echo the complete attempt, and cancel responses echo the complete owner; partial process-only acknowledgements are never authoritative. `createShutdownOwner` registers all signal/fatal/deployment triggers; after service/runtimes it always performs listener close → same-inode owned socket unlink → same-inode owned record unlink → service-lock release. Failure or crash at any cleanup edge may leave an orphan, but a later process uses only the matching opaque recovery proof and never deletes a swapped inode. Production `src/index.ts` wiring is deliberately deferred to Task 4's native adapter; Task 3 has no path-based fallback. `proof-consume` calls this one owner, while a lost reply requires authoritative `consume-status` before the external orchestrator may do anything beyond fail closed.

- [ ] **Step 6: Run focused tests and full server check**

```powershell
node --experimental-strip-types --test --test-name-pattern="drain command|client disconnect|atomically requests shutdown|consume rechecks every radio|consume status|drain cancel|lost proof consume|instance probe|SGID supplies|instance record|second service|binds first|stale owner|socket-only orphan|dead orphan record|swapped orphan|service lock is acquired|stale recovery retries|published only while locked|cleanup orders|cleanup crash points|record swap|release commit mismatch" radio-lite-server/test/deployment-control-socket.test.ts
npm --prefix radio-lite-server run check
```

Expected: PASS. The real Unix socket integration case may be skipped only on Windows; pure protocol and controller tests run everywhere.

- [ ] **Step 7: Commit the local control plane**

```powershell
git add radio-lite-server/src/deploy/control-socket.ts radio-lite-server/src/deploy/deploy-cli.ts radio-lite-server/src/deploy/service-instance-guard.ts radio-lite-server/test/deployment-control-socket.test.ts radio-lite-server/package.json
git commit -m "feat: expose safe deployment drain locally"
```

### Task 4: Add an FD-confined release and rollback orchestrator

**Files:**
- Create: `deploy/native/radio_lite_secure_fs.c`
- Create: `deploy/secure-fs.mjs`
- Create: `deploy/radio-lite-release.mjs`
- Create: `deploy/radio-lite-release.sh`
- Create: `deploy/launcher-contract.json`
- Create: `deploy/radio-lite-launcher-update.mjs`
- Create: `deploy/test-secure-fs-linux.mjs`
- Create: `deploy/test-radio-lite-release.mjs`
- Create: `scripts/build-radio-lite-secure-fs.sh`
- Modify: `radio-lite-server/src/deploy/service-instance-guard.ts`
- Modify: `radio-lite-server/src/deploy/control-socket.ts`
- Modify: `radio-lite-server/src/index.ts`

**Interfaces:**
- Consumes: Task 1's frozen archive, strict `.sha256`/`.commit` companion, and manifest contract using synthetic fixtures during implementation, plus Task 3 CLI. Task 1 enables the real CI artifact jobs only after this task is green.
- Produces: one reviewed Linux N-API addon and Node orchestrator installed by the separate bootstrap action into the root-only launcher trust boundary; a strict launcher contract/identity plus separately invoked updater; a service-owned private candidate that passes dependency installation and all non-radio checks before drain; an immutable root-owned/service-group-readable release tree keyed by the verified 40-hex commit under `/opt/testradio/releases`; FD-pinned archive/companion/log/instance/runtime/current state; and a health-checked switch or safe rollback. The candidate archive's addon bytes are never loaded into the privileged orchestrator; after exec drops permanently to the service identity, the service may load only its narrow fixed-path instance-guard export while every root-only addon method rejects non-root. Every managed filesystem operation is performed by the matching addon relative to retained directory FDs, and every mutation receives already-pinned parent FDs plus basenames. The trusted launcher wrapper cannot inspect or mutate managed data; ordinary deploy and rollback can validate launcher identity but expose no launcher write entrypoint.

- [ ] **Step 1: Write the Linux syscall-barrier and temporary-root harnesses first**

`test-secure-fs-linux.mjs` loads the real compiled addon on Linux. Its addon-only test hook can pause immediately before `openat2`, immediately after a returned FD passes `fstat`, and immediately before a basename-only mutation after both parent FDs are pinned; production builds compile every hook out. Tests make pathname, parent, or leaf swaps deterministically at the barrier instead of relying on scheduler timing. CI captures its original positive nonroot UID/GID, then runs both Linux suites under `sudo` while passing those numbers only through `RADIO_LITE_TEST_*` fixture inputs. Those inputs choose test file ownership and child identities but cannot bypass the production runner's real `geteuid()==0` check; no production CLI reads them. Because setup-node is not `/usr/bin/node`, the test addon alone also mints an opaque host-tool probe over private root-owned fake `usr/bin/node`, `usr/bin/tar`, and `usr/share/nodejs/npm/bin/npm-cli.js` files and reports `/usr/bin/node` plus exact `24.7.0`; injected `runRelease` accepts that probe only when the same addon proves it is a compile-time test build. No environment variable, command-line option, production addon export, or `RADIO_LITE_TEST_*` value can select those fake paths or reported runtime values. A separate exact test invokes the production entry with the actual setup-node executable, requires the specific host-path mismatch exit 70, and proves no test control socket, managed-root sentinel, lock, or drain fake was touched. The suite also drops a subprocess back to the original CI UID and invokes the packaged production entry once to prove non-root rejection before any managed open or drain. `test-radio-lite-release.mjs` creates one private temporary root and controlled fake service commands/process identity/deploy responses. Command fakes append each invocation, effective/supplementary identity, inherited FDs, absolute executable/arguments, and the new-process environment to a log so assertions prove drain/cancel/consume/shutdown/signal ordering. It invokes `radio-lite-release.mjs` directly; a separate test proves the shell wrapper contains and performs only the constant absolute `/usr/bin/node` plus fixed `/opt/testradio/launcher/radio-lite-release.mjs` hand-off.

```js
const manifestCommit = "0123456789abcdef0123456789abcdef01234567";
const archiveRelative = "incoming/Radio-Lite-Server.tar.gz";
const archive = join(root, ...archiveRelative.split("/"));
const testServiceUid = Number.parseInt(process.env.RADIO_LITE_TEST_SERVICE_UID ?? "", 10);
const testServiceGid = Number.parseInt(process.env.RADIO_LITE_TEST_SERVICE_GID ?? "", 10);
const testDeployGid = Number.parseInt(process.env.RADIO_LITE_TEST_DEPLOY_GID ?? "", 10);
const testDeviceGids = (process.env.RADIO_LITE_TEST_DEVICE_GIDS ?? "")
  .split(",").filter(Boolean).map((value) => Number.parseInt(value, 10));
assert.equal(process.geteuid?.(), 0);
for (const id of [testServiceUid, testServiceGid, testDeployGid, ...testDeviceGids]) {
  assert.equal(Number.isSafeInteger(id) && id > 0, true);
}
await mkdir(join(root, "incoming"), { recursive: true });
await mkdir(join(root, "config"), { recursive: true });
await mkdir(join(root, "data"), { recursive: true });
await writeFile(join(root, "config", "runtime.env"), [
  `RADIO_LITE_DATA_DIR=${join(root, "data")}`,
  "RADIO_LITE_HOST=0.0.0.0",
  "RADIO_LITE_PORT=8080",
  "RADIO_LITE_ALLOW_INSECURE=1",
  `RADIO_LITE_SERVICE_UID=${testServiceUid}`,
  `RADIO_LITE_SERVICE_GID=${testServiceGid}`,
  `RADIO_LITE_DEPLOY_GID=${testDeployGid}`,
  `RADIO_LITE_SERVICE_DEVICE_GIDS=${testDeviceGids.join(",")}`,
  "",
].join("\n"));
await writeFile(archive, "deterministic-radio-lite-server-fixture-v1");
const archiveSha256 = createHash("sha256").update(await readFile(archive)).digest("hex");
await writeFile(`${archive}.sha256`, `${archiveSha256}  Radio-Lite-Server.tar.gz\n`);
await writeFile(`${archive}.commit`, `${manifestCommit}\n`);

const result = await runRelease([
  "deploy", archiveRelative, "--sha256", archiveSha256, "--commit", manifestCommit,
], {
  secureFs: testOnlySecureFs,
  rootHandle: testOnlySecureFs.openTestRoot(root),
  commands: fakeCommands,
});
assert.equal(result.exitCode, 0);
assert.equal(await readlink(join(root, "current")), `releases/${manifestCommit}`);
assert.deepEqual(await pathsOutside(root), []);
```

Add separate cases for missing `--sha256`, missing `--commit`, invalid explicit digest/commit lengths, missing companion files, a BOM/additional-line/wrong-filename/mixed-case/malformed `.sha256`, a whitespace/multiple-line/malformed `.commit`, companion-vs-explicit mismatch, wrong archive SHA-256, companion/explicit/`release.json` commit mismatch, drain exits 10–13, stale proof, failed health check with safe old-release restore, dirty destination, absolute/`..` path members, symlink/hardlink archive members, and a process identity whose PID/cwd/`processStartToken`/`releaseCommit` does not match the current release. Add these exact cases:

- `"candidate check failure never requests drain or stops the old process"`: make fake `npm run check` fail, then assert `drainCalls === 0`, `consumeCalls === 0`, `killCalls === 0`, and `current` is unchanged;
- `"process identity guard failure cancels the unconsumed drain"`: assert one cancel receives the exact `DrainOwnerRef` from the drain response and its reply echoes every field, `consumeCalls === 0`, `killCalls === 0`, and the old process remains admitted after cancel;
- `"concurrent deployment loses the lock before drain"`: hold the first invocation after lock acquisition, run a second, and assert the second exits 75 with no drain, stage, symlink, or process call;
- `"openat2 rejects symlink substituted at pre-open barrier without external mutation"`: at the addon's before-open barrier replace each direct/nested managed target or parent with an external sentinel symlink; require `ELOOP`/exit 70, byte-for-byte and link-metadata equality outside the root, and no drain/process call;
- `"non-root production runner exits before managed access"`: invoke the packaged production entry with nonzero effective UID and require exit 77, zero `openRoot`/lock/drain calls, and unchanged root metadata;
- `"privileged harness preserves a nonroot service identity"`: require the suite itself to have euid 0 while the test-only original runner UID/GID inputs remain positive/nonroot; invoke the packaged production entry once under that original UID and require exit 77 before `openRoot`/lock/drain;
- `"child supplementary groups are scoped by role before configured uid and gid"`: run archive listing/extraction, candidate checks, and health with an empty supplementary-group set; run new/rollback service with exactly the configured device GIDs and prove the deployment GID is absent. Force `setgroups`, `setresgid`, and `setresuid` failures independently and require exit 77 before target `execve`;
- `"zero or invalid service identity is rejected before child execution"`: set service UID, service GID, deployment GID, and each device GID to zero/out-of-range/duplicate/primary-service/deployment values in turn; require configuration failure before archive-tool, candidate, health, service, rollback, or drain execution, while the production runner itself remains root;
- `"runtime environment exact key set rejects injected commit"`: accept the exact eight-key file with a present `RADIO_LITE_SERVICE_DEVICE_GIDS=` empty allowlist and again with a valid nonempty allowlist; then cover a missing key, duplicate key, arbitrary unknown key, forbidden `RADIO_LITE_RELEASE_COMMIT`, and every other permitted key empty in turn, requiring rejection before archive-tool, candidate, health, service, rollback, or drain execution;
- `"service-owned stage seals to a root-owned traversable release"`: require the new mode-`0700` stage FD to be `fchown`ed to configured service UID/GID before extraction; run extraction and every candidate command after dropping identity; then use the anchored recursive sealer to make directories root/service-group `0550`, non-executable regular files `0440`, and required executable files `0550`, with no writable or escaping entry. Prove new and rollback services can traverse/read the sealed release but cannot mutate it;
- `"companion files are mandatory strict and cross-checked"`: open the fixed archive plus `.sha256` and `.commit` siblings through one pinned `incoming` FD and cover each missing, malformed, or pairwise mismatch case before stage creation, command execution, lock-protected drain, or process inspection;
- `"archive pathname replacement after hash cannot change listed or extracted bytes"`: pause after `pread` hashing, replace the incoming archive pathname with a second valid-looking archive, then require listing/extraction through the inherited fixed archive FD and `/proc/self/fd/<N>` to use only the original inode and match its `release.json`;
- `"archive spawn rejects every non-ArchiveFd handle"`: pass lock, log, companion, and writable regular handles to the native archive spawn API and require a role/read-only error before fork/exec; only `openArchiveAt` can mint the accepted opaque handle;
- `"temporary stage returns its generated basename with the pinned directory"`: require `makeTempDirAt` to return a validated single-component basename paired with the exact opened FD, then prove rejection/installation renames use that basename and the pinned staging parent even after pathname swaps;
- `"spawn rejects relative PATH and unreviewed absolute executables"`: try `node`, `npm`, `tar`, `/usr/bin/npm`, an empty executable, and `/tmp/tool`; require rejection before fork/exec. Only `/usr/bin/node` and archive-only `/usr/bin/tar` execute directly, while npm calls use the dedicated fixed-script API and no shell;
- `"host Node and npm CLI prerequisites fail before drain"`: require `process.execPath` to be `/usr/bin/node`, the running `process.versions.node` to exactly equal both authenticated `release.json.nodeVersion` and extracted `.node-version`, and the fixed Node/tar/npm-cli paths plus root-owned non-writable ancestors to pass owner/mode/type/link/no-symlink checks. Mismatch, missing npm CLI, or substituted/writable metadata exits 70 before candidate command, drain, process inspection, or managed mutation beyond the rejected private stage;
- `"setup-node production entry rejects before managed access"`: while the privileged suite itself runs through setup-node, invoke the production addon/orchestrator without an injected test-host-tool probe and require the exact host executable-path diagnostic plus exit 70; assert the private managed-root sentinel is unchanged and the lock/drain/process fakes record zero calls. Then run the positive fixture only through the opaque test-addon probe. Passing `RADIO_LITE_TEST_*`, arbitrary environment keys, or CLI arguments must not alter either result;
- `"normal install and failed-health rollback pin mutation parents"`: at the pre-mutation barrier swap `staging`, `releases`, `backups`, and `current` pathnames or intermediate parents with external sentinels; require every `mkdirat`/`unlinkat`/`symlinkat`/`renameat2` to use the already-pinned parent dirfds plus basenames, all external sentinel bytes/link metadata to remain unchanged, and rollback to restore only the pinned in-root prior release;
- `"opened log FD remains safe when its pathname is swapped after open"`: after verified log-FD return, rename/swap the pathname and append through the retained FD; require only the originally opened in-root inode to change and every external sentinel to remain unchanged;
- `"preinstalled lock inode cannot be substituted by service or deployment group"`: require root ownership, mode `0600`, a root-owned non-group-writable pinned parent, and no `O_CREAT`; unprivileged rename/unlink attempts fail, a missing path exits 70, and two concurrent root runners open the same inode so the second loses `flock` before drain;
- `"service lock is close-on-exec held for process lifetime and never inherited"`: precreate `run/service.lock` as service-UID/service-GID mode `0600`, single-link below the root-owned non-writable `run` parent. Open without `O_CREAT`, acquire `LOCK_EX|LOCK_NB` before radio initialization, prove a second service cannot acquire it, prove service children inherit no duplicate lock FD, and prove only orderly final release or process death makes it acquirable;
- `"stale control socket requires dead owner proof and same-inode recheck"`: exercise the real addon with a dead `instance.json` owner and stale socket, pause before unlink, replace either socket or record, and require rejection without deleting the replacement. Without the swap, require one basename-only unlink and exactly one bind retry;
- `"bound socket removes only a proven dead orphan record"`: bind a new lease-owned socket while a dead old `instance.json` remains; require a distinct opaque record-only proof bound to the lease/socket and old record inode, same-inode recheck, record-only unlink, then exclusive publication. Live/unverifiable/swapped records reject without overwriting or unlinking the new socket;
- `"shutdown cleanup orders listener socket record and service lock"`: require service/runtimes, listener close, same-inode socket unlink, same-inode record unlink, then lock close in that exact order. Kill/fail after every edge and prove the next startup either uses the corresponding opaque recovery proof or fails closed; a record swap before cleanup preserves the replacement;
- `"socket-only orphan without a record requires manual repair"`: crash the first process specifically after successful bind/socket verification but before exclusive `instance.json` publication, then start a guarded replacement. Require two total initial bind attempts (the first process succeeds; the replacement gets `EADDRINUSE`), zero replacement bind retry, zero unlink, and a manual-repair diagnostic for that bind→publish crash window;
- `"rollback waits for the failed service to release service lock"`: hold the failed new process after its health failure, require rollback not to start a competing service or touch its live endpoint, then allow exact-process shutdown/lock release and prove rollback acquires the service guard before publishing its own endpoint;
- `"managed regular files reject hardlinks wrong owner mode and type"`: cover deploy/service locks, `instance.json`, `runtime.env`, candidate/new/rollback logs, and every other regular target; require single link, expected UID/GID, no group/other write, and `S_ISREG` before first use;
- `"current symlink outside releases is rejected before process inspection"`: point `current` outside the canonical `releases/<40-hex-commit>` child, then assert no PID inspection, CLI execution, drain, signal, or external mutation;
- `"current read pins release directory FD across current swap"`: pause after `readlinkat` plus release-dir `openat2`/`fstat`, replace `current`, and prove old CLI/PID/cwd checks still consume only the pinned release FD and commit;
- `"control directory SGID supplies deployment gid without service group membership"`: require service UID ownership, deployment GID, exact mode `02750`, a service process whose primary/supplementary groups exclude deployment GID, and inherited deployment GID on the mode-`0660` socket plus service-owned mode-`0640` `instance.json`. Record zero non-root `chown`/`chgrp` calls and reject before drain for missing SGID, group write, wrong owner/GID/type/link count/socket identity, or record metadata;
- `"successful deployment releases the lock for the next deployment"`: leave the first newly started fake service alive, launch a second deployment, and assert it acquires `deploy.lock` and reaches its drain fixture instead of exit 75; on Linux also assert the service's `/proc/<pid>/fd` has no descriptor resolving to `deploy.lock`;
- `"children inherit no deploy root staging parent or lock FDs"`: inspect candidate, health, normal-service, and rollback child FD tables and require every root/staging/parent/lock inode absent. The archive-tool child alone receives one fixed read-only archive FD in addition to its log descriptors;
- `"release manifest binds the launcher contract and component digests"`: strictly accept schema 3 with launcher contract 1 and four lowercase 64-hex fields, recompute each digest from the retained archive bytes, and reject missing/unknown/duplicate/wrong-length/mismatched fields before candidate or drain;
- `"installed launcher bytes must match launcher identity before candidate"`: open fixed `launcher.json`, wrapper, orchestrator, updater, and addon through one pinned root-owned launcher dirfd; require root ownership, single links, frozen modes, exact contract, and actual digests matching both installed identity and authenticated release requirement;
- `"incompatible launcher rejects before candidate drain or current mutation"`: alter each installed component, digest, and contract in turn and require exit 78 `launcher_update_required`, zero candidate/drain/process/current calls, and no automatic repair;
- `"compatible launcher permits deployment without rewriting launcher"`: with exact identity/digests, complete deploy and failed-health rollback while proving launcher directory bytes/inodes/metadata are unchanged;
- `"ordinary deploy and rollback never mutate launcher"`: instrument every native launcher mutation entry and require zero calls from both ordinary subcommands; `radio-lite-release.mjs` neither imports nor invokes `updateLauncherComponents`;
- `"explicit launcher update is confined to launcher and commits identity last"`: hold deploy lock and a safe unconsumed drain, validate target archive/components, clean-load the candidate addon only in a deprivileged child, and record basename-only atomic writes solely below the pinned launcher dirfd with `launcher.json` renamed last; external and other `/opt/testradio` sentinels remain unchanged, then cancellation presents the complete original `DrainOwnerRef` and accepts only a response that echoes every field;
- `"interrupted launcher update fails closed and requires explicit recovery"`: interrupt before each component/identity rename, require ordinary deploy to reject the mixed state with exit 78, and prove the installed contract-1 updater can resume its own parseable contract-1 transaction. A newer, unknown, or malformed contract performs zero launcher/drain writes and reports unsupported; offline re-bootstrap for it is outside this plan and requires a separate reviewed design;
- `"recover cancel after SIGKILL targets only the recorded live drain owner"`: SIGKILL the updater after its first launcher mutation, then invoke installed `recover-cancel --transaction <single-basename>`. Require deploy-lock acquisition first, exact transaction/process/instance/socket/record inode verification, and a complete `DrainOwnerRef` cancel whose reply echoes every field before the transaction can be retired;
- `"old launcher transaction cannot cancel a replacement process or newer drain"`: replay a transaction after process replacement and while the same process holds a later generation; both attempts fail without cancel, launcher write, signal, or `current` mutation. An exact already-cancelled contract-1 retry is idempotent and cannot affect the newer generation;
- `"unknown launcher contract fails closed without writes"`: feed a newer, malformed, or unparseable launcher contract to update and recovery commands; require zero launcher/drain/transaction writes and no claimed recovery path;
- `"launcher update rejects active transmission and cancels its held drain"`: active/unknown/external-PTT/dekey states perform zero launcher writes; every safe success or failure path leaves proof unconsumed and calls `drain-cancel` with the complete original `DrainOwnerRef` exactly once, requires a complete matching echo, and only then releases `deploy.lock`;
- `"production addon exposes no test root or barrier symbols"`: load the packaged addon and require `openTestRoot`/barrier controls to be absent; load the separately compiled test addon only in the harness and require them to exist there;
- `"release start reuses config and injects the matching new or rollback commit"`: require the captured new/rollback process environments to contain the exact data/host/port/insecure/device-GID values parsed from `runtime.env`, never `./data`/8787, and respectively inject the reviewed new or pinned old `RADIO_LITE_RELEASE_COMMIT`; require unique instance record, control reply, service-lock owner, and pinned cwd to agree in both directions;
- `"consume fresh reread rejects a changed safety generation even when final state is safe"`: hold the real privileged consume fixture inside its awaited fresh-read path, advance `deploymentSafetyGeneration` with an unsafe→safe transition, then release a final all-safe snapshot. Require `stale_proof`/rejected status, readiness still false, and exactly zero shutdown registrations, fallback signals, process-stop calls, release renames, or `current` mutations;
- `"lost consume reply requires authoritative registered status"`: drop the consume reply, then require read-only `consume-status` for the identical `ConsumeAttemptRef` (attempt ID, drain generation, complete process identity, and socket device/inode) to return `consumed_shutdown_registered` and echo every field before waiting or allowing bounded exact-process escalation;
- `"unprocessed expired dynamic-invalid and rejected consume never signal or switch current"`: drop replies for an unprocessed request, expired proof, fresh recheck that sees PTT/SWR/de-key/admission change, and handler rejection. Status must not attest registration; each path records zero shutdown fallback signal, release rename, and `current` mutation.

- [ ] **Step 2: Run the harness and verify the red state**

```bash
set -euo pipefail
bash scripts/build-radio-lite-secure-fs.sh deploy/native/radio_lite_secure_fs.node
bash scripts/build-radio-lite-secure-fs.sh --test-hooks deploy/native/radio_lite_secure_fs.test.node
test_uid="$(id -u)"
test_gid="$(id -g)"
node_bin="$(command -v node)"
test "$test_uid" -gt 0
sudo env \
  RADIO_LITE_SECURE_FS_TEST_ADDON="$PWD/deploy/native/radio_lite_secure_fs.test.node" \
  RADIO_LITE_TEST_SERVICE_UID="$test_uid" \
  RADIO_LITE_TEST_SERVICE_GID="$test_gid" \
  RADIO_LITE_TEST_DEPLOY_GID="$((test_gid + 1))" \
  RADIO_LITE_TEST_DEVICE_GIDS="$((test_gid + 2)),$((test_gid + 3))" \
  "$node_bin" --test deploy/test-secure-fs-linux.mjs deploy/test-radio-lite-release.mjs
```

Expected: FAIL because the addon, orchestrator, and exec-only wrapper do not exist.

- [ ] **Step 3: Implement and freeze the native root-FD contract**

`secure-fs.mjs` exposes opaque handles only; callers cannot recover a managed absolute path and
then reopen it with Node `fs`. The production loader exports only the literal `/opt/testradio`
`openRoot()` path. `openTestRoot()` and syscall barriers exist only in a separately compiled test
addon injected into exported `runRelease`; no environment variable or production CLI flag can
redirect the root. The C/N-API addon, not a JavaScript emulation, implements at least:

```ts
type RootFd = { readonly opaqueRootFd: unique symbol };
type ManagedFd = { readonly opaqueManagedFd: unique symbol };
type ManagedDirFd = ManagedFd & { readonly opaqueDirectoryFd: unique symbol };
type ArchiveFd = ManagedFd & { readonly opaqueReadOnlyArchiveFd: unique symbol };
type TestHostToolProbe = { readonly opaqueTestHostToolProbe: unique symbol }; // test addon only
type AbsoluteExecutable = "/usr/bin/node" | "/usr/bin/tar";

openRoot(absRoot: "/opt/testradio"): RootFd;
openDir(anchor: RootFd | ManagedDirFd, relative: string,
  expectation: DirExpectation): ManagedDirFd;
openExistingRegular(anchor: RootFd | ManagedDirFd, relative: string,
  expectation: FileExpectation): ManagedFd;
openArchiveAt(parent: ManagedDirFd, basename: string,
  expectation: FileExpectation): ArchiveFd;
openRegularAt(parent: ManagedDirFd, basename: string, flags: OpenFlags,
  mode: number, expectation: FileExpectation): ManagedFd;
makeDirAt(parent: ManagedDirFd, basename: string, mode: number,
  owner: { uid: number; gid: number }): ManagedDirFd;
makeTempDirAt(parent: ManagedDirFd, prefix: string, mode: number,
  owner: { uid: number; gid: number }): { dirFd: ManagedDirFd; basename: string };
readAll(fd: ManagedFd, maximumBytes: number): Uint8Array;
preadAll(fd: ManagedFd, maximumBytes: number): Uint8Array;
writeAllAndSync(fd: ManagedFd, bytes: Uint8Array): void;
renameAt(fromParent: ManagedDirFd, fromBasename: string,
  toParent: ManagedDirFd, toBasename: string): void;
unlinkAt(parent: ManagedDirFd, basename: string, expected: "regular" | "directory" | "symlink"): void;
symlinkAt(parent: RootFd | ManagedDirFd, targetLiteral: string, basename: string): void;
sealReleaseTree(stage: ManagedDirFd,
  owner: { uid: 0; gid: number }, modes: { directory: 0o550; regular: 0o440; executable: 0o550 }): void;
flockExclusiveNonblock(fd: ManagedFd): void;
readCurrent(root: RootFd): { commit: string; releaseDirFd: ManagedDirFd };
replaceCurrent(root: RootFd, commit: string): void;
inspectControlSocket(root: RootFd, expectation: SocketExpectation):
  { controlDirFd: ManagedDirFd; procFdPath: string };
verifyHostToolPrerequisites(): void;
acquireServiceInstanceGuard(expected: { serviceUid: number; serviceGid: number;
  deploymentGroupId: number; releaseCommit: string;
  nodeVersion: "24.7.0" }): ServiceInstanceLease;
spawnLogged(options: { cwdFd: ManagedDirFd; logFd: ManagedFd;
  executable: AbsoluteExecutable; args: readonly string[]; env: readonly string[];
  uid: number; gid: number; supplementaryGids: readonly number[] }): Child;
spawnNpmCli(options: { cwdFd: ManagedDirFd; logFd: ManagedFd;
  argsAfterCli: readonly string[]; env: readonly string[];
  uid: number; gid: number; supplementaryGids: readonly number[] }): Child;
spawnArchiveTool(options: { cwdFd: ManagedDirFd; logFd: ManagedFd; archiveFd: ArchiveFd;
  executable: "/usr/bin/tar"; argsUsingFixedArchiveFd: readonly string[];
  env: readonly string[]; uid: number; gid: number }): Child;
close(fd: ManagedFd | RootFd): void;
```

Only the separately compiled test addon additionally exports
`makeTestHostToolProbe(testRoot, { reportedExecPath, reportedNodeVersion }): TestHostToolProbe`.
The exported harness form of `runRelease` accepts that opaque probe only when paired with the same
test-addon instance; production `main()`, production `secure-fs.mjs`, environment parsing, and CLI
argument parsing have no corresponding seam. A forged object or probe paired with the production
addon is rejected before managed access.

`openRoot("/opt/testradio")` opens trusted `/opt` first and resolves the literal child `testradio`.
The test build exposes a distinct `openTestRoot` symbol that is absent from the packaged addon.
Every generic root-FD/mutation/spawn method requires effective UID 0. The only non-root production
entry is `acquireServiceInstanceGuard`, which requires the caller's effective UID/GID to equal the
strict expected service identity and exposes no caller-supplied path or generic FD/mutation handle.
It opens fixed `/opt/testradio/run/service.lock` without `O_CREAT`, verifies the service-owned
mode-`0600` single-link file below a root-owned non-group-writable `run` parent, takes
`flock(LOCK_EX|LOCK_NB)`, pins and verifies the service-UID/deployment-GID mode-`02750` SGID control
directory, verifies the service's supplementary groups exclude deployment GID, and returns a
close-on-exec opaque lease whose bind path is only
`/proc/self/fd/<pinnedControlDirFd>/control.sock`. Before opening the lock it also verifies the fixed
Node executable metadata and exact sealed-manifest version through this narrow call. The lease remains
referenced until final shutdown.
Its stale-endpoint classifier binds/probes first, checks nonce reply, unique `instance.json`, boot ID,
PID/start token, cwd/release inode, and recorded socket device/inode, and can mint an opaque stale
socket+record proof only when the recorded owner is dead. Unlink consumes that proof after same-inode
rechecks of both socket and record and accepts basenames only. If bind succeeds but an old record
exists, a separate record-only proof is minted only after proving the old process dead and binding the
proof to the record inode, current lease, and current owned socket inode; it can unlink only that old
record before an exclusive publish. Live/unverifiable owners, changed inodes, a second bind collision,
and socket-only/no-record state fail closed. Cleanup rechecks ownership and fixes the order to listener
close, socket unlink, record unlink, then service-lock close. No other non-root addon export can open
or mutate a managed path.
For the root orchestrator, before `openRoot` or any managed operation,
`verifyHostToolPrerequisites()` opens the three fixed
host paths with no symlink following, verifies each resolved inode plus every ancestor is root-owned
and not group/other writable, requires regular single-link files (and execute bits for Node/tar), and
confirms the active `process.execPath` is literal `/usr/bin/node`. It is read-only and has no
caller-supplied path. `/usr/bin/npm` is never accepted. `spawnNpmCli` repeats the fixed npm-cli
metadata check immediately before dropping identity and `execve("/usr/bin/node", ...)`, prepending
literal `/usr/share/nodejs/npm/bin/npm-cli.js` to its argument array; only trusted root could change
that pathname between checks, and root is already the deployment trust boundary.
Every descendant operation rejects an absolute
path, empty component, `.`, or `..`, and uses `openat2` with these non-negotiable flags:

```c
struct open_how how = {
  .flags = requested_flags | O_CLOEXEC | O_NOFOLLOW,
  .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS,
};
int fd = syscall(SYS_openat2, parent_fd, relative_path, &how, sizeof(how));
```

`ENOSYS` exits 70; there is no compatibility fallback. Do not add `RESOLVE_NO_XDEV`: the product
may deliberately mount `data` separately, while every selected descendant still must satisfy its
FD-level ownership/type/mode contract. Before first use, `fstat` requires directories to be
`S_ISDIR`, expected UID/GID, and free of group/other write unless an explicitly frozen directory
mode says otherwise. Regular managed files must be `S_ISREG`, `st_nlink == 1`, expected UID/GID,
and free of group/other write. The control socket must be `S_ISSOCK`, `st_nlink == 1`, service UID,
deployment GID, and mode `0660`; the mode-`0640` instance record and socket must inherit that GID
without non-root `chown`/`chgrp`, and their parent must be service UID/deployment GID exact mode `02750`.

Open the preinstalled `run/deploy.lock` once as `O_RDWR|O_APPEND|O_CLOEXEC` without `O_CREAT`,
validate root ownership/mode/single-link on its FD, and call `flock(fd, LOCK_EX|LOCK_NB)`. Its pinned
`run` parent is root-owned and non-group-writable; a missing path fails rather than creating a new
inode. The Node parent retains that FD until success or completed rollback. `spawnLogged` receives
an already-open log FD and cwd FD, uses `fchdir`, duplicates only the log to stdout/stderr, replaces
supplementary groups with the exact passed allowlist, then calls checked `setresgid`/`setresuid`,
closes lock/root/staging/parent FDs, and invokes `execve` with the exact reviewed absolute executable;
it never searches `PATH`. Candidate and health callers pass `[]`; only new/rollback service callers
pass the parsed device GIDs. `spawnArchiveTool` always sets an empty supplementary-group list and
additionally maps exactly the retained `ArchiveFd` to one fixed child descriptor. `openArchiveAt`
opens a regular single-link file read-only and tags its native handle role; `spawnArchiveTool`
rechecks that role and `F_GETFL` access mode, so a lock/log/general `ManagedFd` is rejected even if a
JavaScript caller bypasses TypeScript. `spawnNpmCli` shares the same FD/identity/group cleanup but
has no executable or script-path input; its native constants are `/usr/bin/node` plus the verified
Debian npm CLI path. No general arbitrary-FD inheritance API exists.

`run/service.lock` is distinct from `run/deploy.lock`: the orchestrator never passes or holds the
service lease on behalf of a child. Each new or rollback service opens it itself immediately after
exec and before radio initialization. The orchestrator waits for the exact failed/new process to exit
before spawning rollback; startup/health cannot succeed until that child reports a matching locked
`instance.json`. Candidate, health, archive, and service-spawn FD tables contain neither another
process's service-lock FD nor the deploy-lock FD.

Complete Task 3's production seam in `service-instance-guard.ts` with an adapter that loads the sealed
release-relative production addon only after the process has permanently dropped to the configured
service identity; it calls only `acquireServiceInstanceGuard`. Wire `src/index.ts` in this task:
validate environment/cwd/manifest and exact host Node first, acquire the lease, then initialize radios,
bind/publish the control endpoint, and announce readiness. A guard failure exits before radio/audio/
rigctld initialization or any endpoint/record mutation. Every partial-start failure unwinds through
the same owner and releases the lease last. There is no JavaScript `fs`/path-based lock, stale unlink,
or unlocked development fallback in production; tests inject the Task 3 port explicitly.

Every creation, unlink, link, or rename first pins its direct parent directory with `openat2`; the
native mutation receives only those parent FDs plus validated single-component basenames. The addon
never passes `a/b` to a mutating `*at` syscall. `readCurrent` calls `readlinkat(rootFd, "current")`, accepts only the literal relative form
`releases/[0-9a-f]{40}`, resolves that value with the same `openat2` flags, and returns the pinned
directory FD plus commit. Process inspection, old CLI selection, and rollback keep using that FD if
the pathname later changes. `replaceCurrent` creates only `releases/<commit>` as a temporary
same-directory symlink and commits it with `renameat`; it never calls `realpath`, `ln`, or `mv`.

`radio-lite-release.sh` is deliberately incapable of opening a managed target:

```bash
#!/bin/bash
set -euo pipefail
exec /usr/bin/node /opt/testradio/launcher/radio-lite-release.mjs "$@"
```

Initial bootstrap installs that exact wrapper, orchestrator, `radio-lite-launcher-update.mjs`,
production addon, and `launcher.json` to root-owned single-link mode-`0555`/`0444` targets. Create
`deploy/launcher-contract.json` exactly as:

```json
{ "schemaVersion": 1, "contractVersion": 1 }
```

Installed `launcher.json` has schema/contract 1 plus
`releaseWrapperSha256`, `releaseOrchestratorSha256`, `updaterSha256`, and
`secureFsAddonSha256`, each the lowercase 64-hex digest of the installed bytes. It is committed only
after all four component files during bootstrap/update. A normal deploy never rewrites launcher,
resolves deployment code through `current`, imports `updateLauncherComponents`, or accepts an
automatic compatibility fallback.

`radio-lite-launcher-update.mjs` is a separate root-only program exporting
`updateLauncherComponents` plus `recoverCancelTransaction`; both normal `finally` and the installed
recovery command call the same `verifyRecordedDrainOwnerAndCancel` function. Update mode accepts only
`incoming/Radio-Lite-Server.tar.gz --sha256 <64hex> --commit <40hex> --confirm-contract 1`;
recovery accepts only `recover-cancel --transaction <validated-single-basename>`;
opens archive/companions with the same pinned `incoming` and `ArchiveFd` contract; obtains
`run/deploy.lock`; and requests a fresh safe drain without consuming its proof. Active, unknown,
external-PTT, dekey, mismatched process, stale proof, or unsupported contract writes nothing. For a
safe update it creates a generated `.update-*` directory only below the pinned launcher dirfd,
immediately writes/fsyncs the unconsumed drain generation, boot ID, PID/start token, cwd, release
commit, and socket/record device+inode there before the first component mutation,
extracts only the four allowlisted target files through the retained archive FD after strict member
validation, clean-loads the candidate addon in a deprivileged empty-group child, verifies all target
digests, then atomically renames root-owned frozen-mode components by basename and renames the new
`launcher.json` last. Its `finally` path and installed recovery command both call
`verifyRecordedDrainOwnerAndCancel`: deploy lock first, exact live process/instance/socket plus the
complete persisted `DrainOwnerRef` check, then a full-owner cancel whose response must echo every
field before releasing the lock. No success path
stops/restarts the service or changes `current`.

Ordinary deploy authenticates schema-3 `release.json`, then opens installed `launcher.json` and all
four installed components through one pinned launcher dirfd, verifies root owner/mode/type/single-link
and actual digests, and requires installed identity to equal the archive launcher requirement before
the first candidate command or drain. Any mismatch returns exit 78 with code
`launcher_update_required` and no candidate/process/current mutation. An interrupted contract-1 update
leaves a mixed identity that ordinary deploy rejects but the installed contract-1 updater can resume.
Before its first component mutation the updater fsyncs a transaction record containing drain generation,
boot ID, PID, process start token, cwd, release commit, and socket/record device+inode. SIGKILL recovery
uses only installed `radio-lite-launcher-update.mjs recover-cancel --transaction <single-basename>`:
it acquires `deploy.lock` first, reopens and verifies that exact transaction, live process,
`instance.json`, socket and record inodes, then passes the complete persisted `DrainOwnerRef` to
`verifyRecordedDrainOwnerAndCancel` and requires a full-field echo before retiring the record. Its
normal `finally` path calls that same tuple-verification-and-cancel function rather than maintaining a
second validator.
An old process/record/socket or old generation never cancels a replacement/new drain. A newer,
unknown, malformed, or unparseable contract fails closed with zero transaction, launcher, or drain
writes. Any future offline re-bootstrap for such a contract is outside this plan and needs a separate
reviewed design; this plan makes no command or completion promise for it.

The orchestrator opens `config/runtime.env` once with `openExistingRegular` and parses the bytes without
`source`, `eval`, or a Node path reopen. Reject duplicate or unknown keys and whitespace/control or
shell-syntax values; reject an empty value for every key except the required
`RADIO_LITE_SERVICE_DEVICE_GIDS`, whose empty value means no supplementary device groups. Accept
exactly `RADIO_LITE_DATA_DIR`, `RADIO_LITE_HOST`, `RADIO_LITE_PORT`,
`RADIO_LITE_ALLOW_INSECURE`, `RADIO_LITE_SERVICE_UID`, `RADIO_LITE_SERVICE_GID`, and
`RADIO_LITE_DEPLOY_GID` plus `RADIO_LITE_SERVICE_DEVICE_GIDS`; service UID, service GID, and
deployment GID must all be positive integers within the platform ID range (service UID 0 is always
rejected), the port is 1–65535, and the insecure flag is 0 or 1. Device GIDs are an empty string or a
comma-separated, strictly increasing list of positive decimal GIDs; reject whitespace, duplicates,
the primary service GID, deployment GID, 0, or an out-of-range value. `RADIO_LITE_DATA_DIR` must be
the literal `/opt/testradio/data` in production, and the addon separately opens/validates the `data`
directory FD. Build an explicit base environment vector that contains those values but never a
release commit. `RADIO_LITE_RELEASE_COMMIT` is not a permitted `runtime.env` key and is appended only
when spawning a long-running new/rollback service. If host is `0.0.0.0` or `::`, health-check loopback
while preserving the configured listen host.

The archive is accepted only as an `incoming/<basename>` basename beneath one pinned `incoming`
directory FD. Open it once with `openArchiveAt` to obtain an opaque `ArchiveFd`, and open its exact
`<basename>.sha256`/`<basename>.commit` siblings once as ordinary read-only managed files;
strictly parse one checksum line and one commit line, require the explicit 64/40-lowercase-hex
arguments to equal them, and hash with `preadAll` on the retained archive FD. Create the private stage
by destructuring `{ dirFd: stageDirFd, basename: stageBasename } = makeTempDirAt(...)`; the addon
generates and validates the unique single-component basename and verifies the post-`fchown` FD before
a child runs. Listing and extraction use `spawnArchiveTool` with absolute `/usr/bin/tar`, empty
supplementary groups, and that same service identity, and consume only the retained archive at its
fixed child FD. The spawn API rejects a general `ManagedFd`; the archive validator rejects absolute,
empty, `.`, `..`, symlink, hardlink, device, FIFO, and socket members before extraction. Extracting
code never receives an attacker-replaceable archive or stage pathname. `release.json` must match all
companion/explicit values, exact `.node-version`,
`platform=linux`, host `process.arch`, host N-API support, and the packaged addon bytes. It must also
equal the running `process.versions.node` exactly; a compatible N-API level is not a substitute for
the pinned Node version. Host-tool or Node-version failure exits 70 before any candidate command,
drain, process inspection, or release switch. Refuse an
existing release rather than deleting or repairing it. This is an operator-reviewed digest contract,
not an unspecified signature scheme.

Before contacting the old process, run the npm candidate lines through `spawnNpmCli` and the two
ordinary Node lines through `spawnLogged`, always with pinned stage cwd/log FDs and caches opened
below the root:

```text
/usr/bin/node /usr/share/nodejs/npm/bin/npm-cli.js --prefix radio-lite-server ci
/usr/bin/node /usr/share/nodejs/npm/bin/npm-cli.js --prefix radio-lite-server run check
/usr/bin/node /usr/share/nodejs/npm/bin/npm-cli.js --prefix web test
/usr/bin/node scripts/check-ios-radio-lite-contract.mjs
/usr/bin/node scripts/check-radio-lite-release-contract.mjs
/usr/bin/node /usr/share/nodejs/npm/bin/npm-cli.js --prefix radio-lite-server prune --omit=dev
```

The npm lines use `spawnNpmCli`; the display expands its fixed native executable/first argument so the
actual command is auditable. Other lines use `spawnLogged`. No line invokes `/usr/bin/npm`, `/usr/bin/env`,
or a shell, and every
candidate tool receives an empty supplementary-group list while running as the configured service
identity in the service-owned stage. After the
last successful prune, `sealReleaseTree` performs an anchored no-follow recursive walk, rejects
escaping links/special files/unexpected hardlinks, changes ownership to root/service GID, and removes
all write bits (directories `0550`, ordinary files `0440`, files whose reviewed execute bit is needed
`0550`). Reopen representative entrypoint/native/package files through the sealed stage FD and prove
the service identity can traverse/read but not mutate them. Any failure occurs before deploy-socket
connection, drain, PID inspection, signaling, release rename, or `current` replacement. Preserve a
rejected stage with `renameAt(stagingDirFd, stageBasename, backupsDirFd,
rejectedBasename)` and write its diagnostic through an already-open log FD. Package caches, temp
files, instance records, runtime bytes, and rejection records cannot leave the root.

- [ ] **Step 4: Implement drain, exact-process stop, switch and health rollback**

Call `readCurrent(rootFd)` first and retain its release-directory FD. Open the service-owned control
directory and socket through `inspectControlSocket`; connect only through the returned
`/proc/self/fd/<controlDirFd>/control.sock` address. Read the unique service-owned single-link
mode-`0640` `run/control/instance.json` through an addon FD and capture the zero-exit response's
complete `DrainOwnerRef` plus its proof containing `deploymentSafetyGeneration`; require the CLI to
preserve that signed field verbatim. While unconsumed, require the fixed record,
socket inode, drain response, `releaseCommit`, `/proc/<pid>/stat` `processStartToken`, boot ID, and an opened
`/proc/<pid>/cwd` inode to agree with the commit and inode from the pinned release-directory FD. Path
strings alone are diagnostic only. Any failure invokes `drain-cancel` with the complete `DrainOwnerRef`
captured from the safe response, accepts success only when the reply echoes every field, and exits
without consume, signal, release rename, or `current` change.
Repeat the PID/`processStartToken`/cwd-FD/`releaseCommit`/socket identity check immediately before
`proof-consume`, generate one random 128-bit lowercase-hex consume-attempt ID, and send the complete
attempt/process/socket tuple with the proof.

Within five seconds call `proof-consume`; inside the exact held drain/safety serialization it repeats
fresh all-runtime PTT/SWR/de-key/pending-admission reads, rechecks the signed
`deploymentSafetyGeneration` after every await, and only for an unchanged safe result atomically
consumes and synchronously registers its existing idempotent shutdown owner before reply I/O. A valid
reply echoes the complete attempt/process/socket tuple and `shutdownRegistered:true`. Dynamic-invalid,
expired, stale, or rejected consume produces zero shutdown/signal/current mutation.

If the reply is lost, never re-consume, infer success from identity/process exit, or select a process
by name. Send read-only `consume-status` with the identical `ConsumeAttemptRef`. Only an authenticated
reply that both reports `consumed_shutdown_registered` and echoes every attempt field permits waiting
for that exact process; only that retained authority,
followed by reopening `/proc/<pid>` and revalidating boot ID, start token, release commit, cwd inode,
socket identity, and generation, permits a bounded SIGTERM escalation. `held_unconsumed`, `rejected`,
`unknown`, unavailable status, or no reply fails closed with zero signal, release rename, and `current`
mutation. There is no fallible external guard between a successful consume and initial shutdown
registration because the serving process stores that owner synchronously.

After confirmed old-process exit, use `renameAt(stagingDirFd, stageBasename, releasesDirFd,
reviewedCommit)` to install the already sealed stage and `replaceCurrent` to switch the relative
symlink using pinned root/releases parents plus basenames. Reopen the sealed release as a
`ManagedDirFd`, open the new/rollback log once, and call `spawnLogged` with that cwd FD, log FD,
absolute `/usr/bin/node`, the fixed service-entrypoint argument, the validated base environment plus
`RADIO_LITE_RELEASE_COMMIT=<reviewedCommit>`, configured service UID/GID, and the exact device-GID
allowlist. The child receives no deploy-lock/root/staging/parent FD. Wait for the service's
FD-confined `instance.json` and control identity; require both `releaseCommit` values and the cwd inode
to match the pinned new release, and require the record to attest the endpoint published while that
exact process holds `service.lock`, then health-check loopback at the configured port. A child health
helper, if used instead of the orchestrator's own HTTP loop, uses absolute `/usr/bin/node` with empty
supplementary groups. No install or candidate test occurs in the five-second proof window.

On health failure, drain the new process when reachable through the same pinned-control-directory and
identity/consume-self-shutdown flow; if it never created a runtime, require its instance record/state
to prove that fact before the exact-process fallback. Then `replaceCurrent` restores the old commit
and wait for the exact failed process to exit (thereby releasing its service-instance flock) before
`spawnLogged` starts the pinned prior release with the identical validated base environment and
device-GID allowlist but a separately injected `RADIO_LITE_RELEASE_COMMIT=<pinnedOldCommit>`. Its PID
record, control reply, and cwd inode must all match that old commit before rollback is healthy. The parent keeps
the validated lock FD through complete success or rollback; normal service, health, diagnostic, and
rollback children inherit no root/staging/parent/lock FD. The live-child FD test and a second concurrent deployment prove
that lock ownership is transaction-scoped rather than pathname-scoped or accidentally service-lived.

- [ ] **Step 5: Run syntax, harness and forbidden-command checks**

```bash
set -euo pipefail
bash -n deploy/radio-lite-release.sh
node --check deploy/radio-lite-launcher-update.mjs
node -e 'const c=require("./deploy/launcher-contract.json"); if(c.schemaVersion!==1||c.contractVersion!==1||Object.keys(c).length!==2) process.exit(1)'
bash scripts/build-radio-lite-secure-fs.sh deploy/native/radio_lite_secure_fs.node
bash scripts/build-radio-lite-secure-fs.sh --test-hooks deploy/native/radio_lite_secure_fs.test.node
test_uid="$(id -u)"
test_gid="$(id -g)"
node_bin="$(command -v node)"
test "$test_uid" -gt 0
sudo env \
  RADIO_LITE_SECURE_FS_TEST_ADDON="$PWD/deploy/native/radio_lite_secure_fs.test.node" \
  RADIO_LITE_TEST_SERVICE_UID="$test_uid" \
  RADIO_LITE_TEST_SERVICE_GID="$test_gid" \
  RADIO_LITE_TEST_DEPLOY_GID="$((test_gid + 1))" \
  RADIO_LITE_TEST_DEVICE_GIDS="$((test_gid + 2)),$((test_gid + 3))" \
  "$node_bin" --test deploy/test-secure-fs-linux.mjs deploy/test-radio-lite-release.mjs
set +e
forbidden="$(rg -n 'rm -rf|pkill|killall|/etc/|/var/|/usr/bin/npm|/usr/bin/env|realpath -e|\blstat\b|ensure_managed_|exec\s+[0-9]+>>' deploy/radio-lite-release.sh deploy/radio-lite-release.mjs deploy/radio-lite-launcher-update.mjs 2>&1)"
forbidden_status=$?
set -e
if [[ $forbidden_status -eq 0 ]]; then
  printf 'forbidden deployment command found: %s\n' "$forbidden" >&2
  exit 1
fi
test "$forbidden_status" -eq 1
set +e
path_io="$(rg -n "from\\s+['\"]node:fs|require\\(['\"]node:fs|\\bfs\\." deploy/radio-lite-release.mjs deploy/radio-lite-launcher-update.mjs 2>&1)"
path_status=$?
set -e
if [[ $path_status -eq 0 ]]; then
  printf 'orchestrator bypasses secure-fs addon: %s\n' "$path_io" >&2
  exit 1
fi
test "$path_status" -eq 1
```

Expected: syntax/addon/tests PASS and both scans return no matches. These commands are the authoritative privileged suites later owned by `release-readiness`; the artifact packager must not rerun them. The suites preserve positive nonroot service IDs supplied by the invoking account while production still checks real euid 0. Pre-open substitution exits 70 without external mutation; after-open swaps cannot redirect pinned lock/log/current/control state; owner/mode/type/hardlink failures occur before drain; candidate failure records zero drain/consume/signal calls; relative/unreviewed executables and non-`ArchiveFd` handles fail before spawn; identity-guard failure cancels an unconsumed generation; a concurrent deployment loses the deploy FD lock before drain; a concurrent/manual service loses `service.lock` before radio initialization and cannot unlink/replace the live endpoint or `instance.json`; stale endpoint deletion requires dead-owner proof plus same-inode recheck; rollback waits for failed-service lock release; every child lacks root/staging/parent/deploy/service-lock FDs; archive/candidate/health groups are empty and service/rollback groups equal only the device allowlist; consume reply loss follows only the authenticated old process; and new/rollback starts use the same validated base configuration with their own matching injected release commit.

- [ ] **Step 6: Commit the release workflow**

```powershell
git add deploy/native/radio_lite_secure_fs.c deploy/secure-fs.mjs deploy/radio-lite-release.mjs deploy/radio-lite-release.sh deploy/launcher-contract.json deploy/radio-lite-launcher-update.mjs deploy/test-secure-fs-linux.mjs deploy/test-radio-lite-release.mjs scripts/build-radio-lite-secure-fs.sh radio-lite-server/src/deploy/service-instance-guard.ts radio-lite-server/src/deploy/control-socket.ts radio-lite-server/src/index.ts
git commit -m "feat: deploy Radio Lite within testradio"
```

### Task 5: Finish documentation, repository rules and full release verification

**Files:**
- Create: `docs/DEPLOYMENT.md`
- Modify: `README.md`
- Modify: `ios/README.md`
- Modify: `docs/SAFETY.md`
- Modify: `docs/HAMLIB.md`
- Modify: `radio-lite-server/PROTOCOL.md`

**Interfaces:**
- Consumes: completed server, iOS, CI and deployment behavior.
- Produces: one operator checklist and one evidence bundle for GitHub/Debian acceptance.

- [ ] **Step 1: Write exact repository and artifact instructions**

Document these required GitHub checks by exact name:

```text
server-check
web-check
protocol-contract
xcode-build-and-test
release-readiness
```

State that repository ruleset configuration is a one-time GitHub setting and cannot be accomplished by workflow YAML alone. It must not trigger GitHub device authorization; if the repository deploy key cannot manage settings, the user performs that one repository setting manually.
Also document that the workflow's `pull_request` event is intentionally unfiltered and each of the
five required jobs has no path/event `if`, so even a docs-only PR reports a terminal required-check
result. `push.paths` may retain the exact source/release path list because push runs are not used as
the PR merge gate.

- [ ] **Step 2: Replace historical product claims in current docs**

`README.md`, `docs/SAFETY.md`, and `docs/HAMLIB.md` must describe the TypeScript service and native Radio Lite client as current. Historical Python material remains clearly marked non-production. Add the 30-second on-site instruction exactly as a UI/operator escalation, not an assertion that a Node timer is a physical relay.

- [ ] **Step 3: Document the drain and rollback commands**

```bash
cd /opt/testradio
: "${RADIO_LITE_REVIEWED_SHA256:?export the reviewed 64-hex artifact checksum}"
: "${RADIO_LITE_REVIEWED_COMMIT:?export the reviewed 40-hex CI commit}"
sudo /opt/testradio/launcher/radio-lite-release.sh deploy incoming/Radio-Lite-Server.tar.gz \
  --sha256 "$RADIO_LITE_REVIEWED_SHA256" --commit "$RADIO_LITE_REVIEWED_COMMIT"
```

If and only if that command exits 78 with `launcher_update_required`, do not retry ordinary deploy.
After reviewing the same artifact's schema-3 launcher requirement, run the separate manual action:

```bash
sudo /usr/bin/node /opt/testradio/launcher/radio-lite-launcher-update.mjs \
  incoming/Radio-Lite-Server.tar.gz --sha256 "$RADIO_LITE_REVIEWED_SHA256" \
  --commit "$RADIO_LITE_REVIEWED_COMMIT" --confirm-contract 1
```

The updater must report that it acquired `deploy.lock`, obtained a safe unconsumed drain, wrote only
below the pinned launcher directory, committed `launcher.json` last, and cancelled the complete
original `DrainOwnerRef` with a full-field echo. Then rerun the ordinary deploy command from the beginning. Never copy launcher files by
hand during the ordinary release path. The updater prints and fsyncs its single-component transaction
basename before the first mutation. If SIGKILL/interruption leaves that contract-1 transaction, do
not read its generation and issue a bare cancel. Export the exact printed basename and run only:

```bash
: "${RADIO_LITE_LAUNCHER_TRANSACTION:?export the exact .update-* single basename}"
sudo /usr/bin/node /opt/testradio/launcher/radio-lite-launcher-update.mjs \
  recover-cancel --transaction "$RADIO_LITE_LAUNCHER_TRANSACTION"
```

This installed recovery command acquires `deploy.lock`, verifies the persisted generation plus full
bootId/PID/start-token/cwd/release/socket/record-inode tuple against the exact live endpoint, sends the
complete recorded `DrainOwnerRef`, and requires an identical field-by-field echo. Only after it succeeds may the same contract-1
updater resume or be rerun. An old transaction cannot cancel a replacement process or newer drain.
A newer, unknown, malformed, or unparseable contract remains fail-closed with zero write; any future
offline re-bootstrap is a non-goal requiring a separate reviewed design.

Document that all three same-run server artifact files are downloaded together and manually matched
to the reviewed CI run whose `release-readiness` check passed. The orchestrator opens all three
siblings through one `incoming` dirfd and independently verifies companion syntax, bytes, manifest,
addon architecture, and exact host Node version. Service/deployment identities and dialout/audio
device permissions are pre-existing, user-provided prerequisites; verify their numeric IDs and
device-GID allowlist, but never create users/groups, change memberships/ACLs, edit `/etc`, or mutate
device state. Exact Node `24.7.0` at `/usr/bin/node`, plus fixed `/usr/bin/tar` and Debian
`/usr/share/nodejs/npm/bin/npm-cli.js`, are likewise pre-existing read-only prerequisites verified
before candidate execution or drain. Never install or update them, invoke `/usr/bin/npm`, or rely on
PATH for a top-level executable. The CI-only opaque fake-host probe is unavailable to production
CLI/environment and exists only so the root-euid suite can exercise a positive case under
setup-node; a separate production-entry case must fail 70 before managed access.

After those prerequisites have been supplied, the one initial root bootstrap is confined
entirely to `/opt/testradio`: install the reviewed wrapper/orchestrator/updater/addon plus matching
`launcher.json` into root-owned non-writable `launcher`; create root-owned non-group-writable `run` plus the single-link mode-`0600`
root-owned `run/deploy.lock` and service-UID/service-GID `run/service.lock`, both without a runtime
creation path; and create the remaining tree with the exact ownership/modes in this plan.
`run/control` is service-UID/deployment-GID exact mode `02750`; the service is not a deployment-group
member, and socket/record deployment GID is inherited through SGID with no non-root `chgrp`. `runtime.env` contains the exact
data/host/port/insecure/positive-service-UID/service-GID/deployment-GID keys plus the strict
`RADIO_LITE_SERVICE_DEVICE_GIDS` allowlist, which must not contain the deployment group.
`RADIO_LITE_RELEASE_COMMIT` is never stored there: deploy and rollback inject their respective
verified commits into only the service child, whose unique `run/control/instance.json`, control
response, held service-lock identity, socket inode, and cwd must agree. Document bind-first startup,
the prohibition on replacing live/unverifiable endpoints, dead-owner plus same-inode stale recovery,
exactly one bind retry, and clean shutdown releasing `service.lock` only after owned endpoint cleanup.
Neither deployment program edits `/etc`, creates an identity, changes group membership/ACLs,
recreates a missing lock, or rewrites the launcher during ordinary deploy/rollback. Launcher changes
use only the separate exit-78/manual-update flow above. Debian 13 `openat2` and the matching precompiled
addon are hard prerequisites; `ENOSYS`/architecture mismatch has no unsafe fallback. Document the
root-dirfd/openat2/fstat contract, role-tagged read-only archive FD, generated stage basename,
absolute executable allowlist, relative `current`, close-on-exec lock, manual diagnostic
drain/cancel, exits 10–13, five-second proof lifetime, pending-admission rejection, pre-consume
process identity checks, lost-reply handling, candidate checks before drain, preserved data/listen
port, rollback, and the prohibition against editing outside `/opt/testradio`.

- [ ] **Step 4: Run fresh local verification**

```powershell
npm --prefix radio-lite-server run check
npm --prefix web test
node scripts/check-ios-radio-lite-contract.mjs
node scripts/check-radio-lite-release-contract.mjs
node scripts/check-radio-lite-release-readiness.mjs
node --experimental-strip-types --test radio-lite-server/test/deployment-drain.test.ts radio-lite-server/test/deployment-safety-port.test.ts radio-lite-server/test/deployment-control-socket.test.ts
git diff --check
```

On Linux, start as an ordinary positive-UID account with passwordless test sudo and run the privileged
native/orchestrator suites using that account as the child identity. This is the same root-owned test
step used by `release-readiness`; do not copy it into `package-radio-lite-server-release.sh` or the
ordinary `server-release` job:

```bash
set -euo pipefail
bash scripts/build-radio-lite-secure-fs.sh deploy/native/radio_lite_secure_fs.node
bash scripts/build-radio-lite-secure-fs.sh --test-hooks deploy/native/radio_lite_secure_fs.test.node
test_uid="$(id -u)"
test_gid="$(id -g)"
node_bin="$(command -v node)"
test "$test_uid" -gt 0
sudo env \
  RADIO_LITE_SECURE_FS_TEST_ADDON="$PWD/deploy/native/radio_lite_secure_fs.test.node" \
  RADIO_LITE_TEST_SERVICE_UID="$test_uid" \
  RADIO_LITE_TEST_SERVICE_GID="$test_gid" \
  RADIO_LITE_TEST_DEPLOY_GID="$((test_gid + 1))" \
  RADIO_LITE_TEST_DEVICE_GIDS="$((test_gid + 2)),$((test_gid + 3))" \
  "$node_bin" --test deploy/test-secure-fs-linux.mjs deploy/test-radio-lite-release.mjs
```

On macOS/CI also run the simulator suite and both unsigned IPA builds, then run:

```bash
shasum -a 256 -c Radio-Lite-Debug-unsigned.ipa.sha256
shasum -a 256 -c Radio-Lite-Release-unsigned.ipa.sha256
```

Expected: every required job/test passes, the Linux suites run with real root euid plus preserved
positive nonroot service IDs, and both checksum commands report `OK` for their matching IPA.

- [ ] **Step 5: Commit documentation**

```powershell
git add docs/DEPLOYMENT.md README.md ios/README.md docs/SAFETY.md docs/HAMLIB.md radio-lite-server/PROTOCOL.md
git commit -m "docs: define safe Radio Lite release operations"
```

- [ ] **Step 6: Publish once through the repository deploy key**

```powershell
$commonGitDir = (git rev-parse --path-format=absolute --git-common-dir).Trim()
$deployKey = (Resolve-Path -LiteralPath (Join-Path $commonGitDir '..\..\.codex-ssh\github_radio_deploy_ed25519')).Path
$knownHosts = (Resolve-Path -LiteralPath (Join-Path $commonGitDir '..\..\.codex-ssh\github_known_hosts')).Path
$env:GIT_SSH_COMMAND = "ssh -i `"$deployKey`" -o UserKnownHostsFile=`"$knownHosts`" -o StrictHostKeyChecking=yes -p 443"
git push ssh://git@ssh.github.com:443/XINZHOUZHANG/radio.git HEAD
```

If this fails, stop remote publication, retain every local commit, and refresh the repository Git bundle. Do not run `gh auth login`, generate a device code, or retry OAuth.

- [ ] **Step 7: Perform Debian acceptance only after CI artifacts are green**

First run read-only checks for exact path, current SHA, worktree changes, process ownership, and ports. If the checkout is dirty, a required port belongs to an unrelated process, drain does not return 0, or any resolved target leaves `/opt/testradio`, stop without deploying. Begin with Dummy and synthetic audio; real radio testing requires the user's separate confirmation and operator supervision.
