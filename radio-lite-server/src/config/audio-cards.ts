import type { DiscoveredAudioDevice } from "./discovery.ts";

export type DiscoveredAudioCard = {
  hardwareId: string;
  label: string;
  transport: "usb" | "pci" | "virtual" | "unknown";
  complete: boolean;
  input?: DiscoveredAudioDevice;
  output?: DiscoveredAudioDevice;
};

export type AudioCardEndpoints = {
  inputs: readonly DiscoveredAudioDevice[];
  outputs: readonly DiscoveredAudioDevice[];
};

type StableIdentity = {
  hardwareId: string;
  transport: DiscoveredAudioCard["transport"];
  discriminator?: string;
  priority: number;
};

export function pairAudioCards({ inputs, outputs }: AudioCardEndpoints): DiscoveredAudioCard[] {
  const endpoints = [...inputs, ...outputs].filter((endpoint) => !isMonitorEndpoint(endpoint));
  const parent = endpoints.map((_, index) => index);
  const representativeByToken = new Map<string, number>();
  for (const [index, endpoint] of endpoints.entries()) {
    for (const token of correlationTokens(endpoint)) {
      const prior = representativeByToken.get(token);
      if (prior === undefined) {
        representativeByToken.set(token, index);
      } else {
        union(parent, prior, index);
      }
    }
  }

  const groups = new Map<number, DiscoveredAudioDevice[]>();
  for (const [index, endpoint] of endpoints.entries()) {
    const root = find(parent, index);
    const group = groups.get(root) ?? [];
    group.push(endpoint);
    groups.set(root, group);
  }
  const cards = [...groups.values()].map((group) => toCard(group));
  disambiguateLabels(cards);
  return cards.sort((left, right) =>
    left.hardwareId.localeCompare(right.hardwareId) || left.label.localeCompare(right.label));
}

function isMonitorEndpoint(endpoint: DiscoveredAudioDevice): boolean {
  return endpoint.direction === "input" && (
    endpoint.metadata?.isMonitor === true || endpoint.id.endsWith(".monitor")
  );
}

function toCard(endpoints: readonly DiscoveredAudioDevice[]): DiscoveredAudioCard {
  const identities = endpoints.flatMap(stableIdentities);
  const identity = selectStableIdentity(identities);
  const input = singleEndpoint(endpoints, "input");
  const output = singleEndpoint(endpoints, "output");
  const labelSource = input ?? output ?? endpoints[0];
  const stable = identity !== undefined;
  return {
    hardwareId: identity?.hardwareId ?? "unknown",
    label: labelFor(labelSource?.label ?? "Unknown audio device", identity),
    transport: identity?.transport ?? "unknown",
    complete: stable && input !== undefined && output !== undefined,
    ...(input === undefined ? {} : { input }),
    ...(output === undefined ? {} : { output }),
  };
}

function stableIdentities(endpoint: DiscoveredAudioDevice): StableIdentity[] {
  const metadata = endpoint.metadata;
  if (metadata === undefined) return [];
  const vendorId = hexadecimal(metadata.vendorId);
  const productId = hexadecimal(metadata.productId);
  const serial = stablePart(metadata.deviceSerial);
  const topology = stablePart(metadata.busPath) ?? stablePart(metadata.topology);
  const identities: StableIdentity[] = [];
  if (serial !== undefined) {
    identities.push({
      hardwareId: vendorId !== undefined && productId !== undefined
        ? `usb:${vendorId}:${productId}:${serial}`
        : `usb:serial:${serial}`,
      transport: "usb",
      discriminator: serial,
      priority: 1,
    });
  }
  if (vendorId !== undefined && productId !== undefined && topology !== undefined) {
    identities.push({
      hardwareId: `usb:${vendorId}:${productId}:${topology}`,
      transport: "usb",
      discriminator: topology,
      priority: 2,
    });
  }
  const alsaCardId = stableAlsaCardId(metadata.alsaCardId);
  if (alsaCardId !== undefined) {
    identities.push({
      hardwareId: `alsa:${alsaCardId}`,
      transport: alsaCardId.startsWith("PCI") ? "pci" : "unknown",
      priority: 3,
    });
  }
  return identities;
}

function selectStableIdentity(identities: readonly StableIdentity[]): StableIdentity | undefined {
  for (const priority of [1, 2, 3]) {
    const candidates = identities.filter((identity) => identity.priority === priority);
    const unique = new Map(candidates.map((identity) => [identity.hardwareId, identity]));
    if (unique.size === 1) return unique.values().next().value;
    if (unique.size > 1) return undefined;
  }
  return undefined;
}

function correlationTokens(endpoint: DiscoveredAudioDevice): string[] {
  const tokens = stableIdentities(endpoint).map((identity) => `identity:${identity.hardwareId}`);
  const alsaCard = normalized(endpoint.metadata?.alsaCard);
  if (alsaCard !== undefined) tokens.push(`alsa-card:${alsaCard}`);
  return tokens;
}

function singleEndpoint(
  endpoints: readonly DiscoveredAudioDevice[],
  direction: DiscoveredAudioDevice["direction"],
): DiscoveredAudioDevice | undefined {
  const matches = endpoints.filter((endpoint) => endpoint.direction === direction);
  return matches.length === 1 ? matches[0] : undefined;
}

function labelFor(label: string, identity: StableIdentity | undefined): string {
  return identity?.discriminator === undefined ? label : `${label} (${identity.discriminator})`;
}

function disambiguateLabels(cards: DiscoveredAudioCard[]): void {
  const counts = new Map<string, number>();
  for (const card of cards) counts.set(card.label, (counts.get(card.label) ?? 0) + 1);
  for (const card of cards) {
    if ((counts.get(card.label) ?? 0) > 1) card.label = `${card.label} (${card.hardwareId})`;
  }
}

function normalized(value: string | undefined): string | undefined {
  const normalized = value?.trim();
  return normalized ? normalized : undefined;
}

function stablePart(value: string | undefined): string | undefined {
  const part = normalized(value);
  return part !== undefined && /^[A-Za-z0-9._-]{1,128}$/u.test(part) ? part : undefined;
}

function hexadecimal(value: string | undefined): string | undefined {
  const part = normalized(value);
  return part !== undefined && /^[0-9a-f]{4}$/iu.test(part) ? part.toLowerCase() : undefined;
}

function stableAlsaCardId(value: string | undefined): string | undefined {
  const cardId = stablePart(value);
  return cardId !== undefined && /[A-Za-z]/u.test(cardId) ? cardId : undefined;
}

function find(parent: number[], index: number): number {
  if (parent[index] !== index) parent[index] = find(parent, parent[index]!);
  return parent[index]!;
}

function union(parent: number[], left: number, right: number): void {
  const leftRoot = find(parent, left);
  const rightRoot = find(parent, right);
  if (leftRoot !== rightRoot) parent[rightRoot] = leftRoot;
}
