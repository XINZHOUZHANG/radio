# Universal Radio Release and Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify the complete universal-radio delivery, publish and download a checksum-verified unsigned IPA, then deploy the exact reviewed server commit and restart Radio Lite under `/opt/testradio` with fail-closed transmit safety.

**Architecture:** GitHub Actions gates every artifact on server, codec, web, protocol, and Xcode tests and stamps build metadata. The release head is pushed with `[upload-ipa]`, and the exact SHA-named artifact is downloaded and hash-verified locally. Debian deployment stages an immutable release beneath `/opt/testradio`, preserves runtime/data/configuration, refuses legacy restart when any TX-enabled profile lacks drain proof, starts the exact staged commit, and verifies build-aware health.

**Tech Stack:** Git, GitHub Actions, Node.js 24.7.0, Rust 1.85+, Xcode 16/macOS 15, PowerShell, OpenSSH, Debian 13 bash/curl

**Spec:** `docs/superpowers/specs/2026-08-29-universal-radio-platform-design.md`

## Global Constraints

- Final iOS version is `0.3.0` build `15`; the IPA is unsigned and built for a generic iPhone device.
- Node is exactly 24.7.0 on CI and Debian.
- Artifact publication requires successful server, codec, web, protocol, and Xcode test jobs.
- GitHub uses `.codex-ssh/github_radio_deploy_ed25519` over SSH port 443 with strict host-key checking; never run `gh auth login` or a device flow.
- Never force-push.
- Debian changes are confined to `/opt/testradio`; never overwrite `/opt/testradio/data/radios.json`.
- A TX-enabled old service without confirmed drain/PTT-OFF evidence blocks deployment; PID disappearance alone is not proof.
- Deployment health must identify the exact Git commit before success is reported.

---

### Task 1: Artifact gating, build metadata, and version update

**Files:**
- Modify: `.github/workflows/ios.yml`
- Modify: `ios/RadioLite/project.yml`
- Modify: `radio-lite-server/package.json`
- Modify: `radio-lite-server/package-lock.json`
- Modify: `radio-lite-server/src/index.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/test/http-service.test.ts`
- Create: `scripts/check-radio-lite-release-contract.mjs`

**Interfaces:**
- `/healthz` additionally returns `version` and `buildCommit`, without removing `status`, `service`, or `protocolVersion`.
- `RADIO_LITE_BUILD_COMMIT` supplies the 40-hex commit at process start.
- `unsigned-device-ipa` depends on `server-check`, `codec-check`, `web-check`, `protocol-contract`, and `xcode-build-and-test`.

- [ ] **Step 1: Write failing health and executable workflow-contract tests**

```ts
test("health identifies the deployed version and commit", async () => {
  const service = fixture.service({ buildCommit: "a".repeat(40) });
  const health = await fixture.getHealth(service);
  assert.equal(health.version, "0.3.0");
  assert.equal(health.buildCommit, "a".repeat(40));
});
```

`check-radio-lite-release-contract.mjs` parses the workflow YAML blocks and project YAML, asserts version `0.3.0`/build `15`, verifies the IPA job `needs` every gate, and rejects upload logic that can run after a failed dependency.

- [ ] **Step 2: Run and confirm version/gating failures**

Run: `node --experimental-strip-types --test test/http-service.test.ts` from `radio-lite-server`

Run: `node scripts/check-radio-lite-release-contract.mjs`

Expected: FAIL because health metadata, version 0.3.0 (15), codec gate, and artifact `needs` are absent.

- [ ] **Step 3: Implement exact metadata and workflow gating**

Set iOS `MARKETING_VERSION: 0.3.0`, `CURRENT_PROJECT_VERSION: 15`, and server version `0.3.0`. Add `codec-check` on Ubuntu that runs `cargo test --locked --manifest-path radio-codec-helper/Cargo.toml` with Rust 1.85.0. Give `unsigned-device-ipa` the five-job `needs` list. Preserve the existing manual/push upload condition and SHA-named artifact.

- [ ] **Step 4: Run checks**

Run: `node --experimental-strip-types --test test/http-service.test.ts` from `radio-lite-server`

Run: `node scripts/check-radio-lite-release-contract.mjs`

Run: `npm run check` from `radio-lite-server`

