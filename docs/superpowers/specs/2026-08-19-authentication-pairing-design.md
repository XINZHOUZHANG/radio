# Remote Radio Authentication and Device Pairing Design

**Date:** 2026-08-19

**Status:** Approved

**Scope:** Local accounts, browser sessions, iOS device pairing, authorization,
revocation, and audit for the Remote Radio control plane

## 1. Goal

Replace the process-lifetime `device_id -> token` map with a persistent,
revocable authentication system shared by the browser and the native SwiftUI
client. Administrators create local accounts in the web settings page. Users
sign in to the browser with a username and password, and pair an iPhone by
confirming a six-digit, five-minute code.

The server remains authoritative for every permission decision. Hiding a
button in the browser or SwiftUI app is only presentation; direct HTTP and
WebSocket requests must receive the same authorization result.

## 2. Scope and Non-goals

This slice implements:

- one-time creation of the first administrator;
- administrator-managed local accounts;
- username/password browser login;
- secure browser sessions and CSRF protection;
- six-digit iOS device pairing;
- short-lived access credentials and rotating refresh credentials;
- immediate session, device, account, and transmit-permission revocation;
- authorization at the HTTP, WebSocket, PTT, audio, FT8, and tuner boundaries;
- append-only security audit events; and
- a versioned protocol contract consumed by both web and SwiftUI clients.

This slice does not implement public self-registration, email recovery, OAuth,
federation, multi-factor authentication, cloud synchronization, or an
observer/read-only role. It defines authorization gates for audio, FT8, and
tuner operations, but their media/DSP/hardware implementations remain separate
slices. Real-radio transmission remains disabled during this slice.

## 3. Roles and Effective Permissions

There are exactly two account roles:

| Role | Account/device administration | Radio receive/control | Transmit |
|---|---:|---:|---:|
| `admin` | Yes | Yes | Yes |
| `operator` | No | Yes | Only when `can_transmit` is true |

There is no observer role in storage, APIs, protocol messages, or either UI.
An operator without transmit permission can still change frequency, mode,
passband, levels, functions, and split settings; receive audio; decode FT8; and
inspect tuner state. That account is an active receive-side operator, not a
read-only observer.

`can_transmit` is stored for operators and is evaluated dynamically. It gates:

- acquiring or using a PTT lease;
- microphone/audio uplink while transmitting;
- FT8 tune, call, reply, and other transmit actions; and
- any external-tuner operation that intentionally generates an RF carrier.

Administrators have effective transmit permission. Radio safety policy remains
an additional independent gate: authorization never overrides the PTT lease,
heartbeat, hard-duration limit, SWR protection, hardware-TX policy, or rig
capability checks. Simulated transmission is permitted only for the in-process
mock or an identity-verified official Hamlib Dummy model `1`.

The PTT client sends a heartbeat every two seconds. The safety supervisor
forces de-key after ten seconds without a valid heartbeat and after a 180-second
continuous-transmit hard limit, in addition to the existing disconnect and SWR
trips.

Only an administrator may create, disable, reset, change the role or transmit
permission of, or delete another account. The final enabled administrator
cannot be disabled, deleted, or demoted. A user may change their own password
and revoke their own paired devices. Administrators may inspect and revoke all
devices and sessions.

## 4. First Administrator and Account Lifecycle

On startup with an empty database, the service generates one six-digit setup
code using a cryptographically secure random generator and writes it once to
the server console. The code is held only in memory, expires after ten minutes,
allows at most five failed submissions from one source, and is invalidated by
server restart or successful use.

The setup page calls:

```http
POST /api/v1/setup/initialize
Content-Type: application/json

{"setup_code":"123456","username":"connor","password":"..."}
```

The operation succeeds only when no account exists. A process-local setup lock
serializes submissions; inside it, account creation is one database
transaction. The in-memory code is marked consumed after that commit and before
the lock is released. If the process fails between those steps, the committed
administrator still prevents initialization on restart. Concurrent submissions
can therefore create exactly one first administrator. Once initialized, the
endpoint returns `409 already_initialized` and startup no longer prints a setup
code.

