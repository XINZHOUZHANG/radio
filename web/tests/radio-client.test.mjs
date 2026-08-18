import test from "node:test";
import assert from "node:assert/strict";

import {
  deriveWebSocketUrl,
  RadioClient,
  reconnectDelayMs,
} from "../radio-client.js";


class FakeWebSocket {
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.sent = [];
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
  }

  open() {
    this.readyState = 1;
    this.onopen?.({});
  }

  send(wire) {
    if (this.readyState !== 1) {
      throw new Error("socket is not open");
    }
    this.sent.push(JSON.parse(wire));
  }

  message(document) {
    this.onmessage?.({ data: JSON.stringify(document) });
  }

  malformedMessage(text = "not-json") {
    this.onmessage?.({ data: text });
  }

  serverClose(code = 1006) {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.onclose?.({ code });
  }

  close(code = 1000) {
    this.serverClose(code);
  }
}


class FakeTimers {
  constructor() {
    this.nextId = 1;
    this.timeouts = [];
    this.intervals = [];
  }

  setTimeout(fn, delay) {
    const timer = { id: this.nextId++, fn, delay, active: true };
    this.timeouts.push(timer);
    return timer.id;
  }

  clearTimeout(id) {
    const timer = this.timeouts.find((item) => item.id === id);
    if (timer) timer.active = false;
  }

  setInterval(fn, delay) {
    const timer = { id: this.nextId++, fn, delay, active: true };
    this.intervals.push(timer);
    return timer.id;
  }

  clearInterval(id) {
    const timer = this.intervals.find((item) => item.id === id);
    if (timer) timer.active = false;
  }

  activeTimeout(delay) {
    return this.timeouts.find(
      (timer) => timer.active && (delay === undefined || timer.delay === delay),
    );
  }

  fireTimeout(timer) {
    assert.ok(timer?.active, "expected an active timeout");
    timer.active = false;
    timer.fn();
  }

  activeInterval(delay) {
    return this.intervals.find(
      (timer) => timer.active && (delay === undefined || timer.delay === delay),
    );
  }
}


function makeHarness({ ids = ["request-1", "request-2"] } = {}) {
  const sockets = [];
  const timers = new FakeTimers();
  const states = [];
  const capabilities = [];
  const snapshots = [];
  const commandResults = [];
  const authenticationFailures = [];
  let idIndex = 0;
  const client = new RadioClient({
    url: "ws://10.0.0.8:8765/radio",
    deviceId: "web-test",
    token: "secret",
    socketFactory: (url) => {
      const socket = new FakeWebSocket(url);
      sockets.push(socket);
      return socket;
    },
    setTimeoutFn: timers.setTimeout.bind(timers),
    clearTimeoutFn: timers.clearTimeout.bind(timers),
    setIntervalFn: timers.setInterval.bind(timers),
    clearIntervalFn: timers.clearInterval.bind(timers),
    idFactory: () => ids[idIndex++],
    onConnectionState: (state) => states.push(state),
    onCapabilities: (event) => capabilities.push(event),
    onSnapshot: (event) => snapshots.push(event),
    onCommandResult: (event) => commandResults.push(event),
    onAuthenticationFailed: () => authenticationFailures.push(true),
  });
  return {
    client,
    sockets,
    timers,
    states,
    capabilities,
    snapshots,
    commandResults,
    authenticationFailures,
  };
}


function connectReady(harness) {
  harness.client.connect();
  const socket = harness.sockets.at(-1);
  socket.open();
  socket.message({ type: "auth.ok", device_id: "web-test" });
  return socket;
}


test("derives ws and wss URLs from the page host", () => {
  assert.equal(
    deriveWebSocketUrl({ protocol: "http:", hostname: "10.0.0.8" }),
    "ws://10.0.0.8:8765/radio",
  );
  assert.equal(
    deriveWebSocketUrl({ protocol: "https:", hostname: "radio.example" }),
    "wss://radio.example:8765/radio",
  );
});


test("reconnect delay is bounded at five seconds", () => {
  assert.deepEqual(
    [0, 1, 2, 3, 4, 8].map(reconnectDelayMs),
    [500, 1000, 2000, 4000, 5000, 5000],
  );
});


test("authenticates before requesting capabilities and polling snapshots", () => {
  const harness = makeHarness();

  harness.client.connect();
  const socket = harness.sockets[0];
  assert.equal("ws://10.0.0.8:8765/radio", socket.url);
  assert.deepEqual(harness.states, ["connecting"]);
  assert.deepEqual(socket.sent, []);

  socket.open();
  assert.deepEqual(harness.states, ["connecting", "authenticating"]);
  assert.deepEqual(socket.sent, [
    { type: "auth", device_id: "web-test", token: "secret" },
  ]);

  socket.message({ type: "auth.ok", device_id: "web-test" });
  assert.deepEqual(harness.states, ["connecting", "authenticating", "ready"]);
  assert.deepEqual(socket.sent.slice(1), [
    { type: "rig.capabilities" },
    { type: "rig.snapshot" },
  ]);

  const poll = harness.timers.activeInterval(500);
  assert.ok(poll);
  poll.fn();
  assert.deepEqual(socket.sent.at(-1), { type: "rig.snapshot" });
});


