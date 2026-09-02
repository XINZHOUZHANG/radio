const GRID_PATTERN = /^(?:[A-R]{2})(?:[0-9]{2})?(?:[A-X]{2})?(?:[0-9]{2})?$/u;

export type MaidenheadCell = {
  grid: string;
  latitude: number;
  longitude: number;
  latitudeSpan: number;
  longitudeSpan: number;
};

export function normalizeMaidenhead(value: string): string {
  if (typeof value !== "string") {
    throw new TypeError("Maidenhead locator must be text");
  }
  const grid = value.trim().toUpperCase();
  if (![2, 4, 6, 8].includes(grid.length) || !GRID_PATTERN.test(grid)) {
    throw new Error("Maidenhead locator must contain 2, 4, 6 or 8 valid characters");
  }
  return grid;
}

export function maidenheadCenter(value: string): MaidenheadCell {
  const grid = normalizeMaidenhead(value);
  let longitude = -180 + letterIndex(grid[0], "A") * 20;
  let latitude = -90 + letterIndex(grid[1], "A") * 10;
  let longitudeSpan = 20;
  let latitudeSpan = 10;
  if (grid.length >= 4) {
    longitude += Number(grid[2]) * 2;
    latitude += Number(grid[3]);
    longitudeSpan = 2;
    latitudeSpan = 1;
  }
  if (grid.length >= 6) {
    longitude += letterIndex(grid[4], "A") * (5 / 60);
    latitude += letterIndex(grid[5], "A") * (2.5 / 60);
    longitudeSpan = 5 / 60;
    latitudeSpan = 2.5 / 60;
  }
  if (grid.length >= 8) {
    longitude += Number(grid[6]) * (0.5 / 60);
    latitude += Number(grid[7]) * (0.25 / 60);
    longitudeSpan = 0.5 / 60;
    latitudeSpan = 0.25 / 60;
  }
  return {
    grid,
    latitude: latitude + latitudeSpan / 2,
    longitude: longitude + longitudeSpan / 2,
    latitudeSpan,
    longitudeSpan,
  };
}

function letterIndex(value: string, base: "A"): number {
  return value.charCodeAt(0) - base.charCodeAt(0);
}
