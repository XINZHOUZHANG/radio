import { spawn, type ChildProcess } from "node:child_process";
import { createConnection } from "node:net";

import type { ManagedRigctldCommand } from "./rigctld-command.ts";

export type ManagedRigctldExit = {
  generation: number;
  exitCode: number | null;
  signalCode: NodeJS.Signals | null;
  stderr: string;
};

export type ManagedRigctldProcessOptions = {
  startupTimeoutMs?: number;
  stopTimeoutMs?: number;
  spawnProcess?: typeof spawn;
  onUnexpectedExit?: (exit: ManagedRigctldExit) => void;
};

type ManagedChild = {
  child: ChildProcess;
  generation: number;
  expected: boolean;
  ready: boolean;
  exitObserved: boolean;
  stderr: string;
};

export class ManagedRigctldProcess {
  readonly #command: ManagedRigctldCommand;
  readonly #startupTimeoutMs: number;
  readonly #stopTimeoutMs: number;
  readonly #spawnProcess: typeof spawn;
  readonly #onUnexpectedExit: ((exit: ManagedRigctldExit) => void) | undefined;
  #active: ManagedChild | null = null;
  #generation = 0;
  #startPromise: Promise<void> | null = null;
  #closePromise: Promise<void> | null = null;

  constructor(command: ManagedRigctldCommand, options: ManagedRigctldProcessOptions = {}) {
    this.#command = command;
    this.#startupTimeoutMs = positiveInteger(options.startupTimeoutMs ?? 10_000, "startup timeout");
    this.#stopTimeoutMs = positiveInteger(options.stopTimeoutMs ?? 2_000, "stop timeout");
    this.#spawnProcess = options.spawnProcess ?? spawn;
    this.#onUnexpectedExit = options.onUnexpectedExit;
  }

  start(): Promise<void> {
    if (this.#closePromise !== null) {
      return Promise.reject(new Error("rigctld close is in progress"));
    }
    if (this.#startPromise !== null) {
      return this.#startPromise;
    }
    if (this.#active !== null) {
      return this.#active.ready && !this.#active.expected
        ? Promise.resolve()
        : Promise.reject(new Error("rigctld cleanup is required before restart"));
    }
    return this.#trackStart(this.#startChild());
  }

