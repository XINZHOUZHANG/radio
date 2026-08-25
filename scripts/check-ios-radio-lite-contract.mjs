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
const models = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteModels.swift');
const radioView = read('ios', 'TX5DRMobile', 'Features', 'RadioLite', 'RadioLiteRadioView.swift');
const media = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteMediaClient.swift');
const audio = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteAudioEngine.swift');
const microphonePolicy = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteMicrophonePolicy.swift');
const receiveMonitoringPreference = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteReceiveMonitoringPreference.swift');
const rigControls = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteRigControls.swift');
const spectrumAGC = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteSpectrumAGC.swift');
const digitalSlotClock = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteDigitalSlotClock.swift');
const rigControlsView = read('ios', 'TX5DRMobile', 'Features', 'RadioLite', 'RadioLiteRigControlsView.swift');
const frame = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteMediaFrame.swift');
const socket = read('ios', 'TX5DRMobile', 'Core', 'RadioLite', 'RadioLiteWebSocketChannel.swift');
const hamlibRig = read('radio-lite-server', 'src', 'rig', 'hamlib-rig.ts');
const mediaHub = read('radio-lite-server', 'src', 'media', 'media-hub.ts');

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
  'rig.controls.get',
  'rig.frequency.set',
  'rig.mode.set',
  'rig.control.set',
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
  const iosSource = type === 'auth.device'
    ? socket
    : type === 'rig.controls.get' || type === 'rig.control.set'
      ? rigControls
      : session;
  assert(iosSource.includes(`"${type}"`), `iOS control client is missing ${type}`);
  assert(service.includes(`"${type}"`), `Radio Lite service is missing ${type}`);
}

for (const type of ['media.subscribe', 'media.network', 'media.uplink.bind', 'media.unsubscribe']) {
  assert(media.includes(`"${type}"`), `iOS media client is missing ${type}`);
  assert(service.includes(`"${type}"`), `Radio Lite service is missing ${type}`);
}

assert(socket.includes('"radio-lite.v1"'));
assert(service.includes('"radio-lite.v1"'));
for (const type of ['media.subscribe', 'media.network', 'media.uplink.bind', 'media.unsubscribe']) {
  assert(socket.includes(`"${type}"`), `iOS socket correlation is missing ${type}`);
}
assert(socket.includes('object["requestId"] = .string(requestId)'));
assert(socket.includes('item.requestId == requestId'));
assert(socket.includes('item.requestType == requestType'));
assert(socket.includes('resolvedPendingRequest && (type == "command.error" || type == "media.error")'));
assert(service.includes('const correlation = mediaRequestCorrelation(value)'));
assert(service.includes('...correlation'));
assert(/Asynchronous\s+errors[\s\S]+deliberately omit both fields/u.test(protocol));
assert(/The fixed header is 16\s+bytes:/u.test(protocol));
assert(frame.includes('static let headerBytes = 16'));
assert(frame.includes('case audioDownlink = 1'));
assert(frame.includes('case audioUplink = 2'));
assert(frame.includes('case spectrum = 3'));
assert(frame.includes('case statistics = 4'));
assert(frame.includes('struct RadioLiteSpectrumCapability'));
assert(frame.includes('struct RadioLiteSpectrumHistory'));
assert(frame.includes('static func unavailable(reason: String)'));
assert(media.includes('spectrumCapability'));
assert(media.includes('spectrumHistory'));
assert(media.includes('spectrumCapability = RadioLiteSpectrumCapability.unavailable'));
assert(session.includes('voicePTTStartupTask = Task'));
assert(session.includes('voicePTTStartupTask?.cancel()'));
assert(session.includes('transmitEpoch.owns(generation)'));
assert(session.includes('stopUplink(transmitToken: uplink.transmitToken, epoch: uplink.epoch)'));
assert(session.includes('receiveAudioStartupTask = task'));
assert(session.includes('receiveAudioStartupTask?.cancel()'));
assert(session.includes('receiveAudioEpoch.owns(generation)'));
assert(session.includes('func stopReceiveAudio()'));
assert(radioView.includes('session.stopReceiveAudio()'));
assert(media.includes('struct RadioLiteUplinkOwnershipState'));
assert(media.includes('RadioLiteMediaFailurePresentation.route'));
assert(!media.includes('pendingRequestCount'));
assert(!media.includes('requestOwner'));
assert(mediaHub.includes('t: "media.uplink.ended"'));
assert(mediaHub.includes('transmitToken,'));
assert(media.includes('stopUplink(transmitToken: transmitToken)'));
assert(protocol.includes('delayed event'));
assert(audio.includes('struct RadioLiteCaptureEpochState'));
assert(audio.includes('try Task.checkCancellation()'));
assert(audio.includes('stopMicrophoneCapture(epoch:'));
assert(audio.includes('ownership: ownership'));
assert(audio.includes('captureEpochState.isActive(ownership)'));
assert(audio.includes('microphoneTelemetryLimiter.shouldPublish'));
assert(models.includes('case dataUpper = "DATA-U"'));
assert(models.includes('case dataLower = "DATA-L"'));
assert(models.includes('case .dataUpper: "PKTUSB"'));
assert(models.includes('case .dataLower: "PKTLSB"'));
assert(session.includes('"mode": .string(mode.hamlibMode)'));
assert(radioView.includes('mode.matches(readback: session.rigState?.mode)'));
assert(hamlibRig.includes('["DIGU", "PKTUSB"]'));
assert(hamlibRig.includes('["DIGL", "PKTLSB"]'));
assert(protocol.includes('DATA-U/DATA-L labels'));
assert(protocol.includes('mono at 16 kHz'));
assert(protocol.includes('five minutes'));
assert(radioView.includes('RadioLiteRigControlsView('));
assert(rigControlsView.includes('session.refreshRigControls()'));
assert(rigControlsView.includes('session.setRigControl(control.id, value: value)'));
assert(microphonePolicy.includes('audioSessionMode: .measurement'));
assert(microphonePolicy.includes('audioSessionMode: .voiceChat'));
assert(receiveMonitoringPreference.includes('radioPageDidAppear()'));
assert(spectrumAGC.includes('smoothingFactor'));
assert(digitalSlotClock.includes('case "FT8"'));
assert(digitalSlotClock.includes('case "FT4"'));

process.stdout.write(
  `Verified ${httpPaths.length} HTTP paths, ${controlMessages.length} control messages, media messages, and the binary frame contract.\n`,
);
