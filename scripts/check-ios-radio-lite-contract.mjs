#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = (...parts) => readFileSync(join(root, ...parts), 'utf8').replace(/\r\n/g, '\n');

const service = read('radio-lite-server', 'src', 'server', 'radio-lite-service.ts');
const protocol = read('radio-lite-server', 'PROTOCOL.md');
const http = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteHTTPClient.swift');
const session = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteSession.swift');
const media = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteMediaClient.swift');
const frame = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteMediaFrame.swift');
const socket = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteWebSocketChannel.swift');

const httpPaths = [
  '/healthz',
  '/api/v1/setup/status',
  '/api/v1/setup/initialize',
  '/api/v1/session/login',
  '/api/v1/session',
  '/api/v1/session/logout',
  '/api/v1/users',
  '/api/v1/pairing/code',
  '/api/v1/pairing/redeem',
  '/api/v1/device/refresh',
  '/api/v1/radios',
  '/api/v1/logs',
  '/api/v1/logs/grids',
  '/api/v1/logs/export',
  '/api/v1/logs/import',
];
for (const path of httpPaths) {
  assert(http.includes(`"${path}"`), `iOS HTTP client is missing ${path}`);
  assert(service.includes(`"${path}"`), `Radio Lite service is missing ${path}`);
}

const controlMessages = [
  'auth.device',
  'control.acquire',
  'control.heartbeat',
  'control.release',
  'rig.state.get',
  'rig.frequency.set',
  'rig.mode.set',
  'tx.start',
  'tx.heartbeat',
  'tx.stop',
  'digital.snapshot.get',
  'digital.queue.add.decode',
  'digital.queue.add.manual',
  'digital.queue.skip',
  'digital.queue.remove',
  'digital.auto.stop',
];
for (const type of controlMessages) {
  const iosSource = type === 'auth.device' ? socket : session;
  assert(iosSource.includes(`"${type}"`), `iOS control client is missing ${type}`);
  assert(service.includes(`"${type}"`), `Radio Lite service is missing ${type}`);
}

for (const type of ['media.subscribe', 'media.network', 'media.uplink.bind', 'media.unsubscribe']) {
  assert(media.includes(`"${type}"`), `iOS media client is missing ${type}`);
  assert(service.includes(`"${type}"`), `Radio Lite service is missing ${type}`);
}

assert(socket.includes('"radio-lite.v1"'));
assert(service.includes('"radio-lite.v1"'));
assert(/The fixed header is 16\s+bytes:/u.test(protocol));
assert(frame.includes('static let headerBytes = 16'));
assert(frame.includes('case audioDownlink = 1'));
assert(frame.includes('case audioUplink = 2'));
assert(frame.includes('case spectrum = 3'));
assert(frame.includes('case statistics = 4'));
assert(protocol.includes('mono at 16 kHz'));
assert(protocol.includes('five minutes'));

process.stdout.write(
  `Verified ${httpPaths.length} HTTP paths, ${controlMessages.length} control messages, media messages, and the binary frame contract.\n`,
);
