import type {
  RadioControl,
  RadioControlOption,
  RadioControlPresentation,
  RadioControlUnit,
} from "./radio-driver.ts";

export type HamlibControlReport = {
  levels?: readonly string[];
  functions?: readonly string[];
  parameters?: readonly string[];
  operations?: readonly string[];
  modes?: readonly string[];
};

type CatalogueDefinition = Omit<RadioControl, "id" | "token" | "value"> & {
  idPrefix: string;
};

const RATIO = {
  access: "read-write",
  presentation: "slider",
  minimum: 0,
  maximum: 1,
  step: 0.01,
  unit: "ratio",
} as const;

const LEVELS = new Map<string, CatalogueDefinition>([
  ["RFPOWER", level("rf", RATIO, true)],
  ["RF", level("rf", RATIO)],
  ["NB", level("rf", RATIO)],
  ["NR", level("rf", RATIO)],
  ["AGC", level("rf", discrete(0, 6, 1, "index", agcOptions()))],
  ["PREAMP", level("rf", discrete(0, 60, 1, "decibel"))],
  ["ATT", level("rf", discrete(0, 60, 1, "decibel"))],
  ["APF", level("rf", RATIO)],
  ["IF", level("rf", offset(-10_000, 10_000, 10, "hertz"))],
  ["PBT_IN", level("rf", RATIO)],
  ["PBT_OUT", level("rf", RATIO)],
  ["NOTCHF", level("rf", discrete(0, 10_000, 10, "hertz"))],
  ["AF", level("audio", RATIO)],
  ["SQL", level("audio", RATIO)],
  ["MICGAIN", level("audio", RATIO, true)],
  ["COMP", level("audio", RATIO, true)],
  ["MONITOR_GAIN", level("audio", RATIO, true)],
  ["VOXDELAY", level("audio", discrete(0, 100, 1, "index"), true)],
  ["VOXGAIN", level("audio", RATIO, true)],
  ["ANTIVOX", level("audio", RATIO, true)],
  ["BAL", level("audio", RATIO)],
  ["BKINDL", level("cw", discrete(0, 100, 1, "index"), true)],
  ["BKIN_DLYMS", level("cw", discrete(0, 5_000, 10, "milliseconds"), true)],
  ["CWPITCH", level("cw", discrete(300, 1_200, 10, "hertz"))],
  ["KEYSPD", level("cw", discrete(5, 60, 1, "index"), true)],
  ["STRENGTH", meter("rf", "decibel")],
  ["SWR", meter("rf", "ratio")],
  ["ALC", meter("rf", "ratio")],
  ["RFPOWER_METER", meter("rf", "ratio")],
  ["RFPOWER_METER_WATTS", meter("rf", "watts")],
]);

const FUNCTIONS = new Map<string, CatalogueDefinition>([
  ["NB", toggle("rf")],
  ["NR", toggle("rf")],
  ["APF", toggle("rf")],
  ["ANF", toggle("rf")],
  ["MN", toggle("rf")],
  ["COMP", toggle("audio", true)],
  ["MON", toggle("audio", true)],
  ["VOX", toggle("audio", true)],
  ["MUTE", toggle("audio")],
  ["LOCK", toggle("mode")],
  ["TUNER", toggle("rf", true)],
  ["SBKIN", toggle("cw", true)],
  ["FBKIN", toggle("cw", true)],
]);

const PARAMETERS = new Map<string, CatalogueDefinition>([
  ["BKINDL", parameter("cw", discrete(0, 100, 1, "index"), true)],
  ["BKIN_DLYMS", parameter("cw", discrete(0, 5_000, 10, "milliseconds"), true)],
  ["CWPITCH", parameter("cw", discrete(300, 1_200, 10, "hertz"))],
  ["KEYSPD", parameter("cw", discrete(5, 60, 1, "index"), true)],
]);

const OPERATIONS = new Map<string, CatalogueDefinition>([
  ["PASSBAND", operation("passband", "mode", "discrete", true, "hertz", 100, 12_000, 50)],
  ["SPLIT", operation("operation", "mode", "toggle", true)],
  ["RIT", operation("operation", "mode", "offset", false, "hertz", -99_999, 99_999, 1)],
  ["XIT", operation("operation", "mode", "offset", true, "hertz", -99_999, 99_999, 1)],
  ["TUNING_STEP", operation("operation", "mode", "discrete", false, "hertz", 1, 1_000_000, 1)],
  ["REPEATER_SHIFT", operation("repeater", "repeater", "enum", true, undefined, undefined, undefined, undefined, [
    { value: "NONE", label: "None" },
    { value: "PLUS", label: "+" },
    { value: "MINUS", label: "−" },
  ])],
  ["REPEATER_OFFSET", operation("repeater", "repeater", "offset", true, "hertz", 0, 100_000_000, 1)],
  ["CTCSS", operation("repeater", "repeater", "enum", true)],
  ["DCS", operation("repeater", "repeater", "enum", true)],
]);

