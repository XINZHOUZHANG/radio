import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');

function read(relativePath) {
  return readFileSync(resolve(root, relativePath), 'utf8');
}

function requireMatch(source, pattern, message) {
  if (!pattern.test(source)) {
    throw new Error(message);
  }
}

function requireAbsent(source, pattern, message) {
  if (pattern.test(source)) {
    throw new Error(message);
  }
}

const dashboardModel = read('ios/RadioLite/Core/RadioLite/RadioLiteControlDashboard.swift');
const dashboardView = read('ios/RadioLite/Features/RadioLite/RadioLiteControlDashboardView.swift');
const radioView = read('ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift');
const controlsView = read('ios/RadioLite/Features/RadioLite/RadioLiteRigControlsView.swift');
const telemetryStrip = read('ios/RadioLite/Features/RadioLite/RadioLiteTelemetryStrip.swift');

for (const category of [
  'rf',
  'audio',
  'noiseReduction',
  'filter',
  'tuner',
  'modeAndOffset',
  'cw',
  'repeater',
  'spectrumAndDisplay',
  'systemAndOther',
]) {
  requireMatch(
    dashboardModel,
    new RegExp(`case\\s+${category}\\b`),
    `radio-control dashboard is missing category ${category}`,
  );
}

requireAbsent(
  dashboardModel,
  /case\s+antenna\b/,
  'radio-control dashboard must not expose an antenna category',
);
requireMatch(
  dashboardModel,
  /presentation\s*!=\s*\.meter/,
  'read-only meters must be excluded from the control dashboard',
);
requireMatch(
  dashboardModel,
  /action:TUNER/,
  'the tuner must be represented as its own control category',
);
requireMatch(
  dashboardModel,
  /RFPOWER_METER_WATTS[\s\S]{0,240}实时输出功率|实时输出功率[\s\S]{0,240}RFPOWER_METER_WATTS/,
  'actual RF power must have a user-facing label',
);
requireMatch(
  dashboardModel,
  /RFPOWER[\s\S]{0,160}发射功率设置|发射功率设置[\s\S]{0,160}RFPOWER/,
  'RF power setting must be distinguished from measured output power',
);
requireMatch(
  dashboardModel,
  /function:NB[\s\S]{0,500}level:NB|level:NB[\s\S]{0,500}function:NB/,
  'noise blanker switch and level must be grouped into one dashboard item',
);

requireMatch(
  dashboardView,
  /LazyVGrid/,
  'radio controls must be presented as a compact dynamic grid',
);
requireMatch(
  dashboardView,
  /\.sheet\s*\(\s*item:/,
  'a category must open a dedicated adjustment sheet',
);
requireMatch(
  dashboardView,
  /expandedItemID/,
  'the adjustment sheet must keep a single expanded control item',
);
requireMatch(
  controlsView,
  /RadioLiteControlDashboardView/,
  'capability controls must use the compact dashboard',
);

requireAbsent(
  radioView,
  /if\s+let\s+tunerAction\s*=\s*session\.tunerActionCapability/,
  'the fixed bottom dock must not duplicate the tuner action',
);
requireMatch(
  radioView,
  /RadioLiteHoldButton\s*\(/,
  'the fixed bottom dock must retain hold-to-talk PTT',
);
requireMatch(
  telemetryStrip,
  /title\s*==\s*"SWR"[\s\S]{0,160}%\.2f:1/,
  'SWR must be formatted as a ratio such as 1.00:1',
);

console.log('Radio control dashboard contract is satisfied.');
