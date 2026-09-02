import type { DigitalMode, SlotParity } from "./types.ts";

const SLOT_DURATIONS_MS: Record<DigitalMode, number> = {
  FT8: 15_000,
  FT4: 7_500,
};

export function slotDurationMs(mode: DigitalMode): number {
  return SLOT_DURATIONS_MS[mode];
}

export function slotIndexAt(mode: DigitalMode, timestampMs: number): number {
  return Math.floor(timestamp(timestampMs) / slotDurationMs(mode));
}

export function slotStartAt(mode: DigitalMode, timestampMs: number): number {
  return slotIndexAt(mode, timestampMs) * slotDurationMs(mode);
}

export function isSlotBoundary(mode: DigitalMode, timestampMs: number): boolean {
  return timestamp(timestampMs) % slotDurationMs(mode) === 0;
}

export function slotParityAt(mode: DigitalMode, timestampMs: number): SlotParity {
  return slotIndexAt(mode, timestampMs) % 2 === 0 ? "even" : "odd";
}

export function oppositeSlotParity(value: SlotParity): SlotParity {
  return value === "even" ? "odd" : "even";
}

export function nextSlotStart(
  mode: DigitalMode,
  afterMs: number,
  parity?: SlotParity,
): number {
  const duration = slotDurationMs(mode);
  let index = slotIndexAt(mode, afterMs) + 1;
  if (parity !== undefined && parityForIndex(index) !== parity) {
    index += 1;
  }
  return index * duration;
}

function parityForIndex(index: number): SlotParity {
  return index % 2 === 0 ? "even" : "odd";
}

function timestamp(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error("timestamp must be a non-negative epoch millisecond integer");
  }
  return value;
}
