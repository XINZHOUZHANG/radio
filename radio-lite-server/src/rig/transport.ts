import { createConnection, type Socket } from "node:net";

import {
  encodeRigCommand,
  ExtendedResponseParser,
  RigProtocolError,
  type RigResponse,
} from "./extended-protocol.ts";

export class RigTransportError extends Error {}

export class RigReportError extends Error {
  readonly report: number;

  constructor(command: string, report: number) {
    super(`rigctld ${command} failed with RPRT ${report}`);
    this.report = report;
  }
}

export type RigctldTransportOptions = {
  timeoutMs?: number;
  connect?: typeof createConnection;
};

export class RigctldTransport {
  readonly #host: string;
  readonly #port: number;
  readonly #timeoutMs: number;
  readonly #connect: typeof createConnection;
  #socket: Socket | null = null;
  #parser = new ExtendedResponseParser();
  #pending: {
    resolve: (response: RigResponse) => void;
    reject: (error: Error) => void;
  } | null = null;
  #tail: Promise<void> = Promise.resolve();
  #closed = false;

  constructor(host: string, port: number, options: RigctldTransportOptions = {}) {
    if (!host || /[\0\r\n]/u.test(host)) {
      throw new Error("rigctld host is invalid");
    }
    if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
      throw new Error("rigctld port must be in 1..65535");
    }
    this.#host = host;
    this.#port = port;
    this.#timeoutMs = positiveInteger(options.timeoutMs ?? 10_000, "rigctld timeout");
    this.#connect = options.connect ?? createConnection;
  }

  request(command: string): Promise<RigResponse> {
    const encoded = encodeRigCommand(command);
    return this.#serialize(async () => {
      if (this.#closed) {
        throw new RigTransportError("rigctld transport is closed");
      }
      const socket = await this.#ensureConnected();
      const response = await new Promise<RigResponse>((resolve, reject) => {
        const timer = setTimeout(() => {
          this.#pending = null;
          this.#destroySocket();
          reject(new RigTransportError(`rigctld command timed out after ${this.#timeoutMs} ms`));
        }, this.#timeoutMs);
        timer.unref();
        this.#pending = {
          resolve: (value) => {
            clearTimeout(timer);
            resolve(value);
          },
          reject: (error) => {
            clearTimeout(timer);
            reject(error);
          },
        };
        socket.write(encoded, (error) => {
          if (error !== null && error !== undefined) {
            this.#failPending(new RigTransportError("unable to write rigctld command", { cause: error }));
          }
        });
      });
      if (response.report !== 0) {
        throw new RigReportError(response.command, response.report);
      }
      return response;
    });
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#failPending(new RigTransportError("rigctld transport closed"));
    const socket = this.#socket;
    this.#socket = null;
    if (socket === null) {
      return;
    }
    await new Promise<void>((resolve) => {
      socket.once("close", resolve);
      socket.end();
      const timer = setTimeout(() => socket.destroy(), 1_000);
      timer.unref();
    });
  }

  async #ensureConnected(): Promise<Socket> {
    if (this.#socket !== null && !this.#socket.destroyed) {
      return this.#socket;
    }
    this.#parser = new ExtendedResponseParser();
    return new Promise<Socket>((resolve, reject) => {
      const socket = this.#connect({ host: this.#host, port: this.#port });
      const timer = setTimeout(() => {
        cleanup();
        socket.destroy();
        reject(new RigTransportError(`rigctld connection timed out after ${this.#timeoutMs} ms`));
      }, this.#timeoutMs);
      timer.unref();
      const cleanup = () => {
        clearTimeout(timer);
        socket.off("error", onError);
      };
      const onError = (error: Error) => {
        cleanup();
        socket.destroy();
        reject(new RigTransportError("unable to connect to rigctld", { cause: error }));
      };
      socket.once("error", onError);
      socket.once("connect", () => {
        cleanup();
        socket.setNoDelay(true);
        this.#socket = socket;
        this.#attachSocket(socket);
        resolve(socket);
      });
    });
  }

  #attachSocket(socket: Socket): void {
    socket.on("data", (data) => {
      try {
        const responses = this.#parser.feed(data);
        for (const response of responses) {
          const pending = this.#pending;
          if (pending === null) {
            throw new RigProtocolError("rigctld sent an unsolicited response");
          }
          this.#pending = null;
          pending.resolve(response);
        }
      } catch (error) {
        this.#failPending(error instanceof Error ? error : new RigProtocolError(String(error)));
        this.#destroySocket();
      }
    });
    socket.on("error", (error) => {
      this.#failPending(new RigTransportError("rigctld socket failed", { cause: error }));
      this.#destroySocket();
    });
    socket.on("close", () => {
      if (this.#socket === socket) {
        this.#socket = null;
      }
      this.#failPending(new RigTransportError("rigctld connection closed"));
    });
  }

  #failPending(error: Error): void {
    const pending = this.#pending;
    this.#pending = null;
    pending?.reject(error);
  }

  #destroySocket(): void {
    const socket = this.#socket;
    this.#socket = null;
    socket?.destroy();
    this.#parser.reset();
  }

  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}
