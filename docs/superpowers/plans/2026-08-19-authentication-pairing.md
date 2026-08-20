# Remote Radio Authentication and Pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the temporary device-token login with persistent administrator/operator accounts, secure browser sessions, six-digit iOS pairing, revocable device credentials, and server-enforced transmit authorization.

**Architecture:** A focused `remote_radio_server.auth` package owns SQLite persistence, password verification, browser/device sessions, pairing, authorization, revocation, and audit. A strict HTTP API and the existing WebSocket control plane consume that package; the web dashboard and native SwiftUI client share `remote-radio.v1` JSON fixtures. The legacy plaintext public-Dummy token path stays isolated as a labeled acceptance mode, while account mode requires TLS on every non-loopback listener.

**Tech Stack:** Python 3.11 `asyncio`, SQLite, `argon2-cffi`, strict HTTP/WebSocket adapters, dependency-free browser JavaScript with Node's built-in test runner, Swift 5.9+, SwiftUI, URLSession, Security/Keychain, iOS 17+

**Spec:** `docs/superpowers/specs/2026-08-19-authentication-pairing-design.md`

## Global Constraints

- Account roles are exactly `admin` and `operator`; no observer role or observer UI option exists.
- Operators require `can_transmit=true` for PTT, microphone uplink, FT8 transmit, and tuner-carrier actions; administrators have effective transmit permission.
- Authorization never bypasses the two-second PTT heartbeat, ten-second timeout, 180-second hard limit, SWR protection, capability checks, or hardware-TX policy.
- Simulated PTT is allowed only for the in-process mock or an identity-verified official Hamlib Dummy model `1`; real/ambiguous rigs stay transmit-locked.
- Passwords use Argon2id with at least `m=19456 KiB`, `t=2`, `p=1`, a 16-byte salt, and a 32-byte output.
- User passwords are NFC-normalized, 15-128 Unicode code points, at most 1,024 UTF-8 bytes, with no composition or periodic-rotation rule.
- Browser sessions use a `Secure`, `HttpOnly`, `SameSite=Strict`, `Path=/`, `__Host-rr_session` cookie; secrets never enter browser storage or URLs.
- Pairing codes are uniformly generated six-digit strings, expire after five minutes, and can be consumed once.
- Access credentials last 15 minutes; rotating refresh credentials last 30 days; only SHA-256 digests of high-entropy credentials are stored.
- Non-loopback account mode requires direct HTTPS/WSS certificate and key configuration; reverse-proxy trust is outside this slice.
- Protocol negotiation uses `remote-radio.v1`; browser and SwiftUI consume the same canonical JSON fixtures.
- Debian production data defaults to `/opt/testradio/data`; tests use owned temporary directories.
- Remote acceptance may create or modify files only under `/opt/testradio`; it must not touch real radio hardware or merge `main`.
- Follow red-green-refactor: every behavior starts with a failing focused test, then minimal implementation, then the focused and full relevant suites.

## Planned File Structure

| Path | Responsibility |
|---|---|
| `server/remote_radio_server/auth/models.py` | Immutable users, sessions, devices, principals, grants, and role types |
| `server/remote_radio_server/auth/errors.py` | Stable authentication error codes, safe messages, HTTP status, and retry metadata |
| `server/remote_radio_server/auth/audit.py` | Typed, secret-free audit events and metadata validation |
| `server/remote_radio_server/auth/repository.py` | SQLite schema, migrations, atomic persistence, and POSIX permissions |
| `server/remote_radio_server/auth/passwords.py` | Username/password normalization, blocklist, Argon2id hash/verify/rehash |
| `server/remote_radio_server/auth/throttle.py` | Persistent account/source login throttles |
| `server/remote_radio_server/auth/setup.py` | Memory-only first-administrator setup code and serialized consumption |
| `server/remote_radio_server/auth/service.py` | Account lifecycle, login, password reset/change, and audit policy |
| `server/remote_radio_server/auth/sessions.py` | Browser sessions, HMAC-CSRF tokens, and access/rotating-refresh device credentials |
| `server/remote_radio_server/auth/pairing.py` | Memory-only device-code state machine and polling limits |
| `server/remote_radio_server/auth/authorization.py` | Action matrix, authorization revisions, and live revocation ordering |
| `server/remote_radio_server/auth/http_api.py` | Strict versioned setup/session/user/device/pairing/audit routes |
| `server/remote_radio_server/http.py` | Bounded HTTP request parser, response writer, listener, and TLS policy |
| `server/remote_radio_server/web_app.py` | Static-asset/API composition and account application lifecycle |
| `server/remote_radio_server/tls.py` | Direct server TLS context creation and certificate/key validation |
| `protocol/v1/*.json` | Canonical browser/Python/Swift authentication and error fixtures |
| `web/auth-client.js` | Cookie/CSRF account API client |
| `web/settings.js` | Setup, login, users, devices, pairing approval, sessions, and audit UI |
| `ios/Package.swift` | Testable Swift package for protocol/authentication code |
| `ios/Sources/RemoteRadioCore/*` | API DTOs, URLSession client, WebSocket client, and credential-store protocol |
| `ios/RemoteRadio/*` | Native SwiftUI app entry point, app model, pairing, and radio shell |

---

### Task 1: SQLite and Audit Foundation

**Files:**

- Create: `server/remote_radio_server/auth/__init__.py`
- Create: `server/remote_radio_server/auth/models.py`
- Create: `server/remote_radio_server/auth/errors.py`
- Create: `server/remote_radio_server/auth/audit.py`
- Create: `server/remote_radio_server/auth/repository.py`
- Create: `server/remote_radio_server/auth/migrations/001_initial.sql`
- Create: `server/tests/auth/__init__.py`
- Create: `server/tests/auth/test_repository.py`
- Create: `server/tests/auth/test_audit.py`

**Interfaces:**

- Produces `Role`, `UserRecord`, `BrowserSessionRecord`, `DeviceRecord`, `DeviceGrant`, `AuthenticatedIdentity`, `Principal`, `AuditEvent`, `StoredAuditEvent`, and `AuditPage` immutable dataclasses. `AuthenticatedIdentity` has no connection ID; `Principal` adds the server-generated connection-scoped `client_id`.
- Produces `AuthError(code, http_status, safe_message, retry_after_s)` plus `AuthFailure`, `AuthForbidden`, `AuthConflict`, `AuthGone`, and `AuthRateLimited`; no error accepts arbitrary exception text as its client message.
- Produces `AuthRepository.open(data_dir: Path, *, clock: Callable[[], int]) -> AuthRepository` plus repository methods named `close`, `create_user`, `find_user_by_username`, `get_user`, `list_users`, `append_audit`, and `list_audit`.
- Exposes the loaded 32-byte CSRF key through read-only `repository.csrf_key`; no API serializes this property.
- All later services receive an already-open `AuthRepository`; they never open SQLite themselves.

- [ ] **Step 1: Write failing model and schema tests**

```python
class RepositoryTests(unittest.IsolatedAsyncioTestCase):
    async def test_open_migrates_private_database_and_round_trips_user(self):
        repository = await AuthRepository.open(Path(self.temp.name), clock=lambda: 100)
        user = await repository.create_user(
            user_id="user-1",
            username="operator.one",
            password_phc="$argon2id$test",
            role=Role.OPERATOR,
            can_transmit=False,
            must_change_password=False,
            audit=AuditEvent("user.create", "success", actor_user_id="admin-1"),
        )
        self.assertEqual("operator.one", user.username)
        self.assertEqual(user, await repository.find_user_by_username("operator.one"))
        self.assertEqual(1, (await repository.list_audit(None, 20)).events[0].event_id)
```

On POSIX, also assert the data directory mode is `0o700` and the database,
`-wal`, `-shm`, and `csrf.key` files are never broader than `0o600`. On
Windows, skip only the mode assertions, not schema or persistence assertions.

- [ ] **Step 2: Run the focused test and confirm the missing package failure**

Run from `server/`:

```bash
python -m unittest tests.auth.test_repository -v
```

Expected: import failure for `remote_radio_server.auth.repository`.

- [ ] **Step 3: Add immutable records and the complete version-1 migration**

Use `enum.StrEnum` for `Role` and frozen, slotted dataclasses. The migration
must create these tables and constraints in one `BEGIN IMMEDIATE` transaction:

