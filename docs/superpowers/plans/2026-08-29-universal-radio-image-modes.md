# Universal Radio Image Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver streaming SSTV receive/transmit and receive-only Radiofax with progressive rows, partial-image preservation, bounded storage, and confirmed dekey on every transmit exit.

**Architecture:** A pinned Rust 1.85+ helper embeds `rasterwave = 0.1.0` and communicates with Node using bounded newline-delimited JSON frames carrying base64 PCM or row bytes. Node owns helper supervision, authenticated upload/history APIs, shared media routing, websocket fan-out, and the existing transmit interlock. iOS assembles progressive rows into local image buffers and fetches completed originals on demand.

**Tech Stack:** Node.js 24.7.0, TypeScript 5.9, Rust 1.85+, Cargo, `rasterwave` 0.1.0 (MIT), node:test, Swift 5.9, SwiftUI, CoreGraphics

**Spec:** `docs/superpowers/specs/2026-08-29-universal-radio-platform-design.md`

## Global Constraints

- SSTV supports streaming RX and TX; Radiofax supports RX only in the product UI/protocol.
- Voice, FT8/FT4, SSTV TX, and tuner are mutually exclusive.
- SSTV TX cancellation, disconnect, helper failure, or EOF always uses the existing confirmed-dekey path.
- Partial SSTV/Radiofax images are preserved after signal loss or EOF.
- Uploads are JPEG/PNG only, at most 8 MiB compressed and 20 megapixels decoded.
- Progressive events carry bounded row/delta data; completed originals are fetched on demand and never rebroadcast to all clients.
- The Rust helper does not open radios/audio devices or key PTT.
- Node is pinned to 24.7.0; Debian is 13; iOS is 17+ with Swift 5.9.

## Ruling

The approved design mentioned a maintained Node binding and a prebuilt-first path. Authoritative Rasterwave 0.1.0 documentation exposes a Rust crate and describes Node worker integration as future work; no stable Node 24/Debian 13 npm binding is verified. This plan therefore uses a pinned Rust helper as the primary integration. If this ruling is wrong, the cost is an extra helper process and IPC overhead, not a loss of product capability.

---

### Task 1: Pinned Rasterwave helper and framed codec protocol

**Files:**
- Create: `radio-codec-helper/Cargo.toml`
- Create: `radio-codec-helper/Cargo.lock`
- Create: `radio-codec-helper/src/main.rs`
- Create: `radio-codec-helper/src/protocol.rs`
- Create: `radio-codec-helper/src/sstv.rs`
- Create: `radio-codec-helper/src/radiofax.rs`
- Create: `radio-codec-helper/tests/protocol.rs`
- Create: `radio-codec-helper/tests/sstv_roundtrip.rs`
- Create: `radio-codec-helper/tests/radiofax_partial.rs`

**Interfaces:**
- Helper commands are `decode-sstv`, `encode-sstv`, and `decode-radiofax`.
- stdin/stdout use one JSON object per line with a hard 1 MiB decoded-line limit.
- Input frames: `start`, `pcm` (`sampleRate`, `samplesBase64` little-endian signed 16-bit), `image` (normalized RGB bytes), `cancel`, `eof`.
- Output frames: `ready`, `state`, `row`, `pcm`, `complete`, `partial`, `error`.

- [ ] **Step 1: Write failing protocol/round-trip/partial tests**

```rust
#[test]
fn rejects_a_frame_over_one_mebibyte() {
    let input = vec![b'x'; 1_048_577];
    assert_eq!(read_bounded_line(&input[..]).unwrap_err().code(), "frame_too_large");
}

#[test]
fn sstv_round_trip_emits_progressive_rows() {
    let image = fixture_rgb_gradient(320, 256);
    let pcm = encode_sstv_fixture("MartinM1", &image).unwrap();
    let events = decode_sstv_fixture(&pcm).unwrap();
    assert!(events.iter().any(|event| matches!(event, Event::Row { row: 0, .. })));
    assert!(matches!(events.last(), Some(Event::Complete { .. })));
}

#[test]
fn radiofax_eof_preserves_partial_page() {
    let events = decode_radiofax_fixture(&fax_pcm_fixture()[..12_000]).unwrap();
    assert!(matches!(events.last(), Some(Event::Partial { .. })));
}
```

- [ ] **Step 2: Run and confirm missing crate failure**

Run: `cargo test --manifest-path radio-codec-helper/Cargo.toml`

Expected: FAIL because the helper crate does not exist.

- [ ] **Step 3: Implement the helper using the upstream streaming state machines**

