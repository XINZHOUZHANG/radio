#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = (...parts) => readFileSync(join(root, ...parts), 'utf8').replace(/\r\n/g, '\n');

const service = read('radio-lite-server', 'src', 'server', 'radio-lite-service.ts');
const logStore = read('radio-lite-server', 'src', 'log', 'adif-log-store.ts');
const protocol = read('radio-lite-server', 'PROTOCOL.md');
const http = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteHTTPClient.swift');
const session = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteSession.swift');
const server = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteServer.swift');
const rootView = read('ios', 'RadioLite', 'App', 'RootView.swift');
const voicePTTStartup = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteVoicePTTStartup.swift');
const credentialRefresh = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteCredentialRefreshCoordinator.swift');
const operationEpoch = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteOperationEpoch.swift');
const credentialStore = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteCredentialStore.swift');
const models = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteModels.swift');
const radioView = read('ios', 'RadioLite', 'Features', 'RadioLite', 'RadioLiteRadioView.swift');
const media = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteMediaClient.swift');
const audio = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteAudioEngine.swift');
const audioRuntimePolicy = read('ios', 'RadioLite', 'Core', 'Support', 'AudioRuntimePolicy.swift');
const microphonePolicy = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteMicrophonePolicy.swift');
const receiveMonitoringPreference = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteReceiveMonitoringPreference.swift');
const rigControls = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteRigControls.swift');
const capabilityGroupView = read('ios', 'RadioLite', 'Features', 'RadioLite', 'RadioLiteCapabilityGroupView.swift');
const capabilityControlRow = read('ios', 'RadioLite', 'Features', 'RadioLite', 'RadioLiteCapabilityControlRow.swift');
const spectrumAGC = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteSpectrumAGC.swift');
const digitalSlotClock = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteDigitalSlotClock.swift');
const rigControlsView = read('ios', 'RadioLite', 'Features', 'RadioLite', 'RadioLiteRigControlsView.swift');
const deviceConfiguration = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteDeviceConfiguration.swift');
const deviceConfigurationView = read('ios', 'RadioLite', 'Features', 'RadioLite', 'RadioLiteDeviceConfigurationView.swift');
const hardwarePreflight = read('radio-lite-server', 'src', 'config', 'hardware-preflight.ts');
const serverEntrypoint = read('radio-lite-server', 'src', 'index.ts');
const frame = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteMediaFrame.swift');
const socket = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteWebSocketChannel.swift');
const hamlibRig = read('radio-lite-server', 'src', 'rig', 'hamlib-rig.ts');
const mediaHub = read('radio-lite-server', 'src', 'media', 'media-hub.ts');
const logbookView = read('ios', 'RadioLite', 'Features', 'RadioLite', 'RadioLiteLogbookView.swift');
const adifDocument = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteADIFDocument.swift');
const adifDocumentPicker = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteADIFDocumentPicker.swift');
const gridMapPresentation = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteGridMapPresentation.swift');
const gridLogPresentation = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteGridLogPresentation.swift');
const radioLiteProject = read('ios', 'RadioLite', 'project.yml');
const radioLiteInfo = read('ios', 'RadioLite', 'App', 'Info.plist');

