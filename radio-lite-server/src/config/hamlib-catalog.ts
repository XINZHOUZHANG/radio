export type HamlibModel = {
  modelId: number;
  manufacturer: string;
  model: string;
  backendVersion: string;
  status: string;
};

export type CuratedRigPreset = {
  slug: string;
  manufacturer: string;
  model: string;
  defaultBaudRate?: number;
};

export const CURATED_RIG_PRESETS: readonly CuratedRigPreset[] = [
  { slug: "hamlib-dummy", manufacturer: "Hamlib", model: "Dummy" },
  { slug: "yaesu-ft-710", manufacturer: "Yaesu", model: "FT-710", defaultBaudRate: 38_400 },
  { slug: "yaesu-ft-dx10", manufacturer: "Yaesu", model: "FT-DX10", defaultBaudRate: 38_400 },
  { slug: "yaesu-ft-991a", manufacturer: "Yaesu", model: "FT-991A", defaultBaudRate: 38_400 },
  { slug: "icom-ic-7300", manufacturer: "Icom", model: "IC-7300", defaultBaudRate: 115_200 },
  { slug: "icom-ic-7610", manufacturer: "Icom", model: "IC-7610", defaultBaudRate: 115_200 },
  { slug: "icom-ic-705", manufacturer: "Icom", model: "IC-705", defaultBaudRate: 115_200 },
  { slug: "kenwood-ts-590sg", manufacturer: "Kenwood", model: "TS-590SG", defaultBaudRate: 115_200 },
  { slug: "kenwood-ts-890s", manufacturer: "Kenwood", model: "TS-890S", defaultBaudRate: 115_200 },
  { slug: "elecraft-k3", manufacturer: "Elecraft", model: "K3", defaultBaudRate: 38_400 },
  { slug: "elecraft-k4", manufacturer: "Elecraft", model: "K4", defaultBaudRate: 115_200 },
  { slug: "flexradio-6xxx", manufacturer: "FlexRadio", model: "6xxx" },
] as const;

export type ResolvedRigPreset = CuratedRigPreset & {
  hamlibModelId: number | null;
  available: boolean;
};

export function parseRigctlModelList(output: string): HamlibModel[] {
  const models: HamlibModel[] = [];
  for (const line of output.split(/\r?\n/u)) {
    if (!/^\s*\d+/u.test(line)) {
      continue;
    }
    const columns = line.trim().split(/\s{2,}/u);
    if (columns.length < 5 || !/^\d+$/u.test(columns[0])) {
      continue;
    }
    const modelId = Number(columns[0]);
    if (!Number.isSafeInteger(modelId) || modelId <= 0) {
      continue;
    }
    models.push({
      modelId,
      manufacturer: columns[1].trim(),
      model: columns[2].trim(),
      backendVersion: columns[3].trim(),
      status: columns.slice(4).join(" ").trim(),
    });
  }
  return models.sort((left, right) =>
    left.manufacturer.localeCompare(right.manufacturer) ||
    left.model.localeCompare(right.model) ||
    left.modelId - right.modelId,
  );
}

export function resolveCuratedPresets(
  models: readonly HamlibModel[],
): ResolvedRigPreset[] {
  return CURATED_RIG_PRESETS.map((preset) => {
    const exact = models.find(
      (candidate) =>
        normalize(candidate.manufacturer) === normalize(preset.manufacturer) &&
        normalize(candidate.model) === normalize(preset.model),
    );
    const fuzzy = exact ?? models.find(
      (candidate) =>
        normalize(candidate.manufacturer).includes(normalize(preset.manufacturer)) &&
        normalize(candidate.model).includes(normalize(preset.model)),
    );
    return {
      ...preset,
      hamlibModelId: fuzzy?.modelId ?? null,
      available: fuzzy !== undefined,
    };
  });
}

function normalize(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/gu, "");
}
