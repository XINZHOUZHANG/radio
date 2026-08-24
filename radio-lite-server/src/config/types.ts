export const RADIO_CONFIG_VERSION = 1;

export type SerialConnection = {
  kind: "managed-serial";
  devicePath: string;
  baudRate?: number;
};

export type NetworkRigctldConnection = {
  kind: "network-rigctld";
  host: string;
  port: number;
};

export type DummyConnection = {
  kind: "hamlib-dummy";
};

export type RigConnection = SerialConnection | NetworkRigctldConnection | DummyConnection;

export type AudioEndpoint = {
  backend: "alsa" | "pulse";
  id: string;
  label?: string;
};

export type StationIdentity = {
  callsign: string;
  grid?: string;
};

export type RadioProfile = {
  id: string;
  name: string;
  hamlibModelId: number;
  connection: RigConnection;
  audioInput: AudioEndpoint;
  audioOutput: AudioEndpoint;
  station: StationIdentity;
  hardwareTxEnabled: boolean;
};

export type RadioConfigFile = {
  version: typeof RADIO_CONFIG_VERSION;
  radios: RadioProfile[];
};

const ID_PATTERN = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const CALLSIGN_PATTERN = /^[A-Z0-9/]{3,16}$/;
const GRID_PATTERN = /^[A-R]{2}[0-9]{2}(?:[A-X]{2})?$/;
const SAFE_HOST_PATTERN = /^[A-Za-z0-9._:-]{1,253}$/;
const ALLOWED_BAUD_RATES = new Set([
  1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400,
]);

export function parseRadioConfig(value: unknown): RadioConfigFile {
  const root = objectValue(value, "configuration");
  exactKeys(root, ["version", "radios"], "configuration");
  if (root.version !== RADIO_CONFIG_VERSION) {
    throw new Error(`unsupported radio configuration version: ${String(root.version)}`);
  }
  if (!Array.isArray(root.radios)) {
    throw new TypeError("configuration.radios must be an array");
  }
  const radios = root.radios.map((radio, index) =>
    parseRadioProfile(radio, `configuration.radios[${index}]`),
  );
  const ids = new Set<string>();
  for (const radio of radios) {
    if (ids.has(radio.id)) {
      throw new Error(`duplicate radio id: ${radio.id}`);
    }
    ids.add(radio.id);
  }
  return { version: RADIO_CONFIG_VERSION, radios };
}

export function parseRadioProfile(value: unknown, field = "radio"): RadioProfile {
  const radio = objectValue(value, field);
  exactKeys(
    radio,
    [
      "id",
      "name",
      "hamlibModelId",
      "connection",
      "audioInput",
      "audioOutput",
      "station",
      "hardwareTxEnabled",
    ],
    field,
  );
  const id = text(radio.id, `${field}.id`, 1, 32);
  if (!ID_PATTERN.test(id)) {
    throw new Error(`${field}.id must match ${ID_PATTERN}`);
  }
  const name = text(radio.name, `${field}.name`, 1, 64);
  const hamlibModelId = positiveInteger(radio.hamlibModelId, `${field}.hamlibModelId`);
  const hardwareTxEnabled = booleanValue(
    radio.hardwareTxEnabled,
    `${field}.hardwareTxEnabled`,
  );
  if (hamlibModelId === 1 && hardwareTxEnabled) {
    throw new Error("Hamlib Dummy cannot enable hardware transmission");
  }
  const connection = parseConnection(radio.connection, `${field}.connection`);
  if ((hamlibModelId === 1) !== (connection.kind === "hamlib-dummy")) {
    throw new Error("Hamlib Dummy model and hamlib-dummy connection must be selected together");
  }
  return {
    id,
    name,
    hamlibModelId,
    connection,
    audioInput: parseAudioEndpoint(radio.audioInput, `${field}.audioInput`),
    audioOutput: parseAudioEndpoint(radio.audioOutput, `${field}.audioOutput`),
    station: parseStation(radio.station, `${field}.station`),
    hardwareTxEnabled,
  };
}

