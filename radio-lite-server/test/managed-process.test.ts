import assert from "node:assert/strict";
import { type ChildProcess, type spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { type AddressInfo, createServer } from "node:net";
import { PassThrough } from "node:stream";
import { setImmediate as nextTurn } from "node:timers/promises";
import { test } from "node:test";

import {
  ManagedRigctldProcess,
  type ManagedRigctldExit,
} from "../src/rig/managed-process.ts";

test("managed rigctld startup failure waits for the killed child to exit", async () => {
  const child = new EventEmitter() as ChildProcess;
  Object.assign(child, {
    pid: 12_345,
    exitCode: null,
    signalCode: null,
    stderr: new PassThrough(),
  });
  const killed = deferred<void>();
  child.kill = ((signal?: NodeJS.Signals | number) => {
    if (signal === "SIGKILL") {
      killed.resolve();
    }
    return true;
  }) as ChildProcess["kill"];
  const spawnProcess = (() => {
    setImmediate(() => child.emit("error", new Error("spawn failed")));
    return child;
  }) as typeof spawn;
  const process = new ManagedRigctldProcess(
    { executable: "rigctld", args: [], host: "127.0.0.1", port: 65_534 },
    { spawnProcess, startupTimeoutMs: 1_000, stopTimeoutMs: 1_000 },
  );

  const starting = process.start();
  let settled = false;
  void starting.then(
    () => { settled = true; },
    () => { settled = true; },
  );
  await killed.promise;
  await nextTurn();
  assert.equal(settled, false, "startup must keep the serial reservation until process exit");

  Object.assign(child, { signalCode: "SIGKILL" });
  child.emit("exit", null, "SIGKILL");
  await assert.rejects(starting, /unable to start rigctld: spawn failed/u);
});

test("managed rigctld retains an unconfirmed child so cleanup can be retried", async () => {
  const child = new EventEmitter() as ChildProcess;
  Object.assign(child, {
    pid: 54_321,
    exitCode: null,
    signalCode: null,
    stderr: new PassThrough(),
  });
  const signals: Array<NodeJS.Signals | number | undefined> = [];
  child.kill = ((signal?: NodeJS.Signals | number) => {
    signals.push(signal);
    if (signals.length === 2) {
      setImmediate(() => {
        Object.assign(child, { signalCode: "SIGTERM" });
        child.emit("exit", null, "SIGTERM");
      });
    }
    return true;
  }) as ChildProcess["kill"];
  const spawnProcess = (() => {
    setImmediate(() => child.emit("error", new Error("spawn failed")));
    return child;
  }) as typeof spawn;
  const process = new ManagedRigctldProcess(
    { executable: "rigctld", args: [], host: "127.0.0.1", port: 65_533 },
    { spawnProcess, startupTimeoutMs: 1_000, stopTimeoutMs: 10 },
  );

  await assert.rejects(process.start(), /did not exit after startup failure/u);
  await assert.rejects(
    process.start(),
    /cleanup is required/u,
    "an unconfirmed startup child must never be reported ready",
  );
  await process.close();

  assert.deepEqual(signals, ["SIGKILL", "SIGTERM"]);
});

test("unexpected managed rigctld exit is generation tagged and reported once", async () => {
  await withListeningServer(async (port) => {
    const first = fakeChild(101);
    const second = fakeChild(102);
    const children = [first, second];
    const exits: ManagedRigctldExit[] = [];
    const spawnProcess = (() => children.shift()!) as typeof spawn;
    const process = new ManagedRigctldProcess(
      { executable: "rigctld", args: [], host: "127.0.0.1", port },
      {
        spawnProcess,
        startupTimeoutMs: 1_000,
        stopTimeoutMs: 1_000,
        onUnexpectedExit: (exit) => exits.push(exit),
      },
    );

    await process.start();
    first.stderr?.emit("data", Buffer.from("first crash"));
    Object.assign(first, { exitCode: 17 });
    first.emit("exit", 17, null);
    first.emit("exit", 17, null);

    assert.deepEqual(exits, [{
      generation: 1,
      exitCode: 17,
      signalCode: null,
      stderr: "first crash",
    }]);

    await process.start();
    first.emit("exit", 17, null);
    assert.equal(exits.length, 1, "a duplicate old-generation exit must be ignored");

    const secondSignals: Array<NodeJS.Signals | number | undefined> = [];
    second.kill = ((signal?: NodeJS.Signals | number) => {
      secondSignals.push(signal);
      Object.assign(second, { signalCode: signal as NodeJS.Signals });
      second.emit("exit", null, signal);
      return true;
    }) as ChildProcess["kill"];
    await process.close();
    assert.deepEqual(secondSignals, ["SIGTERM"]);
    assert.equal(exits.length, 1, "an old exit must not detach the active generation");
  });
});

test("concurrent managed starts share readiness instead of returning early", async () => {
  const reservation = createServer();
  await listen(reservation, 0);
  const port = (reservation.address() as AddressInfo).port;
  await closeServer(reservation);

  const child = fakeChild(151);
  child.kill = ((signal?: NodeJS.Signals | number) => {
    Object.assign(child, { signalCode: signal as NodeJS.Signals });
    child.emit("exit", null, signal);
    return true;
  }) as ChildProcess["kill"];
  const process = new ManagedRigctldProcess(
    { executable: "rigctld", args: [], host: "127.0.0.1", port },
    {
      spawnProcess: (() => child) as typeof spawn,
      startupTimeoutMs: 1_000,
      stopTimeoutMs: 1_000,
    },
  );

  const first = process.start();
  const second = process.start();
  let secondSettled = false;
  void second.finally(() => { secondSettled = true; });
  await nextTurn();
  assert.equal(secondSettled, false, "a concurrent start must await the active readiness check");

  const listener = createServer((socket) => socket.end());
  await listen(listener, port);
  try {
    await Promise.all([first, second]);
  } finally {
    await process.close();
    await closeServer(listener);
  }
});

test("exit before managed readiness is a startup failure, not a recovery trigger", async () => {
  const child = fakeChild(181);
  let unexpectedExits = 0;
  const process = new ManagedRigctldProcess(
    { executable: "rigctld", args: [], host: "127.0.0.1", port: 65_531 },
    {
      spawnProcess: (() => {
        setImmediate(() => {
          Object.assign(child, { exitCode: 23 });
          child.emit("exit", 23, null);
        });
        return child;
      }) as typeof spawn,
      startupTimeoutMs: 1_000,
      stopTimeoutMs: 1_000,
      onUnexpectedExit: () => { unexpectedExits += 1; },
    },
  );

  await assert.rejects(process.start(), /exited during startup/u);
  assert.equal(unexpectedExits, 0);
});

test("post-readiness child errors are observed without an uncaught EventEmitter error", async () => {
  await withListeningServer(async (port) => {
    const child = fakeChild(191);
    child.kill = ((signal?: NodeJS.Signals | number) => {
      Object.assign(child, { signalCode: signal as NodeJS.Signals });
      child.emit("exit", null, signal);
      return true;
    }) as ChildProcess["kill"];
    const process = new ManagedRigctldProcess(
      { executable: "rigctld", args: [], host: "127.0.0.1", port },
      {
        spawnProcess: (() => child) as typeof spawn,
        startupTimeoutMs: 1_000,
        stopTimeoutMs: 1_000,
      },
    );

    await process.start();
    assert.doesNotThrow(() => child.emit("error", new Error("late child error")));
    await process.close();
  });
});

test("start during managed close rejects and cannot leak a queued generation", async () => {
  await withListeningServer(async (port) => {
    const first = fakeChild(211);
    const second = fakeChild(212);
    const children = [first, second];
    const signals: string[] = [];
    first.kill = ((signal?: NodeJS.Signals | number) => {
      signals.push(`first:${String(signal)}`);
      return true;
    }) as ChildProcess["kill"];
    second.kill = ((signal?: NodeJS.Signals | number) => {
      signals.push(`second:${String(signal)}`);
      Object.assign(second, { signalCode: signal as NodeJS.Signals });
      second.emit("exit", null, signal);
      return true;
    }) as ChildProcess["kill"];
    const process = new ManagedRigctldProcess(
      { executable: "rigctld", args: [], host: "127.0.0.1", port },
      {
        spawnProcess: (() => children.shift()!) as typeof spawn,
        startupTimeoutMs: 1_000,
        stopTimeoutMs: 1_000,
      },
    );
    await process.start();

    const closing = process.close();
    const restarting = process.start();
    const repeatedClose = process.close();
    await assert.rejects(restarting, /close is in progress/u);
    assert.equal(children.length, 1, "a rejected restart must not queue another child");

    Object.assign(first, { signalCode: "SIGTERM" });
    first.emit("exit", null, "SIGTERM");
    await Promise.all([closing, repeatedClose]);

    await process.start();
    assert.equal(children.length, 0, "restart must spawn the next managed generation");
    await process.close();
    assert.deepEqual(signals, ["first:SIGTERM", "second:SIGTERM"]);
  });
});

test("managed close exit never restarts rigctld", async () => {
  await withListeningServer(async (port) => {
    const child = fakeChild(201);
    let recoveryStarts = 0;
    child.kill = ((signal?: NodeJS.Signals | number) => {
      Object.assign(child, { signalCode: signal as NodeJS.Signals });
      child.emit("exit", null, signal);
      return true;
    }) as ChildProcess["kill"];
    const process = new ManagedRigctldProcess(
      { executable: "rigctld", args: [], host: "127.0.0.1", port },
      {
        spawnProcess: (() => child) as typeof spawn,
        startupTimeoutMs: 1_000,
        stopTimeoutMs: 1_000,
        onUnexpectedExit: () => { recoveryStarts += 1; },
      },
    );

    await process.start();
    await process.close();

    assert.equal(recoveryStarts, 0);
  });
});

test("close racing managed startup is expected and cannot return a live start", async () => {
  await withListeningServer(async (port) => {
    const child = fakeChild(251);
    let unexpectedExits = 0;
    child.kill = ((signal?: NodeJS.Signals | number) => {
      Object.assign(child, { signalCode: signal as NodeJS.Signals });
      child.emit("exit", null, signal);
      return true;
    }) as ChildProcess["kill"];
    const process = new ManagedRigctldProcess(
      { executable: "rigctld", args: [], host: "127.0.0.1", port },
      {
        spawnProcess: (() => child) as typeof spawn,
        startupTimeoutMs: 1_000,
        stopTimeoutMs: 1_000,
        onUnexpectedExit: () => { unexpectedExits += 1; },
      },
    );

    const starting = process.start();
    const closing = process.close();
    await assert.rejects(process.start(), /close is in progress/u);
    await closing;

    await assert.rejects(starting, /cancelled before readiness/u);
    assert.equal(unexpectedExits, 0);
  });
});

test("startup-failure cleanup is expected and does not emit a recovery trigger", async () => {
  const child = fakeChild(301);
  let unexpectedExits = 0;
  child.kill = ((signal?: NodeJS.Signals | number) => {
    Object.assign(child, { signalCode: signal as NodeJS.Signals });
    child.emit("exit", null, signal);
    return true;
  }) as ChildProcess["kill"];
  const spawnProcess = (() => {
    setImmediate(() => child.emit("error", new Error("spawn failed")));
    return child;
  }) as typeof spawn;
  const process = new ManagedRigctldProcess(
    { executable: "rigctld", args: [], host: "127.0.0.1", port: 65_532 },
    {
      spawnProcess,
      startupTimeoutMs: 1_000,
      stopTimeoutMs: 1_000,
      onUnexpectedExit: () => { unexpectedExits += 1; },
    },
  );

  await assert.rejects(process.start(), /unable to start rigctld: spawn failed/u);
  assert.equal(unexpectedExits, 0);
});

function fakeChild(pid: number): ChildProcess {
  const child = new EventEmitter() as ChildProcess;
  Object.assign(child, {
    pid,
    exitCode: null,
    signalCode: null,
    stderr: new PassThrough(),
  });
  child.kill = (() => true) as ChildProcess["kill"];
  return child;
}

async function withListeningServer(
  run: (port: number) => Promise<void>,
): Promise<void> {
  const server = createServer((socket) => socket.end());
  await listen(server, 0);
  const port = (server.address() as AddressInfo).port;
  try {
    await run(port);
  } finally {
    await closeServer(server);
  }
}

function listen(server: ReturnType<typeof createServer>, port: number): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });
}

function closeServer(server: ReturnType<typeof createServer>): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error === undefined) {
        resolve();
      } else {
        reject(error);
      }
    });
  });
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
} {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}