```sql
CREATE TABLE schema_meta(version INTEGER NOT NULL);
INSERT INTO schema_meta(version) VALUES (1);
CREATE TABLE users(
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  password_phc TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('admin','operator')),
  can_transmit INTEGER NOT NULL CHECK(can_transmit IN (0,1)),
  enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
  must_change_password INTEGER NOT NULL CHECK(must_change_password IN (0,1)),
  auth_revision INTEGER NOT NULL DEFAULT 1 CHECK(auth_revision >= 1),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_login_at INTEGER,
  deleted_at INTEGER
);
CREATE TABLE browser_sessions(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
  secret_digest BLOB NOT NULL UNIQUE,
  created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
  idle_expires_at INTEGER NOT NULL, absolute_expires_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE TABLE devices(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL, platform TEXT NOT NULL CHECK(platform = 'ios'),
  created_at INTEGER NOT NULL, last_seen_at INTEGER, revoked_at INTEGER
);
CREATE TABLE access_credentials(
  id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id),
  secret_digest BLOB NOT NULL UNIQUE, created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL, revoked_at INTEGER
);
CREATE TABLE refresh_credentials(
  id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id),
  family_id TEXT NOT NULL, secret_digest BLOB NOT NULL UNIQUE,
  previous_id TEXT, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  used_at INTEGER, revoked_at INTEGER
);
CREATE TABLE login_throttles(
  scope_key TEXT PRIMARY KEY, failure_count INTEGER NOT NULL,
  window_started_at INTEGER NOT NULL, blocked_until INTEGER NOT NULL
);
CREATE TABLE audit_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at INTEGER NOT NULL,
  action TEXT NOT NULL, result TEXT NOT NULL,
  actor_user_id TEXT, actor_device_id TEXT, actor_session_id TEXT,
  target_id TEXT, source_address TEXT, metadata_json TEXT NOT NULL
);
```

`AuthRepository.open` must resolve/create only the supplied directory, create
a 256-bit `csrf.key` with mode `0600` when absent, apply
`PRAGMA foreign_keys=ON`, `journal_mode=WAL`, and `busy_timeout=5000`, reject an
unknown newer schema, and serialize `sqlite3` work behind one `asyncio.Lock`
plus `asyncio.to_thread`. User, session, device, credential, and family IDs use
lowercase `str(uuid.uuid4())` values from injected factories; IDs are opaque but
are never treated as authentication secrets.

- [ ] **Step 4: Run the repository tests to green**

```bash
python -m unittest tests.auth.test_repository -v
```

Expected: all repository/schema tests pass.

- [ ] **Step 5: Write the failing audit secret-redaction test**

```python
def test_audit_event_rejects_secret_shaped_metadata(self):
    for key in ("password", "token", "cookie", "csrf", "setup_code", "pairing_code"):
        with self.subTest(key=key), self.assertRaises(ValueError):
            AuditEvent("login", "failure", metadata={key: "must-not-log"})
```

- [ ] **Step 6: Implement strict audit metadata and cursor pagination**

`AuditEvent` accepts only JSON scalar values, lists of scalars, and mappings.
Reject exact keys `password`, `setup_code`, `pairing_code`, `user_code`,
`cookie`, and `csrf`, plus any normalized key ending in `_password`, `_secret`,
`_token`, or `_cookie`; allow safe keys such as `error_code` and `reason`.
Serialize with sorted keys, compact separators, and `allow_nan=False`; cap
serialized metadata at 4 KiB. `list_audit` accepts limits `1..100`, orders
newest first, and returns `next_after_id` from the final row.

- [ ] **Step 7: Run both focused suites and commit**

```bash
python -m unittest tests.auth.test_repository tests.auth.test_audit -v
git add server/remote_radio_server/auth server/tests/auth
git commit -m "feat: add authentication persistence foundation"
```

### Task 2: Password Policy, Argon2id, and Login Throttling

**Files:**

- Create: `server/remote_radio_server/auth/passwords.py`
- Create: `server/remote_radio_server/auth/throttle.py`
- Create: `server/tests/auth/test_passwords.py`
- Create: `server/tests/auth/test_throttle.py`
- Modify: `server/pyproject.toml`
- Modify: `server/remote_radio_server/auth/repository.py`

**Interfaces:**

- Produces `normalize_username(value: str) -> str`.
- Produces `PasswordService.validate(username: str, password: str) -> str`, `hash(password: str) -> str`, and `verify(password: str, phc: str) -> PasswordCheck(valid: bool, needs_rehash: bool)`.
- Produces `LoginThrottle.check(username: str, source: str) -> ThrottleDecision`, `failure(username: str, source: str) -> ThrottleDecision`, and `success(username: str, source: str) -> None` backed by `login_throttles`.

- [ ] **Step 1: Add the dependency and failing password-policy tests**

Add `argon2-cffi>=23.1,<26` to project dependencies. Test exact username
normalization, NFC normalization, 15/128-code-point bounds, 1,024-byte bound,
spaces, and context/common-password rejection:

```python
def test_password_hash_uses_approved_argon2id_floor(self):
    encoded = service.hash("correct horse battery staple")
    parameters = extract_parameters(encoded)
    self.assertEqual("argon2id", parameters.type.name.lower())
    self.assertGreaterEqual(parameters.memory_cost, 19_456)
    self.assertGreaterEqual(parameters.time_cost, 2)
    self.assertGreaterEqual(parameters.parallelism, 1)
    self.assertTrue(service.verify("correct horse battery staple", encoded).valid)
```

The bundled initial blocklist is the normalized set `passwordpassword`,
`qwertyqwertyqwerty`, `letmeinletmein`, `administratoradmin`,
`remoteradioremote`, `remote-radio-admin`, `123456789012345`, and
`000000000000000`; also reject a password equal to or containing two repeated
copies of the normalized username or product name.

- [ ] **Step 2: Run and observe the missing password service**

```bash
python -m unittest tests.auth.test_passwords -v
```

Expected: import failure or missing `PasswordService`.

- [ ] **Step 3: Implement password validation and dummy-hash verification**

Configure `argon2.PasswordHasher(time_cost=2, memory_cost=19456,
parallelism=1, hash_len=32, salt_len=16, type=Type.ID)`. Convert all
`VerifyMismatchError`, malformed-hash errors, and disabled/deleted lookups into
the same `PasswordCheck(False, False)` result. Precompute one valid dummy PHC at
service construction and verify against it when an account cannot authenticate.
Keep this service synchronous and CPU-bound; Tasks 3 and 4 must call every
hash/verify/rehash operation through `asyncio.to_thread` so the PTT watchdog
event loop cannot be monopolized.

- [ ] **Step 4: Run password tests to green**

```bash
python -m unittest tests.auth.test_passwords -v
```

- [ ] **Step 5: Write failing fake-clock throttle tests**

```python
async def test_fifth_failure_blocks_for_30_seconds_and_backoff_caps_at_15_minutes(self):
    for _ in range(5):
        await throttle.failure("operator.one", "203.0.113.9")
    self.assertEqual(30, (await throttle.check("operator.one", "203.0.113.9")).retry_after_s)
    clock.advance(30)
    await throttle.failure("operator.one", "203.0.113.9")
    self.assertEqual(60, (await throttle.check("operator.one", "203.0.113.9")).retry_after_s)
```

Also cover the source-wide 30 failures/ten minutes rule, 15-minute cap,
successful account-scope reset, and identical keys for unknown/known accounts.

- [ ] **Step 6: Implement persistent account and source scopes**

Use SHA-256 scope names `account:<normalized-username>:<source>` and
`source:<source>` so raw passwords never enter throttle storage. Compute delays
as `min(30 * 2 ** (failure_count - 5), 900)` for account failures at or above
five. Source-wide block begins at 30 failures inside 600 seconds and lasts 900
seconds. `success` clears only the account scope.

- [ ] **Step 7: Run focused tests and commit**

```bash
python -m unittest tests.auth.test_passwords tests.auth.test_throttle -v
git add server/pyproject.toml server/remote_radio_server/auth server/tests/auth
git commit -m "feat: secure passwords and throttle login attempts"
```

### Task 3: First Administrator and Account Lifecycle

**Files:**

- Create: `server/remote_radio_server/auth/setup.py`
- Create: `server/remote_radio_server/auth/service.py`
- Create: `server/tests/auth/test_setup.py`
- Create: `server/tests/auth/test_accounts.py`
- Modify: `server/remote_radio_server/auth/repository.py`
- Modify: `server/remote_radio_server/auth/models.py`

**Interfaces:**

- Produces `SetupCodeManager.issue_if_needed(has_users: bool) -> SetupCodeGrant | None` and serialized `consume(code, operation)` behavior.
- Produces account-service methods named `initialize_admin`, `create_user`, `update_user`, `delete_user`, `reset_password`, and `change_password` with the signatures listed in Step 5.
- Consumes a `RevocationSink` protocol with `revoke_user(user_id, reason)` and `remove_transmit(user_id, reason)`; use `NullRevocationSink` until Task 9.

- [ ] **Step 1: Write failing setup-code tests**