Usernames are case-insensitive ASCII identifiers. They are trimmed, normalized
to lowercase, and must match `[a-z0-9][a-z0-9_.-]{2,31}`. The original display
case is not retained. Deleting an account creates a disabled tombstone so its
username and audit identity are not silently reused.

The settings page provides:

- create account with role and operator transmit permission;
- list account status and last successful login;
- enable or disable an account;
- change role or `can_transmit`;
- issue a temporary replacement password with `must_change_password=true`;
- revoke browser sessions and paired devices; and
- delete an account subject to the final-administrator invariant.

A temporary-password login can access only password change and logout. A
successful password change or administrator reset revokes every existing
browser session, access credential, refresh credential, WebSocket connection,
PTT lease, and media uplink owned by that account.

## 5. Password Policy and Storage

Passwords are accepted as Unicode, normalized with NFC, and must contain 15 to
128 Unicode code points and no more than 1,024 UTF-8 bytes. Spaces and paste or
password-manager input are allowed. There are no mandatory uppercase,
lowercase, digit, symbol, periodic-rotation, or security-question rules.

New passwords are compared against a bundled offline blocklist of common and
compromised values plus context-specific values derived from the username and
product name. No password or password-derived value is sent to a third-party
service.

Passwords are hashed with Argon2id through `argon2-cffi`, using at least:

- memory cost: 19,456 KiB;
- time cost: 2;
- parallelism: 1;
- random per-password salt: 16 bytes; and
- output length: 32 bytes.

Only the versioned PHC-format Argon2id string is stored. Plaintext passwords,
setup codes, pairing codes, browser session secrets, access credentials, and
refresh credentials are never written to the database or logs. A successful
login transparently rehashes the password when the configured Argon2 policy is
newer than the stored PHC parameters.

Authentication failures use the same status, response size class, and safe
message for unknown usernames, incorrect passwords, disabled accounts, and
deleted accounts. Verification performs a real Argon2id calculation against a
fixed dummy hash when no usable account exists, reducing account-enumeration
timing differences.

Login throttling is keyed by normalized username and source address. Five
consecutive failures trigger a 30-second delay; subsequent failures double the
delay up to 15 minutes. A source-wide budget of 30 failures in ten minutes
triggers a 15-minute block. Success resets the account-specific failure count.
Rate-limit responses use `429` and `Retry-After` without revealing whether the
account exists.

## 6. Browser Authentication and Session Security

The browser authenticates with `POST /api/v1/session/login`. Success creates an
opaque 256-bit random session secret. The browser receives it only as a cookie:

```text
__Host-rr_session=<opaque>; Secure; HttpOnly; SameSite=Strict; Path=/
```

The database stores only a SHA-256 digest of this high-entropy secret. Browser
sessions expire after 30 minutes of inactivity or 12 hours from creation,
whichever occurs first. Logout deletes the server-side session and expires the
cookie. The session is not copied to `localStorage`, `sessionStorage`, URLs, or
JavaScript-readable state.

Authenticated HTTP or WebSocket activity may advance the inactivity deadline
at most once per minute to avoid a database write per radio message. The
absolute deadline never moves. A browser WebSocket closes when either deadline
is reached.

Every state-changing cookie-authenticated HTTP request requires both:

- an exact allowed `Origin`/`Host` check; and
- an `X-CSRF-Token` bound to the presented session cookie.

Browser setup and login requests also require the exact allowed `Origin` and
`Host`, even though no session exists yet, to prevent login/setup CSRF. Native
pairing-challenge, pairing-poll, and device-refresh requests do not use browser
CSRF tokens; they remain TLS-only, strictly shaped, and rate-limited.

The CSRF token is `HMAC-SHA-256(server_csrf_key,
"remote-radio-csrf\0" || session_token)`, encoded as base64url. The 256-bit
server CSRF key is generated once and stored as a mode-`0600` file in the data
directory; the database still stores only the session-token digest. The token
is returned by `GET /api/v1/session`, kept in memory by the web application,
and never placed in a cookie or persistent browser storage. CORS is disabled.
JSON endpoints require `Content-Type: application/json`, exact known fields,
bounded bodies, and no duplicate JSON keys.