const capabilityModelFields = [
  'id', 'token', 'group', 'access', 'presentation', 'value', 'minimum', 'maximum',
  'step', 'unit', 'options', 'transmitLocked',
];
const capabilityFixture = {
  t: 'rig.capabilities', radioId: 'main', commandId: 'capabilities-1', controls: [
    { id: 'parameter:CWPITCH', token: 'CWPITCH', group: 'cw', access: 'read-write', presentation: 'discrete', value: 700, minimum: 300, maximum: 1_000, step: 50, unit: 'hertz', options: [{ value: 600, label: '600 Hz' }, { value: 700, label: '700 Hz' }], transmitLocked: false },
    { id: 'level:AF', token: 'AF', group: 'audio', access: 'read-write', presentation: 'slider', value: 0.42, minimum: 0, maximum: 1, step: 0.01, unit: 'ratio', transmitLocked: false },
    { id: 'level:RFPOWER', token: 'RFPOWER', group: 'rf', access: 'read-write', presentation: 'slider', value: 0.25, minimum: 0, maximum: 1, step: 0.01, unit: 'ratio', transmitLocked: true },
    { id: 'function:NB', token: 'NB', group: 'rf', access: 'read-write', presentation: 'toggle', value: true, minimum: 0, maximum: 1, step: 1, unit: 'boolean', transmitLocked: false },
    { id: 'action:TUNER', token: 'TUNER', group: 'rf', access: 'action', presentation: 'button', value: null, transmitLocked: true },
  ],
};
for (const field of capabilityModelFields) {
  assert(new RegExp(`\\blet ${field}:`, 'u').test(rigControls), `iOS capability model is missing ${field}`);
}
const decodedCapabilityFixture = capabilityFixture.controls.map((control) =>
  Object.fromEntries(capabilityModelFields.filter((field) => Object.hasOwn(control, field)).map((field) => [field, control[field]])));
assert.deepEqual(decodedCapabilityFixture[3].value, true, 'boolean controls must not be coerced to numbers');
assert.equal(decodedCapabilityFixture[0].options[1].value, 700);
const groupOrder = ['antenna', 'rf', 'audio', 'mode', 'cw', 'repeater', 'spectrum', 'system'];
assert.deepEqual(
  [...new Set(decodedCapabilityFixture.filter((control) => control.id !== 'action:TUNER').map((control) => control.group))]
    .sort((left, right) => groupOrder.indexOf(left) - groupOrder.indexOf(right)),
  ['rf', 'audio', 'cw'],
);
function capabilityGetRequest(radioId, commandId) {
  return { t: 'rig.capabilities.get', radioId, commandId };
}
function typedControlSetRequest(radioId, controlToken, controlId, value, commandId) {
  return { t: 'rig.control.set', radioId, controlToken, controlId, value, commandId };
}
function actionInvokeRequest(radioId, controlToken, id, commandId) {
  return { t: 'rig.action.invoke', radioId, controlToken, id, commandId };
}
assert.deepEqual(
  capabilityGetRequest('main', 'capabilities-1'),
  { t: 'rig.capabilities.get', radioId: 'main', commandId: 'capabilities-1' },
);
assert.deepEqual(
  typedControlSetRequest('main', 'lease-token', 'function:NB', false, 'control-nb-1'),
  { t: 'rig.control.set', radioId: 'main', controlToken: 'lease-token', controlId: 'function:NB', value: false, commandId: 'control-nb-1' },
);
assert.deepEqual(
  actionInvokeRequest('main', 'lease-token', 'action:TUNER', 'tuner-1'),
  { t: 'rig.action.invoke', radioId: 'main', controlToken: 'lease-token', id: 'action:TUNER', commandId: 'tuner-1' },
);
assert(rigControls.includes('"rig.capabilities.get"'));
assert(rigControls.includes('RadioLiteControlValue'));
assert(session.includes('expecting: ["rig.capabilities"]'));
assert(session.includes('expecting: ["rig.action.confirmed"]'));
assert(capabilityGroupView.includes('RadioLiteCapabilityControlRow'));
for (const nativeControl of ['Toggle(', 'Slider(', 'Picker(', 'Button(']) {
  assert(capabilityControlRow.includes(nativeControl), `native capability row is missing ${nativeControl}`);
}

function controlTelemetryContract(radioId, subscribeCommandId, unsubscribeCommandId) {
  return {
    subscribe: { t: 'rig.telemetry.subscribe', radioId, commandId: subscribeCommandId },
    subscribed: { t: 'rig.telemetry.subscribed', radioId, commandId: subscribeCommandId },
    unsubscribe: { t: 'rig.telemetry.unsubscribe', radioId, commandId: unsubscribeCommandId },
    unsubscribed: { t: 'rig.telemetry.unsubscribed', radioId, commandId: unsubscribeCommandId },
  };
}