```python
async def test_setup_code_is_six_digits_memory_only_and_creates_one_admin(self):
    grant = setup.issue_if_needed(has_users=False)
    self.assertRegex(grant.code, r"^\d{6}$")
    first = await accounts.initialize_admin(grant.code, "Connor", PASSPHRASE, "127.0.0.1")
    self.assertEqual((Role.ADMIN, True), (first.role, first.enabled))
    with self.assertRaises(AuthConflict) as caught:
        await accounts.initialize_admin(grant.code, "second", PASSPHRASE, "127.0.0.1")
    self.assertEqual("already_initialized", caught.exception.code)
```

Cover ten-minute expiry, five failed submissions per source, restart
invalidation, leading zeroes, and two concurrent correct submissions producing
one administrator.

- [ ] **Step 2: Run setup tests and verify failure**

```bash
python -m unittest tests.auth.test_setup -v
```

- [ ] **Step 3: Implement serialized setup and transactional first-user creation**

Use `secrets.randbelow(1_000_000)` formatted as `f"{value:06d}"`, one
`asyncio.Lock`, monotonic expiry, and per-source attempt counters. Inside the
lock, re-check `repository.has_users()`, validate the code, commit the first
administrator plus `setup.initialize` audit event, then mark the in-memory code
consumed before releasing the lock.

- [ ] **Step 4: Write failing account invariant and revocation tests**

Test administrator-only CRUD, normalized duplicate usernames, operator
`can_transmit`, final-enabled-administrator protection, tombstone username
reservation, temporary-password `must_change_password`, audit events, and the
fact that disable/delete/password reset calls the revocation sink after commit.

- [ ] **Step 5: Implement account mutations as repository transactions**

Use these service signatures exactly:

- `create_user(actor: Principal, username: str, password: str, role: Role, can_transmit: bool, source: str) -> UserRecord`
- `update_user(actor: Principal, user_id: str, *, enabled: bool | None, role: Role | None, can_transmit: bool | None, source: str) -> UserRecord`
- `reset_password(actor: Principal, user_id: str, temporary_password: str, source: str) -> None`
- `change_password(actor: Principal, old_password: str, new_password: str, source: str) -> None`
- `delete_user(actor: Principal, user_id: str, source: str) -> None`

Every mutation increments `auth_revision`. For admins, persist
`can_transmit=1`; reject attempts to make an admin receive-only. Soft deletion
sets `enabled=0` and `deleted_at`, leaving username/audit identity reserved.

- [ ] **Step 6: Run account suites and commit**

```bash
python -m unittest tests.auth.test_setup tests.auth.test_accounts -v
git add server/remote_radio_server/auth server/tests/auth
git commit -m "feat: manage administrator and operator accounts"
```

### Task 4: Browser Login and Revocable Sessions

**Files:**

- Create: `server/remote_radio_server/auth/sessions.py`
- Create: `server/tests/auth/test_browser_sessions.py`
- Create: `server/tests/auth/test_login.py`
- Modify: `server/remote_radio_server/auth/service.py`
- Modify: `server/remote_radio_server/auth/repository.py`
- Modify: `server/remote_radio_server/auth/models.py`

**Interfaces:**

- Produces `BrowserSessionGrant(session_id, session_token, csrf_token, user, absolute_expires_at)` and `CsrfTokenService.issue(session_token) -> str`/`verify(session_token, presented_token) -> bool`.
- Produces `BrowserSessionService.login(username: str, password: str, source: str) -> BrowserSessionGrant`, `authenticate(session_token: str) -> AuthenticatedIdentity`, `touch(session_id: str)`, `logout(session_id: str)`, `list_sessions(actor: Principal)`, and `revoke_session(actor: Principal, session_id: str)`.
- Reuses `AuthenticatedIdentity(user_id, device_id, browser_session_id, role, can_transmit, auth_kind, auth_revision, expires_at)` and `Principal(identity fields plus client_id)` from Task 1. The legacy gateway principal remains untouched until Task 9 replaces it and re-exports the auth principal for import compatibility.

- [ ] **Step 1: Write failing login equivalence and session-digest tests**

```python
async def test_login_stores_only_digests_and_returns_one_plaintext_grant(self):
    grant = await sessions.login("operator.one", PASSPHRASE, "203.0.113.9")
    row = await repository.get_browser_session(grant.session_id)
    self.assertNotEqual(grant.session_token.encode(), row.secret_digest)
    self.assertEqual(hashlib.sha256(grant.session_token.encode()).digest(), row.secret_digest)
    self.assertNotIn(grant.session_token, database_bytes())
```

Use a recording password service to assert unknown, disabled, and deleted users
perform one dummy Argon2 verification and return the same
`AuthFailure("authentication_failed")` as a wrong password. A gated fake hash
worker must also prove the asyncio event loop remains responsive while login is
waiting for password verification.

- [ ] **Step 2: Run focused tests and confirm missing service behavior**

```bash
python -m unittest tests.auth.test_login tests.auth.test_browser_sessions -v
```

- [ ] **Step 3: Implement session issuance, lookup, and expiry**

Generate one `secrets.token_urlsafe(32)` session secret and store only its
SHA-256 digest. Derive the browser-visible CSRF token as base64url
`HMAC-SHA-256(csrf_key, b"remote-radio-csrf\0" + session_token)`; never persist
that derived value. Set idle expiry to `now+1800`, absolute expiry to
`now+43200`, and authenticate/verify with `hmac.compare_digest`. Active HTTP/WS
activity extends idle expiry to at most `min(now+1800, absolute)` only when the
last persisted touch is at least 60 seconds old. Expiry/revocation returns no
principal and never deletes audit history.

- [ ] **Step 4: Add failing temporary-password and session-revocation tests**

Verify a `must_change_password` principal can perform only password change and
logout; password change/reset revokes every browser/device credential; admin
session listing is cursor-bounded; logout revokes only the current session; and
unrelated users stay connected.

- [ ] **Step 5: Implement login audit/throttle ordering and revocation hooks**

Order login as throttle check, lookup, real/dummy Argon2 verify, failure audit
and throttle update, or success transaction that updates `last_login_at`,
creates the session, and appends audit. If the success audit transaction fails,
return no grant. Return an `AuthenticatedIdentity` whose
`browser_session_id` is the session ID and whose `device_id` is `None`; HTTP
creates `client_id=http:<session_id>`, while Task 10 assigns a unique WebSocket
client ID.

- [ ] **Step 6: Run focused plus repository/password suites and commit**

```bash
python -m unittest tests.auth.test_login tests.auth.test_browser_sessions tests.auth.test_passwords tests.auth.test_repository -v
git add server/remote_radio_server/auth server/tests/auth
git commit -m "feat: add revocable browser login sessions"
```

### Task 5: Bounded HTTP Engine and Direct TLS Policy

**Files:**

- Create: `server/remote_radio_server/http.py`
- Create: `server/remote_radio_server/tls.py`
- Create: `server/tests/test_http.py`
- Create: `server/tests/test_tls.py`
- Modify: `server/remote_radio_server/static_http.py`
- Modify: `server/tests/test_static_http.py`

**Interfaces:**

- Produces `HttpRequest(method, target, path, query, headers, body, peer_address, secure)` and `HttpResponse(status, headers, body)`.
- Produces `HttpServer(handler, *, allow_non_loopback: bool, require_tls_on_non_loopback: bool)` with `serve(host, port, ssl_context=None)` and `close()`.
- Produces `build_server_ssl_context(cert_path: Path, key_path: Path) -> ssl.SSLContext`.
- Retains `StaticWebServer` as a compatibility wrapper over `HttpServer` and a fixed asset handler.

- [ ] **Step 1: Write failing bounded-request parser tests**

Cover lower-cased unique headers, duplicate `Content-Length` rejection,
`Transfer-Encoding` rejection, non-ASCII header rejection, exact body reads,
32 KiB API-body cap, two-second timeout, peer address, query splitting, and the
existing 8 KiB header cap:

```python
async def test_post_reads_exact_json_body_and_exposes_peer_context(self):
    request = await capture_request(
        b"POST /api/v1/session/login?x=1 HTTP/1.1\r\n"
        b"Host: radio.test\r\nContent-Type: application/json\r\n"
        b"Content-Length: 2\r\n\r\n{}"
    )
    self.assertEqual(("/api/v1/session/login", "x=1", b"{}"),
                     (request.path, request.query, request.body))
```

- [ ] **Step 2: Run HTTP tests and verify failure**

```bash
python -m unittest tests.test_http -v
```

- [ ] **Step 3: Extract the generic server without weakening static assets**

Move connection ownership, bounded parsing, response writing, and listener
lifecycle into `http.py`. Handlers implement
`async def handle(request: HttpRequest) -> HttpResponse`. Preserve static
allowlist, traversal rejection, CSP, `nosniff`, no directory listing, and
cleanup semantics in `StaticWebServer`.

- [ ] **Step 4: Run old and new HTTP suites**

```bash
python -m unittest tests.test_http tests.test_static_http -v
```

- [ ] **Step 5: Write failing TLS policy tests**

