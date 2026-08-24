export type SerialDevice = {
  id: string;
  path: string;
  label: string;
  stable: boolean;
};

export type DiscoveredAudioDevice = {
  backend: "alsa" | "pulse";
  direction: "input" | "output";
  id: string;
  label: string;
};

export function serialDevicesFromNames(
  stableNames: readonly string[],
  ttyNames: readonly string[] = [],
): SerialDevice[] {
  const stable = stableNames
    .filter(safeDeviceName)
    .sort()
    .map((name) => ({
      id: `by-id:${name}`,
      path: `/dev/serial/by-id/${name}`,
      label: humanizeSerialName(name),
      stable: true,
    }));
  if (stable.length > 0) {
    return stable;
  }
  return ttyNames
    .filter((name) => /^(?:ttyUSB|ttyACM)\d+$/u.test(name))
    .sort()
    .map((name) => ({
      id: `tty:${name}`,
      path: `/dev/${name}`,
      label: name,
      stable: false,
    }));
}

export function parsePactlJson(
  output: string,
  direction: "input" | "output",
): DiscoveredAudioDevice[] {
  const parsed: unknown = JSON.parse(output);
  if (!Array.isArray(parsed)) {
    throw new TypeError("pactl output must be a JSON array");
  }
  const devices: DiscoveredAudioDevice[] = [];
  for (const item of parsed) {
    if (item === null || typeof item !== "object" || Array.isArray(item)) {
      continue;
    }
    const record = item as Record<string, unknown>;
    if (typeof record.name !== "string" || record.name.length === 0) {
      continue;
    }
    const properties = record.properties;
    const description = properties !== null && typeof properties === "object"
      ? (properties as Record<string, unknown>)["device.description"]
      : undefined;
    const label = typeof description === "string" && description.trim()
      ? description.trim()
      : record.name;
    devices.push({
      backend: "pulse",
      direction,
      id: record.name,
      label,
    });
  }
  return devices.sort((left, right) => left.label.localeCompare(right.label));
}

export function parseAlsaHardwareList(
  output: string,
  direction: "input" | "output",
): DiscoveredAudioDevice[] {
  const devices: DiscoveredAudioDevice[] = [];
  const seen = new Set<string>();
  for (const line of output.split(/\r?\n/u)) {
    const match = /^card\s+(\d+):\s*([^\[]+)\[([^\]]+)\],\s*device\s+(\d+):\s*([^\[]+)\[([^\]]+)\]/iu.exec(line.trim());
    if (match === null) {
      continue;
    }
    const id = `hw:${match[1]},${match[4]}`;
    if (seen.has(id)) {
      continue;
    }
    seen.add(id);
    devices.push({
      backend: "alsa",
      direction,
      id,
      label: `${match[3].trim()} — ${match[6].trim()}`,
    });
  }
  return devices;
}

function safeDeviceName(name: string): boolean {
  return name.length > 0 && name.length <= 255 && !/[\\/\0\r\n]/u.test(name);
}

function humanizeSerialName(name: string): string {
  return name
    .replace(/^usb-/u, "")
    .replace(/-if\d+(?:-port\d+)?$/u, "")
    .replaceAll("_", " ");
}
