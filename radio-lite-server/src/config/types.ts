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

export type NoRadioConnection = {
  kind: "no-radio";
};

export type IcomWlanConnection = {
  kind: "icom-wlan";
  host: string;
  port?: number;
  username: string;
  password: string;
};

export type TciConnection = {
  kind: "tci";
  url: string;
  trx: number;
  allowPublicEndpoint?: boolean;
};

export type RigConnection =
  | SerialConnection
  | NetworkRigctldConnection
  | DummyConnection
  | NoRadioConnection
  | IcomWlanConnection
  | TciConnection;

export type PublicRigConnection =
  | SerialConnection
  | NetworkRigctldConnection
  | DummyConnection
  | NoRadioConnection
  | Omit<IcomWlanConnection, "password">
  | TciConnection;

export type AudioEndpoint = {
  backend: "alsa" | "pulse";
  id: string;
  label?: string;
};

export const AUDIO_LATENCIES = ["low", "balanced", "stable"] as const;

export type AudioLatency = typeof AUDIO_LATENCIES[number];

export type AudioRoute =
  | { kind: "system-device"; hardwareId: string; latency: AudioLatency }
  | { kind: "driver-stream" }
  | { kind: "none" };

export const PTT_METHODS = [
  "RIG",
  "DTR",
  "RTS",
  "Parallel",
  "CM108",
  "GPIO",
  "GPION",
  "None",
] as const;

export type PttMethod = typeof PTT_METHODS[number];

export type PttConfiguration = {
  method: PttMethod;
  path?: string;
  bit?: number;
};

export const SERIAL_BAUD_RATES = [
  1_200,
  2_400,
  4_800,
  9_600,
  19_200,
  38_400,
  57_600,
  115_200,
  230_400,
] as const;

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
  audioRoute?: AudioRoute;
  ptt: PttConfiguration;
  station: StationIdentity;
  hardwareTxEnabled: boolean;
};

export type PublicRadioProfile = {
  id: string;
  name: string;
  hamlibModelId?: number;
  connection: PublicRigConnection;
  audioInput?: AudioEndpoint;
  audioOutput?: AudioEndpoint;
  audioRoute?: AudioRoute;
  ptt: PttConfiguration;
  station: StationIdentity;
  hardwareTxEnabled: boolean;
};

export type PublicRadioConfigFile = {
  version: typeof RADIO_CONFIG_VERSION;
  radios: PublicRadioProfile[];
};

export type RadioConfigFile = {
  version: typeof RADIO_CONFIG_VERSION;
  radios: RadioProfile[];
};

const ID_PATTERN = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const CALLSIGN_PATTERN = /^[A-Z0-9/]{3,16}$/;
const GRID_PATTERN = /^[A-R]{2}[0-9]{2}(?:[A-X]{2})?$/;
const SAFE_HOST_PATTERN = /^[A-Za-z0-9._:-]{1,253}$/;
const ALLOWED_BAUD_RATES = new Set<number>(SERIAL_BAUD_RATES);
const ALLOWED_PTT_METHODS = new Set<string>(PTT_METHODS);
const ALLOWED_AUDIO_LATENCIES = new Set<string>(AUDIO_LATENCIES);
const STABLE_HARDWARE_ID_PATTERN = /^(?:usb:(?:[0-9a-f]{4}:[0-9a-f]{4}:|serial:)[A-Za-z0-9._-]{1,128}|alsa:(?=[A-Za-z0-9_]*[A-Za-z])[A-Za-z0-9_]{1,15})$/iu;

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
      "audioRoute",
      "ptt",
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
  const connection = parseConnection(radio.connection, `${field}.connection`);
  const legacyConnection = connection.kind === "managed-serial" ||
    connection.kind === "network-rigctld" || connection.kind === "hamlib-dummy";
  if (legacyConnection && radio.hamlibModelId === undefined) {
    throw new Error(`${field}.hamlibModelId is required`);
  }
  if (!legacyConnection && radio.hamlibModelId !== undefined) {
    throw new Error(`${field}.hamlibModelId is not used by ${connection.kind}`);
  }
  const hamlibModelId = legacyConnection
    ? positiveInteger(radio.hamlibModelId, `${field}.hamlibModelId`)
    : undefined;
  const hardwareTxEnabled = booleanValue(
    radio.hardwareTxEnabled,
    `${field}.hardwareTxEnabled`,
  );
  if (hamlibModelId === 1 && hardwareTxEnabled) {
    throw new Error("Hamlib Dummy cannot enable hardware transmission");
  }
  if (legacyConnection && ((hamlibModelId === 1) !== (connection.kind === "hamlib-dummy"))) {
    throw new Error("Hamlib Dummy model and hamlib-dummy connection must be selected together");
  }
  const ptt = radio.ptt === undefined
    ? {
        method: connection.kind === "hamlib-dummy" || connection.kind === "no-radio"
          ? "None" as const
          : "RIG" as const,
      }
    : parsePttConfiguration(radio.ptt, `${field}.ptt`);
  if (connection.kind === "network-rigctld" && ptt.method !== "RIG") {
    throw new Error(`${field}.connection network rigctld manages PTT externally`);
  }
  if (hardwareTxEnabled && ptt.method === "None") {
    throw new Error(`${field}.ptt None cannot enable hardware transmission`);
  }
  const audioRoute = radio.audioRoute === undefined
    ? undefined
    : parseAudioRoute(radio.audioRoute, `${field}.audioRoute`);
  const requiresAudioEndpoints = audioRoute?.kind !== "driver-stream" &&
    audioRoute?.kind !== "none";
  if (requiresAudioEndpoints && radio.audioInput === undefined) {
    throw new Error(`${field}.audioInput is required`);
  }
  if (requiresAudioEndpoints && radio.audioOutput === undefined) {
    throw new Error(`${field}.audioOutput is required`);
  }
  const audioInput = radio.audioInput === undefined
    ? undefined
    : parseAudioEndpoint(radio.audioInput, `${field}.audioInput`);
  const audioOutput = radio.audioOutput === undefined
    ? undefined
    : parseAudioEndpoint(radio.audioOutput, `${field}.audioOutput`);
  const parsed = {
    id,
    name,
    ...(hamlibModelId === undefined ? {} : { hamlibModelId }),
    connection,
    ...(audioInput === undefined ? {} : { audioInput }),
    ...(audioOutput === undefined ? {} : { audioOutput }),
    ...(audioRoute === undefined ? {} : { audioRoute }),
    ptt,
    station: parseStation(radio.station, `${field}.station`),
    hardwareTxEnabled,
  };
  return parsed as RadioProfile;
}

