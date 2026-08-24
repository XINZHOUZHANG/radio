import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";

import { readJsonWithBackup, writeJsonAtomic } from "../storage/atomic-json.ts";

export type DeviceCredentialBundle = {
  deviceId: string;
  accessToken: string;
  accessExpiresAtMs: number;
  refreshToken: string;
  refreshExpiresAtMs: number;
};

type StoredDevice = {
  id: string;
  userId: string;
  name: string;
  accessDigest: string;
  accessExpiresAtMs: number;
  refreshDigest: string;
  previousRefreshDigest: string | null;
  refreshExpiresAtMs: number;
  createdAtMs: number;
  updatedAtMs: number;
  revokedAtMs: number | null;
};

export type PublicDevice = Omit<
  StoredDevice,
  "accessDigest" | "refreshDigest" | "previousRefreshDigest"
>;

type DeviceFile = {
  version: 1;
  devices: StoredDevice[];
};

export type DeviceStoreOptions = {
  now?: () => number;
  idFactory?: () => string;
  tokenFactory?: () => string;
  accessLifetimeMs?: number;
  refreshLifetimeMs?: number;
};

export class InvalidDeviceCredentialError extends Error {}
export class RefreshTokenReuseError extends Error {}

export class DeviceStore {
  readonly #path: string;
  readonly #now: () => number;
  readonly #idFactory: () => string;
  readonly #tokenFactory: () => string;
  readonly #accessLifetimeMs: number;
  readonly #refreshLifetimeMs: number;
  #file: DeviceFile = { version: 1, devices: [] };
  #loaded = false;
  #tail: Promise<void> = Promise.resolve();

  constructor(path: string, options: DeviceStoreOptions = {}) {
    if (!path) {
      throw new Error("devices.json path is required");
    }
    this.#path = path;
    this.#now = options.now ?? Date.now;
    this.#idFactory = options.idFactory ?? randomUUID;
    this.#tokenFactory = options.tokenFactory ?? (() => randomBytes(32).toString("base64url"));
    this.#accessLifetimeMs = positiveInteger(
      options.accessLifetimeMs ?? 15 * 60_000,
      "access lifetime",
    );
    this.#refreshLifetimeMs = positiveInteger(
      options.refreshLifetimeMs ?? 30 * 24 * 60 * 60_000,
      "refresh lifetime",
    );
  }

  async load(): Promise<{ devices: PublicDevice[]; recoveredFromBackup: boolean }> {
    return this.#serialize(async () => {
      const result = await readJsonWithBackup(
        this.#path,
        parseDeviceFile,
        () => ({ version: 1, devices: [] }),
      );
      this.#file = result.value;
      this.#loaded = true;
      return {
        devices: this.list(),
        recoveredFromBackup: result.source === "backup",
      };
    });
  }

  list(userId?: string): PublicDevice[] {
    this.#assertLoaded();
    return this.#file.devices
      .filter((device) => userId === undefined || device.userId === userId)
      .map(publicDevice)
      .sort((left, right) => left.createdAtMs - right.createdAtMs);
  }

  async pair(userId: string, name: string): Promise<DeviceCredentialBundle> {
    const normalizedName = deviceName(name);
    if (!userId.trim()) {
      throw new Error("device owner is required");
    }
    return this.#serialize(async () => {
      this.#assertLoaded();
      const now = this.#now();
      const accessToken = this.#newToken();
      const refreshToken = this.#newToken();
      const device: StoredDevice = {
        id: this.#idFactory(),
        userId,
        name: normalizedName,
        accessDigest: digestToken(accessToken),
        accessExpiresAtMs: now + this.#accessLifetimeMs,
        refreshDigest: digestToken(refreshToken),
        previousRefreshDigest: null,
        refreshExpiresAtMs: now + this.#refreshLifetimeMs,
        createdAtMs: now,
        updatedAtMs: now,
        revokedAtMs: null,
      };
      await this.#commit({ version: 1, devices: [...this.#file.devices, device] });
      return credentials(device, accessToken, refreshToken);
    });
  }

  verifyAccess(deviceId: string, accessToken: string): PublicDevice | null {
    this.#assertLoaded();
    const device = this.#file.devices.find((candidate) => candidate.id === deviceId);
    if (
      device === undefined ||
      device.revokedAtMs !== null ||
      device.accessExpiresAtMs <= this.#now() ||
      !digestMatches(device.accessDigest, accessToken)
    ) {
      return null;
    }
    return publicDevice(device);
  }

  async refresh(deviceId: string, refreshToken: string): Promise<DeviceCredentialBundle> {
    return this.#serialize(async () => {
      this.#assertLoaded();
      const device = this.#file.devices.find((candidate) => candidate.id === deviceId);
      if (device === undefined || device.revokedAtMs !== null) {
        throw new InvalidDeviceCredentialError("invalid device credential");
      }
      if (
        device.previousRefreshDigest !== null &&
        digestMatches(device.previousRefreshDigest, refreshToken)
      ) {
        const revoked = { ...device, revokedAtMs: this.#now(), updatedAtMs: this.#now() };
        await this.#replace(revoked);
        throw new RefreshTokenReuseError("rotated refresh credential was reused");
      }
      if (
        device.refreshExpiresAtMs <= this.#now() ||
        !digestMatches(device.refreshDigest, refreshToken)
      ) {
        throw new InvalidDeviceCredentialError("invalid device credential");
      }
      const now = this.#now();
      const newAccessToken = this.#newToken();
      const newRefreshToken = this.#newToken();
      const updated: StoredDevice = {
        ...device,
        accessDigest: digestToken(newAccessToken),
        accessExpiresAtMs: now + this.#accessLifetimeMs,
        previousRefreshDigest: device.refreshDigest,
        refreshDigest: digestToken(newRefreshToken),
        refreshExpiresAtMs: now + this.#refreshLifetimeMs,
        updatedAtMs: now,
      };
      await this.#replace(updated);
      return credentials(updated, newAccessToken, newRefreshToken);
    });
  }

  async revokeDevice(deviceId: string): Promise<boolean> {
    return this.#serialize(async () => {
      this.#assertLoaded();
      const device = this.#file.devices.find((candidate) => candidate.id === deviceId);
      if (device === undefined || device.revokedAtMs !== null) {
        return false;
      }
      const now = this.#now();
      await this.#replace({ ...device, revokedAtMs: now, updatedAtMs: now });
      return true;
    });
  }

  async revokeUser(userId: string): Promise<number> {
    return this.#serialize(async () => {
      this.#assertLoaded();
      const now = this.#now();
      let count = 0;
      const devices = this.#file.devices.map((device) => {
        if (device.userId !== userId || device.revokedAtMs !== null) {
          return device;
        }
        count += 1;
        return { ...device, revokedAtMs: now, updatedAtMs: now };
      });
      if (count > 0) {
        await this.#commit({ version: 1, devices });
      }
      return count;
    });
  }

  async #replace(updated: StoredDevice): Promise<void> {
    const devices = this.#file.devices.map((device) =>
      device.id === updated.id ? updated : device,
    );
    await this.#commit({ version: 1, devices });
  }

  async #commit(file: DeviceFile): Promise<void> {
    const validated = parseDeviceFile(file);
    await writeJsonAtomic(this.#path, validated);
    this.#file = validated;
  }

  #newToken(): string {
    const token = this.#tokenFactory();
    if (!/^[A-Za-z0-9_-]{32,128}$/u.test(token)) {
      throw new Error("device token factory returned an unsafe or too-short token");
    }
    return token;
  }

  #assertLoaded(): void {
    if (!this.#loaded) {
      throw new Error("device store has not been loaded");
    }
  }

  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