Password, setup, pairing, refresh, and authenticated control traffic must use
HTTPS/WSS whenever a listener is reachable beyond loopback. In this slice,
account mode fails closed at startup unless every non-loopback HTTP/WebSocket
listener has a directly configured TLS certificate and key; trusted reverse
proxy handling is outside this slice. The explicitly test-only plaintext
`--public-dummy-test` path may retain its temporary token for legacy Dummy
acceptance, but it cannot expose password or pairing endpoints. It is not an
authentication-mode fallback.

## 7. Six-digit iOS Pairing

Pairing follows a device-code flow so the user enters only six digits while the
actual device secrets retain high entropy.

1. The unpaired SwiftUI app calls `POST /api/v1/pairing/challenges` with a
   bounded device name, platform `ios`, and client version.
2. The server returns a random opaque challenge handle, a separate 256-bit poll
   secret, a uniformly generated six-digit code including leading zeroes, a
   five-minute expiry, and a two-second minimum poll interval. The code is
   regenerated on collision so it is unique among active challenges.
3. The app displays the six-digit code. The user signs in to the web settings
   page and enters that code under **Pair device**.
4. The cookie-authenticated, CSRF-protected
   `POST /api/v1/pairing/approve` binds the challenge to the currently signed-in
   account. An administrator pairing their own device follows the same flow;
   an administrator cannot silently pair a device as another user.
5. The app polls `POST /api/v1/pairing/token` with the challenge handle and poll
   secret. Before approval it receives `authorization_pending`. After approval
   it receives device credentials exactly once, and the challenge is consumed.

Pairing challenges and six-digit codes are memory-only. A restart invalidates
them. Only SHA-256 digests of high-entropy challenge poll secrets are retained
while active, and audit events never include the code or secret. Challenge
creation is limited to three active challenges per source and ten creations per
source in ten minutes.

Codes expire after five minutes and are single-use. Approval attempts are
limited to five per authenticated session in five minutes and ten per source in
ten minutes, followed by a 15-minute lock. Challenge polling faster than the
advertised interval returns `slow_down`; repeated abuse invalidates the
challenge. Concurrent approval or token claims can produce exactly one
successful consumption.

The paired device links to its account rather than receiving a copied role.
Later account disablement, role changes, or `can_transmit` changes therefore
apply without re-pairing.

## 8. iOS Credentials and Keychain Handling

Successful pairing returns:

- a stable random `device_id`;
- an opaque 256-bit access credential valid for 15 minutes;
- an opaque 256-bit refresh credential valid for 30 days;
- expiry timestamps; and
- the current effective role and transmit permission for display.

The access credential is kept in memory. The refresh credential and device ID
are stored in iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
The app never stores the user's password. Backgrounding immediately releases
PTT, stops microphone uplink, and closes transmit media state before normal iOS
suspension; foregrounding refreshes credentials as required.

A device WebSocket cannot outlive the access credential used to authenticate
it. The server emits `auth.expiring` shortly before expiry, and the app obtains
rotated credentials over HTTPS and reconnects. Expiry closes the old socket
even if it is otherwise healthy.

Only SHA-256 digests of high-entropy device credentials are stored server-side.
Every refresh rotates both access and refresh credentials in one transaction.
Reuse of an already-rotated refresh credential is treated as theft: all
credentials for that device are revoked and its live connections are closed.

An account owner may name and revoke their own device. An administrator may
revoke any device. Revocation first forces PTT off and terminates transmit
media, then invalidates credentials and closes the WebSocket. Deleting or
disabling an account performs the same operation for all owned devices.

## 9. HTTP API Boundary

The account service extends the existing fixed-asset HTTP listener with a
strict `/api/v1` router. It does not become a general filesystem or application
server.

