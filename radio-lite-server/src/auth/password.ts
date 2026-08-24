import { argon2, randomBytes, timingSafeEqual } from "node:crypto";

export type PasswordHashPolicy = {
  memoryKiB: number;
  passes: number;
  parallelism: number;
  saltBytes: number;
  tagBytes: number;
};

export const PASSWORD_HASH_POLICY: Readonly<PasswordHashPolicy> = {
  memoryKiB: 19_456,
  passes: 2,
  parallelism: 1,
  saltBytes: 16,
  tagBytes: 32,
};

type ParsedHash = PasswordHashPolicy & {
  salt: Buffer;
  tag: Buffer;
};

const COMMON_PASSWORDS = new Set([
  "123456789012345",
  "passwordpassword",
  "qwertyuiop12345",
  "radio-lite-server",
]);

export function normalizeNewPassword(password: string, username?: string): string {
  if (typeof password !== "string") {
    throw new TypeError("password must be text");
  }
  const normalized = password.normalize("NFC");
  const characters = Array.from(normalized);
  if (characters.length < 15 || characters.length > 128) {
    throw new Error("password must contain 15..128 Unicode characters");
  }
  if (Buffer.byteLength(normalized, "utf8") > 1_024) {
    throw new Error("password is too large when encoded as UTF-8");
  }
  const folded = normalized.toLocaleLowerCase("en-US");
  if (COMMON_PASSWORDS.has(folded)) {
    throw new Error("password is too common");
  }
  if (username !== undefined) {
    const normalizedUsername = username.trim().toLocaleLowerCase("en-US");
    if (normalizedUsername.length >= 3 && folded.includes(normalizedUsername)) {
      throw new Error("password must not contain the username");
    }
  }
  return normalized;
}

export async function hashPassword(password: string, username?: string): Promise<string> {
  const normalized = normalizeNewPassword(password, username);
  const salt = randomBytes(PASSWORD_HASH_POLICY.saltBytes);
  const tag = await deriveArgon2id(normalized, salt, PASSWORD_HASH_POLICY);
  return serializePhc(PASSWORD_HASH_POLICY, salt, tag);
}

export async function verifyPassword(password: string, encoded: string): Promise<boolean> {
  if (typeof password !== "string" || Buffer.byteLength(password, "utf8") > 1_024) {
    return false;
  }
  const parsed = parsePhc(encoded);
  if (parsed === null) {
    return false;
  }
  const actual = await deriveArgon2id(password.normalize("NFC"), parsed.salt, parsed);
  return actual.length === parsed.tag.length && timingSafeEqual(actual, parsed.tag);
}

export function passwordHashNeedsUpgrade(encoded: string): boolean {
  const parsed = parsePhc(encoded);
  return parsed === null ||
    parsed.memoryKiB < PASSWORD_HASH_POLICY.memoryKiB ||
    parsed.passes < PASSWORD_HASH_POLICY.passes ||
    parsed.parallelism !== PASSWORD_HASH_POLICY.parallelism ||
    parsed.salt.length < PASSWORD_HASH_POLICY.saltBytes ||
    parsed.tag.length < PASSWORD_HASH_POLICY.tagBytes;
}

function deriveArgon2id(
  password: string,
  salt: Buffer,
  policy: Pick<PasswordHashPolicy, "memoryKiB" | "passes" | "parallelism" | "tagBytes">,
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    argon2(
      "argon2id",
      {
        message: Buffer.from(password, "utf8"),
        nonce: salt,
        parallelism: policy.parallelism,
        tagLength: policy.tagBytes,
        memory: policy.memoryKiB,
        passes: policy.passes,
      },
      (error, result) => {
        if (error !== null && error !== undefined) {
          reject(error);
          return;
        }
        resolve(Buffer.from(result));
      },
    );
  });
}

function serializePhc(policy: PasswordHashPolicy, salt: Buffer, tag: Buffer): string {
  return [
    "$argon2id",
    "$v=19",
    `$m=${policy.memoryKiB},t=${policy.passes},p=${policy.parallelism}`,
    `$${salt.toString("base64").replace(/=+$/u, "")}`,
    `$${tag.toString("base64").replace(/=+$/u, "")}`,
  ].join("");
}

function parsePhc(encoded: string): ParsedHash | null {
  if (typeof encoded !== "string" || encoded.length > 512) {
    return null;
  }
  const match = /^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$/u.exec(encoded);
  if (match === null) {
    return null;
  }
  const memoryKiB = Number(match[1]);
  const passes = Number(match[2]);
  const parallelism = Number(match[3]);
  const salt = decodeUnpaddedBase64(match[4]);
  const tag = decodeUnpaddedBase64(match[5]);
  if (
    !Number.isSafeInteger(memoryKiB) || memoryKiB < 8 || memoryKiB > 262_144 ||
    !Number.isSafeInteger(passes) || passes < 1 || passes > 10 ||
    !Number.isSafeInteger(parallelism) || parallelism < 1 || parallelism > 16 ||
    salt === null || salt.length < 8 || salt.length > 64 ||
    tag === null || tag.length < 16 || tag.length > 64
  ) {
    return null;
  }
  return {
    memoryKiB,
    passes,
    parallelism,
    saltBytes: salt.length,
    tagBytes: tag.length,
    salt,
    tag,
  };
}

function decodeUnpaddedBase64(value: string): Buffer | null {
  try {
    const decoded = Buffer.from(value, "base64");
    const canonical = decoded.toString("base64").replace(/=+$/u, "");
    return canonical === value ? decoded : null;
  } catch {
    return null;
  }
}