```python
async def test_public_account_listener_requires_ssl_context(self):
    server = HttpServer(handler, allow_non_loopback=True,
                        require_tls_on_non_loopback=True)
    with self.assertRaisesRegex(ValueError, "TLS"):
        await server.serve(host="0.0.0.0", port=0, ssl_context=None)
```

Also assert certificate/key arguments must be supplied together, resolve to
regular files, and load into `ssl.PROTOCOL_TLS_SERVER` with TLS 1.2 minimum.

- [ ] **Step 6: Implement TLS context and the `ssl` argument on the asyncio listener**

Set `context.minimum_version = ssl.TLSVersion.TLSv1_2`, disable compression,
and never catch/replace certificate parsing errors with a plaintext fallback.
`HttpRequest.secure` is true only when `writer.get_extra_info("ssl_object")` is
present.

- [ ] **Step 7: Run HTTP/TLS/static suites and commit**

```bash
python -m unittest tests.test_http tests.test_tls tests.test_static_http -v
git add server/remote_radio_server/http.py server/remote_radio_server/tls.py server/remote_radio_server/static_http.py server/tests/test_http.py server/tests/test_tls.py server/tests/test_static_http.py
git commit -m "feat: add strict HTTP and TLS transport"
```

### Task 6: Setup, Login, Account, Session, and Audit HTTP API

**Files:**

- Create: `server/remote_radio_server/auth/http_api.py`
- Create: `server/remote_radio_server/web_app.py`
- Create: `server/tests/auth/test_http_api.py`
- Create: `server/tests/test_web_app.py`
- Modify: `server/remote_radio_server/static_http.py`

**Interfaces:**

- Consumes `AccountService`, `BrowserSessionService`, and `AuthRepository` from Tasks 1-4.
- Produces `AuthApi.handle(request: HttpRequest) -> HttpResponse` and `WebApplicationHandler.handle(request)`.
- `WebApplicationHandler` sends `/api/v1/*` to `AuthApi` and every other path to the fixed static handler.

- [ ] **Step 1: Write failing strict JSON and cookie tests**

```python
async def test_login_sets_only_host_secure_cookie_and_no_store(self):
    response = await api.handle(json_request(
        "POST", "/api/v1/session/login",
        {"username": "operator.one", "password": PASSPHRASE}, secure=True,
    ))
    self.assertEqual(200, response.status)
    cookie = response.header("set-cookie")
    self.assertIn("__Host-rr_session=", cookie)
    for attribute in ("Secure", "HttpOnly", "SameSite=Strict", "Path=/"):
        self.assertIn(attribute, cookie)
    self.assertNotIn("Domain=", cookie)
    self.assertEqual("no-store", response.header("cache-control"))
```

Also reject duplicate JSON keys, unknown fields, array roots, non-JSON content
types, bodies above 32 KiB, insecure secret-bearing requests, and malformed or
duplicate session cookies. Setup and login require exact allowed `Origin` and
`Host` even without a cookie; native pairing challenge/poll and device refresh
are the only non-browser POST routes exempt from browser CSRF headers.

- [ ] **Step 2: Run API tests and confirm missing router**

```bash
python -m unittest tests.auth.test_http_api -v
```

- [ ] **Step 3: Implement exact JSON helpers and safe error envelopes**

Decode UTF-8 strictly with `object_pairs_hook` duplicate detection and
`parse_constant` rejection. Responses use:

```json
{"error":{"code":"authentication_failed","message":"authentication failed"}}
```

Map `400/401/403/409/410/429` exactly as the spec states. Include
`Retry-After` only for throttling. Never serialize exception text, PHC strings,
codes, cookies, or tokens.

- [ ] **Step 4: Add failing endpoint authorization and CSRF tests**

Cover `setup/status`, `setup/initialize`, login, session read/logout/password,
user list/create/update/delete/reset, session list/revoke, and audit pagination.
For every unsafe cookie-authenticated route, independently test missing/wrong
Origin, missing/wrong CSRF, operator access, and a valid administrator request.

- [ ] **Step 5: Implement the first route set and static/API composition**

Use one route table keyed by `(method, path-shape)`. `GET /api/v1/session`
returns the principal plus the HMAC-derived CSRF token only after validating
the session cookie; neither that token nor the cookie value is persisted. Allowed origins are
exact configured strings such as `https://radio.example:8080`; no wildcard,
suffix, or forwarded-host matching is permitted.

- [ ] **Step 6: Run focused and static HTTP suites**

```bash
python -m unittest tests.auth.test_http_api tests.test_web_app tests.test_http tests.test_static_http -v
```

- [ ] **Step 7: Commit the HTTP account surface**

```bash
git add server/remote_radio_server/auth/http_api.py server/remote_radio_server/web_app.py server/remote_radio_server/static_http.py server/tests/auth/test_http_api.py server/tests/test_web_app.py
git commit -m "feat: expose secure account HTTP API"
```

### Task 7: Six-digit Pairing Challenge State Machine

**Files:**

- Create: `server/remote_radio_server/auth/pairing.py`
- Create: `server/tests/auth/test_pairing.py`
- Modify: `server/remote_radio_server/auth/models.py`
- Modify: `server/remote_radio_server/auth/audit.py`

**Interfaces:**

- Produces `PairingService.create(device_name, platform, client_version, source) -> PairingChallengeGrant`.
- Produces `approve(code, principal, source) -> None` and `claim(challenge_id, poll_secret, source) -> DeviceGrant`.
- Consumes an async `DeviceIssuer.issue(user_id, device_name, platform, source) -> DeviceGrant` callback supplied by Task 8.

- [ ] **Step 1: Write failing generation, collision, and expiry tests**

```python
async def test_pairing_code_preserves_leading_zeroes_and_expires_at_five_minutes(self):
    service = PairingService(code_factory=lambda: 7,
                             secret_factory=lambda: "fixture-poll-secret",
                             clock=clock, issuer=issuer)
    grant = await service.create("Connor's iPhone", "ios", "1.0", "203.0.113.9")
    self.assertEqual("000007", grant.user_code)
    self.assertEqual(300, grant.expires_at - clock.now)
    clock.advance(301)
    with self.assertRaises(AuthGone):
        await service.approve("000007", operator, "203.0.113.9")
```

Use a sequence code factory to prove active-code collision regenerates. Assert
challenge and poll secrets never appear in audit metadata.

- [ ] **Step 2: Run pairing tests and confirm the missing state machine**

```bash
python -m unittest tests.auth.test_pairing -v
```

- [ ] **Step 3: Implement memory-only challenge creation**

Validate device names as trimmed Unicode of 1-64 code points, platform exactly
`ios`, and client version as 1-32 visible ASCII characters. Generate a UUID
challenge ID, `token_urlsafe(32)` poll secret, and unique six-digit code. Store
only `sha256(poll_secret)`, cap active challenges at three per source, and cap
creation at ten per source per ten minutes.

- [ ] **Step 4: Write failing approval, polling, and concurrency tests**

Cover five approval attempts/session/five minutes, ten/source/ten minutes,
15-minute lock, `authorization_pending`, two-second `slow_down`, repeated poll
abuse invalidation, wrong poll secret, approval bound to the current user,
restart invalidation, response-loss terminal behavior, and two concurrent
claimers producing exactly one `DeviceGrant`.

- [ ] **Step 5: Implement the locked approve/claim transitions**

States are `pending`, `approved`, `issuing`, and terminal `consumed`/`expired`.
Hold the per-challenge lock while moving `approved -> issuing`; call the issuer,
then mark consumed and erase code/poll digest before returning. If issuance
raises, return to `approved` without exposing details. Never allow an admin to
select another target account during approval.

- [ ] **Step 6: Run and commit**

```bash
python -m unittest tests.auth.test_pairing tests.auth.test_audit -v
git add server/remote_radio_server/auth/pairing.py server/remote_radio_server/auth/models.py server/remote_radio_server/auth/audit.py server/tests/auth/test_pairing.py
git commit -m "feat: add six digit device pairing flow"
```

### Task 8: Device Credentials, Rotation, and Pairing API Completion

**Files:**

- Modify: `server/remote_radio_server/auth/sessions.py`
- Modify: `server/remote_radio_server/auth/repository.py`
- Modify: `server/remote_radio_server/auth/service.py`
- Modify: `server/remote_radio_server/auth/http_api.py`
- Create: `server/tests/auth/test_device_credentials.py`
- Create: `server/tests/auth/test_pairing_http.py`

**Interfaces:**

- Produces `DeviceCredentialService.issue(user_id: str, device_name: str, platform: str, source: str) -> DeviceGrant`, `authenticate(device_id: str, access_token: str) -> AuthenticatedIdentity`, `refresh(device_id: str, refresh_token: str) -> DeviceGrant`, `rename(actor: Principal, device_id: str, name: str) -> DeviceRecord`, and `revoke(actor: Principal, device_id: str) -> None`.
- Completes `/pairing/challenges`, `/pairing/approve`, `/pairing/token`, `/device/refresh`, and device list/rename/revoke routes.
- A `DeviceGrant` carries plaintext secrets once: `device_id`, `access_token`, `access_expires_at`, `refresh_token`, `refresh_expires_at`, `role`, and `can_transmit`.