Pin `rasterwave = "=0.1.0"`, `serde`, `serde_json`, `base64`, and `thiserror` in `Cargo.toml`; commit `Cargo.lock`. Convert only at the IPC boundary. Emit rows as soon as Rasterwave reports them, including revised row indices. Radiofax supports IOC 288/576, auto LPM 60/90/120/240, explicit 180, APT/phasing/dead-sector/stop state, and partial completion. Catch broken stdout and exit without touching any radio resource.

- [ ] **Step 4: Run helper tests and inspect licenses**

Run: `cargo test --manifest-path radio-codec-helper/Cargo.toml`

Run: `cargo tree --manifest-path radio-codec-helper/Cargo.toml`

Expected: tests exit 0 and dependency tree contains no copyleft codec dependency.

- [ ] **Step 5: Commit**

```bash
git add radio-codec-helper
git commit -m "feat: add Rasterwave image codec helper"
```

### Task 2: Node helper supervisor and bounded image storage

**Files:**
- Create: `radio-lite-server/src/image/codec-protocol.ts`
- Create: `radio-lite-server/src/image/codec-helper.ts`
- Create: `radio-lite-server/src/image/image-store.ts`
- Test: `radio-lite-server/test/codec-helper.test.ts`
- Test: `radio-lite-server/test/image-store.test.ts`

**Interfaces:**
- Produces `CodecHelperSession` with `writePcm`, `writeImage`, `finish`, `cancel`, async event subscription, and `close`.
- Produces `ImageStore` with atomic `begin`, `appendRows`, `complete`, `preservePartial`, `list`, `openOriginal`, and bounded thumbnail metadata.

- [ ] **Step 1: Write failing fake-process and filesystem behavior tests**

```ts
test("helper rejects oversized or malformed output and terminates the child", async () => {
  const session = fixture.session();
  fixture.child.stdout.write("x".repeat(1_048_577));
  await assert.rejects(session.finished, /codec frame too large/);
  assert.equal(fixture.child.terminated, true);
});

test("signal loss atomically preserves a partial page", async () => {
  const item = await store.begin({ radioId: "main", mode: "radiofax" });
  await store.appendRows(item.id, [{ index: 0, pixels: Uint8Array.of(0, 64, 255) }]);
  await store.preservePartial(item.id, "signal_lost");
  assert.equal((await store.list("main"))[0].status, "partial");
});
```

- [ ] **Step 2: Run and confirm missing modules**

Run: `node --experimental-strip-types --test test/codec-helper.test.ts test/image-store.test.ts`

Expected: FAIL because codec supervision/storage modules are absent.

- [ ] **Step 3: Implement bounded supervision and storage**

Spawn the configured helper binary with no shell, a fixed command allowlist, a minimal environment, stderr ring buffer, and startup/idle timeouts. Enforce the 1 MiB line bound in Node too. Store metadata and images beneath the configured Radio Lite data directory using temp-file plus rename. Keep only bounded thumbnails in list responses; sanitize every generated identifier and never accept a client filesystem path.

- [ ] **Step 4: Run checks and commit**

Run: `node --experimental-strip-types --test test/codec-helper.test.ts test/image-store.test.ts`

Run: `npm run check`

```bash
git add radio-lite-server/src/image/codec-protocol.ts radio-lite-server/src/image/codec-helper.ts radio-lite-server/src/image/image-store.ts radio-lite-server/test/codec-helper.test.ts radio-lite-server/test/image-store.test.ts
git commit -m "feat: supervise image codec sessions"
```

### Task 3: Shared RX sessions and progressive websocket protocol

**Files:**
- Create: `radio-lite-server/src/image/image-mode-controller.ts`
- Modify: `radio-lite-server/src/media/media-hub.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/PROTOCOL.md`
- Test: `radio-lite-server/test/image-mode-controller.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`

**Interfaces:**
- Produces one shared RX decoder session per `(radioId, mode)` and subscriber fan-out.
- Produces `image.mode.subscribe`, `image.mode.unsubscribe`, `image.rx.state`, `image.rx.rows`, and authenticated history/original HTTP reads.

- [ ] **Step 1: Write failing sharing/progression/partial tests**

