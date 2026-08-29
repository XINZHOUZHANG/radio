import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildDummyAudioSettings,
  selectDummyAudioDevices,
} from '../configure-dummy.mjs';

function fixture() {
  return {
    inputDevices: [
      { id: 'input-1', name: 'Fallback microphone', type: 'input', channels: 1, sampleRate: 44_100, isDefault: true },
      { id: 'input-2', name: 'Monitor of TX5DR_Dummy_Output', type: 'input', channels: 1, sampleRate: 48_000, sampleRates: [44_100, 48_000] },
    ],
    outputDevices: [
      { id: 'output-3', name: 'Fallback speaker', type: 'output', channels: 2, sampleRate: 44_100, isDefault: true },
      { id: 'output-4', name: 'TX5DR_Dummy_Output', type: 'output', channels: 1, sampleRate: 48_000, capabilities: { sampleRates: [48_000] } },
    ],
    inputBufferSizes: [256, 1_024],
    outputBufferSizes: [512, 1_024],
  };
}

test('selects the named PulseAudio loopback devices over unrelated defaults', () => {
  const selected = selectDummyAudioDevices(fixture());
  assert.equal(selected.input.id, 'input-2');
  assert.equal(selected.output.id, 'output-4');
});

test('builds a stable 48 kHz mono TX-5DR audio configuration', () => {
  assert.deepEqual(buildDummyAudioSettings(fixture()), {
    inputDeviceName: 'Monitor of TX5DR_Dummy_Output',
    outputDeviceName: 'TX5DR_Dummy_Output',
    inputDeviceId: 'input-2',
    outputDeviceId: 'output-4',
    inputSampleRate: 48_000,
    outputSampleRate: 48_000,
    inputBufferSize: 1_024,
    outputBufferSize: 1_024,
    outputSampleFormat: 'float32',
    outputChannelMode: 'mono',
    inputSignalType: 'af',
  });
});

test('rejects a device response without a usable direction', () => {
  const payload = fixture();
  payload.inputDevices = [];
  assert.throws(() => selectDummyAudioDevices(payload), /usable input audio device/);
});