function parseConnection(value: unknown, field: string): RigConnection {
  const connection = objectValue(value, field);
  const kind = text(connection.kind, `${field}.kind`, 1, 32);
  if (kind === "hamlib-dummy") {
    exactKeys(connection, ["kind"], field);
    return { kind };
  }
  if (kind === "managed-serial") {
    exactKeys(connection, ["kind", "devicePath", "baudRate"], field);
    const devicePath = text(connection.devicePath, `${field}.devicePath`, 1, 512);
    if (!devicePath.startsWith("/dev/") || /[\0\r\n]/u.test(devicePath)) {
      throw new Error(`${field}.devicePath must be an absolute /dev path`);
    }
    const baudRate = connection.baudRate === undefined
      ? undefined
      : positiveInteger(connection.baudRate, `${field}.baudRate`);
    if (baudRate !== undefined && !ALLOWED_BAUD_RATES.has(baudRate)) {
      throw new Error(`${field}.baudRate is not a supported standard rate`);
    }
    return baudRate === undefined
      ? { kind, devicePath }
      : { kind, devicePath, baudRate };
  }
  if (kind === "network-rigctld") {
    exactKeys(connection, ["kind", "host", "port"], field);
    const host = text(connection.host, `${field}.host`, 1, 253);
    if (!SAFE_HOST_PATTERN.test(host) || host === "0.0.0.0" || host === "::") {
      throw new Error(`${field}.host is invalid`);
    }
    const port = portNumber(connection.port, `${field}.port`);
    return { kind, host, port };
  }
  throw new Error(`${field}.kind is unsupported`);
}

function parseAudioEndpoint(value: unknown, field: string): AudioEndpoint {
  const endpoint = objectValue(value, field);
  exactKeys(endpoint, ["backend", "id", "label"], field);
  if (endpoint.backend !== "alsa" && endpoint.backend !== "pulse") {
    throw new Error(`${field}.backend must be alsa or pulse`);
  }
  const id = text(endpoint.id, `${field}.id`, 1, 256);
  if (/[\0\r\n]/u.test(id)) {
    throw new Error(`${field}.id contains a prohibited character`);
  }
  const label = endpoint.label === undefined
    ? undefined
    : text(endpoint.label, `${field}.label`, 1, 128);
  return label === undefined
    ? { backend: endpoint.backend, id }
    : { backend: endpoint.backend, id, label };
}

function parseStation(value: unknown, field: string): StationIdentity {
  const station = objectValue(value, field);
  exactKeys(station, ["callsign", "grid"], field);
  const callsign = text(station.callsign, `${field}.callsign`, 3, 16).toUpperCase();
  if (!CALLSIGN_PATTERN.test(callsign)) {
    throw new Error(`${field}.callsign is invalid`);
  }
  if (station.grid === undefined) {
    return { callsign };
  }
  const grid = text(station.grid, `${field}.grid`, 4, 6).toUpperCase();
  if (!GRID_PATTERN.test(grid)) {
    throw new Error(`${field}.grid is not a 4 or 6 character Maidenhead locator`);
  }
  return { callsign, grid };
}

function objectValue(value: unknown, field: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function exactKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  field: string,
): void {
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(value)) {
    if (!allowedSet.has(key)) {
      throw new Error(`${field} contains unknown field: ${key}`);
    }
  }
  for (const required of allowed) {
    if (!(required in value) && required !== "baudRate" && required !== "label" && required !== "grid") {
      throw new Error(`${field}.${required} is required`);
    }
  }
}

function text(value: unknown, field: string, min: number, max: number): string {
  if (typeof value !== "string") {
    throw new TypeError(`${field} must be text`);
  }
  const normalized = value.trim();
  if (normalized.length < min || normalized.length > max) {
    throw new Error(`${field} length must be ${min}..${max}`);
  }
  return normalized;
}

function positiveInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || (value as number) <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value as number;
}

function portNumber(value: unknown, field: string): number {
  const port = positiveInteger(value, field);
  if (port > 65_535) {
    throw new Error(`${field} must be in 1..65535`);
  }
  return port;
}

function booleanValue(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw new TypeError(`${field} must be boolean`);
  }
  return value;
}