export function toPublicRadioProfile(profile: RadioProfile): PublicRadioProfile {
  const connection = publicConnection(profile.connection);
  return {
    id: profile.id,
    name: profile.name,
    ...(hasOwn(profile, "hamlibModelId") ? { hamlibModelId: profile.hamlibModelId } : {}),
    connection,
    ...(hasOwn(profile, "audioInput") ? { audioInput: publicAudioEndpoint(profile.audioInput) } : {}),
    ...(hasOwn(profile, "audioOutput") ? { audioOutput: publicAudioEndpoint(profile.audioOutput) } : {}),
    ...(profile.audioRoute === undefined ? {} : { audioRoute: publicAudioRoute(profile.audioRoute) }),
    ptt: {
      method: profile.ptt.method,
      ...(profile.ptt.path === undefined ? {} : { path: profile.ptt.path }),
      ...(profile.ptt.bit === undefined ? {} : { bit: profile.ptt.bit }),
    },
    station: {
      callsign: profile.station.callsign,
      ...(profile.station.grid === undefined ? {} : { grid: profile.station.grid }),
    },
    hardwareTxEnabled: profile.hardwareTxEnabled,
  };
}

function publicAudioEndpoint(endpoint: AudioEndpoint): AudioEndpoint {
  return {
    backend: endpoint.backend,
    id: endpoint.id,
    ...(endpoint.label === undefined ? {} : { label: endpoint.label }),
  };
}

function publicAudioRoute(route: AudioRoute): AudioRoute {
  return route.kind === "system-device"
    ? {
        kind: route.kind,
        hardwareId: route.hardwareId,
        latency: route.latency,
      }
    : { kind: route.kind };
}

function publicConnection(connection: RigConnection): PublicRigConnection {
  switch (connection.kind) {
    case "managed-serial":
      return {
        kind: connection.kind,
        devicePath: connection.devicePath,
        ...(connection.baudRate === undefined ? {} : { baudRate: connection.baudRate }),
      };
    case "network-rigctld":
      return { kind: connection.kind, host: connection.host, port: connection.port };
    case "hamlib-dummy":
    case "no-radio":
      return { kind: connection.kind };
    case "icom-wlan":
      return {
        kind: connection.kind,
        host: connection.host,
        ...(connection.port === undefined ? {} : { port: connection.port }),
        username: connection.username,
      };
    case "tci":
      return {
        kind: connection.kind,
        url: connection.url,
        trx: connection.trx,
        ...(connection.allowPublicEndpoint === undefined
          ? {}
          : { allowPublicEndpoint: connection.allowPublicEndpoint }),
      };
  }
}

function parseAudioRoute(value: unknown, field: string): AudioRoute {
  const route = objectValue(value, field);
  const kind = text(route.kind, `${field}.kind`, 1, 32);
  if (kind === "system-device") {
    exactKeys(route, ["kind", "hardwareId", "latency"], field);
    const hardwareId = text(route.hardwareId, `${field}.hardwareId`, 1, 256);
    if (!STABLE_HARDWARE_ID_PATTERN.test(hardwareId)) {
      throw new Error(`${field}.hardwareId must identify a stable card`);
    }
    const latency = text(route.latency, `${field}.latency`, 1, 16);
    if (!ALLOWED_AUDIO_LATENCIES.has(latency)) {
      throw new Error(`${field}.latency is unsupported`);
    }
    return { kind, hardwareId, latency: latency as AudioLatency };
  }
  if (kind === "driver-stream" || kind === "none") {
    exactKeys(route, ["kind"], field);
    return { kind };
  }
  throw new Error(`${field}.kind is unsupported`);
}