test("correlates command results, times out requests, and exposes no PTT API", () => {
  const harness = makeHarness({ ids: ["freq-1", "mode-2"] });
  const socket = connectReady(harness);

  assert.equal("freq-1", harness.client.setFrequency(7_074_000));
  assert.equal("mode-2", harness.client.setMode("USB", 2400));
  assert.deepEqual(socket.sent.slice(-2), [
    {
      type: "rig.command",
      request_id: "freq-1",
      command: "set_frequency",
      frequency_hz: 7_074_000,
    },
    {
      type: "rig.command",
      request_id: "mode-2",
      command: "set_mode",
      mode: "USB",
      passband_hz: 2400,
    },
  ]);

  socket.message({
    type: "rig.command_result",
    request_id: "unknown",
    command: "set_frequency",
    status: "confirmed",
    message: "ignored",
  });
  assert.deepEqual(harness.commandResults, []);

  const confirmed = {
    type: "rig.command_result",
    request_id: "freq-1",
    command: "set_frequency",
    status: "confirmed",
    message: "frequency confirmed",
    revision: 4,
  };
  socket.message(confirmed);
  assert.deepEqual(harness.commandResults, [confirmed]);

  harness.timers.fireTimeout(harness.timers.activeTimeout(3000));
  assert.deepEqual(harness.commandResults.at(-1), {
    type: "rig.command_result",
    request_id: "mode-2",
    command: "set_mode",
    status: "timeout",
    message: "request timed out",
  });
  socket.message({
    type: "rig.command_result",
    request_id: "mode-2",
    command: "set_mode",
    status: "confirmed",
    message: "late",
  });
  assert.equal(2, harness.commandResults.length);

  assert.throws(() => harness.client.setFrequency(true), /frequency/i);
  assert.throws(() => harness.client.setMode(" ", 2400), /mode/i);
  assert.throws(() => harness.client.setMode("USB", -1), /passband/i);
  assert.equal("undefined", typeof harness.client.setPtt);
});


test("ignores stale snapshots and malformed server messages", () => {
  const harness = makeHarness();
  const socket = connectReady(harness);
  const snapshot = (revision) => ({
    type: "rig.snapshot",
    revision,
    lifecycle: "ready",
    frequency_hz: 14_074_000,
    mode: "USB",
    meters: {},
  });

  socket.message(snapshot(9));
  socket.message(snapshot(8));
  socket.malformedMessage();
  socket.message(snapshot(10));

  assert.deepEqual(
    harness.snapshots.map((event) => event.revision),
    [9, 10],
  );
});


test("maps only a correlated server error to the pending command", () => {
  const harness = makeHarness({ ids: ["freq-error"] });
  const socket = connectReady(harness);
  harness.client.setFrequency(7_074_000);

  socket.message({
    type: "error",
    code: "not_ready",
    message: "rig session changed",
    request_id: "different-request",
  });
  assert.deepEqual(harness.commandResults, []);

  socket.message({
    type: "error",
    code: "not_ready",
    message: "rig session changed",
    request_id: "freq-error",
  });
  assert.deepEqual(harness.commandResults, [
    {
      type: "rig.command_result",
      request_id: "freq-error",
      command: "set_frequency",
      status: "error",
      message: "rig session changed",
      code: "not_ready",
    },
  ]);
  assert.equal(undefined, harness.timers.activeTimeout(3000));
});


test("rejects duplicate and oversized UTF-8 request IDs before sending", () => {
  const duplicate = makeHarness({ ids: ["same-id", "same-id"] });
  const duplicateSocket = connectReady(duplicate);
  duplicate.client.setFrequency(7_074_000);
  const sentBeforeDuplicate = duplicateSocket.sent.length;

  assert.throws(
    () => duplicate.client.setMode("USB", 2400),
    /request ID must be unique/i,
  );
  assert.equal(sentBeforeDuplicate, duplicateSocket.sent.length);

  const oversized = makeHarness({ ids: ["é".repeat(65)] });
  const oversizedSocket = connectReady(oversized);
  const sentBeforeOversized = oversizedSocket.sent.length;
  assert.throws(
    () => oversized.client.setFrequency(7_074_000),
    /128 UTF-8 bytes/i,
  );
  assert.equal(sentBeforeOversized, oversizedSocket.sent.length);
});


test("reconnects with increasing delays and explicit disconnect cancels retry", () => {
  const harness = makeHarness();
  const first = connectReady(harness);

  first.serverClose(1006);
  assert.equal("reconnecting", harness.states.at(-1));
  const firstRetry = harness.timers.activeTimeout(500);
  harness.timers.fireTimeout(firstRetry);
  assert.equal(2, harness.sockets.length);
  assert.equal("connecting", harness.states.at(-1));

  harness.sockets[1].serverClose(1006);
  assert.equal("reconnecting", harness.states.at(-1));
  assert.ok(harness.timers.activeTimeout(1000));

  harness.client.disconnect();
  assert.equal("disconnected", harness.states.at(-1));
  assert.equal(undefined, harness.timers.activeTimeout());
});


test("authentication policy close clears credentials and does not reconnect", () => {
  const harness = makeHarness();
  harness.client.connect();
  const socket = harness.sockets[0];
  socket.open();

  socket.serverClose(1008);

  assert.deepEqual(harness.authenticationFailures, [true]);
  assert.equal("disconnected", harness.states.at(-1));
  assert.equal(undefined, harness.timers.activeTimeout());
  assert.throws(() => harness.client.connect(), /token/i);
});