  #trackStart(starting: Promise<void>): Promise<void> {
    this.#startPromise = starting;
    void starting.then(
      () => {
        if (this.#startPromise === starting) this.#startPromise = null;
      },
      () => {
        if (this.#startPromise === starting) this.#startPromise = null;
      },
    );
    return starting;
  }

  async #startChild(): Promise<void> {
    const child = this.#spawnProcess(this.#command.executable, this.#command.args, {
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "ignore", "pipe"],
    });
    const managed: ManagedChild = {
      child,
      generation: this.#generation + 1,
      expected: false,
      ready: false,
      exitObserved: false,
      stderr: "",
    };
    this.#generation = managed.generation;
    this.#active = managed;
    child.once("exit", (exitCode, signalCode) => {
      this.#observeExit(managed, exitCode, signalCode);
    });
    child.stderr?.on("data", (data) => {
      managed.stderr = `${managed.stderr}${data.toString("utf8")}`.slice(-4_096);
    });
    let rejectSpawnError!: (error: Error) => void;
    const spawnError = new Promise<never>((_resolve, reject) => {
      rejectSpawnError = reject;
    });
    // ChildProcess may emit `error` after a successful spawn (for example when a
    // later signal operation fails). Keep a permanent observer so EventEmitter
    // never promotes that diagnostic into an uncaught process exception.
    child.on("error", (error: Error) => {
      managed.stderr = `${managed.stderr}child process error: ${error.message}\n`.slice(-4_096);
      if (!managed.ready && !managed.expected && !managed.exitObserved) {
        rejectSpawnError(new Error(`unable to start rigctld: ${error.message}`, { cause: error }));
      }
    });
    try {
      await Promise.race([
        waitUntilReachable(
          this.#command.host,
          this.#command.port,
          child,
          this.#startupTimeoutMs,
          () => managed.stderr,
        ),
        spawnError,
      ]);
      if (managed.expected || managed.exitObserved || this.#active !== managed) {
        throw new Error("rigctld start was cancelled before readiness completed");
      }
      managed.ready = true;
    } catch (error) {
      managed.expected = true;
      if (
        child.pid !== undefined &&
        !managed.exitObserved &&
        child.exitCode === null &&
        child.signalCode === null
      ) {
        child.kill("SIGKILL");
        if (!(await waitForExit(child, this.#stopTimeoutMs))) {
          throw new Error("rigctld did not exit after startup failure", { cause: error });
        }
      }
      if (this.#active === managed) {
        this.#active = null;
      }
      throw error;
    }
  }

  close(): Promise<void> {
    if (this.#closePromise !== null) {
      return this.#closePromise;
    }
    const closing = this.#closeChild();
    this.#closePromise = closing;
    void closing.then(
      () => {
        if (this.#closePromise === closing) this.#closePromise = null;
      },
      () => {
        if (this.#closePromise === closing) this.#closePromise = null;
      },
    );
    return closing;
  }

  async #closeChild(): Promise<void> {
    const managed = this.#active;
    if (managed === null) {
      return;
    }
    // Set this before the first signal: test doubles and a fast real child may emit
    // exit synchronously from kill(), and an intentional close must never request restart.
    managed.expected = true;
    const child = managed.child;
    if (
      managed.exitObserved ||
      child.exitCode !== null ||
      child.signalCode !== null
    ) {
      if (this.#active === managed) {
        this.#active = null;
      }
      return;
    }
    child.kill("SIGTERM");
    if (await waitForExit(child, this.#stopTimeoutMs)) {
      if (this.#active === managed) {
        this.#active = null;
      }
      return;
    }
    child.kill("SIGKILL");
    if (!(await waitForExit(child, this.#stopTimeoutMs))) {
      throw new Error("rigctld did not exit after SIGKILL");
    }
    if (this.#active === managed) {
      this.#active = null;
    }
  }

  #observeExit(
    managed: ManagedChild,
    exitCode: number | null,
    signalCode: NodeJS.Signals | null,
  ): void {
    if (managed.exitObserved) {
      return;
    }
    managed.exitObserved = true;
    if (this.#active === managed) {
      this.#active = null;
    }
    if (managed.expected || !managed.ready || this.#onUnexpectedExit === undefined) {
      return;
    }
    try {
      this.#onUnexpectedExit({
        generation: managed.generation,
        exitCode: exitCode ?? managed.child.exitCode,
        signalCode: signalCode ?? managed.child.signalCode,
        stderr: managed.stderr,
      });
    } catch {
      // A notification consumer must not turn a child-process exit into an
      // uncaught EventEmitter exception. The supervisor owns its own recovery errors.
    }
  }
}

async function waitUntilReachable(
  host: string,
  port: number,
  child: ChildProcess,
  timeoutMs: number,
  stderr: () => string,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(`rigctld exited during startup${stderr() ? `: ${stderr()}` : ""}`);
    }
    if (await canConnect(host, port)) {
      return;
    }
    await delay(100);
  }
  throw new Error(`rigctld did not listen within ${timeoutMs} ms${stderr() ? `: ${stderr()}` : ""}`);
}

function canConnect(host: string, port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host, port });
    const timer = setTimeout(() => {
      socket.destroy();
      resolve(false);
    }, 250);
    timer.unref();
    socket.once("connect", () => {
      clearTimeout(timer);
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => {
      clearTimeout(timer);
      socket.destroy();
      resolve(false);
    });
  });
}

function waitForExit(child: ChildProcess, timeoutMs: number): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve(true);
  }
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      cleanup();
      resolve(false);
    }, timeoutMs);
    timer.unref();
    const onExit = () => {
      cleanup();
      resolve(true);
    };
    const cleanup = () => {
      clearTimeout(timer);
      child.off("exit", onExit);
    };
    child.once("exit", onExit);
  });
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds);
    timer.unref();
  });
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}