export class HamlibControlCatalogue {
  async discover(report: HamlibControlReport): Promise<RadioControl[]> {
    const controls: RadioControl[] = [];
    appendReported(controls, report.levels, LEVELS);
    appendReported(controls, report.functions, FUNCTIONS);
    if (includesReportedToken(report.functions, "TUNER")) {
      controls.push(descriptor("TUNER", action("rf", true)));
    }
    appendReported(controls, report.parameters, PARAMETERS);
    for (const rawToken of report.operations ?? []) {
      const token = validToken(rawToken);
      if (token === null) continue;
      if (token === "MODE") {
        const options = validOptions(report.modes);
        if (options.length === 0) continue;
        controls.push({
          id: "mode:CURRENT",
          kind: "mode",
          token: "CURRENT",
          group: "mode",
          access: "read-write",
          presentation: "enum",
          value: null,
          options,
          transmitLocked: true,
        });
        continue;
      }
      const definition = OPERATIONS.get(token);
      if (definition !== undefined) controls.push(descriptor(token, definition));
    }
    return controls;
  }
}

function appendReported(
  output: RadioControl[],
  reported: readonly string[] | undefined,
  definitions: ReadonlyMap<string, CatalogueDefinition>,
): void {
  for (const rawToken of reported ?? []) {
    const token = validToken(rawToken);
    if (token === null) continue;
    const definition = definitions.get(token);
    if (definition !== undefined) output.push(descriptor(token, definition));
  }
}

function includesReportedToken(reported: readonly string[] | undefined, expected: string): boolean {
  return (reported ?? []).some((rawToken) => validToken(rawToken) === expected);
}

function descriptor(token: string, definition: CatalogueDefinition): RadioControl {
  const { idPrefix, ...metadata } = definition;
  const idToken = token === "PASSBAND"
    ? "CURRENT"
    : token.startsWith("REPEATER_")
      ? token.slice("REPEATER_".length)
      : token;
  return { id: `${idPrefix}:${idToken}`, token, value: null, ...metadata };
}

function validToken(token: string): string | null {
  return /^[A-Z][A-Z0-9_]{0,31}$/u.test(token) ? token : null;
}

function validOptions(tokens: readonly string[] | undefined): RadioControlOption[] {
  return (tokens ?? []).flatMap((token) => {
    const value = validToken(token);
    return value === null ? [] : [{ value, label: value }];
  });
}

function level(
  group: RadioControl["group"],
  metadata: Partial<CatalogueDefinition>,
  transmitLocked = false,
): CatalogueDefinition {
  return { idPrefix: "level", kind: "level", group, transmitLocked, ...metadata } as CatalogueDefinition;
}

function parameter(
  group: RadioControl["group"],
  metadata: Partial<CatalogueDefinition>,
  transmitLocked = false,
): CatalogueDefinition {
  return { idPrefix: "parameter", kind: "parameter", group, transmitLocked, ...metadata } as CatalogueDefinition;
}

function toggle(group: RadioControl["group"], transmitLocked = false): CatalogueDefinition {
  return {
    idPrefix: "function", kind: "function", group, access: "read-write", presentation: "toggle",
    minimum: 0, maximum: 1, step: 1, unit: "boolean", transmitLocked,
  };
}

function action(group: RadioControl["group"], transmitLocked: boolean): CatalogueDefinition {
  return {
    idPrefix: "action", kind: "action", group, access: "action", presentation: "button",
    transmitLocked,
  };
}

function meter(group: RadioControl["group"], unit: RadioControlUnit): CatalogueDefinition {
  return {
    idPrefix: "level", kind: "level", group, access: "read-only", presentation: "meter", unit,
    transmitLocked: false,
  };
}

function discrete(
  minimum: number,
  maximum: number,
  step: number,
  unit: RadioControlUnit,
  options?: RadioControlOption[],
): Partial<CatalogueDefinition> {
  return { access: "read-write", presentation: "discrete", minimum, maximum, step, unit, options };
}

function offset(minimum: number, maximum: number, step: number, unit: RadioControlUnit): Partial<CatalogueDefinition> {
  return { access: "read-write", presentation: "offset", minimum, maximum, step, unit };
}

function operation(
  idPrefix: string,
  group: RadioControl["group"],
  presentation: RadioControlPresentation,
  transmitLocked: boolean,
  unit?: RadioControlUnit,
  minimum?: number,
  maximum?: number,
  step?: number,
  options?: RadioControlOption[],
): CatalogueDefinition {
  return {
    idPrefix, kind: idPrefix === "passband" ? "passband" : "operation", group,
    access: "read-write", presentation, unit, minimum, maximum, step, options, transmitLocked,
  };
}

function agcOptions(): RadioControlOption[] {
  return ["Off", "Super fast", "Fast", "Slow", "User", "Medium", "Auto"]
    .map((label, value) => ({ value, label }));
}
