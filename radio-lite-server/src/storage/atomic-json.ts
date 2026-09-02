import { randomUUID } from "node:crypto";
import {
  chmod,
  copyFile,
  mkdir,
  open,
  readFile,
  rename,
  unlink,
} from "node:fs/promises";
import { basename, dirname, join } from "node:path";

export type JsonReadResult<T> = {
  value: T;
  source: "primary" | "backup" | "missing";
};

export async function readJsonWithBackup<T>(
  path: string,
  parse: (value: unknown) => T,
  fallback: () => T,
): Promise<JsonReadResult<T>> {
  try {
    return { value: parse(JSON.parse(await readFile(path, "utf8"))), source: "primary" };
  } catch (primaryError) {
    if (isMissing(primaryError)) {
      return { value: fallback(), source: "missing" };
    }
    try {
      return {
        value: parse(JSON.parse(await readFile(`${path}.bak`, "utf8"))),
        source: "backup",
      };
    } catch (backupError) {
      throw new AggregateError(
        [primaryError, backupError],
        `unable to read valid JSON from ${path} or its backup`,
      );
    }
  }
}

export async function writeJsonAtomic(
  path: string,
  value: unknown,
  mode = 0o600,
): Promise<void> {
  const directory = dirname(path);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await bestEffortChmod(directory, 0o700);

  const token = `${process.pid}-${randomUUID()}`;
  const temporary = join(directory, `.${basename(path)}.${token}.tmp`);
  const backupTemporary = join(directory, `.${basename(path)}.${token}.bak.tmp`);
  const serialized = `${JSON.stringify(value, null, 2)}\n`;
  let temporaryExists = false;
  let backupTemporaryExists = false;

  try {
    const handle = await open(temporary, "wx", mode);
    temporaryExists = true;
    try {
      await handle.writeFile(serialized, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await bestEffortChmod(temporary, mode);

    try {
      await copyFile(path, backupTemporary);
      backupTemporaryExists = true;
      await bestEffortChmod(backupTemporary, mode);
      await replacePath(backupTemporary, `${path}.bak`);
      backupTemporaryExists = false;
    } catch (error) {
      if (!isMissing(error)) {
        throw error;
      }
    }

    await replacePath(temporary, path);
    temporaryExists = false;
    await bestEffortChmod(path, mode);
    await syncDirectory(directory);
  } finally {
    if (temporaryExists) {
      await unlink(temporary).catch(() => undefined);
    }
    if (backupTemporaryExists) {
      await unlink(backupTemporary).catch(() => undefined);
    }
  }
}

async function replacePath(source: string, destination: string): Promise<void> {
  try {
    await rename(source, destination);
  } catch (error) {
    if (!isReplaceConflict(error)) {
      throw error;
    }
    const displaced = `${destination}.replace-${process.pid}-${randomUUID()}`;
    let displacedExists = false;
    try {
      try {
        await rename(destination, displaced);
        displacedExists = true;
      } catch (moveError) {
        if (!isMissing(moveError)) {
          throw moveError;
        }
      }
      await rename(source, destination);
      if (displacedExists) {
        await unlink(displaced);
        displacedExists = false;
      }
    } catch (replacementError) {
      if (displacedExists) {
        await rename(displaced, destination).catch(() => undefined);
      }
      throw replacementError;
    }
  }
}

async function syncDirectory(directory: string): Promise<void> {
  if (process.platform === "win32") {
    return;
  }
  const handle = await open(directory, "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function bestEffortChmod(path: string, mode: number): Promise<void> {
  await chmod(path, mode).catch((error) => {
    if (process.platform !== "win32") {
      throw error;
    }
  });
}

function isMissing(error: unknown): boolean {
  return isNodeError(error) && error.code === "ENOENT";
}

function isReplaceConflict(error: unknown): boolean {
  return isNodeError(error) && (error.code === "EEXIST" || error.code === "EPERM");
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error;
}