function consumeTelemetryFixture(selectedRadioId, message) {
  assert.equal(message.t, 'rig.telemetry');
  if (message.radioId !== selectedRadioId) return undefined;
  assert.equal(typeof message.sampledAtMs, 'number');
  assert.equal(typeof message.state?.ptt, 'boolean');
  assert(Array.isArray(message.availableMeters));
  const meters = message.meters ?? {};
  assert(!Object.hasOwn(meters, 'rfPower'), 'RFPOWER setting must not be consumed as measured power');
  return {
    radioId: message.radioId,
    sampledAtMs: message.sampledAtMs,
    rfPowerWatts: meters.rfPowerWatts,
    swr: meters.swr,
    actualPowerAvailable: message.availableMeters.includes('RFPOWER_METER_WATTS')
      || message.availableMeters.includes('RFPOWER_METER'),
  };
}

function consumeDiscoveryFixture(message) {
  return {
    ...message,
    audioCards: (message.audioCards ?? []).filter((card) =>
      card.transport === 'usb' && card.complete && card.input !== undefined && card.output !== undefined),
  };
}

const telemetryProtocol = controlTelemetryContract('main', 'subscribe-1', 'unsubscribe-1');
assert.deepEqual(telemetryProtocol.subscribe, {
  t: 'rig.telemetry.subscribe', radioId: 'main', commandId: 'subscribe-1',
});
assert.deepEqual(telemetryProtocol.subscribed, {
  t: 'rig.telemetry.subscribed', radioId: 'main', commandId: 'subscribe-1',
});
assert.deepEqual(telemetryProtocol.unsubscribe, {
  t: 'rig.telemetry.unsubscribe', radioId: 'main', commandId: 'unsubscribe-1',
});
assert.deepEqual(telemetryProtocol.unsubscribed, {
  t: 'rig.telemetry.unsubscribed', radioId: 'main', commandId: 'unsubscribe-1',
});
const transmitTelemetry = consumeTelemetryFixture('main', {
  t: 'rig.telemetry', radioId: 'main', sampledAtMs: 1787700000000,
  state: { frequencyHz: 14074000, mode: 'USB', passbandHz: 3000, ptt: true },
  meters: { rfPowerWatts: 37.5, swr: 1.4, alcRatio: 0.32 },
  availableMeters: ['SWR', 'ALC', 'RFPOWER', 'RFPOWER_METER_WATTS'],
});
assert.deepEqual(transmitTelemetry, {
  radioId: 'main', sampledAtMs: 1787700000000, rfPowerWatts: 37.5, swr: 1.4,
  actualPowerAvailable: true,
});
assert.equal(consumeTelemetryFixture('main', {
  t: 'rig.telemetry', radioId: 'main', sampledAtMs: 1787700000000,
  state: { frequencyHz: 14074000, mode: 'USB', passbandHz: 3000, ptt: true },
  meters: {}, availableMeters: ['RFPOWER'],
})?.actualPowerAvailable, false);
assert.equal(consumeTelemetryFixture('backup', {
  t: 'rig.telemetry', radioId: 'main', sampledAtMs: 1787700000000,
  state: { frequencyHz: 14074000, mode: 'USB', passbandHz: 3000, ptt: true },
  meters: {}, availableMeters: [],
}), undefined);
const discoveryFixture = consumeDiscoveryFixture({
  audioInputs: [], audioOutputs: [],
  audioCards: [{
    hardwareId: 'usb:1234:5678:SN42', label: 'USB Audio CODEC', transport: 'usb', complete: true,
    input: { backend: 'alsa', direction: 'input', id: 'hw:3,0', label: 'USB RX' },
    output: { backend: 'alsa', direction: 'output', id: 'hw:3,0', label: 'USB TX' },
  }, {
    hardwareId: 'unknown', label: 'Incomplete', transport: 'unknown', complete: false,
  }],
});
assert.deepEqual(discoveryFixture.audioCards.map((card) => card.hardwareId), ['usb:1234:5678:SN42']);
assert.deepEqual(consumeDiscoveryFixture({ audioInputs: [], audioOutputs: [] }).audioCards, []);