Expected: all exit 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ios.yml ios/RadioLite/project.yml radio-lite-server/package.json radio-lite-server/package-lock.json radio-lite-server/src/index.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/test/http-service.test.ts scripts/check-radio-lite-release-contract.mjs
git commit -m "release: gate Radio Lite 0.3.0 artifacts"
```

### Task 2: Versioned Debian staging and fail-closed restart scripts

**Files:**
- Modify: `.github/workflows/ios.yml`
- Create: `deploy/package-radio-lite-server.mjs`
- Create: `deploy/deploy-radio-lite.sh`
- Create: `deploy/start-radio-lite.sh`
- Create: `deploy/stop-radio-lite.sh`
- Create: `deploy/status-radio-lite.sh`
- Create: `deploy/test/deployment-smoke.sh`
- Test: `radio-lite-server/test/index-shutdown.test.ts`

**Interfaces:**
- Packager produces `Radio-Lite-Server-<sha>.tar.gz` and `.sha256`, containing the server, locked dependencies, web assets if required, Rust helper binary/source contract, deploy scripts, and a manifest with exact commit/version/Node requirements.
- `server-release`, gated by the same five successful jobs as the IPA, builds the locked Rust helper on Ubuntu, runs the packager, and uploads the SHA-named server archive plus checksum.
- Deployment stores releases under `/opt/testradio/releases/<sha>`, candidate under `/opt/testradio/staging/<sha>`, and rollback backup under `/opt/testradio/releases/previous-*`.
- Stop returns success only after the process exits and the new service-created shutdown proof says cleanup/PTT OFF was confirmed; the one-time legacy path is allowed only when every stored profile has `hardwareTxEnabled !== true`.

- [ ] **Step 1: Write failing shutdown-proof and sandboxed deployment smoke tests**

```ts
test("SIGTERM writes safe shutdown proof only after service close resolves", async () => {
  const fixture = await spawnIndexFixture({ closeOutcome: "confirmed" });
  fixture.kill("SIGTERM");
  assert.deepEqual(await fixture.readProof(), { status: "safe", buildCommit: fixture.commit });
});

test("failed cleanup writes uncertain proof and exits nonzero", async () => {
  const fixture = await spawnIndexFixture({ closeOutcome: "rejected" });
  fixture.kill("SIGTERM");
  assert.equal((await fixture.readProof()).status, "uncertain");
  assert.notEqual(await fixture.exitCode(), 0);
});
```

The shell smoke test creates a temporary fake root, fake Node/service/curl processes, then exercises candidate validation, successful switch, health failure rollback, preservation of `data/radios.json`, and refusal of TX-enabled legacy stop.

- [ ] **Step 2: Run and confirm missing release scripts/proof**

Run: `node --experimental-strip-types --test test/index-shutdown.test.ts` from `radio-lite-server`

Run: `bash deploy/test/deployment-smoke.sh`

Expected: FAIL because proof and deployment scripts are absent.

- [ ] **Step 3: Implement staging, proof, rollback, and confinement**

Validate `ROOT` resolves exactly to `/opt/testradio` in production and is not a symlink. Use explicit paths, `set -Eeuo pipefail`, a deployment lock, checksum/manifest/commit checks, `npm ci` in the candidate, and candidate checks before touching the live service. Never copy a sample `radios.json`. Write shutdown proof through temp plus rename under `/opt/testradio/run`. After a safe stop, atomically replace `/opt/testradio/repo`; on failed exact-commit health, stop the candidate and restore the previous release.

- [ ] **Step 4: Run tests and package a local fixture**

Run: `node --experimental-strip-types --test test/index-shutdown.test.ts` from `radio-lite-server`

Run: `bash deploy/test/deployment-smoke.sh`

Run: `node deploy/package-radio-lite-server.mjs --commit 0000000000000000000000000000000000000000 --helper radio-codec-helper/target/release/radio-codec-helper --output artifacts/test-release`

Expected: all exit 0; the fixture archive checksum verifies.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ios.yml deploy radio-lite-server/test/index-shutdown.test.ts
git commit -m "feat: deploy Radio Lite with safe restart proof"
```

### Task 3: Whole-branch verification and release head

**Files:**
- Modify: `docs/DEPLOYMENT.md`
- Create: `scripts/radio-lite-release.json`

- [ ] **Step 1: Run fresh complete verification**

Run: `cargo test --locked --manifest-path radio-codec-helper/Cargo.toml`

Run: `npm ci && npm run check` from `radio-lite-server`

Run: `npm test` from `web`

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Run: `node scripts/check-radio-lite-release-contract.mjs`

Run: `bash deploy/test/deployment-smoke.sh`

Expected: every command exits 0 with no failed tests.

- [ ] **Step 2: Verify worktree and release diff**

Run: `git status --short --branch`

Run: `git diff --check $(git merge-base origin/main HEAD)..HEAD`

Expected: only the ignored `.superpowers/` workspace is untracked; diff check is empty.

- [ ] **Step 3: Create the artifact-triggering head commit**

