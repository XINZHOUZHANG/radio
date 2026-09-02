import { randomUUID } from "node:crypto";
import { chmod, mkdir, open, rename, unlink } from "node:fs/promises";
import { basename, dirname, join } from "node:path";

export async function writeFileAtomic(
  path: string,
  value: Uint8Array,
  mode = 0o600,
): Promise<void> {
  const directory = dirname(path);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = join(
    directory,
    `.${basename(path)}.${process.pid}-${randomUUID()}.tmp`,
  );
  let temporaryExists = false;
  try {
    const handle = await open(temporary, "wx", mode);
    temporaryExists = true;
    try {
      await handle.writeFile(value);
      await handle.sync();
    } finally {
      await handle.close();
    }
    await bestEffortChmod(temporary, mode);
    await replacePath(temporary, path);
    temporaryExists = false;
    await bestEffortChmod(path, mode);
    await syncDirectory(directory);
  } finally {
    if (temporaryExists) {
      await unlink(temporary).catch(() => undefined);
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
