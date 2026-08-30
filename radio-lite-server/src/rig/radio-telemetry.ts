import type {
  RadioDriver,
  RadioMeterSample,
  RadioState,
} from "./radio-driver.ts";

export type RadioTelemetry = {
  radioId: string;
  sampledAtMs: number;
  state: RadioState;
  meters: {
    strengthDbRelativeS9?: number;
    swr?: number;
    alcRatio?: number;
    rfPowerRatio?: number;
    rfPowerWatts?: number;
  };
  availableMeters: string[];
};

export type RadioTelemetryListener = (value: RadioTelemetry) => void;

export interface RadioTelemetryClock {
  now(): number;
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(timer: unknown): void;
}

export type RadioTelemetrySamplerOptions = {
  clock?: RadioTelemetryClock;
  now?: () => number;
  receivePeriodMs?: number;
  transmitPeriodMs?: number;
};

const RECEIVE_PERIOD_MS = 2_000;
const TRANSMIT_PERIOD_MS = 1_000;

export class RadioTelemetrySampler {
  readonly #radioId: string;
  readonly #driver: RadioDriver;
  readonly #clock: RadioTelemetryClock;
  readonly #receivePeriodMs: number;
  readonly #transmitPeriodMs: number;
  readonly #listeners = new Set<RadioTelemetryListener>();
  #value: RadioTelemetry | null = null;
  #timer: unknown = null;
  #inFlight: Promise<void> | null = null;
  #started = false;
  #closed = false;
  #phase: "receive" | "transmit" = "receive";
  #confirmedRevision = 0;
  #pendingConfirmedState: Partial<RadioState> = {};

  constructor(
    radioId: string,
    driver: RadioDriver,
    options: RadioTelemetrySamplerOptions = {},
  ) {
    this.#radioId = radioId;
    this.#driver = driver;
    this.#clock = options.clock ?? systemClock(options.now ?? Date.now);
    this.#receivePeriodMs = options.receivePeriodMs ?? RECEIVE_PERIOD_MS;
    this.#transmitPeriodMs = options.transmitPeriodMs ?? TRANSMIT_PERIOD_MS;
  }