| Endpoint | Authentication | Purpose |
|---|---|---|
| `GET /api/v1/setup/status` | None | Report only whether initialization is required |
| `POST /api/v1/setup/initialize` | Setup code | Create the first administrator once |
| `POST /api/v1/session/login` | Username/password | Create browser session |
| `GET /api/v1/session` | Browser session | Return principal and CSRF token |
| `POST /api/v1/session/logout` | Browser session + CSRF | Revoke current session |
| `POST /api/v1/session/password` | Browser session + CSRF | Change own password |
| `GET/POST /api/v1/users` | Administrator + CSRF for POST | List/create accounts |
| `PATCH/DELETE /api/v1/users/{id}` | Administrator + CSRF | Modify/delete account |
| `POST /api/v1/users/{id}/password-reset` | Administrator + CSRF | Set temporary password |
| `GET /api/v1/devices` | Browser session | List own devices; admin may list all |
| `PATCH/DELETE /api/v1/devices/{id}` | Owner or administrator + CSRF | Rename/revoke a device |
| `GET /api/v1/sessions` | Administrator | List active browser/device sessions |
| `DELETE /api/v1/sessions/{id}` | Administrator + CSRF | Revoke a selected session |
| `GET /api/v1/audit` | Administrator | Read a bounded, cursor-paginated audit view |
| `POST /api/v1/pairing/challenges` | None, rate-limited | Begin iOS pairing |
| `POST /api/v1/pairing/approve` | Browser session + CSRF | Approve code for current account |
| `POST /api/v1/pairing/token` | Challenge handle + poll secret | Complete pairing once |
| `POST /api/v1/device/refresh` | Device refresh credential | Rotate credentials |

Errors use a consistent JSON envelope with a stable code and safe message.
Malformed requests return `400`, missing/invalid authentication `401`, valid
authentication without permission `403`, lifecycle conflicts `409`, expired or
consumed credentials `410`, and throttling `429`. Secret-bearing responses use
`Cache-Control: no-store` and `Referrer-Policy: no-referrer`.

## 10. WebSocket Authentication and Protocol Versioning

Both clients negotiate WebSocket subprotocol `remote-radio.v1`. Unsupported or
missing versions are rejected before control messages are accepted.

The browser authenticates during the WebSocket upgrade with its secure session
cookie and an allowed `Origin`. SwiftUI sends one strict first message using its
short-lived access credential:

```json
{
  "type": "auth.device",
  "protocol_version": 1,
  "device_id": "<opaque-id>",
  "access_token": "<opaque-secret>"
}
```

Success returns the same principal shape to either client:

```json
{
  "type": "auth.ok",
  "protocol_version": 1,
  "principal": {
    "user_id": "<opaque-id>",
    "device_id": "<opaque-id-or-null>",
    "role": "operator",
    "can_transmit": false
  }
}
```

After authentication, browser and SwiftUI use the same strict rig, PTT, audio,
FT8, tuner, state, and error messages. A shared set of canonical JSON fixtures
is consumed by Python tests, Node tests, and XCTest so field names, numeric
units, nullability, and error codes cannot drift.

`Principal` is expanded from `device_id/is_admin` to immutable `user_id`,
`client_id`, optional `device_id`, `role`, effective `can_transmit`,
authentication kind, and authorization revision. Administrative raw Hamlib
commands require `role=admin`; transmit entry points require effective transmit
permission. PTT lease ownership uses the connection-scoped `client_id`, not a
user-supplied device identifier.

## 11. Immediate Revocation and Live Connections

The authentication service maintains an active-connection registry indexed by
user, device, and browser session. Each account has a monotonic authorization
revision. Account or permission updates commit first, increment that revision,
and then notify the registry.

Safety-sensitive order is mandatory when access is reduced:

1. reject new transmit operations;
2. force PTT off and stop microphone/FT8/tuner transmit activity;
3. invalidate the PTT lease;
4. revoke affected browser/device credentials; and
5. send `auth.revoked` when possible and close affected sockets with policy
   code `1008`.

Every inbound WebSocket message compares the connection revision with the
current in-memory account revision before dispatch, except that a strictly
validated PTT-off from the current lease owner is always allowed to reach the
safety supervisor. Every transmit-on entry point checks again immediately
before the safety/hardware action. Thus a cached principal cannot act during
the short interval between the database commit and socket closure, while no
authorization transition can prevent de-key.