- [ ] **Step 1: Write failing issue/authenticate tests**

```python
async def test_device_grant_uses_digest_storage_and_live_account_permissions(self):
    grant = await credentials.issue(user.id, "Connor's iPhone", "ios", "203.0.113.9")
    identity = await credentials.authenticate(grant.device_id, grant.access_token)
    self.assertEqual(user.id, identity.user_id)
    self.assertEqual(grant.device_id, identity.device_id)
    self.assertNotIn(grant.access_token, database_bytes().decode("latin1"))
    self.assertNotIn(grant.refresh_token, database_bytes().decode("latin1"))
```

Change the linked operator's `can_transmit` and assert the same unexpired access
credential authenticates with the new effective permission and revision.

- [ ] **Step 2: Run device tests and verify failure**

```bash
python -m unittest tests.auth.test_device_credentials -v
```

- [ ] **Step 3: Implement access and refresh issuance**

Generate independent `token_urlsafe(32)` values and SHA-256 digests. Access
expiry is `now+900`; refresh expiry is `now+2_592_000`. `authenticate` joins the
device to the current user row, rejects revoked/expired/disabled/deleted state,
updates last-seen at most once per minute, and never trusts role fields from a
token.

- [ ] **Step 4: Write failing atomic rotation and replay tests**

Test one successful refresh invalidates the old access and refresh credentials,
returns a new pair, preserves the 30-day absolute family limit, and accepts the
new pair. Replaying the old refresh must revoke every credential for that
device, call the revocation sink, append `credential.reuse`, and leave unrelated
devices valid. Race two refresh calls and assert one success. Simulate losing
the successful response, retry the old credential, and assert fail-closed device
revocation rather than two live refresh credentials.

- [ ] **Step 5: Implement transactional rotation and device lifecycle**

Inside `BEGIN IMMEDIATE`, select the presented digest, distinguish active from
already-used history, mark the active row `used_at`, revoke prior access rows,
insert the new pair, and append audit. Replay marks the entire device family
revoked before returning `credential_reuse`. Rename is owner-or-admin; revoke
first invokes the safety-aware sink, then marks database credentials revoked.

- [ ] **Step 6: Add failing HTTP pairing/device tests and implement routes**

Assert exact request/response fields, `authorization_pending`, `slow_down`,
`410` on terminal challenges, no secret caching, CSRF on approval/rename/revoke,
owner/admin scope, admin all-device listing, and one-time token response. The
API response must never return stored digest IDs. Extend the administrator
session view from Task 6 to include active device access sessions, while an
operator still sees only their own devices and current browser session.

- [ ] **Step 7: Run and commit**

```bash
python -m unittest tests.auth.test_device_credentials tests.auth.test_pairing tests.auth.test_pairing_http tests.auth.test_http_api -v
git add server/remote_radio_server/auth server/tests/auth
git commit -m "feat: issue and rotate paired device credentials"
```

### Task 9: Authorization Matrix and Safety-aware Live Revocation

**Files:**

- Create: `server/remote_radio_server/auth/authorization.py`
- Create: `server/tests/auth/test_authorization.py`
- Create: `server/tests/auth/test_revocation.py`
- Modify: `server/remote_radio_server/gateway.py`
- Modify: `server/remote_radio_server/rig/safety.py`
- Modify: `server/tests/test_gateway.py`
- Modify: `server/tests/rig/test_safety.py`

**Interfaces:**

- Produces `Action` values `RADIO_CONTROL`, `ADMIN_RAW`, `ACCOUNT_ADMIN`, `PTT`, `AUDIO_UPLINK`, `FT8_TRANSMIT`, and `TUNER_CARRIER`.
- Produces `AuthorizationService.require(principal, action)`, `assert_current(principal)`, and async `authorize_transmit(principal, action, audit_metadata)`.
- Produces `ActiveConnectionRegistry.register(connection: LiveConnection)`, `unregister(client_id: str)`, `revoke_user(user_id: str, reason: str)`, `revoke_device(device_id: str, reason: str)`, `revoke_session(session_id: str, reason: str)`, and `remove_transmit(user_id: str, reason: str)`.
- Defines `LiveConnection` with immutable `principal` plus async `stop_transmit(reason)`, `send_event(event)`, and `close(code)` operations.
- `RigMessageGateway` receives an `AuthorizationService`; PTT leases use `principal.client_id`.

- [ ] **Step 1: Write the failing exact matrix tests**

```python
def test_operator_without_transmit_keeps_receive_control_but_not_tx_actions(self):
    receive_only = principal(Role.OPERATOR, can_transmit=False)
    authorization.require(receive_only, Action.RADIO_CONTROL)
    for action in (Action.PTT, Action.AUDIO_UPLINK,
                   Action.FT8_TRANSMIT, Action.TUNER_CARRIER):
        with self.subTest(action=action), self.assertRaises(AuthForbidden):
            authorization.require(receive_only, action)
```

Assert admins can perform all actions, transmitting operators cannot perform
account administration or raw Hamlib, disabled/stale revisions fail, and no
enum value named `OBSERVER` exists. Inject an audit failure and assert
`authorize_transmit` denies PTT, audio uplink, FT8 transmit, and tuner carrier
without invoking the downstream action.

- [ ] **Step 2: Run authorization tests and confirm failure**

```bash
python -m unittest tests.auth.test_authorization -v
```

- [ ] **Step 3: Implement the centralized matrix and gateway checks**

Call `assert_current` before every gateway dispatch except a strictly validated
`ptt.set` with `enabled=false` from the current lease owner. Require
`RADIO_CONTROL` for capability/snapshot/normal commands, `ADMIN_RAW` for
`send_raw`, and `PTT` for lease, heartbeat, and PTT-on. The PTT-off exception
reaches only the safety supervisor, so a stale client can de-key but perform no
other action. Recheck `PTT`
and append the transmit-on authorization audit immediately before
`request_ptt(lease_id, True)`; an audit failure rejects PTT-on. Future audio,
FT8, and tuner services must call the same `authorize_transmit` method rather
than duplicating the role matrix.

Delete the old two-field principal definition from `gateway.py`, import the
Task 1 principal, and keep `Principal` in `gateway.__all__` so existing imports
continue to work while all construction sites migrate to explicit fields.

- [ ] **Step 4: Write failing revocation-order race tests**

Use a gated fake PTT-off and two fake connections. Removing transmit while the
target owns keyed PTT must: reject a racing PTT-on, await physical off, invalidate
the lease, revoke credentials, emit `auth.revoked`, and close only the target.
Audit failure must not delay off/revocation. Also cover browser logout, device
revoke, account disable, and password reset.

- [ ] **Step 5: Implement registry indexes and safety-first ordering**

Index connections by `client_id`, `user_id`, optional `device_id`, and optional
browser session ID. On access reduction, increment the in-memory authorization
revision first, call `safety.client_disconnected(client_id)` and transmit-media
stop hooks, revoke credentials, then notify/close sockets. Record audit after
emergency off; if it fails, latch an `audit_degraded` health flag without
re-keying or restoring credentials.

- [ ] **Step 6: Run authorization, gateway, and safety suites**

```bash
python -m unittest tests.auth.test_authorization tests.auth.test_revocation tests.test_gateway tests.rig.test_safety -v
```

- [ ] **Step 7: Commit**

```bash
git add server/remote_radio_server/auth/authorization.py server/remote_radio_server/gateway.py server/remote_radio_server/rig/safety.py server/tests/auth server/tests/test_gateway.py server/tests/rig/test_safety.py
git commit -m "feat: enforce account and transmit permissions"
```

### Task 10: Versioned Browser and Device WebSocket Authentication

**Files:**

- Create: `protocol/v1/auth-device.json`
- Create: `protocol/v1/auth-ok-operator.json`
- Create: `protocol/v1/auth-ok-admin.json`
- Create: `protocol/v1/error-forbidden.json`
- Create: `protocol/v1/auth-revoked.json`
- Create: `protocol/v1/README.md`
- Modify: `server/remote_radio_server/websocket.py`
- Modify: `server/remote_radio_server/server.py`
- Modify: `server/tests/test_websocket.py`
- Modify: `server/tests/integration/helpers.py`
- Modify: `server/tests/integration/test_websocket_control_plane.py`
- Create: `server/tests/integration/test_account_websocket.py`
- Create: `server/tests/test_protocol_fixtures.py`

**Interfaces:**

