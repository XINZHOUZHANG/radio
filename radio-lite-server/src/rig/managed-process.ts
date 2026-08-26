import { spawn, type ChildProcess } from "node:child_process";
import { createConnection } from "node:net";

import type { ManagedRigctldCommand } from "./rigctld-command.ts";

export type ManagedRigctldProcessOptions = {
  startupTimeoutMs?: number;
  stopTimeoutMs?: number;
  spawnProcess?: typeof spawn;
};

export class ManagedRigctldProcess {
  readonly #command: ManagedRigctldCommand;
  readonly #startupTimeoutMs: number;
  readonly #stopTimeoutMs: number;
  readonly #spawnProcess: typeof spawn;
  #child: ChildProcess | null = null;
  #stderr = "";

  constructor(command: ManagedRigctldCommand, options: ManagedRigctldProcessOptions = {}) {
    this.#command = command;
    this.#startupTimeoutMs = positiveInteger(options.startupTimeoutMs ?? 10_000, "startup timeout");
    this.#stopTimeoutMs = positiveInteger(options.stopTimeoutMs ?? 2_000, "stop timeout");
    this.#spawnProcess = options.spawnProcess ?? spawn;
  }

  async start(): Promise<void> {
    if (this.#child !== null) {
      return;
    }
    const child = this.#spawnProcess(this.#command.executable, this.#command.args, {
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "ignore", "pipe"],
    });
    this.#child = child;
    child.stderr?.on("data", (data) => {
      this.#stderr = `${this.#stderr}${data.toString("utf8")}`.slice(-4_096);
    });
    let removeSpawnErrorListener: () => void = () => undefined;
    const spawnError = new Promise<never>((_resolve, reject) => {
      const onError = (error: Error) => {
        reject(new Error(`unable to start rigctld: ${error.message}`, { cause: error }));
      };
      child.once("error", onError);
      removeSpawnErrorListener = () => { child.off("error", onError); };
    });
    try {
      await Promise.race([
        waitUntilReachable(
          this.#command.host,
          this.#command.port,
          child,
          this.#startupTimeoutMs,
          () => this.#stderr,
        ),
        spawnError,
      ]);
    } catch (error) {
      if (child.pid !== undefined) {
        child.kill("SIGKILL");
        if (!(await waitForExit(child, this.#stopTimeoutMs))) {
          throw new Error("rigctld did not exit after startup failure", { cause: error });
        }
      }
      if (this.#child === child) {
        this.#child = null;
      }
      throw error;
    } finally {
      removeSpawnErrorListener();
    }
  }

  async close(): Promise<void> {
    const child = this.#child;
    if (child === null || child.exitCode !== null || child.signalCode !== null) {
      if (this.#child === child) {
        this.#child = null;
      }
      return;
    }
    child.kill("SIGTERM");
    if (await waitForExit(child, this.#stopTimeoutMs)) {
      if (this.#child === child) {
        this.#child = null;
      }
      return;
    }
    child.kill("SIGKILL");
    if (!(await waitForExit(child, this.#stopTimeoutMs))) {
      throw new Error("rigctld did not exit after SIGKILL");
    }
    if (this.#child === child) {
      this.#child = null;
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