Session expiry, logout, refresh-token reuse, password change/reset, account
disable/delete, device revocation, and removal of `can_transmit` all follow this
path. Existing disconnect cleanup remains a final independent de-key defense.

## 12. Persistence and Audit

The production data directory defaults to `/opt/testradio/data` on Debian and
is configurable only so tests can use an owned temporary directory. The data
directory is mode `0700`; `remote-radio.sqlite3` and its SQLite sidecar files
and the CSRF HMAC key are mode `0600`. Schema migrations are numbered,
transactional, and refuse to run against an unknown newer schema. Connections
enable foreign keys, a bounded busy timeout, and WAL mode. Blocking SQLite and
Argon2 work runs outside the asyncio event loop through bounded worker
execution.

The schema has focused tables for users, browser sessions, devices, access
credentials, refresh-credential rotation, login throttles, schema metadata, and
audit events. Pairing challenges are not persisted.

Audit events are append-only through the application service and record UTC
time, action, result, actor user/device/session identifiers, target identifier,
source address, and bounded non-secret metadata. They cover:

- setup and login success/failure/throttling;
- account creation, role/permission change, disable, reset, and deletion;
- pairing challenge creation, approval, expiry, completion, and abuse lock;
- browser session, device, and credential revocation;
- all PTT lease/state/trip events; and
- FT8, audio-uplink, and tuner transmit authorization outcomes.

Passwords, cookies, CSRF secrets, setup/pairing codes, and access/refresh
credentials are structurally excluded from audit payloads. The first slice
does not automatically delete audit history.

## 13. Component Boundaries and Migration

Add a focused `remote_radio_server.auth` package:

- repository: schema, transactions, and typed persistence records;
- passwords: normalization, policy, Argon2id verification, and rehashing;
- service: setup, login, account lifecycle, permissions, and revocation;
- sessions: browser and device credential issuance/rotation;
- pairing: memory-only challenge state machine and throttling;
- middleware/authorizer: HTTP and WebSocket principal construction; and
- audit: typed secret-free security events.

The HTTP router owns request parsing, cookie/CSRF handling, and response
serialization but delegates policy to the authentication service. The rig
gateway accepts only a validated `Principal` and never parses passwords or
tokens.

The production path removes `_DeviceAuthorizer` and the startup token from
public account mode. A dependency-injected in-memory authorizer may remain in
isolated unit tests and the separately labeled legacy `--public-dummy-test`
acceptance path, but no account-mode CLI option may activate it or bypass the
database authorizer. Web UI migration removes the token input and
`sessionStorage` handling from account mode, replacing them with
setup/login/settings views and cookie-authenticated WebSocket startup.

Existing rig control, PTT safety, and public-Dummy tests are adapted rather than
discarded. Authentication does not make hardware TX available. The official
Dummy can enable simulated PTT only after model `1` identity verification; any
real or ambiguous backend remains transmit-locked.

## 14. Error and Failure Behavior

- Database or migration failure prevents authenticated listeners from opening.
- TLS policy failure on non-loopback prevents password/pairing listeners from
  opening.
- Authentication-store loss never falls back to a startup token.
- Expired browser sessions and access credentials cannot reconnect.
- A failed audit write blocks account, credential-issuance, and transmit-on
  mutations rather than performing them unaudited. Emergency PTT-off,
  permission reduction, and credential revocation always proceed; their audit
  failure is latched and reported but can never delay de-key.
- Pairing approval after expiry or consumption returns the same safe terminal
  response.
- Refresh rotation is atomic; a response loss may require re-pairing but cannot
  leave two valid refresh credentials.
- Closing a revoked socket is best-effort, while PTT-off and credential
  invalidation are authoritative server operations.
- Client permission displays are advisory and are refreshed after login,
  pairing, token refresh, and every WebSocket authentication.

## 15. Testing and Acceptance

Implementation follows test-driven development with a fake clock and injected
random-secret source where deterministic behavior is required.