function parseDeviceFile(value: unknown): DeviceFile {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("devices.json must contain an object");
  }
  const root = value as Record<string, unknown>;
  if (root.version !== 1 || !Array.isArray(root.devices)) {
    throw new Error("devices.json has an unsupported shape or version");
  }
  const devices = root.devices.map(parseStoredDevice);
  const ids = new Set<string>();
  for (const device of devices) {
    if (ids.has(device.id)) {
      throw new Error("devices.json contains a duplicate id");
    }
    ids.add(device.id);
  }
  return { version: 1, devices };
}

function parseStoredDevice(value: unknown): StoredDevice {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("stored device must be an object");
  }
  const item = value as Record<string, unknown>;
  return {
    id: text(item.id, "device.id", 1, 128),
    userId: text(item.userId, "device.userId", 1, 128),
    name: deviceName(item.name),
    accessDigest: digest(item.accessDigest, "device.accessDigest"),
    accessExpiresAtMs: integer(item.accessExpiresAtMs, "device.accessExpiresAtMs"),
    refreshDigest: digest(item.refreshDigest, "device.refreshDigest"),
    previousRefreshDigest: item.previousRefreshDigest === null
      ? null
      : digest(item.previousRefreshDigest, "device.previousRefreshDigest"),
    refreshExpiresAtMs: integer(item.refreshExpiresAtMs, "device.refreshExpiresAtMs"),
    createdAtMs: integer(item.createdAtMs, "device.createdAtMs"),
    updatedAtMs: integer(item.updatedAtMs, "device.updatedAtMs"),
    revokedAtMs: item.revokedAtMs === null
      ? null
      : integer(item.revokedAtMs, "device.revokedAtMs"),
  };
}

function credentials(
  device: StoredDevice,
  accessToken: string,
  refreshToken: string,
): DeviceCredentialBundle {
  return {
    deviceId: device.id,
    accessToken,
    accessExpiresAtMs: device.accessExpiresAtMs,
    refreshToken,
    refreshExpiresAtMs: device.refreshExpiresAtMs,
  };
}

function publicDevice(device: StoredDevice): PublicDevice {
  const {
    accessDigest: _accessDigest,
    refreshDigest: _refreshDigest,
    previousRefreshDigest: _previousRefreshDigest,
    ...safe
  } = device;
  return structuredClone(safe);
}

function digestToken(token: string): string {
  return createHash("sha256").update("radio-lite-device\0", "utf8").update(token, "utf8").digest("hex");
}

function digestMatches(expectedHex: string, token: string): boolean {
  if (typeof token !== "string" || token.length > 256) {
    return false;
  }
  const expected = Buffer.from(expectedHex, "hex");
  const actual = Buffer.from(digestToken(token), "hex");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

function deviceName(value: unknown): string {
  const normalized = text(value, "device.name", 1, 64).trim();
  if (/[\0\r\n]/u.test(normalized)) {
    throw new Error("device name contains a prohibited character");
  }
  return normalized;
}

function digest(value: unknown, field: string): string {
  const result = text(value, field, 64, 64);
  if (!/^[a-f0-9]{64}$/u.test(result)) {
    throw new Error(`${field} must be a SHA-256 digest`);
  }
  return result;
}

function text(value: unknown, field: string, min: number, max: number): string {
  if (typeof value !== "string" || value.length < min || value.length > max) {
    throw new Error(`${field} must be text with length ${min}..${max}`);
  }
  return value;
}

function integer(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error(`${field} must be a non-negative integer`);
  }
  return value as number;
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}
