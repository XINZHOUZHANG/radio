import type { RadioProfile } from "../config/types.ts";

export type ManagedRigctldCommand = {
  executable: "rigctld";
  args: string[];
  host: "127.0.0.1";
  port: number;
};

export type RigctldTarget = {
  managed: boolean;
  host: string;
  port: number;
  command?: ManagedRigctldCommand;
};

export function rigctldTarget(
  profile: RadioProfile,
  managedPort: number,
): RigctldTarget {
  if (!Number.isSafeInteger(managedPort) || managedPort < 1 || managedPort > 65_535) {
    throw new Error("managed rigctld port must be in 1..65535");
  }
  if (profile.connection.kind === "network-rigctld") {
    return {
      managed: false,
      host: profile.connection.host,
      port: profile.connection.port,
    };
  }
  const args = ["-m", String(profile.hamlibModelId)];
  if (profile.connection.kind === "managed-serial") {
    args.push("-r", profile.connection.devicePath);
    if (profile.connection.baudRate !== undefined) {
      args.push("-s", String(profile.connection.baudRate));
    }
  }
  args.push("-P", rigctldPttMethod(profile.ptt.method));
  if (profile.ptt.path !== undefined) {
    args.push("-p", profile.ptt.path);
  }
  if (profile.ptt.bit !== undefined) {
    args.push("-C", `ptt_bitnum=${profile.ptt.bit}`);
  }
  args.push("-T", "127.0.0.1", "-t", String(managedPort));
  return {
    managed: true,
    host: "127.0.0.1",
    port: managedPort,
    command: {
      executable: "rigctld",
      args,
      host: "127.0.0.1",
      port: managedPort,
    },
  };
}

function rigctldPttMethod(method: RadioProfile["ptt"]["method"]): string {
  if (method === "Parallel") {
    return "PARALLEL";
  }
  if (method === "None") {
    return "NONE";
  }
  return method;
}
