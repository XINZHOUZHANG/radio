#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = resolve(SCRIPT_DIR, '..');

function readText(path) {
  return readFileSync(path, 'utf8').replace(/\r\n/g, '\n');
}

export function extractHTTPUsages(source) {
  return [...source.matchAll(
    /\b(?:request|json|data)\(\s*\.(get|post|put|patch|delete)\s*,\s*"([^"]+)"/gs,
  )].map((match) => ({
    method: match[1].toUpperCase(),
    path: match[2],
  }));
}

export function extractSettingsEndpointUsages(source) {
  const entries = [...source.matchAll(
    /loadPath:\s*"([^"]+)"\s*,\s*savePath:\s*(?:"([^"]+)"|(nil))\s*,\s*saveMethod:\s*\.(get|post|put|patch|delete)/gs,
  )];
  return entries.flatMap((match) => {
    const usages = [{ method: 'GET', path: match[1] }];
    if (!match[3]) usages.push({ method: match[4].toUpperCase(), path: match[2] });
    return usages;
  });
}

export function extractOutboundMessageTypes(source) {
  return [...new Set(
    [...source.matchAll(/\bsend\(\s*"([^"]+)"/g)].map((match) => match[1]),
  )];
}

export function extractInboundMessageTypes(source) {
  const start = source.indexOf('private func handle(');
  const end = source.indexOf('private func mergeFrames', start);
  assert(start >= 0 && end > start, 'RadioWebSocket.handle could not be located');
  const handler = source.slice(start, end);
  const caseGroups = [...handler.matchAll(/case\s+((?:"[^"]+"\s*,?\s*)+):/g)];
  return [...new Set(caseGroups.flatMap((group) => (
    [...group[1].matchAll(/"([^"]+)"/g)].map((match) => match[1])
  )))];
}

export function apiPathForClientPath(path) {
  if (path === '/api' || path.startsWith('/api/')) return path;
  return `/api${path.startsWith('/') ? path : `/${path}`}`;
}

function isSwiftInterpolation(segment) {
  return /^\\\([^)]+\)$/.test(segment);
}

export function clientPathMatchesRoute(clientPath, routePath) {
  const clientSegments = apiPathForClientPath(clientPath).split('/');
  const routeSegments = routePath.split('/');
  if (clientSegments.length !== routeSegments.length) return false;
  return clientSegments.every((segment, index) => {
    const declared = routeSegments[index];
    if (declared.startsWith(':')) return segment.length > 0;
    if (isSwiftInterpolation(segment)) return false;
    return segment === declared;
  });
}

export function verifyIOSContract(root = DEFAULT_ROOT) {
  const contract = JSON.parse(readText(join(root, 'docs', 'tx5dr', 'contract.json')));
  const extension = JSON.parse(readText(join(root, 'docs', 'tx5dr', 'mobile-extension-contract.json')));
  const apiSource = readText(join(root, 'ios', 'TX5DRMobile', 'Core', 'API', 'TX5DRAPIClient.swift'));
  const advancedSettingsSource = readText(join(root, 'ios', 'TX5DRMobile', 'Features', 'Settings', 'AdvancedSettingsView.swift'));
  const socketSource = readText(join(root, 'ios', 'TX5DRMobile', 'Core', 'WebSocket', 'RadioWebSocket.swift'));
  const audioSource = readText(join(root, 'ios', 'TX5DRMobile', 'Core', 'Audio', 'TX5DRAudioClient.swift'));
  const codecSource = readText(join(root, 'ios', 'TX5DRMobile', 'Core', 'Audio', 'RealtimeAudioFrameCodec.swift'));
  const patchSource = readText(join(root, extension.implementationPatch));

  const declaredRoutes = [...contract.http.routes, ...extension.http.routes];
  const httpUsages = [
    ...extractHTTPUsages(apiSource),
    ...extractSettingsEndpointUsages(advancedSettingsSource),
  ];
  const missingRoutes = httpUsages.filter((usage) => !declaredRoutes.some((route) => (
    route.method === usage.method && clientPathMatchesRoute(usage.path, route.path)
  )));
  assert.deepEqual(missingRoutes, [], `Undeclared iOS HTTP routes: ${JSON.stringify(missingRoutes)}`);

  for (const route of extension.http.routes) {
    const relativePath = route.path.replace(/^\/api\/auth/, '');
    assert(
      patchSource.includes(`fastify.post('${relativePath}'`),
      `Mobile extension route is absent from the deployment patch: ${route.path}`,
    );
  }

  const messageDirections = new Map(
    contract.websocket.messages.map((message) => [message.value, message.direction]),
  );
  const outbound = extractOutboundMessageTypes(socketSource);
  const invalidOutbound = outbound.filter((type) => ![
    'client-to-server',
    'bidirectional',
  ].includes(messageDirections.get(type)));
  assert.deepEqual(invalidOutbound, [], `Undeclared iOS outbound WebSocket messages: ${invalidOutbound.join(', ')}`);

  const inbound = extractInboundMessageTypes(socketSource);
  const invalidInbound = inbound.filter((type) => ![
    'server-to-client',
    'bidirectional',
    'server-or-specialized-channel',
  ].includes(messageDirections.get(type)));
  assert.deepEqual(invalidInbound, [], `Undeclared iOS inbound WebSocket messages: ${invalidInbound.join(', ')}`);

  assert.equal(contract.websocket.controlPath, '/api/ws');
  assert(socketSource.includes('webSocketURL("/ws")'), 'iOS control socket path changed without a contract update');
  assert(contract.realtimeAudio.compatibilityFrameMagic.includes('TX5D'));
  assert(codecSource.includes('0x5458_3544'), 'iOS TX5D frame magic changed without a contract update');
  for (const direction of ['recv', 'send']) {
    assert(contract.realtimeAudio.supportedDirections.includes(direction));
    assert(audioSource.includes(`realtimeSession(direction: "${direction}")`));
  }

  return {
    httpRoutes: httpUsages.length,
    outboundMessages: outbound.length,
    inboundMessages: inbound.length,
  };
}

function runCli() {
  const root = process.argv[2] ? resolve(process.argv[2]) : DEFAULT_ROOT;
  const result = verifyIOSContract(root);
  process.stdout.write(
    `Verified ${result.httpRoutes} iOS HTTP usages, ${result.outboundMessages} outbound WS messages, and ${result.inboundMessages} inbound WS messages.\n`,
  );
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli();
}
