import { randomUUID } from "node:crypto";

import { readJsonWithBackup, writeJsonAtomic } from "../storage/atomic-json.ts";
import {
  hashPassword,
  passwordHashNeedsUpgrade,
  verifyPassword,
} from "./password.ts";

export type UserRole = "admin" | "operator";

export type StoredUser = {
  id: string;
  username: string;
  passwordHash: string;
  role: UserRole;
  canTransmit: boolean;
  enabled: boolean;
  mustChangePassword: boolean;
  authRevision: number;
  createdAtMs: number;
  updatedAtMs: number;
  lastLoginAtMs: number | null;
};

export type PublicUser = Omit<StoredUser, "passwordHash">;

type UserFile = {
  version: 1;
  users: StoredUser[];
};

export type NewUser = {
  username: string;
  password: string;
  role: UserRole;
  canTransmit?: boolean;
  mustChangePassword?: boolean;
};

export type UserStoreOptions = {
  now?: () => number;
  idFactory?: () => string;
};

const USERNAME_PATTERN = /^[a-z0-9][a-z0-9_.-]{2,31}$/u;
const DUMMY_PASSWORD = "not-a-real-user-password-2026";

export class UserStore {
  readonly #path: string;
  readonly #now: () => number;
  readonly #idFactory: () => string;
  #file: UserFile = { version: 1, users: [] };
  #loaded = false;
  #tail: Promise<void> = Promise.resolve();
  #dummyHash: Promise<string> | null = null;

  constructor(path: string, options: UserStoreOptions = {}) {
    if (!path) {
      throw new Error("users.json path is required");
    }
    this.#path = path;
    this.#now = options.now ?? Date.now;
    this.#idFactory = options.idFactory ?? randomUUID;
  }

  async load(): Promise<{ users: PublicUser[]; recoveredFromBackup: boolean }> {
    return this.#serialize(async () => {
      const result = await readJsonWithBackup(
        this.#path,
        parseUserFile,
        () => ({ version: 1, users: [] }),
      );
      this.#file = result.value;
      this.#loaded = true;
      return {
        users: this.#publicUsers(),
        recoveredFromBackup: result.source === "backup",
      };
    });
  }

  list(): PublicUser[] {
    this.#assertLoaded();
    return this.#publicUsers();
  }

  async initializeAdmin(username: string, password: string): Promise<PublicUser> {
    const normalizedUsername = normalizeUsername(username);
    const passwordHash = await hashPassword(password, normalizedUsername);
    return this.#serialize(async () => {
      this.#assertLoaded();
      if (this.#file.users.length !== 0) {
        throw new Error("server already has an administrator");
      }
      const user = this.#newStoredUser({
        username: normalizedUsername,
        passwordHash,
        role: "admin",
        canTransmit: true,
        mustChangePassword: false,
      });
      await this.#commit({ version: 1, users: [user] });
      return publicUser(user);
    });
  }

  async create(input: NewUser): Promise<PublicUser> {
    const username = normalizeUsername(input.username);
    const role = parseRole(input.role);
    const passwordHash = await hashPassword(input.password, username);
    const canTransmit = role === "admin" ? true : input.canTransmit === true;
    const mustChangePassword = input.mustChangePassword === true;
    return this.#serialize(async () => {
      this.#assertLoaded();
      if (this.#file.users.some((user) => user.username === username)) {
        throw new Error("username already exists");
      }
      const user = this.#newStoredUser({
        username,
        passwordHash,
        role,
        canTransmit,
        mustChangePassword,
      });
      await this.#commit({ version: 1, users: [...this.#file.users, user] });
      return publicUser(user);
    });
  }

  async authenticate(username: string, password: string): Promise<PublicUser | null> {
    let normalizedUsername: string | null = null;
    try {
      normalizedUsername = normalizeUsername(username);
    } catch {
      // Invalid and unknown usernames follow the same expensive password path.
    }
    return this.#serialize(async () => {
      this.#assertLoaded();
      const user = normalizedUsername === null
        ? undefined
        : this.#file.users.find((candidate) => candidate.username === normalizedUsername);
      const hash = user?.passwordHash ?? await this.#getDummyHash();
      const correct = await verifyPassword(password, hash);
      if (!correct || user === undefined || !user.enabled) {
        return null;
      }
      const now = this.#now();
      let passwordHash = user.passwordHash;
      if (passwordHashNeedsUpgrade(passwordHash)) {
        passwordHash = await hashPassword(password, user.username);
      }
      const updated: StoredUser = {
        ...user,
        passwordHash,
        lastLoginAtMs: now,
        updatedAtMs: passwordHash === user.passwordHash ? user.updatedAtMs : now,
      };
      await this.#replaceUser(updated);
      return publicUser(updated);
    });
  }

  async setAccess(
    userId: string,
    changes: { role?: UserRole; canTransmit?: boolean; enabled?: boolean },
  ): Promise<PublicUser> {
    return this.#serialize(async () => {
      this.#assertLoaded();
      const user = this.#requireUser(userId);
      const role = changes.role === undefined ? user.role : parseRole(changes.role);
      const enabled = changes.enabled ?? user.enabled;
      const canTransmit = role === "admin" ? true : (changes.canTransmit ?? user.canTransmit);
      const updated: StoredUser = {
        ...user,
        role,
        enabled,
        canTransmit,
        authRevision: user.authRevision + 1,
        updatedAtMs: this.#now(),
      };
      const nextUsers = this.#file.users.map((candidate) =>
        candidate.id === userId ? updated : candidate,
      );
      ensureEnabledAdmin(nextUsers);
      await this.#commit({ version: 1, users: nextUsers });
      return publicUser(updated);
    });
  }

  async changePassword(userId: string, password: string): Promise<PublicUser> {
    const current = this.list().find((user) => user.id === userId);
    if (current === undefined) {
      throw new Error("user does not exist");
    }
    const passwordHash = await hashPassword(password, current.username);
    return this.#serialize(async () => {
      this.#assertLoaded();
      const user = this.#requireUser(userId);
      const updated: StoredUser = {
        ...user,
        passwordHash,
        mustChangePassword: false,
        authRevision: user.authRevision + 1,
        updatedAtMs: this.#now(),
      };
      await this.#replaceUser(updated);
      return publicUser(updated);
    });
  }

  #newStoredUser(input: {
    username: string;
    passwordHash: string;
    role: UserRole;
    canTransmit: boolean;
    mustChangePassword: boolean;
  }): StoredUser {
    const now = this.#now();
    return {
      id: this.#idFactory(),
      ...input,
      enabled: true,
      authRevision: 1,
      createdAtMs: now,
      updatedAtMs: now,
      lastLoginAtMs: null,
    };
  }

  #requireUser(userId: string): StoredUser {
    const user = this.#file.users.find((candidate) => candidate.id === userId);
    if (user === undefined) {
      throw new Error("user does not exist");
    }
    return user;
  }

  async #replaceUser(updated: StoredUser): Promise<void> {
    const users = this.#file.users.map((user) => user.id === updated.id ? updated : user);
    await this.#commit({ version: 1, users });
  }

  async #commit(file: UserFile): Promise<void> {
    const validated = parseUserFile(file);
    await writeJsonAtomic(this.#path, validated);
    this.#file = validated;
  }

  #publicUsers(): PublicUser[] {
    return this.#file.users
      .map(publicUser)
      .sort((left, right) => left.username.localeCompare(right.username));
  }

  async #getDummyHash(): Promise<string> {
    this.#dummyHash ??= hashPassword(DUMMY_PASSWORD);
    return this.#dummyHash;
  }

  #assertLoaded(): void {
    if (!this.#loaded) {
      throw new Error("user store has not been loaded");
    }
  }

  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