const telemetry = read('ios', 'RadioLite', 'Core', 'RadioLite', 'RadioLiteTelemetry.swift');
const telemetryStrip = read('ios', 'RadioLite', 'Features', 'RadioLite', 'RadioLiteTelemetryStrip.swift');

assert(audioRuntimePolicy.includes('struct AudioBackgroundRuntimeDecision'));
assert(audioRuntimePolicy.includes('backgroundDecision(receiveAudioDesired:'));
assert(audioRuntimePolicy.includes('allowsReceiveRecovery('));
const backgroundTransition = session.slice(
  session.indexOf('func appDidEnterBackground()'),
  session.indexOf('func appDidBecomeActive()'),
);
assert(backgroundTransition.includes('AudioRuntimePolicy.backgroundDecision('));
assert(backgroundTransition.includes('if decision.suspendsReceiveAudio'));
assert(backgroundTransition.includes('media.setSpectrumVisible(decision.spectrumVisible)'));
assert(!backgroundTransition.includes('isAppActive = true'));
assert(rigControls.includes('enum RadioLiteTunerTapAction'));
assert(rigControls.includes('enum RadioLiteTunerInteractionPolicy'));
assert(rigControls.includes('reflectingSuccessfulTuneStart('));
assert(rigControls.includes('static func tunerSwitch(in controls:'));
assert(rigControls.includes('static func generalControls(in controls:'));
assert(rigControls.includes('case "TUNER": return "机内天调接入"'));
assert(radioView.includes('session.tunerActionCapability'));
assert(radioView.includes('capability.displayState('));
assert(!radioView.includes('supportsInternalTuner'));
assert(rigControlsView.includes('RadioLiteTunerInteractionPolicy.generalControls('));
assert(session.includes('reflectSuccessfulTunerStart(radioId:'));
assert(session.includes('endTuning(reason: .operatorCancellation)'));
assert(server.includes('configuration.waitsForConnectivity = false'));
assert(server.includes('static let deadline: TimeInterval = 10'));
assert(session.includes('func cancelSessionRestore()'));
assert(rootView.includes('Button("换服务器")'));