```ts
test("two clients share one SSTV decoder", async () => {
  const first = controller.subscribe("main", "sstv", firstListener);
  const second = controller.subscribe("main", "sstv", secondListener);
  assert.equal(helperFactory.created, 1);
  media.emitPcm(pcmFrame);
  assert.deepEqual(firstListener.events, secondListener.events);
  first.close();
  second.close();
});

test("media EOF publishes and stores a partial radiofax page", async () => {
  controller.subscribe("main", "radiofax", listener);
  helper.emit({ type: "row", row: 3, pixelsBase64: "AAE=" });
  helper.emit({ type: "partial", reason: "signal_lost" });
  assert.equal(listener.events.at(-1)?.t, "image.rx.state");
  assert.equal((await store.list("main"))[0].status, "partial");
});
```

- [ ] **Step 2: Run and confirm missing controller/messages**

Run: `node --experimental-strip-types --test test/image-mode-controller.test.ts test/http-service.test.ts`

Expected: FAIL because shared image sessions/protocol do not exist.

- [ ] **Step 3: Implement shared capture and bounded events**

Feed the existing internal 12/16 kHz signed-16 PCM capture into the helper, resampling only once before fan-out. `image.rx.rows` carries session ID, dimensions, first row, row count, revision, encoding (`gray8` or `rgb8`), and base64 bytes capped below the control WebSocket payload limit. When the final subscriber leaves, finish the helper and preserve non-empty partial data.

- [ ] **Step 4: Run checks and commit**

Run: `node --experimental-strip-types --test test/image-mode-controller.test.ts test/http-service.test.ts`

Run: `npm run check`

```bash
git add radio-lite-server/src/image/image-mode-controller.ts radio-lite-server/src/media/media-hub.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/PROTOCOL.md radio-lite-server/test/image-mode-controller.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: stream SSTV and radiofax receive rows"
```

### Task 4: Bounded SSTV upload and confirmed-dekey transmit

**Files:**
- Create: `radio-lite-server/src/image/image-upload.ts`
- Modify: `radio-lite-server/src/image/image-mode-controller.ts`
- Modify: `radio-lite-server/src/server/radio-lite-service.ts`
- Modify: `radio-lite-server/src/media/media-hub.ts`
- Test: `radio-lite-server/test/image-upload.test.ts`
- Test: `radio-lite-server/test/image-mode-controller.test.ts`
- Test: `radio-lite-server/test/http-service.test.ts`

**Interfaces:**
- Produces bearer-authenticated `POST /api/v1/radios/:radioId/image-transmissions` for JPEG/PNG and returns an opaque `imageId`.
- Produces `image.tx.prepare`, `image.tx.start`, `image.tx.stop`, and progress/state events.
- Uses `RadioRuntime.startTransmit(..., "sstv")` and existing `stopTransmitOutcome`/supervisor cleanup.

- [ ] **Step 1: Write failing validation, exclusivity, cancel, and disconnect tests**

```ts
test("rejects compressed or decoded image limits before codec start", async () => {
  assert.equal((await upload(oversizedPng)).statusCode, 413);
  assert.equal(helperFactory.created, 0);
});

test("SSTV cancel waits for confirmed PTT OFF", async () => {
  await controller.startSstvTx(request);
  const stopping = controller.stopSstvTx(request.ownerId);
  assert.equal(driver.writePttCalls.at(-1), false);
  driver.confirmPtt(false);
  await stopping;
  assert.equal(controller.txState.kind, "idle");
});

test("owner disconnect cannot leave SSTV keyed", async () => {
  await controller.startSstvTx(request);
  await controller.ownerDisconnected(request.ownerId);
  assert.equal(await driver.readPtt(), false);
});
```

- [ ] **Step 2: Run and confirm missing upload/TX behavior**

Run: `node --experimental-strip-types --test test/image-upload.test.ts test/image-mode-controller.test.ts test/http-service.test.ts`

Expected: FAIL because upload and SSTV TX do not exist.

- [ ] **Step 3: Implement normalized upload and digital transmit ownership**

Stream-limit request bodies to 8 MiB, accept only signature-confirmed PNG/JPEG, decode dimensions before full allocation, reject above 20 megapixels, strip metadata, and normalize to the selected SSTV mode dimensions. The codec PCM sink uses the same digital transmit path as FT8 and is mutually exclusive with every other TX mode. All termination paths call the existing confirmed-dekey logic; a failed confirmation latches recovery rather than reporting idle.

- [ ] **Step 4: Run checks and commit**

Run: `node --experimental-strip-types --test test/image-upload.test.ts test/image-mode-controller.test.ts test/http-service.test.ts`

Run: `npm run check`

```bash
git add radio-lite-server/src/image/image-upload.ts radio-lite-server/src/image/image-mode-controller.ts radio-lite-server/src/server/radio-lite-service.ts radio-lite-server/src/media/media-hub.ts radio-lite-server/test/image-upload.test.ts radio-lite-server/test/image-mode-controller.test.ts radio-lite-server/test/http-service.test.ts
git commit -m "feat: transmit SSTV with confirmed dekey"
```

