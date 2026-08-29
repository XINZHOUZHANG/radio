import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const DEFAULT_API_BASE = 'http://127.0.0.1:4000/api';
const DEFAULT_WS_URL = 'ws://127.0.0.1:4000/api/ws';
const DEFAULT_TOKEN_PATH = '/app/data/config/.admin-token';
const RADIO_CONFIG = Object.freeze({
  type: 'network',
  network: { host: 'dummy-rig', port: 4532 },
  digitalModeRadioMode: 'usb-data',
  transmitCompensationMs: 0,
  fakeFrequency: { enabled: false },
  pttMethod: 'cat',
});

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function deviceScore(device) {
  const name = String(device?.name ?? '');
  let score = 0;
  if (/tx5dr[_ ]dummy/i.test(name)) score += 100;
  if (/monitor/i.test(name)) score += 20;
  if (device?.isDefault) score += 10;
  if (device?.availability === 'active') score += 5;
  if (device?.availability !== 'cached') score += 2;
  if (device?.backend === 'rtaudio') score += 1;
  return score;
}

function bestDevice(devices, direction) {
  const usable = devices
    .filter((device) => device?.type === direction && Number(device.channels) > 0)
    .filter((device) => device.availability !== 'cached')
    .sort((left, right) => deviceScore(right) - deviceScore(left));
  if (usable.length === 0) {
    throw new Error(`TX-5DR did not discover a usable ${direction} audio device`);
  }
  return usable[0];
}

export function selectDummyAudioDevices(payload) {
  if (!payload || !Array.isArray(payload.inputDevices) || !Array.isArray(payload.outputDevices)) {
    throw new Error('Unexpected /audio/devices response');
  }
  return {
    input: bestDevice(payload.inputDevices, 'input'),
    output: bestDevice(payload.outputDevices, 'output'),
  };
}

function preferredSampleRate(device) {
  const advertised = [
    ...(Array.isArray(device.sampleRates) ? device.sampleRates : []),
    ...(Array.isArray(device.capabilities?.sampleRates) ? device.capabilities.sampleRates : []),
  ].filter((value) => Number.isFinite(value) && value > 0);
  if (advertised.includes(48_000)) return 48_000;
  if (Number.isFinite(device.sampleRate) && device.sampleRate > 0) return device.sampleRate;
  return advertised[0] ?? 48_000;
}

function preferredBufferSize(sizes) {
  const usable = Array.isArray(sizes) ? sizes.filter((value) => Number.isInteger(value) && value > 0) : [];
  return usable.includes(1_024) ? 1_024 : (usable[0] ?? 1_024);
}

export function buildDummyAudioSettings(devicesPayload, selection = selectDummyAudioDevices(devicesPayload)) {
  return {
    inputDeviceName: selection.input.name,
    outputDeviceName: selection.output.name,
    inputDeviceId: selection.input.id,
    outputDeviceId: selection.output.id,
    inputSampleRate: preferredSampleRate(selection.input),
    outputSampleRate: preferredSampleRate(selection.output),
    inputBufferSize: preferredBufferSize(devicesPayload.inputBufferSizes),
    outputBufferSize: preferredBufferSize(devicesPayload.outputBufferSizes),
    outputSampleFormat: 'float32',
    outputChannelMode: 'mono',
    inputSignalType: 'af',
  };
}

function bearer(jwt) {
  return {
    authorization: `Bearer ${jwt}`,
    'content-type': 'application/json',
  };
}

export async function requestJSON(apiBase, path, init = {}) {
  const response = await fetch(`${apiBase}${path}`, init);
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  if (!response.ok) {
    throw new Error(`${init.method ?? 'GET'} ${path} failed (${response.status}): ${text}`);
  }
  return body;
}

async function waitForServer(apiBase) {
  let lastError;
  for (let attempt = 0; attempt < 90; attempt += 1) {
    try {
      await requestJSON(apiBase, '/hello');
      return;
    } catch (error) {
      lastError = error;
      await sleep(1_000);
    }
  }
  throw lastError ?? new Error('TX-5DR did not become ready');
}