- `perform_server_handshake(reader, writer, required_subprotocol) -> WebSocketUpgrade(path, headers, selected_protocol)` returns validated request metadata and writes `Sec-WebSocket-Protocol: remote-radio.v1` for account mode.
- `WebSocketAuthenticator.browser(headers, peer, secure) -> AuthenticatedIdentity | None` and `device(message, peer, secure) -> AuthenticatedIdentity` consume Tasks 4 and 8.
- `RemoteRadioServer` accepts an authorizer, registry, clock, and optional SSL context; legacy Dummy tests inject a separate test-only token authorizer.

- [ ] **Step 1: Add canonical fixtures and failing fixture-shape tests**

Use exact documents such as:

```json
{"type":"auth.device","protocol_version":1,"device_id":"device-1","access_token":"fixture-secret"}
```

```json
{"type":"auth.ok","protocol_version":1,"principal":{"user_id":"user-1","device_id":"device-1","role":"operator","can_transmit":false}}
```

The fixture test rejects unknown roles, missing booleans, non-integer protocol
versions, and secret-shaped fields in every server-to-client fixture.

- [ ] **Step 2: Write failing upgrade metadata and subprotocol tests**

Assert account mode accepts only path `/radio`, exactly one allowed `Origin`,
one session cookie, and offered subprotocol `remote-radio.v1`; missing or
unsupported protocol receives a bounded HTTP rejection before `101`. Preserve
all RFC 6455 key/version/duplicate-header tests.

- [ ] **Step 3: Return validated upgrade data and select the protocol**

Change `_validate_upgrade` to return a frozen `WebSocketUpgrade` rather than
only the key. Never concatenate unvalidated protocol text into the response.
Legacy test mode passes `required_subprotocol=None`; account mode passes the
literal `remote-radio.v1`.

- [ ] **Step 4: Write failing browser-cookie and device-first-message tests**

Browser: the upgrade cookie produces `auth.ok` immediately, with no secret JSON
message. Device: after `101`, only the exact `auth.device` document above is
accepted within five seconds. Test wrong/expired/revoked credentials, wrong
Origin, plaintext non-loopback, extra fields, duplicate JSON keys, and no token
echo in close frames/logs.

- [ ] **Step 5: Implement the two authentication paths and principal event**

After authentication, generate `client_id=ws:<uuid4>` and combine it with the
identity to create the immutable `Principal`; two sockets from one device must
receive distinct client IDs. Register the connection only after this step. Send
the same `auth.ok` principal shape for browser and device, without exposing the
client ID. A device connection schedules
`auth.expiring` 60 seconds before access expiry and closes with `1008` at
expiry. A browser connection closes at its idle/absolute session deadline and
calls the session service's one-minute-coalesced `touch` after accepted traffic.
Every message calls `authorization.assert_current` before the gateway.

- [ ] **Step 6: Add failing revocation/cleanup and legacy-isolation tests**

Revoke an account/device/session during keyed mock PTT and assert de-key,
`auth.revoked`, close `1008`, empty registry indexes, and no leaked tasks.
Separately prove legacy public-Dummy token authentication still works only when
the explicit legacy authorizer is injected and cannot call account endpoints.

- [ ] **Step 7: Run WebSocket and protocol suites**

```bash
python -m unittest tests.test_protocol_fixtures tests.test_websocket tests.integration.test_websocket_control_plane tests.integration.test_account_websocket -v
```

- [ ] **Step 8: Commit**

```bash
git add protocol server/remote_radio_server/websocket.py server/remote_radio_server/server.py server/tests/test_websocket.py server/tests/test_protocol_fixtures.py server/tests/integration
git commit -m "feat: authenticate versioned browser and device sockets"
```

### Task 11: Account Application Stack, CLI, and Verified Dummy PTT

**Files:**

- Create: `server/remote_radio_server/app.py`
- Create: `server/tests/test_app.py`
- Create: `server/tests/integration/test_public_dummy_accounts.py`
- Modify: `server/remote_radio_server/public_dummy.py`
- Modify: `server/remote_radio_server/runtime.py`
- Modify: `server/remote_radio_server/__main__.py`
- Modify: `server/tests/test_public_dummy.py`
- Modify: `server/tests/integration/test_cli.py`

**Interfaces:**

- Produces `AccountApplicationConfig(web_root, data_dir, http_host, http_port, websocket_host, websocket_port, tls_cert, tls_key, allowed_origins)`.
- Produces `AccountApplicationStartup(url, websocket_url, setup_code, identity)`; `setup_code` is `None` after initialization.
- Produces `AccountApplicationStack(runtime, config)` that owns repository, auth services, HTTP, WebSocket, registry, and shutdown.
- Adds explicit CLI mode `--public-dummy-accounts`; the existing `--public-dummy-test` remains the isolated plaintext/token test mode.
- Produces `ControlPlaneRuntime.enable_verified_dummy_tx()` that succeeds only for an owned, ready, official model `1` launcher configured with `public_dummy_test=True`.

- [ ] **Step 1: Write failing application startup/cleanup tests**

Start with fakes and assert exact ordering: repository/migrations, auth services,
runtime readiness, TLS context, WebSocket, then HTTP. Inject a failure at every
stage and assert only already-owned resources close in reverse order. Setup code
appears once in `AccountApplicationStartup` only for an empty database. A
missing/corrupt/newer auth database must abort startup and must never construct
the legacy token authorizer.

- [ ] **Step 2: Run the focused lifecycle test**

```bash
python -m unittest tests.test_app -v
```

- [ ] **Step 3: Implement the composition root**

`AccountApplicationStack.start()` constructs exactly one repository,
`PasswordService`, throttle, account/session/device/pairing services,
authorization service, registry, `AuthApi`, static/API handler, WebSocket
server, and HTTP server. It injects dependencies instead of importing globals.
Shutdown first rejects new work, safety-revokes live connections, closes
listeners, closes the runtime, and finally closes SQLite.

- [ ] **Step 4: Write failing Dummy identity and TX-enablement tests**

Test model `1` plus owned public-Dummy launcher enables only simulated PTT.
Test model `2`, missing identity, external rigctld, in-process configuration
without ownership, and hardware flags all reject with no PTT attempt. Preserve
legacy mode's `hardware_tx_disabled` behavior.

- [ ] **Step 5: Implement self-verifying Dummy enablement**

`enable_verified_dummy_tx()` reads the current ready session identity itself;
it accepts no caller-supplied model ID. It also verifies the launcher's frozen
config has `model_id=1`, `public_dummy_test=True`, and no device path before
setting the runtime's private simulated-TX capability. Account authorization
and the existing PTT safety supervisor remain mandatory.

- [ ] **Step 6: Write failing CLI validation tests**

`--public-dummy-accounts` is mutually exclusive with `--mock`,
`--launch-rigctld`, `--serve`, `--once`, `--device-token`, hardware-TX flags,
and legacy `--public-dummy-test`. It accepts `--data-dir` (default
`/opt/testradio/data`), repeatable `--allowed-origin`, `--tls-cert`, `--tls-key`,
and the existing three ports. It requires both TLS files and at least one exact
HTTPS origin, rejects wildcard/non-HTTPS origins, and starts all three listeners
on `0.0.0.0`.

- [ ] **Step 7: Implement CLI/startup event and official-Dummy integration**

Emit one compact console event:

```json
{"type":"public-dummy.accounts_started","url":"https://ah.992218.xyz:8080","websocket_url":"wss://ah.992218.xyz:8765/radio","setup_code":"123456","identity":{"model_id":1,"model":"Dummy"}}
```

Omit `setup_code` after initialization. Never emit a browser session, CSRF,
access, or refresh secret. Resolve `--data-dir` once and join only the fixed
database, CSRF-key, and owned log names beneath it; reject traversal through
symlinks or relative `..` segments.

- [ ] **Step 8: Run application, CLI, public-Dummy, and PTT integration suites**

```bash
python -m unittest tests.test_app tests.test_public_dummy tests.integration.test_cli tests.integration.test_public_dummy_accounts tests.integration.test_public_dummy_web -v
```

The official-Hamlib tests may skip only when the test helper cannot find
`rigctld`; fake/mock tests must still pass.

- [ ] **Step 9: Commit**

```bash
git add server/remote_radio_server/app.py server/remote_radio_server/public_dummy.py server/remote_radio_server/runtime.py server/remote_radio_server/__main__.py server/tests
git commit -m "feat: run TLS account mode with verified Dummy PTT"
```

### Task 12: Browser Account Client and Cookie-authenticated Radio Client

**Files:**

- Create: `web/auth-client.js`
- Create: `web/tests/auth-client.test.mjs`
- Create: `web/legacy/index.html`
- Create: `web/legacy/styles.css`
- Create: `web/legacy/radio-client.js`
- Create: `web/legacy/dashboard.js`
- Modify: `web/radio-client.js`
- Modify: `web/dashboard.js`
- Modify: `web/tests/radio-client.test.mjs`
- Modify: `web/tests/dashboard.test.mjs`
- Modify: `web/package.json`
- Modify: `server/remote_radio_server/__main__.py`
- Modify: `server/tests/integration/test_public_dummy_web.py`

