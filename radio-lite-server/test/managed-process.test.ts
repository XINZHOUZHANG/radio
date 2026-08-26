import assert from "node:assert/strict";
import { type ChildProcess, type spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { setImmediate as nextTurn } from "node:timers/promises";
import { test } from "node:test";

import { ManagedRigctldProcess } from "../src/rig/managed-process.ts";

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
  await process.close();

  assert.deepEqual(signals, ["SIGKILL", "SIGTERM"]);
});

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