function parsePttConfiguration(value: unknown, field: string): PttConfiguration {
  const ptt = objectValue(value, field);
  exactKeys(ptt, ["method", "path", "bit"], field);
  const method = text(ptt.method, `${field}.method`, 1, 32);
  if (!ALLOWED_PTT_METHODS.has(method)) {
    throw new Error(`${field}.method is unsupported`);
  }
  const typedMethod = method as PttMethod;
  const path = ptt.path === undefined
    ? undefined
    : text(ptt.path, `${field}.path`, 1, 512);
  const pathRequired = typedMethod === "DTR" ||
    typedMethod === "RTS" ||
    typedMethod === "Parallel" ||
    typedMethod === "CM108" ||
    typedMethod === "GPIO" ||
    typedMethod === "GPION";
  if (path !== undefined) {
    if (!pathRequired) {
      throw new Error(`${field}.path is not used by ${typedMethod}`);
    }
    if (!path.startsWith("/dev/") || /[\0\r\n]/u.test(path)) {
      throw new Error(`${field}.path must be an absolute /dev path`);
    }
  } else if (pathRequired) {
    throw new Error(`${field}.path is required by ${typedMethod}`);
  }
  const bit = ptt.bit === undefined ? undefined : ptt.bit;
  if (bit !== undefined) {
    if (!Number.isSafeInteger(bit) || (bit as number) < 0 || (bit as number) > 7) {
      throw new Error(`${field}.bit must be in 0..7`);
    }
    if (typedMethod !== "GPIO" && typedMethod !== "GPION") {
      throw new Error(`${field}.bit is only used by GPIO or GPION`);
    }
  }
  return {
    method: typedMethod,
    ...(path === undefined ? {} : { path }),
    ...(bit === undefined ? {} : { bit: bit as number }),
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
  if (kind === "no-radio") {
    exactKeys(connection, ["kind"], field);
    return { kind };
  }
  if (kind === "icom-wlan") {
    exactKeys(connection, ["kind", "host", "port", "username", "password"], field);
    const host = safeHost(connection.host, `${field}.host`);
    const port = connection.port === undefined
      ? undefined
      : portNumber(connection.port, `${field}.port`);
    const username = text(connection.username, `${field}.username`, 1, 128);
    const password = secretText(connection.password, `${field}.password`, 1, 1_024);
    return {
      kind,
      host,
      ...(port === undefined ? {} : { port }),
      username,
      password,
    };
  }
  if (kind === "tci") {
    exactKeys(connection, ["kind", "url", "trx", "allowPublicEndpoint"], field);
    const url = webSocketUrl(connection.url, `${field}.url`);
    const trx = nonNegativeInteger(connection.trx, `${field}.trx`);
    const allowPublicEndpoint = connection.allowPublicEndpoint === undefined
      ? undefined
      : booleanValue(connection.allowPublicEndpoint, `${field}.allowPublicEndpoint`);
    return {
      kind,
      url,
      trx,
      ...(allowPublicEndpoint === undefined ? {} : { allowPublicEndpoint }),
    };
  }
  throw new Error(`${field}.kind is unsupported`);
}

function safeHost(value: unknown, field: string): string {
  const host = text(value, field, 1, 253);
  if (!SAFE_HOST_PATTERN.test(host) || host === "0.0.0.0" || host === "::") {
    throw new Error(`${field} is invalid`);
  }
  return host;
}

function webSocketUrl(value: unknown, field: string): string {
  const raw = text(value, field, 1, 2_048);
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(`${field} is invalid`);
  }
  if ((parsed.protocol !== "ws:" && parsed.protocol !== "wss:") || parsed.hostname.length === 0) {
    throw new Error(`${field} must use ws or wss`);
  }
  return raw;
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
    if (
      !(required in value) &&
      required !== "baudRate" &&
      required !== "label" &&
      required !== "grid" &&
      required !== "ptt" &&
      required !== "path" &&
      required !== "bit"
      && required !== "audioRoute"
      && required !== "hamlibModelId"
      && required !== "audioInput"
      && required !== "audioOutput"
      && required !== "port"
      && required !== "allowPublicEndpoint"
    ) {
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

function nonNegativeInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error(`${field} must be a non-negative integer`);
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

function secretText(value: unknown, field: string, min: number, max: number): string {
  if (typeof value !== "string" || value.length < min || value.length > max) {
    throw new Error(`${field} must be text with length ${min}..${max}`);
  }
  return value;
}

function hasOwn(value: object, key: PropertyKey): boolean {
  return Object.prototype.hasOwnProperty.call(value, key);
}