**Interfaces:**

- Produces `AuthClient` methods `setupStatus`, `initialize`, `login`, `session`, `logout`, `changePassword`, `listUsers`, `createUser`, `updateUser`, `deleteUser`, `resetPassword`, `listDevices`, `renameDevice`, `revokeDevice`, `approvePairing`, `listSessions`, `revokeSession`, and `listAudit`.
- `RadioClient` no longer accepts `deviceId` or `token`; it opens `new WebSocket(url, "remote-radio.v1")` and waits for cookie-authenticated `auth.ok`.

- [ ] **Step 1: Write failing AuthClient request tests**

```javascript
test("unsafe requests send in-memory CSRF and credentials without storing secrets", async () => {
  const client = new AuthClient({ fetchFn, baseUrl: "https://radio.test:8080" });
  await client.login("operator.one", "correct horse battery staple");
  await client.createUser({
    username: "operator.two", password: "long passphrase for operator two",
    role: "operator", can_transmit: false,
  });
  assert.equal(requests[1].options.credentials, "same-origin");
  assert.equal(requests[1].options.headers["X-CSRF-Token"], fixtureCsrf);
  assert.equal(globalThis.localStorage, undefined);
});
```

Test every method's HTTP verb/path/body, no query-string secrets, generic
errors, `Retry-After`, CSRF refresh, and response shape validation.

- [ ] **Step 2: Implement the fetch client with one memory-only CSRF value**

Always use `credentials: "same-origin"`, `cache: "no-store"`, exact JSON
headers, and `redirect: "error"`. Clear CSRF/principal on `401`, logout, or
`auth.revoked`. Never accept role values other than `admin`/`operator`.

- [ ] **Step 3: Write failing cookie-WebSocket tests**

Update the fake socket constructor to capture the protocols argument. Assert no
JSON authentication message is sent on open, `auth.ok` must carry
`protocol_version:1`, permission updates reach callbacks, `auth.expiring` and
`auth.revoked` stop PTT/reconnect appropriately, and policy close never clears a
nonexistent token from storage.

- [ ] **Step 4: Implement the new WebSocket state machine**

States remain `disconnected`, `connecting`, `authenticating`, `ready`, and
`reconnecting`. On open, wait for server `auth.ok`; do not send control messages
until it arrives. On `auth.revoked`, stop timers, clear pending requests, notify
the auth controller, and require a fresh HTTP session or pairing.

- [ ] **Step 5: Remove legacy token/sessionStorage handling from account dashboard code**

Before deleting account-mode token handling, copy the current four dashboard
assets byte-for-byte into `web/legacy/`. Point only `--public-dummy-test` at
that fixed legacy directory and keep its existing integration test. Then delete
`SESSION_TOKEN_KEY`, device token form wiring, and all storage access from the
account-mode files in `web/`; `--public-dummy-accounts` continues to serve the
new account entry point.

- [ ] **Step 6: Run web tests and commit**

```bash
npm test
git add web server/remote_radio_server/__main__.py server/tests/integration/test_public_dummy_web.py
git commit -m "feat: connect browser with account sessions"
```

### Task 13: Web Setup, Login, Settings, Pairing, and Audit UI

**Files:**

- Create: `web/settings.js`
- Create: `web/tests/settings.test.mjs`
- Modify: `web/index.html`
- Modify: `web/styles.css`
- Modify: `web/dashboard.js`
- Modify: `web/radio-client.js`
- Modify: `web/tests/dashboard.test.mjs`
- Modify: `web/tests/radio-client.test.mjs`
- Modify: `server/remote_radio_server/static_http.py`
- Modify: `server/tests/test_static_http.py`

**Interfaces:**

- `initializeSettings(documentLike, windowLike, authClient)` owns setup/login/account/device/session/audit DOM state.
- `initializeDashboard` receives the confirmed principal and enables transmit controls only when `can_transmit` is true; server rejection still wins.
- `RadioClient` produces `requestPttLease()`, `setPtt(leaseId, enabled)`, and `heartbeatPtt(leaseId)` only for the hold-to-talk controller.

- [ ] **Step 1: Write failing view-state tests before editing markup**

Test these exact states: setup required, login, temporary-password change,
operator radio view, administrator settings, disabled/revoked, pairing approval
pending/success/error, paginated audit, and loading/error buttons. Assert the
role selector options are exactly `admin` and `operator` and every interactive
button uses the existing rounded control classes.

- [ ] **Step 2: Run the new settings test and observe missing exports**

```bash
node --test tests/settings.test.mjs
```

- [ ] **Step 3: Add semantic setup/login/settings markup**

Keep the approved deep-graphite single workspace, large frequency, spectrum,
waterfall, and bottom control dock. Add accessible dialog/section markup for:

- first-admin setup with six-digit setup code, username, password, show/hide;
- username/password login with autofill and paste enabled;
- own password and paired devices;
- administrator users with role, enabled, and `can_transmit` controls;
- six-digit pairing approval input;
- active session/device revoke actions; and
- cursor-paginated audit events.

Do not add a registration link, observer copy, plaintext token field, or a
password composition checklist.

- [ ] **Step 4: Implement server-confirmed settings behavior**

Render mutations only after API confirmation. Reset sensitive input elements
immediately after submission. Disable all submit buttons while pending, map
stable server error codes to concise Chinese messages, and keep generic login
failure text identical. Permission changes update the dashboard only after the
next `GET /session`/WebSocket `auth.ok`.

- [ ] **Step 5: Add failing PTT presentation tests and implement hold-to-talk gating**

For `can_transmit=false`, keep PTT/FT8 reply/tuner-carrier/microphone controls
disabled with a permission explanation. For authorized simulated mode, PTT is
pointer/keyboard hold-to-talk: acquire lease, send heartbeat every two seconds,
send on at press, off at release/cancel/blur/visibility change, and never latch.
Test every release path with fake timers and a fake radio client.

- [ ] **Step 6: Update fixed-asset allowlist and run all web/static tests**

Add `/auth-client.js` and `/settings.js` to the server asset allowlist with
JavaScript MIME type and the existing security headers.

```bash
npm test
python -m unittest tests.test_static_http -v
```

- [ ] **Step 7: Commit**

```bash
git add web server/remote_radio_server/static_http.py server/tests/test_static_http.py
git commit -m "feat: add account and pairing settings UI"
```

### Task 14: Shared Fixtures and Swift Authentication Core

**Files:**

- Create: `ios/Package.swift`
- Create: `ios/Sources/RemoteRadioCore/AuthModels.swift`
- Create: `ios/Sources/RemoteRadioCore/AuthAPIClient.swift`
- Create: `ios/Sources/RemoteRadioCore/RadioWebSocketClient.swift`
- Create: `ios/Sources/RemoteRadioCore/CredentialStore.swift`
- Create: `ios/Sources/RemoteRadioCore/KeychainCredentialStore.swift`
- Create: `ios/Tests/RemoteRadioCoreTests/AuthModelsTests.swift`
- Create: `ios/Tests/RemoteRadioCoreTests/AuthAPIClientTests.swift`
- Create: `ios/Tests/RemoteRadioCoreTests/CredentialStoreTests.swift`
- Create: `ios/Tests/RemoteRadioCoreTests/ProtocolFixtureTests.swift`
- Modify: `protocol/v1/README.md`

**Interfaces:**

- Produces `PairingChallenge`, `DeviceGrant`, `Principal`, `Role`, `AuthEvent`, and `APIError` `Codable`, `Sendable`, and `Equatable` values.
- Produces actor `AuthAPIClient` with `beginPairing`, `pollPairing`, and `refresh` using injected `URLSessionProtocol`.
- Produces actor `RadioWebSocketClient` using WebSocket subprotocol `remote-radio.v1`, an injected access-token provider, and typed `acquirePttLease`, `setPtt`, and `heartbeatPtt` methods for Task 15's hold-to-talk controller.
- Produces `CredentialStore` protocol and Security-backed `KeychainCredentialStore` using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

- [ ] **Step 1: Add the Swift package and failing fixture decoding tests**

Declare `.iOS(.v17)` and `.macOS(.v14)` so core tests can run on a Mac while
the app floor remains iOS 17. Copy `protocol/v1` into test resources. Decode
every canonical fixture and assert exact enum/optional/numeric behavior:

```swift
func testOperatorAuthFixture() throws {
    let event = try fixtureDecoder.decode(AuthEvent.self, named: "auth-ok-operator")
    XCTAssertEqual(event.principal?.role, .operator)
    XCTAssertEqual(event.principal?.canTransmit, false)
    XCTAssertEqual(event.protocolVersion, 1)
}
```

- [ ] **Step 2: On macOS, run and observe missing model failures**

