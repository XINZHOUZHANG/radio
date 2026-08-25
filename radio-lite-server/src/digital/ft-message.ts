export type ParsedFtMessage =
  | {
      kind: "cq";
      text: string;
      senderCallsign: string;
      grid: string | null;
      qualifier: string | null;
    }
  | {
      kind: "grid";
      text: string;
      senderCallsign: string;
      recipientCallsign: string;
      grid: string;
    }
  | {
      kind: "report" | "roger_report";
      text: string;
      senderCallsign: string;
      recipientCallsign: string;
      report: number;
    }
  | {
      kind: "rrr" | "rr73" | "73";
      text: string;
      senderCallsign: string;
      recipientCallsign: string;
    }
  | {
      kind: "free_text";
      text: string;
    };

const GRID_PATTERN = /^[A-R]{2}[0-9]{2}(?:[A-X]{2})?$/u;
const REPORT_PATTERN = /^([+-])([0-9]{2})$/u;
const ROGER_REPORT_PATTERN = /^R([+-])([0-9]{2})$/u;

export function parseFtMessage(value: string): ParsedFtMessage {
  const text = normalizeFtText(value);
  const tokens = text.split(" ");
  if (tokens[0] === "CQ" && tokens.length >= 2) {
    const grid = GRID_PATTERN.test(tokens.at(-1) ?? "") ? tokens.at(-1)! : null;
    const callsignIndex = grid === null ? tokens.length - 1 : tokens.length - 2;
    const senderCallsign = callsign(tokens[callsignIndex], "CQ sender callsign");
    const qualifierTokens = tokens.slice(1, callsignIndex);
    return {
      kind: "cq",
      text,
      senderCallsign,
      grid,
      qualifier: qualifierTokens.length === 0 ? null : qualifierTokens.join(" "),
    };
  }
  if (tokens.length < 3 || !isCallsign(tokens[0]) || !isCallsign(tokens[1])) {
    return { kind: "free_text", text };
  }
  const recipientCallsign = callsign(tokens[0], "recipient callsign");
  const senderCallsign = callsign(tokens[1], "sender callsign");
  const payload = tokens.slice(2).join(" ");
  if (payload === "RRR" || payload === "RR73" || payload === "73") {
    return {
      kind: payload === "RRR" ? "rrr" : payload === "RR73" ? "rr73" : "73",
      text,
      senderCallsign,
      recipientCallsign,
    };
  }
  if (GRID_PATTERN.test(payload)) {
    return { kind: "grid", text, senderCallsign, recipientCallsign, grid: payload };
  }
  const report = REPORT_PATTERN.exec(payload);
  if (report !== null) {
    return {
      kind: "report",
      text,
      senderCallsign,
      recipientCallsign,
      report: numericReport(report[1], report[2]),
    };
  }
  const rogerReport = ROGER_REPORT_PATTERN.exec(payload);
  if (rogerReport !== null) {
    return {
      kind: "roger_report",
      text,
      senderCallsign,
      recipientCallsign,
      report: numericReport(rogerReport[1], rogerReport[2]),
    };
  }
  return { kind: "free_text", text };
}

export function normalizeFtText(value: string): string {
  if (typeof value !== "string") {
    throw new Error("FT message must be text");
  }
  const normalized = value.trim().toUpperCase().replace(/\s+/gu, " ");
  if (normalized.length < 1 || normalized.length > 64 || /[\0\r\n]/u.test(normalized)) {
    throw new Error("FT message must be 1..64 characters on one line");
  }
  return normalized;
}

export function normalizeCallsign(value: string): string {
  return callsign(value, "callsign");
}

export function normalizeGrid(value: string): string {
  if (typeof value !== "string") {
    throw new Error("grid must be text");
  }
  const normalized = value.trim().toUpperCase();
  if (!GRID_PATTERN.test(normalized)) {
    throw new Error("grid must be a 4 or 6 character Maidenhead locator");
  }
  return normalized;
}

export function formatSignalReport(value: number): string {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error("signal report must be finite");
  }
  const rounded = Math.max(-50, Math.min(49, Math.round(value)));
  return `${rounded >= 0 ? "+" : "-"}${Math.abs(rounded).toString().padStart(2, "0")}`;
}

export function formatDirectedMessage(
  recipientCallsign: string,
  senderCallsign: string,
  payload: string,
): string {
  const recipient = callsign(recipientCallsign, "recipient callsign");
  const sender = callsign(senderCallsign, "sender callsign");
  const normalizedPayload = normalizeFtText(payload);
  const message = `${recipient} ${sender} ${normalizedPayload}`;
  if (message.length > 64) {
    throw new Error("directed FT message exceeds 64 characters");
  }
  return message;
}

function callsign(value: string, field: string): string {
  if (typeof value !== "string") {
    throw new Error(`${field} must be text`);
  }
  const normalized = value.trim().toUpperCase();
  if (!isCallsign(normalized)) {
    throw new Error(`${field} is invalid`);
  }
  return normalized.startsWith("<") ? normalized.slice(1, -1) : normalized;
}

function isCallsign(value: string): boolean {
  const unwrapped = value.startsWith("<") && value.endsWith(">")
    ? value.slice(1, -1)
    : value;
  return /^[A-Z0-9/.-]{3,16}$/u.test(unwrapped)
    && /[A-Z]/u.test(unwrapped)
    && /[0-9]/u.test(unwrapped);
}

function numericReport(sign: string, digits: string): number {
  const value = Number(digits) * (sign === "-" ? -1 : 1);
  if (value < -50 || value > 49) {
    throw new Error("FT signal report is outside -50..+49");
  }
  return value;
}