  start(): void {
    if (this.#started || this.#closed) return;
    this.#started = true;
    this.#scheduleNext();
  }

  subscribe(listener: RadioTelemetryListener): () => void {
    if (this.#closed) {
      throw new Error("radio telemetry sampler is closed");
    }
    this.#listeners.add(listener);
    if (this.#value === null) {
      void this.#sample().catch(() => undefined);
    } else {
      const current = cloneTelemetry(this.#value);
      queueMicrotask(() => {
        if (this.#listeners.has(listener) && !this.#closed) {
          this.#deliver(listener, current);
        }
      });
    }
    let active = true;
    return () => {
      if (!active) return;
      active = false;
      this.#listeners.delete(listener);
    };
  }

  snapshot(): RadioTelemetry | null {
    return this.#value === null ? null : cloneTelemetry(this.#value);
  }

  async readState(): Promise<RadioState> {
    if (this.#value === null) {
      await this.#sample();
    }
    if (this.#value === null) {
      throw new Error("radio state is unavailable");
    }
    return { ...this.#value.state };
  }

  confirmFrequency(frequencyHz: number): void {
    this.#confirmState({ frequencyHz });
  }

  confirmMode(mode: string, passbandHz: number): void {
    this.#confirmState({ mode, passbandHz });
  }

  confirmPtt(ptt: boolean): void {
    const previous = this.#phase;
    this.#phase = ptt ? "transmit" : "receive";
    this.#confirmState({ ptt });
    if (previous !== this.#phase && this.#timer !== null) {
      this.#clock.clearTimeout(this.#timer);
      this.#timer = null;
      this.#scheduleNext();
    }
  }

  close(): Promise<void> {
    if (!this.#closed) {
      this.#closed = true;
      this.#started = false;
      if (this.#timer !== null) {
        this.#clock.clearTimeout(this.#timer);
        this.#timer = null;
      }
      this.#listeners.clear();
    }
    const active = this.#inFlight;
    return active === null ? Promise.resolve() : active.catch(() => undefined);
  }

  #confirmState(value: Partial<RadioState>): void {
    this.#confirmedRevision += 1;
    this.#pendingConfirmedState = { ...this.#pendingConfirmedState, ...value };
    if (this.#value !== null) {
      this.#value = {
        ...this.#value,
        state: { ...this.#value.state, ...value },
      };
    }
  }

  #sample(): Promise<void> {
    if (this.#closed) return Promise.resolve();
    if (this.#inFlight !== null) return this.#inFlight;
    const operation = this.#performSample();
    this.#inFlight = operation;
    void operation.finally(() => {
      if (this.#inFlight === operation) this.#inFlight = null;
    }).catch(() => undefined);
    return operation;
  }

  async #performSample(): Promise<void> {
    const confirmedRevision = this.#confirmedRevision;
    this.#pendingConfirmedState = {};
    const mode = this.#phase === "transmit" && this.#value !== null
      ? "transmit"
      : "receive";
    let state: RadioState;
    let meters: RadioMeterSample;
    if (mode === "receive") {
      [state, meters] = await Promise.all([
        this.#driver.readState({ source: "telemetry" }),
        this.#driver.readTelemetry("receive"),
      ]);
    } else {
      state = { ...this.#value!.state };
      meters = await this.#driver.readTelemetry("transmit");
      if (meters.ptt !== undefined) state.ptt = meters.ptt;
    }
    if (this.#closed) return;
    if (this.#confirmedRevision !== confirmedRevision) {
      state = {
        ...state,
        ...this.#pendingConfirmedState,
      };
    }
    this.#pendingConfirmedState = {};
    const value: RadioTelemetry = {
      radioId: this.#radioId,
      sampledAtMs: this.#clock.now(),
      state,
      meters: meterValues(meters),
      availableMeters: [...(meters.availableMeters ?? [])],
    };
    this.#phase = state.ptt ? "transmit" : "receive";
    this.#value = value;
    for (const listener of [...this.#listeners]) {
      this.#deliver(listener, cloneTelemetry(value));
    }
    if (this.#started) {
      if (this.#timer !== null) this.#clock.clearTimeout(this.#timer);
      this.#timer = null;
      this.#scheduleNext();
    }
  }

  #deliver(listener: RadioTelemetryListener, value: RadioTelemetry): void {
    try {
      listener(value);
    } catch {
      this.#listeners.delete(listener);
    }
  }

  #scheduleNext(): void {
    if (!this.#started || this.#closed || this.#timer !== null) return;
    const delayMs = this.#phase === "transmit"
      ? this.#transmitPeriodMs
      : this.#receivePeriodMs;
    this.#timer = this.#clock.setTimeout(() => {
      this.#timer = null;
      void this.#sample()
        .catch(() => undefined)
        .finally(() => this.#scheduleNext());
    }, delayMs);
  }
}

function meterValues(sample: RadioMeterSample): RadioTelemetry["meters"] {
  const values: RadioTelemetry["meters"] = {};
  if (sample.strengthDbRelativeS9 !== undefined) {
    values.strengthDbRelativeS9 = sample.strengthDbRelativeS9;
  }
  if (sample.swr !== undefined) values.swr = sample.swr;
  if (sample.alcRatio !== undefined) values.alcRatio = sample.alcRatio;
  if (sample.rfPowerRatio !== undefined) values.rfPowerRatio = sample.rfPowerRatio;
  if (sample.rfPowerWatts !== undefined) values.rfPowerWatts = sample.rfPowerWatts;
  return values;
}

function cloneTelemetry(value: RadioTelemetry): RadioTelemetry {
  return {
    ...value,
    state: { ...value.state },
    meters: { ...value.meters },
    availableMeters: [...value.availableMeters],
  };
}

function systemClock(now: () => number): RadioTelemetryClock {
  return {
    now,
    setTimeout: (callback, delayMs) => {
      const timer = setTimeout(callback, delayMs);
      timer.unref();
      return timer;
    },
    clearTimeout: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
  };
}