Update `docs/DEPLOYMENT.md` with exact artifact/restart instructions. Create the watched release marker with exactly `{ "version": "0.3.0", "build": 15 }`, then:

```bash
git add docs/DEPLOYMENT.md scripts/radio-lite-release.json
git commit -m "release: Radio Lite 0.3.0 [upload-ipa]"
```

- [ ] **Step 4: Confirm the head triggers artifact upload**

Run: `git log -1 --format=%s`

Run: `git diff-tree --no-commit-id --name-only -r HEAD`

Expected: subject contains `[upload-ipa]` and the head includes a path watched by `.github/workflows/ios.yml`.

### Task 4: Push, wait for GitHub Actions, and download IPA

**Files:**
- Output: `D:/CodeX/remote radio/artifacts/<sha>/Radio-Lite-Debug-unsigned.ipa`
- Output: `D:/CodeX/remote radio/artifacts/<sha>/Radio-Lite-Debug-unsigned.ipa.sha256`

- [ ] **Step 1: Verify GitHub without starting authentication**

Run: `gh auth status --hostname github.com`

Expected: exit 0 using an existing credential. If unavailable, stop without running `gh auth login`; retain local commits and refresh the Git bundle required by workspace policy.

- [ ] **Step 2: Push the exact release head over the repository SSH configuration**

```powershell
$env:GIT_SSH_COMMAND = 'ssh.exe -F "D:/CodeX/remote radio/.codex-ssh/github_config"'
git push --porcelain origin HEAD:refs/heads/codex/public-dummy-web-integration
Remove-Item Env:GIT_SSH_COMMAND
```

Verify `git ls-remote` returns the exact local SHA. Never force-push.

- [ ] **Step 3: Wait for the SHA-matching workflow**

Use `gh run list --repo XINZHOUZHANG/radio --workflow ios.yml --branch codex/public-dummy-web-integration --event push --json databaseId,headSha,status,conclusion,url`, select exact `headSha`, then `gh run watch <run-id> --repo XINZHOUZHANG/radio --exit-status`.

Expected: all required jobs and unsigned-device-ipa succeed.

- [ ] **Step 4: Download without overwriting and verify SHA-256**

```powershell
gh run download <run-id> --repo XINZHOUZHANG/radio --name "Radio-Lite-Debug-unsigned-<sha>" --dir "D:/CodeX/remote radio/artifacts/<sha>"
```

Compare `Get-FileHash -Algorithm SHA256` against the companion file and require equality.

Download `Radio-Lite-Server-<sha>` from the same run into the same SHA directory and independently verify `Radio-Lite-Server-<sha>.tar.gz.sha256`. Do not deploy either artifact if one checksum or job is missing.

### Task 5: Deploy exact server commit and restart Debian Radio Lite

**Files:**
- Input: `D:/CodeX/remote radio/artifacts/<sha>/Radio-Lite-Server-<sha>.tar.gz`
- Remote: `/opt/testradio/staging/<sha>` and `/opt/testradio/releases/<sha>` only

- [ ] **Step 1: Perform read-only remote preflight**

Connect with `ssh.exe`, key `D:/CodeX/remote radio/.codex-ssh/testradio_ed25519`, port 3022, `IdentitiesOnly=yes`, strict host checking, and `D:/CodeX/remote radio/.codex-ssh/known_hosts`. Verify `/opt/testradio` resolves to itself, Node reports exactly `v24.7.0`, inspect the current health/build commit, and parse `/opt/testradio/data/radios.json` only for whether any `hardwareTxEnabled === true`.

- [ ] **Step 2: Enforce the first-restart safety boundary**

If the running old service cannot emit a shutdown proof and any profile is TX-enabled, stop the deployment without sending TERM. If all profiles are TX-disabled, the one-time legacy stop may proceed; every subsequent restart requires the proof-aware scripts.

- [ ] **Step 3: Upload the checksum-verified candidate beneath `/opt/testradio`**

Create the exact staging directory, copy only the release archive and checksum, and run the committed `deploy-radio-lite.sh`. Never copy local `data/`, sample configuration, or anything outside the release archive.

- [ ] **Step 4: Verify exact-commit health after restart**

Require `status-radio-lite.sh` success and parse `/healthz` for `status == "ok"`, `service == "radio-lite"`, `protocolVersion == 1`, `version == "0.3.0"`, and `buildCommit == <sha>`.

- [ ] **Step 5: Record deployment evidence**

Record old SHA/version, new SHA/version, restart script exit, health JSON, PID/cmdline, and IPA SHA-256. If candidate health fails, confirm rollback health and report deployment failure rather than claiming completion.