const httpPaths = [
  '/healthz',
  '/api/v1/setup/status',
  '/api/v1/setup/initialize',
  '/api/v1/session/login',
  '/api/v1/session',
  '/api/v1/session/logout',
  '/api/v1/users',
  '/api/v1/hardware/test',
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
assert(session.includes('voicePTTStartupTask = RadioLiteVoicePTTStartup.schedule'));
assert(voicePTTStartup.includes('prepareReceiveRecovery()'));
assert(voicePTTStartup.includes('guard !Task.isCancelled else { return }'));
assert(session.includes('voicePTTStartupTask?.cancel()'));
assert(session.includes('transmitEpoch.owns(generation)'));
assert(credentialRefresh.includes('let server: RadioLiteServer'));
assert(credentialRefresh.includes('let deviceId: String'));
assert(credentialRefresh.includes('case pendingCommit(RadioLiteDeviceCredentials)'));
assert(credentialRefresh.includes('case retryingCommit('));
assert(credentialRefresh.includes('func pendingCommitCredentials('));
assert(credentialRefresh.includes('AsyncThrowingStream<RadioLiteCredentialRefreshLease, Error>'));
assert(operationEpoch.includes('struct RadioLiteAuthenticationOwnershipState'));
assert(session.includes('try requireCurrentAuthentication(authenticationOwnership)'));
assert(session.includes('credentialRefreshCoordinator.pendingCommitCredentials('));
assert(session.includes('scheduleCredentialPersistenceRetry('));
assert(session.includes('operation: { _ in throw CancellationError() }'));
assert(session.includes('stopReceiveAudio()'));
assert(session.includes('clearAuthenticatedState()'));
assert(credentialStore.includes('func delete(ifMatching expected: RadioLiteStoredLogin)'));
assert(session.includes('try requireCurrentReconnect(reconnectOwnership)'));
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
assert(audio.includes('AVAudioSession.interruptionNotification'));
assert(audio.includes('AVAudioSession.mediaServicesWereLostNotification'));
assert(audio.includes('AVAudioSession.mediaServicesWereResetNotification'));
assert(audio.includes('RadioLiteAudioInterruptionPolicy.action'));
assert(audio.includes('return type == .began ? .stopCaptureAndTransmit : .resumeReceiveOnly'));
assert(audio.includes('final class RadioLiteAudioInterruptionObserver'));
assert(audio.includes('final class RadioLiteNotificationObservationBag'));
assert(audio.includes('stopDeliveredForCurrentEpisode'));
assert(audio.includes('struct RadioLiteAudioReconfigurationGate'));
assert(audio.includes('static let cooldown: TimeInterval = 0.25'));
assert(audio.includes('monotonicTime: @escaping @MainActor () -> TimeInterval'));
assert(audio.includes('audioReconfigurationGate.isCoolingDown(at: uptime)'));
assert(!audio.includes('audioReconfigurationDeliveredForCurrentEpisode'));
assert(!audio.includes('resetDeliveredForCurrentEpisode'));
assert(audio.includes('case .resumeReceiveOnly:'));
assert(audio.includes('func rearm()'));
const interruptionObserver = audio.slice(
  audio.indexOf('final class RadioLiteAudioInterruptionObserver'),
  audio.indexOf('struct RadioLiteMicrophoneCaptureOwnership'),
);
const rearm = interruptionObserver.slice(
  interruptionObserver.indexOf('func rearm()'),
  interruptionObserver.indexOf('private func receive('),
);
assert(!rearm.includes('audioReconfigurationGate'));
assert(/func startMonitoring\(\) throws \{\n\s*audioSessionInterruptionObserver\?\.rearm\(\)/u.test(audio));
assert(audio.includes('resumeMonitoringAfterCapture: false'));
assert(audio.includes('onCaptureInterrupted?()'));
assert(audio.includes('onMediaServicesReset()'));
assert(audio.includes('rebuildAudioResourcesAfterMediaServicesReset()'));
assert(audio.includes('playbackEngine = AVAudioEngine()'));
assert(audio.includes('captureEngine = AVAudioEngine()'));
assert(audio.includes('player = AVAudioPlayerNode()'));
assert(audio.includes('removeObserver(observer)'));
assert(/private func handleAudioSessionInterruption\(\) \{[\s\S]*stopMicrophoneCapture\(resumeMonitoringAfterCapture: false\)[\s\S]*onCaptureInterrupted\?\(\)/u.test(audio));
assert(/addObserver\([\s\S]*\) \{ \[weak self\] notification in/u.test(audio));
assert(session.includes('audio.onCaptureInterrupted ='));
assert(session.includes('audio.onReceiveMayResume ='));
assert(session.includes('endVoicePTT(reason: .audioInterruption)'));
assert(/private func handleAudioSessionInterruption\(\) \{[\s\S]*suspendReceiveAudio\(\)[\s\S]*endVoicePTT\(reason: \.audioInterruption\)[\s\S]*endTuning\(\)/u.test(session));
assert(session.includes('audio.armPTTInterruptionFailSafe()'));
assert(operationEpoch.includes('case audioInterruption'));
assert(operationEpoch.includes('case .connectionLoss, .audioInterruption: return false'));
assert(operationEpoch.includes('struct RadioLiteVoicePTTReleaseState'));
assert(operationEpoch.includes('struct RadioLiteVoicePTTStartReleaseState'));
assert(operationEpoch.includes('enum RadioLiteVoicePTTStartedDisposition'));
const beginVoicePTT = session.slice(
  session.indexOf('func beginVoicePTT()'),
  session.indexOf('func endVoicePTT()'),
);
const startDispatchOwnership = beginVoicePTT.indexOf('markStartDispatched');
const startRequest = beginVoicePTT.indexOf('self.control.request');
const startedDisposition = beginVoicePTT.indexOf('receiveStarted');
const lateStartedStop = beginVoicePTT.indexOf(
  'await self.stopRemoteTransmit',
  startedDisposition,
);
const uplinkBind = beginVoicePTT.indexOf(
  'let uplinkOwnership = try await self.media.bindUplink',
  startedDisposition,
);
assert(startDispatchOwnership >= 0);
assert(startRequest > startDispatchOwnership);
assert(startedDisposition > startRequest);
assert(lateStartedStop > startedDisposition);
assert(uplinkBind > lateStartedStop);
const endVoicePTT = session.slice(
  session.indexOf('private func endVoicePTT(reason:'),
  session.indexOf('func beginTuning()'),
);
assert(!endVoicePTT.includes('onDispatchCompleted:'));
const localTransmitStop = endVoicePTT.indexOf(
  '_ = stopLocalTransmit(resumeMonitoringAfterCapture: false)',
);
const finishReceiveCall = endVoicePTT.indexOf('finishReceiveMonitoringAfterTransmit(');
const remoteTransmitStop = endVoicePTT.indexOf('stopRemoteTransmit');
assert(localTransmitStop >= 0);
assert(finishReceiveCall > localTransmitStop);
assert(remoteTransmitStop >= 0);
assert(finishReceiveCall < remoteTransmitStop);
const finishReceiveMonitoring = session.slice(
  session.indexOf('private func finishReceiveMonitoringAfterTransmit('),
  session.indexOf('func beginTuning()'),
);
const localPlaybackResume = finishReceiveMonitoring.indexOf(
  'audio.resumeAfterLocalTransmitRelease()',
);
const receiveRestoreTask = finishReceiveMonitoring.indexOf(
  'voicePTTReceiveResumeTask = Task',
);
assert(localPlaybackResume >= 0);
assert(receiveRestoreTask < 0 || localPlaybackResume < receiveRestoreTask);
const audioInterruptionHandler = session.slice(
  session.indexOf('private func handleAudioSessionInterruption()'),
  session.indexOf('private func resumeReceiveAudioAfterInterruption()'),
);
assert(audioInterruptionHandler.includes('endTuning(reason: .audioInterruption)'));
const endTuning = session.slice(
  session.indexOf('func endTuning()'),
  session.indexOf('func refreshDigitalSnapshot('),
);
assert(endTuning.includes('endTuning(reason: .userRelease)'));
const tuningLocalStop = endTuning.indexOf('guard stopLocalTransmit() else { return }');
const tuningReceiveRecovery = endTuning.indexOf('finishReceiveMonitoringAfterTransmit(');
const tuningRemoteStop = endTuning.indexOf('stopRemoteTransmit');
assert(tuningLocalStop >= 0);
assert(tuningReceiveRecovery > tuningLocalStop);
assert(tuningRemoteStop > tuningReceiveRecovery);
const beginTuning = session.slice(
  session.indexOf('func beginTuning()'),
  session.indexOf('func endTuning()'),
);
assert(beginTuning.includes('finishReceiveMonitoringAfterTransmit('));
assert(beginTuning.includes('reason: .transmitFailure'));
const transmitHeartbeat = session.slice(
  session.indexOf('private func startTransmitHeartbeat('),
  session.indexOf('private func stopRemoteTransmit('),
);
assert(transmitHeartbeat.includes('finishReceiveMonitoringAfterTransmit('));
assert(transmitHeartbeat.includes('reason: .transmitFailure'));
assert(socket.includes('onDispatchCompleted?(.success(()))'));
assert(media.includes('struct RadioLiteMediaLivenessState'));
assert(microphonePolicy.includes('struct RadioLiteMicrophoneProcessor'));
assert(audio.includes('microphoneProcessor.processFrame'));
assert(audio.includes('AVAudioSession.routeChangeNotification'));
assert(audio.includes('.AVAudioEngineConfigurationChange'));
assert(audio.includes('onAudioReconfiguration'));
assert(audio.includes('handleAudioReconfiguration'));
assert(models.includes('let supportsInternalTuner: Bool?'));
assert(service.includes('supportsInternalTuner'));
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
assert(deviceConfiguration.includes('struct RadioLiteHardwarePreflightResult'));
assert(deviceConfiguration.includes('let readOnly: Bool'));
assert(deviceConfiguration.includes('struct RadioLiteHardwarePreflightOwnership'));
assert(deviceConfiguration.includes('private let serverAddressSnapshot: String'));
assert(deviceConfiguration.includes('private let userIdSnapshot: String?'));
assert(http.includes('func testHardware('));
assert(session.includes('func testRadioConfiguration('));
assert(deviceConfigurationView.includes('测试 CAT 与音频端点'));
assert(deviceConfigurationView.includes('guard !testingHardware else { return }'));
assert(deviceConfigurationView.includes('serverAddress: session.serverAddress'));
assert(deviceConfigurationView.includes('userId: session.principal?.userId'));
assert(deviceConfigurationView.includes('guard ownership.isCurrent('));
assert(deviceConfigurationView.includes('CAT 预检只发送读取查询'));
assert(deviceConfigurationView.includes('不会发送 PTT、天调、频率或模式写命令'));
assert(hardwarePreflight.includes('const READ_ONLY_COMMANDS'));
for (const command of ['\\\\get_freq', '\\\\get_mode', '\\\\get_ptt', '\\\\get_func TUNER', '\\\\get_level ?', '\\\\get_func ?']) {
  assert(hardwarePreflight.includes(`"${command}"`), `hardware preflight is missing ${command}`);
}
assert(!hardwarePreflight.includes('"\\\\set_ptt'));
assert(!hardwarePreflight.includes('"\\\\set_func'));
assert(!hardwarePreflight.includes('"\\\\set_freq'));
assert(!hardwarePreflight.includes('"\\\\set_mode'));
assert(protocol.includes('read-only CAT/capability/audio-endpoint preflight'));
assert(protocol.includes('PTT forced to `None`'));
assert(!serverEntrypoint.includes('finally(() => process.exit(0))'));
assert(serverEntrypoint.includes('process.exit(1)'));
assert(serverEntrypoint.includes('shutdown cleanup could not be confirmed'));
assert(telemetry.includes('RadioLiteTelemetrySubscriptionOwnership'));
assert(telemetry.includes('RFPOWER_METER_WATTS'));
assert(session.includes('@Published private(set) var telemetry: RadioLiteTelemetry?'));
assert(session.includes('await unsubscribeTelemetry()'));
assert(session.includes('try await subscribeTelemetry('));
assert(telemetryStrip.includes('frame(height: 52)'));
assert(adifDocument.includes('UTType(importedAs: typeIdentifier, conformingTo: .plainText)'));
assert(adifDocument.includes('static let allowedContentTypes: [UTType] = [.item]'));
assert(adifDocument.includes('supportedFilenameExtensions.contains(url.pathExtension.lowercased())'));
assert(adifDocument.includes('NSFileCoordinator()'));
assert(adifDocument.includes('copyItem(at: coordinatedURL, to: temporaryURL)'));
assert(adifDocumentPicker.includes('UIViewControllerRepresentable'));
assert(adifDocumentPicker.includes('UIDocumentPickerViewController('));
assert(adifDocumentPicker.includes('forOpeningContentTypes: RadioLiteADIFDocument.allowedContentTypes'));
assert(adifDocumentPicker.includes('asCopy: true'));
assert(adifDocumentPicker.includes('picker.allowsMultipleSelection = false'));
assert(adifDocumentPicker.includes('didPickDocumentsAt urls: [URL]'));
assert(adifDocumentPicker.includes('documentPickerWasCancelled'));
assert(logbookView.includes('.sheet(isPresented: $showImporter)'));
assert(logbookView.includes('RadioLiteADIFDocumentPicker('));
assert(!logbookView.includes('.fileImporter('));
const adifSelectionHandler = logbookView.slice(
  logbookView.indexOf('private func handleImportSelection('),
  logbookView.indexOf('private func importFile(at:'),
);
assert(adifSelectionHandler.indexOf('validateImportURL(url)') >= 0);
assert(adifSelectionHandler.indexOf('startAccessingSecurityScopedResource()') >= 0);
assert(adifSelectionHandler.indexOf('validateImportURL(url)') < adifSelectionHandler.indexOf('startAccessingSecurityScopedResource()'));
assert(adifSelectionHandler.indexOf('startAccessingSecurityScopedResource()') < adifSelectionHandler.indexOf('Task {'));
for (const source of [radioLiteProject, radioLiteInfo]) {
  assert(source.includes('UTImportedTypeDeclarations'));
  assert(source.includes('xyz.992218.radio-lite.adif'));
  assert(source.includes('public.plain-text'));
  assert(source.includes('application/adif'));
}
assert(/public\.filename-extension:\s*\n\s*- adi\s*\n\s*- adif/u.test(radioLiteProject));
assert(/<key>public\.filename-extension<\/key>[\s\S]*?<string>adi<\/string>[\s\S]*?<string>adif<\/string>/u.test(radioLiteInfo));
assert(logbookView.includes('RadioLiteGridMapView(grids: session.grids)'));
assert(http.includes('URLQueryItem(name: "grid", value: grid)'));
assert(session.includes('func logs(inGrid grid: String'));
assert(session.includes('http.logs(limit: limit, offset: offset, grid: grid)'));
assert(service.includes('exactQueryKeys(url, ["grid", "limit", "offset"])'));
assert(service.includes('this.#log.pageByGrid(grid, limit, offset)'));
assert(logStore.includes('pageByGrid('));
assert(logbookView.includes('try await session.logs(inGrid: grid, limit: limit, offset: offset)'));
assert(logbookView.includes('RadioLiteGridQSOListView(summary: item, loadGridPage: loadGridPage)'));
assert(logbookView.includes('RadioLiteQSORecordDetailView(qso: qso)'));
assert(gridLogPresentation.includes('guard normalizedGrid == grid else'));
assert(gridLogPresentation.includes('guard page.offset == 0 || page.offset == nextOffset else'));
assert(gridLogPresentation.includes('nextOffset = page.offset + page.records.count'));
const gridMapView = logbookView.slice(logbookView.indexOf('struct RadioLiteGridMapView: View'));
assert(!gridMapView.includes('@EnvironmentObject'));
assert(!gridMapView.includes('Map(position: $camera)'));
assert(gridMapView.includes('Map(initialPosition: .automatic)'));
assert(gridMapView.includes('.onMapCameraChange(frequency: .onEnd)'));
assert(gridMapView.includes('SpatialTapGesture()'));
assert(gridMapView.includes('including: .gesture'));
assert(gridMapView.includes('proxy.convert(event.location, from: .local)'));
assert(!gridMapView.includes('session.grids.prefix(600)'));
assert(gridMapView.includes('ForEach(renderSet.cells)'));
assert(gridMapView.includes('ForEach(renderSet.labeledCells)'));
assert(gridMapPresentation.includes('static let detailEnterLongitudeDelta = 28.0'));
assert(gridMapPresentation.includes('static let detailExitLongitudeDelta = 34.0'));
assert(gridMapPresentation.includes('static let maximumDetailedCells = 240'));
assert(gridMapPresentation.includes('static let maximumDetailLabels = 80'));
assert(gridMapPresentation.includes('static let maximumOverviewLabels = 40'));
assert(gridMapPresentation.includes('let sourceCells: [RadioLiteGridMapCell]'));
assert(gridMapPresentation.includes('fieldCells = Self.aggregateFields(grids)'));
assert(gridMapPresentation.includes('memberGridIDs'));
assert(!gridMapPresentation.includes('grids.prefix('));
assert(/^\s*CURRENT_PROJECT_VERSION:\s*25\s*$/mu.test(radioLiteProject));
assert(/^\s*MARKETING_VERSION:\s*0\.2\.13\s*$/mu.test(radioLiteProject));
assert(deviceConfiguration.includes('audioCards = try container.decodeIfPresent'));
assert(deviceConfigurationView.includes('isSelectableUSBCard'));

process.stdout.write(
  `Verified ${httpPaths.length} HTTP paths, ${controlMessages.length} control messages, telemetry/audio-card fixtures, media messages, and the binary frame contract.\n`,
);