### Task 5: iOS progressive SSTV/Radiofax UI and history

**Files:**
- Create: `ios/RadioLite/Core/RadioLite/RadioLiteImageModes.swift`
- Create: `ios/RadioLite/Features/RadioLite/RadioLiteSSTVView.swift`
- Create: `ios/RadioLite/Features/RadioLite/RadioLiteRadiofaxView.swift`
- Create: `ios/RadioLite/Features/RadioLite/RadioLiteImageHistoryView.swift`
- Modify: `ios/RadioLite/Core/RadioLite/RadioLiteSession.swift`
- Modify: `ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift`
- Modify: `scripts/check-ios-radio-lite-contract.mjs`
- Test: `ios/RadioLiteTests/RadioLiteImageModesTests.swift`
- Test: `ios/RadioLiteTests/RadioLiteImageHistoryTests.swift`

**Interfaces:**
- Consumes image RX/TX websocket events plus upload/history/original HTTP APIs.
- Produces progressive row assembly with revision replacement, SSTV picker/upload/TX/cancel, receive-only Radiofax controls, and bounded thumbnail history.

- [ ] **Step 1: Write failing row assembly/state tests and contract fixtures**

```swift
func testRevisedRowsReplaceEarlierPixels() throws {
    var image = RadioLiteProgressiveImage(width: 2, height: 2, format: .gray8)
    try image.apply(firstRow: 0, rowCount: 1, revision: 1, bytes: [0, 64])
    try image.apply(firstRow: 0, rowCount: 1, revision: 2, bytes: [128, 255])
    XCTAssertEqual(image.bytes.prefix(2), [128, 255])
}

func testRadiofaxExposesNoTransmitAction() {
    XCTAssertFalse(RadioLiteImageMode.radiofax.supportsTransmit)
}
```

Extend the executable contract script for every image message and HTTP response field.

- [ ] **Step 2: Run and confirm missing model failures**

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Expected: FAIL because image-mode models/messages are absent.

- [ ] **Step 3: Implement views and session lifecycle**

Subscribe only while the selected mode view is active; preserve a partial local image through transient reconnect; replace revised rows by revision; discard out-of-bounds/oversized events. SSTV TX requires the control lease and displays prepare/keying/sending/dekeying/recovery states. Radiofax displays IOC, LPM, acquisition, partial/completed state and never renders TX controls. Fetch originals only on user selection.

- [ ] **Step 4: Run contract/server checks and commit**

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Run: `npm run check` from `radio-lite-server`

```bash
git add ios/RadioLite/Core/RadioLite/RadioLiteImageModes.swift ios/RadioLite/Features/RadioLite/RadioLiteSSTVView.swift ios/RadioLite/Features/RadioLite/RadioLiteRadiofaxView.swift ios/RadioLite/Features/RadioLite/RadioLiteImageHistoryView.swift ios/RadioLite/Core/RadioLite/RadioLiteSession.swift ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift ios/RadioLiteTests/RadioLiteImageModesTests.swift ios/RadioLiteTests/RadioLiteImageHistoryTests.swift scripts/check-ios-radio-lite-contract.mjs
git commit -m "feat: add progressive SSTV and radiofax UI"
```

### Task 6: Image-mode slice verification

**Files:**
- Modify: `radio-lite-server/PROTOCOL.md`
- Modify: `radio-codec-helper/README.md`

- [ ] **Step 1: Run complete Rust, server, web, and contract gates**

Run: `cargo test --manifest-path radio-codec-helper/Cargo.toml`

Run: `npm run check` from `radio-lite-server`

Run: `npm test` from `web`

Run: `node scripts/check-ios-radio-lite-contract.mjs`

Expected: all exit 0.

- [ ] **Step 2: Verify safety and partial-page acceptance evidence**

Confirm fresh output includes SSTV round-trip progressive rows, Radiofax EOF partial preservation, upload limits, mutually exclusive transmit admission, cancel dekey confirmation, disconnect dekey confirmation, and two-client shared RX.

- [ ] **Step 3: Document build/runtime contract and commit**

Document Rust 1.85+ build, helper binary discovery, bounded NDJSON protocol, data directory layout, and MIT upstream attribution.

```bash
git add radio-lite-server/PROTOCOL.md radio-codec-helper/README.md
git commit -m "docs: describe image codec integration"
```
