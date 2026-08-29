import assert from "node:assert/strict";
import { test } from "node:test";

import { CatCommandLimiter } from "../src/rig/cat-command-limiter.ts";
import { HamlibDriver } from "../src/rig/hamlib-driver.ts";
import { HamlibRig } from "../src/rig/hamlib-rig.ts";

test("receive budget prevents a third ordinary CAT start before 1,000 ms", async () => {
  const clock = new VirtualClock();
  const limiter = new CatCommandLimiter({ now: clock.now, delay: clock.delay });
  const startedAtMs: number[] = [];

  await limiter.waitForBudget();
  startedAtMs.push(clock.now());
  const second = limiter.waitForBudget().then(() => startedAtMs.push(clock.now()));
  await clock.advanceBy(500);
  await second;
  const third = limiter.waitForBudget().then(() => startedAtMs.push(clock.now()));
  await clock.advanceBy(500);
  await third;

  assert.deepEqual(startedAtMs, [0, 500, 1_000]);
});

test("transmit budget permits ordinary CAT starts 250 ms apart", async () => {
  const clock = new VirtualClock();
  const limiter = new CatCommandLimiter({ now: clock.now, delay: clock.delay });
  limiter.setMode("transmit");

  await limiter.waitForBudget();
  const second = limiter.waitForBudget();
  await clock.advanceBy(249);
  let started = false;
  void second.then(() => { started = true; });
  await flush();
  assert.equal(started, false, "a 249 ms transmit gap would exceed the CAT budget");
  await clock.advanceBy(1);
  await second;
});

test("confirmed PTT readback changes the injected CAT budget only after physical evidence", async () => {
  const modes: Array<"receive" | "transmit"> = [];
  let ptt = true;
  const driver = new HamlibDriver(new HamlibRig({
    request: async (command) => ({
      command: command.slice(1),
      fields: command === "\\get_ptt" ? new Map([["PTT", ptt ? "1" : "0"]]) : new Map(),
      values: [],
      report: 0,
    }),
  }), { onTransportMode: (mode) => modes.push(mode) });

  await driver.writePtt(true);
  assert.deepEqual(modes, [], "a write acknowledgement is not PTT confirmation");
  assert.equal(await driver.readPtt(), true);
  ptt = false;
  assert.equal(await driver.readPtt({ purpose: "off-recovery" }), false);

  assert.deepEqual(modes, ["transmit", "receive"]);
});

class VirtualClock {
  #now = 0;
  #timers: Array<{
    dueAtMs: number;
    resolve: () => void;
    reject: (error: Error) => void;
    signal: AbortSignal;
    onAbort: () => void;
  }> = [];

  now = (): number => this.#now;

  delay = (milliseconds: number, signal: AbortSignal): Promise<void> => new Promise((resolve, reject) => {
    const timer = {
      dueAtMs: this.#now + milliseconds,
      resolve: () => resolve(),
      reject,
      signal,
      onAbort: () => {},
    };
    timer.onAbort = () => {
      this.#timers = this.#timers.filter((candidate) => candidate !== timer);
      reject(signal.reason instanceof Error ? signal.reason : new Error("delay aborted"));
    };
    signal.addEventListener("abort", timer.onAbort, { once: true });
    this.#timers.push(timer);
  });

  async advanceBy(milliseconds: number): Promise<void> {
    this.#now += milliseconds;
    const due = this.#timers.filter((timer) => timer.dueAtMs <= this.#now);
    this.#timers = this.#timers.filter((timer) => timer.dueAtMs > this.#now);
    for (const timer of due) {
      timer.signal.removeEventListener("abort", timer.onAbort);
      timer.resolve();
    }
    await flush();
  }
}

async function flush(): Promise<void> {
  await new Promise<void>((resolve) => queueMicrotask(resolve));
}
