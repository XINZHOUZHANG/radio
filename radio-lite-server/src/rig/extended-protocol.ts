export type RigResponse = {
  command: string;
  fields: ReadonlyMap<string, string>;
  values: readonly string[];
  report: number;
};

export class RigProtocolError extends Error {}

export function encodeRigCommand(command: string): Buffer {
  if (typeof command !== "string" || command.length < 1 || command.length > 4_096) {
    throw new Error("rigctld command must contain 1..4096 characters");
  }
  if (/[\r\n\0]/u.test(command)) {
    throw new Error("rigctld command must be exactly one line");
  }
  if (!/^[\x20-\x7e]+$/u.test(command)) {
    throw new Error("rigctld command must be ASCII");
  }
  return Buffer.from(`|${command}\n`, "ascii");
}

export class ExtendedResponseParser {
  readonly #maxBufferBytes: number;
  #buffer = "";
  #decoder = new TextDecoder("utf-8", { fatal: true });

  constructor(maxBufferBytes = 262_144) {
    if (!Number.isSafeInteger(maxBufferBytes) || maxBufferBytes < 1) {
      throw new Error("parser buffer limit must be a positive integer");
    }
    this.#maxBufferBytes = maxBufferBytes;
  }

  feed(data: Uint8Array): RigResponse[] {
    try {
      this.#buffer += this.#decoder.decode(data, { stream: true });
    } catch (error) {
      this.reset();
      throw new RigProtocolError("rigctld response contains invalid UTF-8", { cause: error });
    }
    this.#enforceLimit();
    const responses: RigResponse[] = [];
    while (true) {
      const terminal = terminalMatch(this.#buffer);
      const malformed = /\|RPRT[^|\r\n]*(?:\||\r?\n)/u.exec(this.#buffer);
      if (malformed !== null && (terminal === null || malformed.index < terminal.start)) {
        this.reset();
        throw new RigProtocolError("rigctld response has a malformed report code");
      }
      if (terminal === null) {
        break;
      }
      const payload = this.#buffer.slice(0, terminal.start);
      this.#buffer = this.#buffer.slice(terminal.end);
      responses.push(parseResponse(payload, terminal.report));
      this.#enforceLimit();
    }
    return responses;
  }

  reset(): void {
    this.#buffer = "";
    this.#decoder = new TextDecoder("utf-8", { fatal: true });
  }

  get hasTrailingData(): boolean {
    return this.#buffer !== "" && this.#buffer !== "\n" && this.#buffer !== "\r\n";
  }

  #enforceLimit(): void {
    if (Buffer.byteLength(this.#buffer, "utf8") > this.#maxBufferBytes) {
      this.reset();
      throw new RigProtocolError("rigctld response exceeds configured limit");
    }
  }
}

function terminalMatch(buffer: string): { start: number; end: number; report: number } | null {
  const pipe = /\|RPRT (-?\d+)\|(?:\r?\n)?/u.exec(buffer);
  const newline = /(?:^|[|\n])RPRT (-?\d+)\r?\n/u.exec(buffer);
  const matches = [pipe, newline].filter((match): match is RegExpExecArray => match !== null);
  if (matches.length === 0) {
    return null;
  }
  const match = matches.reduce((earliest, item) => item.index < earliest.index ? item : earliest);
  return { start: match.index, end: match.index + match[0].length, report: Number(match[1]) };
}

function parseResponse(payload: string, report: number): RigResponse {
  const records = payload.split("|");
  const header = records.shift() ?? "";
  const headerMatch = /^([a-z][a-z0-9_]*):(?: .*)?$/u.exec(header);
  if (headerMatch === null) {
    throw new RigProtocolError("rigctld response has a malformed command header");
  }
  const fields = new Map<string, string>();
  const values: string[] = [];
  for (const record of records) {
    if (!record) {
      continue;
    }
    const separator = record.indexOf(":");
    if (separator > 0 && /^[ \t]/u.test(record.slice(separator + 1, separator + 2))) {
      const key = record.slice(0, separator);
      if (key === key.trim() && !key.includes("\n")) {
        fields.set(key, record.slice(separator + 1).trimStart());
        continue;
      }
    }
    if (/^[A-Za-z][A-Za-z0-9_ ]*=.*$/u.test(record)) {
      throw new RigProtocolError("rigctld response has a malformed field");
    }
    values.push(record);
  }
  return { command: headerMatch[1], fields, values, report };
}