export function normalizeUsername(username: string): string {
  if (typeof username !== "string") {
    throw new TypeError("username must be text");
  }
  const normalized = username.trim().toLowerCase();
  if (!USERNAME_PATTERN.test(normalized)) {
    throw new Error("username must match [a-z0-9][a-z0-9_.-]{2,31}");
  }
  return normalized;
}

function parseUserFile(value: unknown): UserFile {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("users.json must contain an object");
  }
  const root = value as Record<string, unknown>;
  if (root.version !== 1 || !Array.isArray(root.users)) {
    throw new Error("users.json has an unsupported shape or version");
  }
  const users = root.users.map(parseStoredUser);
  const ids = new Set<string>();
  const usernames = new Set<string>();
  for (const user of users) {
    if (ids.has(user.id) || usernames.has(user.username)) {
      throw new Error("users.json contains a duplicate id or username");
    }
    ids.add(user.id);
    usernames.add(user.username);
  }
  if (users.length > 0) {
    ensureEnabledAdmin(users);
  }
  return { version: 1, users };
}

function parseStoredUser(value: unknown): StoredUser {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("stored user must be an object");
  }
  const user = value as Record<string, unknown>;
  const id = requiredText(user.id, "user.id", 1, 128);
  const username = normalizeUsername(requiredText(user.username, "user.username", 3, 32));
  const passwordHash = requiredText(user.passwordHash, "user.passwordHash", 1, 512);
  const role = parseRole(user.role);
  const canTransmit = requiredBoolean(user.canTransmit, "user.canTransmit");
  const enabled = requiredBoolean(user.enabled, "user.enabled");
  const mustChangePassword = requiredBoolean(user.mustChangePassword, "user.mustChangePassword");
  const authRevision = positiveInteger(user.authRevision, "user.authRevision");
  const createdAtMs = nonNegativeInteger(user.createdAtMs, "user.createdAtMs");
  const updatedAtMs = nonNegativeInteger(user.updatedAtMs, "user.updatedAtMs");
  const lastLoginAtMs = user.lastLoginAtMs === null
    ? null
    : nonNegativeInteger(user.lastLoginAtMs, "user.lastLoginAtMs");
  if (role === "admin" && !canTransmit) {
    throw new Error("administrator must have effective transmit permission");
  }
  return {
    id,
    username,
    passwordHash,
    role,
    canTransmit,
    enabled,
    mustChangePassword,
    authRevision,
    createdAtMs,
    updatedAtMs,
    lastLoginAtMs,
  };
}

function parseRole(value: unknown): UserRole {
  if (value !== "admin" && value !== "operator") {
    throw new Error("role must be admin or operator");
  }
  return value;
}

function ensureEnabledAdmin(users: readonly StoredUser[]): void {
  if (!users.some((user) => user.enabled && user.role === "admin")) {
    throw new Error("the final enabled administrator cannot be disabled or demoted");
  }
}

function publicUser(user: StoredUser): PublicUser {
  const { passwordHash: _passwordHash, ...safe } = user;
  return structuredClone(safe);
}

function requiredText(value: unknown, field: string, min: number, max: number): string {
  if (typeof value !== "string" || value.length < min || value.length > max) {
    throw new Error(`${field} must be text with length ${min}..${max}`);
  }
  return value;
}

function requiredBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw new Error(`${field} must be boolean`);
  }
  return value;
}

function positiveInteger(value: unknown, field: string): number {
  const result = nonNegativeInteger(value, field);
  if (result === 0) {
    throw new Error(`${field} must be positive`);
  }
  return result;
}

function nonNegativeInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error(`${field} must be a non-negative integer`);
  }
  return value as number;
}