```bash
swift test --package-path ios
```

This is an explicit Mac checkpoint. On Windows/Debian, stop this task after
source review and fixture validation; do not claim Swift compilation passed.

- [ ] **Step 3: Implement strict DTOs and API client**

Use snake-case `CodingKeys`, reject protocol versions other than `1`, accept
only `.admin`/`.operator`, and convert HTTP error envelopes into stable
`APIError`. `pollPairing` honors the server's two-second interval and
`slow_down`; it never logs or describes access/refresh values.

- [ ] **Step 4: Write failing Keychain accessibility and rotation tests**

Inject a `KeychainBackend` recorder. Assert the refresh token and device ID use
service `RemoteRadio`, account keyed by server origin/device ID, and
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; access tokens remain only in
actor memory. A successful refresh atomically replaces the stored refresh
token; revoke deletes it.

- [ ] **Step 5: Implement Keychain and WebSocket clients**

Use `URLSessionWebSocketTask` with protocol `remote-radio.v1`. Send exact
`auth.device` once connected, accept only `auth.ok` version `1`, surface
`auth.expiring`, and close/erase access state on `auth.revoked`. Redact secrets
from `CustomStringConvertible`, errors, and debug logging.

- [ ] **Step 6: Run Mac tests plus cross-language fixture tests**

```bash
swift test --package-path ios
python -m unittest tests.test_protocol_fixtures -v
npm test
```

- [ ] **Step 7: Commit**

```bash
git add ios protocol
git commit -m "feat: add Swift authentication core"
```

### Task 15: Native SwiftUI Pairing App and Background Safety

**Files:**

- Create: `ios/RemoteRadio/RemoteRadioApp.swift`
- Create: `ios/RemoteRadio/AppModel.swift`
- Create: `ios/RemoteRadio/PairingView.swift`
- Create: `ios/RemoteRadio/RadioView.swift`
- Create: `ios/RemoteRadio/SettingsView.swift`
- Create: `ios/RemoteRadioTests/AppModelTests.swift`
- Create on macOS: `ios/RemoteRadio.xcodeproj/project.pbxproj`
- Create on macOS: `ios/RemoteRadio.xcodeproj/xcshareddata/xcschemes/RemoteRadio.xcscheme`

**Interfaces:**

- `@MainActor AppModel` exposes states `unpaired`, `pairing(code, expiry)`, `connecting`, `ready(principal)`, `revoked`, and `error(message)`.
- `PairingView` displays only server URL, six-digit code, expiry, retry/cancel, and approval instructions.
- `AppModel.scenePhaseChanged(_:)` releases PTT and microphone state before handling `.inactive` or `.background`.

- [ ] **Step 1: Write failing AppModel state-transition tests on macOS**

Use fake API/WebSocket/credential-store/PTT clients. Cover fresh pairing,
pending/approved polling, restart refresh, refresh failure returning to pairing,
device revocation, and permission change. Assert no app state contains the
plaintext refresh credential.

- [ ] **Step 2: Implement the SwiftUI app shell and six-digit pairing screen**

Use `NavigationStack`, monospaced six-digit code with accessibility grouping,
countdown based on server expiry, and Chinese instructions to approve in web
settings. The app must not show or request username/password and must not offer
manual long-token entry.

- [ ] **Step 3: Add failing background/de-key tests**

```swift
func testBackgroundStopsTransmitBeforeDisconnect() async {
    await model.scenePhaseChanged(.background)
    XCTAssertEqual(ptt.calls, [.set(false), .releaseLease])
    XCTAssertEqual(audio.calls, [.stopUplink])
    XCTAssertEqual(socket.calls.last, .disconnect)
}
```

Also test loss of `canTransmit`, access expiry, WebSocket policy close, and
pairing revocation use the same safety-first sequence.

- [ ] **Step 4: Implement radio/settings views with server-authoritative permissions**

Reuse the professional radio layout concept: large frequency, compact controls,
receive audio/FT8 status, tuner status, and hold-to-talk PTT. Hide no receive
controls from an operator. Disable every transmit affordance when
`canTransmit=false`, but retain server rejection handling for stale UI state.

- [ ] **Step 5: Create the native Xcode project on macOS and run tests/build**

Create an iOS App target named `RemoteRadio`, SwiftUI lifecycle, deployment
target `17.0`, and a unit-test target. Link the local `RemoteRadioCore` package
and Security framework. Use a project-local development bundle identifier
`xyz.992218.RemoteRadio`; signing team remains unset until the user's Mac
chooses it.

```bash
swift test --package-path ios
xcodebuild -project ios/RemoteRadio.xcodeproj -scheme RemoteRadio -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 6: Commit only after the Mac build succeeds**

```bash
git add ios
git commit -m "feat: add native SwiftUI pairing client"
```

### Task 16: Full Regression, Debian Acceptance, and Operations Documentation

**Files:**

- Create: `docs/AUTHENTICATION.md`
- Create: `docs/PAIRING-IOS.md`
- Modify: `docs/SAFETY.md`
- Modify: `docs/HAMLIB.md`
- Modify: `server/tests/integration/test_public_dummy_accounts.py`

**Interfaces:**

- Documents the exact account-mode CLI, setup/login/pairing/revocation flow,
  TLS requirement, data backup boundary, and emergency de-key behavior.
- Produces one repeatable `/opt/testradio` acceptance checklist without service
  installation or writes elsewhere.

- [ ] **Step 1: Add the final end-to-end acceptance test**

With fake time/randomness and the in-process mock, cover: initialize admin,
login, create receive-only operator, browser WebSocket, six-digit device pairing,
device WebSocket, receive control, denied PTT, grant transmit, simulated PTT,
heartbeat, remove transmit during PTT, immediate de-key, connection close,
credential refresh/replay revocation, logout, and restart persistence.

- [ ] **Step 2: Run complete local regression suites**

From `server/` and `web/` respectively:

```bash
python -m unittest discover -s tests -v
npm test
```

On macOS also run:

```bash
swift test --package-path ios
xcodebuild -project ios/RemoteRadio.xcodeproj -scheme RemoteRadio -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 3: Perform static secret and legacy-bypass checks**

Search tracked source and generated test databases for session/access/refresh
fixture values, PHC plaintext inputs, `localStorage`, `sessionStorage`, and
account-mode construction of the legacy authorizer. Expected findings are only
test fixture declarations and the isolated legacy public-Dummy path; account
mode has none. Run `git diff --check`.

- [ ] **Step 4: Write the operator documentation**

Document:

- copying/provisioning a TLS certificate and key specifically to
  `/opt/testradio/data/tls/server.crt` and `server.key` with mode `0600`;
- configuring exact `--allowed-origin https://ah.992218.xyz:8080` rather than a
  wildcard or forwarded-host rule;
- first administrator setup and the ten-minute setup-code behavior;
- account CRUD, temporary password, pairing, device/session revoke, and audit;
- browser HTTPS and SwiftUI trusted-certificate requirements;
- database location and stop-before-copy backup procedure; and
- explicit prohibition on using account authorization as hardware-TX approval.

- [ ] **Step 5: Run Debian acceptance strictly under `/opt/testradio`**

First verify `pwd` resolves to `/opt/testradio` and both TLS files already exist
inside its `data/tls` directory; if either check fails, stop without creating or
modifying anything elsewhere. Then run:

```bash
cd /opt/testradio
python3 -m venv /opt/testradio/.venv
.venv/bin/python -m pip install -e /opt/testradio/server
.venv/bin/python -m unittest discover -s server/tests -v
npm --prefix web test
.venv/bin/python -m remote_radio_server --public-dummy-accounts --data-dir /opt/testradio/data --allowed-origin https://ah.992218.xyz:8080 --tls-cert /opt/testradio/data/tls/server.crt --tls-key /opt/testradio/data/tls/server.key
```

If `python3`, `venv`, Node, npm, Hamlib, or the TLS files are absent, report the
preflight failure and stop; do not install system packages or modify paths
outside `/opt/testradio`.

In a second terminal, confirm `0.0.0.0:8080`, `0.0.0.0:8765`, and
`0.0.0.0:4532`; initialize/login through HTTPS; pair the iOS simulator/client;
exercise permission denial and simulated PTT revocation; stop the process; and
confirm all three owned listeners and the owned Dummy child are gone. Do not
install a system service or write to `/etc`, `/var`, another `/opt` directory,
or a home directory.

- [ ] **Step 6: Run final verification and commit**

```bash
python -m unittest discover -s tests -v
npm test
git diff --check
git status --short
git add docs server/tests/integration/test_public_dummy_accounts.py
git commit -m "docs: add account and pairing operations guide"
```

Expected: all available Python/Node tests pass; Hamlib-dependent tests either
pass or report only the existing explicit missing-`rigctld` skip; Swift build
status is reported separately and is not claimed from Windows/Debian.