async function waitForAudioDevices(apiBase, jwt) {
  let lastError;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      const payload = await requestJSON(apiBase, '/audio/devices', { headers: bearer(jwt) });
      selectDummyAudioDevices(payload);
      return payload;
    } catch (error) {
      lastError = error;
      await sleep(1_000);
    }
  }
  throw lastError ?? new Error('TX-5DR did not discover the PulseAudio dummy devices');
}

function message(type, data) {
  return JSON.stringify({
    type,
    timestamp: new Date().toISOString(),
    ...(data === undefined ? {} : { data }),
  });
}

export async function startDummyEngine(wsURL, jwt, timeoutMs = 30_000) {
  if (typeof WebSocket !== 'function') {
    throw new Error('Node.js WebSocket support is unavailable');
  }

  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsURL);
    let settled = false;
    let authSent = false;
    let handshaking = false;
    let startRequested = false;
    const finish = (error, status) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.close(1000, 'bootstrap complete'); } catch { /* ignored */ }
      if (error) reject(error);
      else resolve(status);
    };
    const send = (type, data) => socket.send(message(type, data));
    const sendAuth = () => {
      if (authSent) return;
      authSent = true;
      send('authToken', { jwt });
    };
    const timer = setTimeout(() => {
      finish(new Error('Timed out waiting for the TX-5DR engine to start with dummy audio'));
    }, timeoutMs);

    socket.addEventListener('open', sendAuth);
    socket.addEventListener('message', (event) => {
      let envelope;
      try {
        envelope = JSON.parse(typeof event.data === 'string' ? event.data : String(event.data));
      } catch {
        return;
      }

      if (envelope.type === 'authRequired') {
        sendAuth();
        return;
      }
      if (envelope.type === 'authResult') {
        if (envelope.data?.success !== true) {
          finish(new Error(`TX-5DR WebSocket authentication failed: ${envelope.data?.error ?? 'unknown error'}`));
          return;
        }
        if (!handshaking) {
          handshaking = true;
          send('clientHandshake', {
            enabledOperatorIds: null,
            selectedOperatorId: null,
            clientInstanceId: 'testradio-dummy-bootstrap',
            clientVersion: 'testradio-bootstrap-1',
            clientCapabilities: ['handshakeProtocol'],
          });
        }
        return;
      }
      if (envelope.type === 'serverHandshakeComplete' && !startRequested) {
        startRequested = true;
        send('startEngine');
        send('getStatus');
        return;
      }
      if (envelope.type === 'systemStatus') {
        const status = envelope.data ?? {};
        if (status.isRunning === true && status.audioStarted === true && status.radioConnected === true) {
          finish(null, status);
        }
        return;
      }
      if (envelope.type === 'error') {
        const command = envelope.data?.context?.command ?? envelope.data?.details?.command;
        if (command === 'startEngine') {
          finish(new Error(`TX-5DR startEngine failed: ${envelope.data?.userMessage ?? envelope.data?.message ?? 'unknown error'}`));
        }
      }
    });
    socket.addEventListener('error', () => finish(new Error('TX-5DR WebSocket connection failed')));
    socket.addEventListener('close', (event) => {
      if (!settled) finish(new Error(`TX-5DR WebSocket closed before engine startup (code ${event.code})`));
    });
  });
}

async function ensureDummyOperator(apiBase, jwt, ft8Mode) {
  const existing = await requestJSON(apiBase, '/operators', { headers: bearer(jwt) });
  if (Array.isArray(existing?.data) && existing.data.length > 0) return existing.data[0];

  const created = await requestJSON(apiBase, '/operators', {
    method: 'POST',
    headers: bearer(jwt),
    body: JSON.stringify({
      myCallsign: process.env.TX5DR_DUMMY_CALLSIGN ?? 'N0CALL',
      myGrid: process.env.TX5DR_DUMMY_GRID ?? 'AA00',
      frequency: 1_500,
      transmitCycles: [0],
      mode: ft8Mode,
    }),
  });
  if (!created?.data?.id) throw new Error('TX-5DR did not return the created dummy operator');
  return created.data;
}

