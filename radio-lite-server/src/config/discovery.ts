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
  metadata?: AudioDeviceMetadata;
};

export type AudioDeviceMetadata = {
  deviceSerial?: string;
  vendorId?: string;
  productId?: string;
  busPath?: string;
  topology?: string;
  alsaCard?: string;
  alsaCardId?: string;
  alsaCardName?: string;
  isMonitor?: boolean;
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
    const properties = record.properties !== null && typeof record.properties === "object"
      && !Array.isArray(record.properties)
      ? record.properties as Record<string, unknown>
      : {};
    const isMonitor = direction === "input" && (
      record.monitor_of_sink !== undefined ||
      properties["device.class"] === "monitor" ||
      record.name.endsWith(".monitor")
    );
    if (isMonitor) continue;
    const description = properties["device.description"];
    const label = typeof description === "string" && description.trim()
      ? description.trim()
      : record.name;
    const metadata = pulseMetadata(properties);
    devices.push({
      backend: "pulse",
      direction,
      id: record.name,
      label,
      ...(metadata === undefined ? {} : { metadata }),
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
      metadata: {
        alsaCard: match[1],
        alsaCardId: match[2].trim(),
        alsaCardName: match[3].trim(),
      },
    });
  }
  return devices;
}

function pulseMetadata(properties: Record<string, unknown>): AudioDeviceMetadata | undefined {
  const metadata: AudioDeviceMetadata = {};
  addMetadata(metadata, "deviceSerial", propertyText(properties, "device.serial"));
  addMetadata(metadata, "vendorId", propertyText(properties, "device.vendor.id"));
  addMetadata(metadata, "productId", propertyText(properties, "device.product.id"));
  addMetadata(metadata, "busPath", propertyText(properties, "device.bus_path"));
  addMetadata(metadata, "topology", propertyText(properties, "device.topology"));
  addMetadata(metadata, "alsaCard", propertyText(properties, "alsa.card"));
  addMetadata(metadata, "alsaCardId", propertyText(properties, "api.alsa.card.id"));
  addMetadata(
    metadata,
    "alsaCardName",
    propertyText(properties, "api.alsa.card.name")
      ?? propertyText(properties, "alsa.card_name")
      ?? propertyText(properties, "alsa.long_card_name"),
  );
  return Object.keys(metadata).length > 0 ? metadata : undefined;
}

function propertyText(properties: Record<string, unknown>, key: string): string | undefined {
  const value = properties[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function addMetadata<K extends keyof AudioDeviceMetadata>(
  metadata: AudioDeviceMetadata,
  key: K,
  value: AudioDeviceMetadata[K],
): void {
  if (value !== undefined) metadata[key] = value;
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