### Unit tests

- username normalization, password length/blocklist policy, Argon2id parameters,
  dummy-hash verification, and transparent rehash;
- schema migration, uniqueness, tombstones, final-administrator invariants, and
  rollback on partial failure;
- browser session idle/absolute expiry, cookie attributes, Origin checks, CSRF,
  logout, and digest-only storage;
- pairing leading zeroes, five-minute expiry, one-time consumption, poll
  throttling, approval limits, restart invalidation, and concurrent races;
- access/refresh expiry, atomic rotation, reuse detection, and revocation;
- the exact `admin`/`operator` matrix and operator `can_transmit` gates; and
- structural audit redaction for every secret-bearing input.

### Integration tests

- fresh-database setup creates exactly one administrator and a second attempt
  cannot initialize again;
- administrator account create/list/update/disable/reset/delete works, while an
  operator and the final-administrator guard reject forbidden mutations;
- unknown-user, wrong-password, disabled-user, and deleted-user login responses
  are indistinguishable and rate-limited;
- browser cookie and iOS access credential produce the same WebSocket principal
  and post-authentication protocol behavior;
- account, session, device, password, and permission revocation close the right
  connections without affecting unrelated users;
- an operator without `can_transmit` cannot acquire PTT, publish microphone
  audio, transmit FT8, or start tuner-carrier operations even with handcrafted
  messages;
- granting `can_transmit` allows only simulated-device PTT through the existing
  lease/watchdog/SWR checks;
- removing `can_transmit` during simulated PTT forces immediate de-key before
  socket closure;
- refresh-token replay revokes the device; and
- protocol fixtures pass Python, browser/Node, and Swift decoding tests.

### Web acceptance

1. Initialize the first administrator on a fresh database.
2. Log in, reload, log out, and confirm the session secret never appears in
   JavaScript storage or URLs.
3. Create an operator without transmit permission and confirm there is no
   observer role option.
4. Change role/status/transmit permission and confirm the page reflects only
   server-confirmed state.
5. Approve, list, rename, and revoke a six-digit paired device.
6. Confirm account and device actions appear in the audit view without secrets.

### SwiftUI acceptance

1. On an iOS 17-or-newer device or simulator, request pairing and display a
   six-digit code.
2. Approve it in the web settings page and complete without copying a long
   token or entering an account password on iOS.
3. Restart the app and confirm Keychain-backed refresh restores the session.
4. Revoke the device and confirm reconnect/refresh fails and the app returns to
   pairing.
5. Background during simulated PTT and confirm the server de-keys.

Xcode build, signing, Keychain entitlement, and physical-device acceptance
require macOS/Xcode and cannot be certified from the current Windows/Debian
environment. Canonical protocol fixtures and server behavior are still tested
before that final platform pass.

### Debian acceptance boundary

All database, TLS test material, logs, and generated artifacts remain under
`/opt/testradio`. Acceptance must not modify or delete anything outside that
directory. It uses the in-process mock or verified official Hamlib Dummy only,
never a serial device, real radio, antenna, or RF path.

## 16. Completion Criteria

This authentication slice is complete when:

- a fresh install creates one administrator through a one-time setup code;
- administrators manage local accounts from settings with no observer role;
- browser password login uses revocable secure cookie sessions;
- SwiftUI pairs through a six-digit code and stores only silent high-entropy
  credentials in Keychain;
- role and transmit-permission changes apply to paired devices immediately;
- every PTT/audio/FT8/tuner transmit path is denied without effective transmit
  permission and remains subject to independent rig safety;
- revocation during simulated PTT forces de-key and terminates the connection;
- browser and SwiftUI pass the same versioned protocol fixtures; and
- all specified unit, integration, web, and available platform tests pass.

## 17. Security References

- OWASP Password Storage Cheat Sheet:

  https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
- NIST SP 800-63B, Passwords:

  https://pages.nist.gov/800-63-4/sp800-63b/passwords/
- NIST SP 800-63B, Session Management:

  https://pages.nist.gov/800-63-4/sp800-63b.html#sec5