export async function configureDummy({
  apiBase = DEFAULT_API_BASE,
  wsURL = DEFAULT_WS_URL,
  tokenPath = DEFAULT_TOKEN_PATH,
} = {}) {
  await waitForServer(apiBase);
  const token = (await readFile(tokenPath, 'utf8')).trim();
  const login = await requestJSON(apiBase, '/auth/login', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token }),
  });
  if (!login?.jwt) throw new Error('TX-5DR admin login did not return a JWT');

  const authHeaders = bearer(login.jwt);
  const devices = await waitForAudioDevices(apiBase, login.jwt);
  const selectedDevices = selectDummyAudioDevices(devices);
  const audioSettings = buildDummyAudioSettings(devices, selectedDevices);
  await requestJSON(apiBase, '/audio/settings', {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify(audioSettings),
  });

  await requestJSON(apiBase, '/radio/config', {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify(RADIO_CONFIG),
  });
  await requestJSON(apiBase, '/radio/connect', { method: 'POST', headers: authHeaders });

  const modes = await requestJSON(apiBase, '/mode', { headers: authHeaders });
  const ft8Mode = modes?.data?.find((mode) => String(mode?.name).toUpperCase() === 'FT8');
  if (!ft8Mode) throw new Error('TX-5DR did not advertise FT8 mode');
  await requestJSON(apiBase, '/mode/switch', {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify(ft8Mode),
  });
  const operator = await ensureDummyOperator(apiBase, login.jwt, ft8Mode);

  const engineStatus = await startDummyEngine(wsURL, login.jwt);
  const radioStatus = await requestJSON(apiBase, '/radio/status', { headers: authHeaders });
  if (radioStatus?.status?.connected !== true) throw new Error('Hamlib dummy radio is not connected');

  const rigctld = await requestJSON(apiBase, '/rigctld/config', {
    method: 'PUT',
    headers: authHeaders,
    body: JSON.stringify({ enabled: true, bindAddress: '0.0.0.0', port: 4532, readOnly: true }),
  });
  if (rigctld?.running !== true) throw new Error('TX-5DR rigctld bridge did not start');

  const pttTest = await requestJSON(apiBase, '/radio/test-ptt', {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify(RADIO_CONFIG),
  });
  if (pttTest?.success !== true) throw new Error('Hamlib dummy PTT test failed');

  const tuner = await requestJSON(apiBase, '/radio/tuner/capabilities', { headers: authHeaders });
  if (tuner?.capabilities?.supported !== true) {
    throw new Error('Hamlib dummy radio did not expose a usable tuner operation');
  }
  if (tuner.capabilities.hasManualTune) {
    const tuned = await requestJSON(apiBase, '/radio/tuner/tune', { method: 'POST', headers: authHeaders });
    if (tuned?.success !== true) throw new Error('Hamlib dummy manual tuner test failed');
  }

  return {
    audio: {
      input: selectedDevices.input.name,
      output: selectedDevices.output.name,
      inputSampleRate: audioSettings.inputSampleRate,
      outputSampleRate: audioSettings.outputSampleRate,
    },
    radio: radioStatus.status.connectionStatus,
    rigctld: { running: rigctld.running, readOnly: rigctld.config?.readOnly === true },
    ptt: 'verified',
    ft8: engineStatus.isDecoding === true ? 'decoding' : 'engine-ready',
    tuner: tuner.capabilities,
    operator: { id: operator.id, callsign: operator.myCallsign },
  };
}

async function runCLI() {
  const result = await configureDummy();
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runCLI().catch((error) => {
    process.stderr.write(`Dummy bootstrap failed: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
