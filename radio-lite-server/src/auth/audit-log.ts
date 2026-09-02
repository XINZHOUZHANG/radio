import { mkdir, open, readFile } from "node:fs/promises";
import { dirname } from "node:path";

export type AuditResult = "success" | "denied" | "failure";

export type AuditEvent = {
  occurredAtMs: number;
  action: string;
  result: AuditResult;
  actorUserId?: string;
  actorDeviceId?: string;
  targetId?: string;
  sourceAddress?: string;
  metadata?: Record<string, string | number | boolean | null>;
};

const ACTION_PATTERN = /^[a-z][a-z0-9_.-]{1,63}$/u;
const SECRET_KEY_PATTERN = /(?:password|token|secret|code|credential|cookie)/iu;

export class AuditLog {
  readonly #path: string;
  #tail: Promise<void> = Promise.resolve();

  constructor(path: string) {
    if (!path) {
      throw new Error("audit log path is required");
    }
    this.#path = path;
  }

  append(event: AuditEvent): Promise<void> {
    return this.#serialize(async () => {
      const validated = validateEvent(event);
      const directory = dirname(this.#path);
      await mkdir(directory, { recursive: true, mode: 0o700 });
      const handle = await open(this.#path, "a", 0o600);
      try {
        await handle.write(`${JSON.stringify(validated)}\n`, null, "utf8");
        await handle.sync();
      } finally {
        await handle.close();
      }
    });
  }

  async readNewest(limit = 100): Promise<AuditEvent[]> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1_000) {
      throw new Error("audit read limit must be in 1..1000");
    }
    let content: string;
    try {
      content = await readFile(this.#path, "utf8");
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === "ENOENT") {
        return [];
      }
      throw error;
    }
    return content
      .split(/\r?\n/u)
      .filter(Boolean)
      .slice(-limit)
      .reverse()
      .map((line) => validateEvent(JSON.parse(line)));
  }

  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

function validateEvent(value: unknown): AuditEvent {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("audit event must be an object");
  }
  const item = value as Record<string, unknown>;
  if (!Number.isSafeInteger(item.occurredAtMs) || (item.occurredAtMs as number) < 0) {
    throw new Error("audit occurredAtMs must be a non-negative integer");
  }
  if (typeof item.action !== "string" || !ACTION_PATTERN.test(item.action)) {
    throw new Error("audit action is invalid");
  }
  if (item.result !== "success" && item.result !== "denied" && item.result !== "failure") {
    throw new Error("audit result is invalid");
  }
  const event: AuditEvent = {
    occurredAtMs: item.occurredAtMs as number,
    action: item.action,
    result: item.result,
  };
  for (const key of ["actorUserId", "actorDeviceId", "targetId", "sourceAddress"] as const) {
    const field = item[key];
    if (field !== undefined) {
      if (typeof field !== "string" || field.length < 1 || field.length > 256 || /[\0\r\n]/u.test(field)) {
        throw new Error(`audit ${key} is invalid`);
      }
      event[key] = field;
    }
  }
  if (item.metadata !== undefined) {
    if (item.metadata === null || typeof item.metadata !== "object" || Array.isArray(item.metadata)) {
      throw new Error("audit metadata must be an object");
    }
    const metadata: Record<string, string | number | boolean | null> = {};
    for (const [key, field] of Object.entries(item.metadata as Record<string, unknown>)) {
      if (!/^[a-z][a-z0-9_.-]{0,63}$/u.test(key) || SECRET_KEY_PATTERN.test(key)) {
        throw new Error(`audit metadata key is prohibited: ${key}`);
      }
      if (
        field !== null &&
        typeof field !== "string" &&
        typeof field !== "number" &&
        typeof field !== "boolean"
      ) {
        throw new Error(`audit metadata value is invalid: ${key}`);
      }
      if (typeof field === "string" && field.length > 512) {
        throw new Error(`audit metadata value is too long: ${key}`);
      }
      metadata[key] = field;
    }
    event.metadata = metadata;
  }
  return event;
}
