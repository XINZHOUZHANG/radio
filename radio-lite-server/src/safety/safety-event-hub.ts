import { randomUUID } from "node:crypto";

export type PersistentSafetyAlertKind =
  | "active"
  | "external_ptt"
  | "telemetry_uncertain"
  | "dekey_required"
  | "dekey_escalated"
  | "swr_trip_latched"
  | "swr_rearm_pending";

export type SafetyEventKind = PersistentSafetyAlertKind | "recovered";
export type SafetyAlertOwner = "transmit" | "swr" | "telemetry";

export type SafetyOwnerVersion = {
  generation: number;
  ownerRevision: number;
};

export type SafetyOwnerCursor = SafetyOwnerVersion & {
  radioId: string;
  owner: SafetyAlertOwner;
};

export type SafetyPublishProof = {
  kind: "swr_reset_persisted";
  generation: number;
};

export type SafetyClearProof = {
  kind: "ptt_off_confirmed" | "swr_rearm_safe" | "telemetry_recovered";
  generation: number;
};

export type SwrSafetyStoredState =
  | "armed"
  | "latched"
  | "rearm_pending"
  | "rearm_in_progress";

export type SwrSafetyRecord = {
  radioId: string;
  state: SwrSafetyStoredState;
  trippedAtMs: number | null;
};

export type SafetyAlert = {
  kind: PersistentSafetyAlertKind;
  startedAtMs: number;
  source: "software" | "external" | "telemetry";
};

export type SafetyAlertSnapshot = {
  t: "safety.snapshot";
  safetyEpoch: string;
  radioId: string;
  revision: number;
  alert: SafetyAlert | null;
};

export type SafetyEvent = {
  t: "safety.event";
  safetyEpoch: string;
  radioId: string;
  revision: number;
  kind: SafetyEventKind;
  startedAtMs: number;
  source: "software" | "external" | "telemetry";
};

export type SafetyStreamMessage =
  | SafetyAlertSnapshot
  | SafetyEvent
  | { t: "safety.snapshot.begin"; safetyEpoch: string }
  | { t: "safety.snapshot.end"; safetyEpoch: string };

export type SafetyMutation = {
  cursor: SafetyOwnerCursor;
  event: SafetyEvent | null;
};

export type SafetyEventHubOptions = {
  configuredRadioIds: () => readonly string[];
  safetyEpoch?: string;
};

type OwnerSlot = {
  generation: number;
  ownerRevision: number;
  alert: SafetyAlert | null;
  // Needed to prove that an SWR reset was begun after the trip it is replacing.
  alertGeneration: number | null;
};

type RadioState = {
  revision: number;
  owners: Record<SafetyAlertOwner, OwnerSlot>;
};

type Subscriber = {
  send: (value: SafetyStreamMessage) => void;
  queue: SafetyStreamMessage[];
  bufferedEvents: SafetyEvent[];
  bufferingSnapshot: boolean;
  delivering: boolean;
  active: boolean;
};

const PRIORITY: Record<PersistentSafetyAlertKind, number> = {
  telemetry_uncertain: 1,
  external_ptt: 2,
  active: 3,
  swr_rearm_pending: 4,
  swr_trip_latched: 5,
  dekey_required: 6,
  dekey_escalated: 7,
};

export class SafetyEventHub {
  readonly safetyEpoch: string;

  readonly #configuredRadioIds: () => readonly string[];
  readonly #radios = new Map<string, RadioState>();
  readonly #subscribers = new Set<Subscriber>();

  constructor(options: SafetyEventHubOptions) {
    this.#configuredRadioIds = options.configuredRadioIds;
    this.safetyEpoch = options.safetyEpoch ?? randomUUID();
  }

  ownerVersion(radioId: string, owner: SafetyAlertOwner): SafetyOwnerVersion {
    const slot = this.#radio(radioId).owners[owner];
    return {
      generation: slot.generation,
      ownerRevision: slot.ownerRevision,
    };
  }

  beginOwnerGeneration(
    radioId: string,
    owner: SafetyAlertOwner,
    expected: SafetyOwnerVersion,
  ): SafetyOwnerCursor | null {
    const slot = this.#radio(radioId).owners[owner];
    if (!sameVersion(slot, expected)) {
      return null;
    }
    slot.generation += 1;
    return cursorFor(radioId, owner, slot);
  }

  publish(
    expected: SafetyOwnerCursor,
    alert: SafetyAlert,
    proof?: SafetyPublishProof,
  ): SafetyMutation | null {
    const radio = this.#radio(expected.radioId);
    const slot = radio.owners[expected.owner];
    if (!sameVersion(slot, expected)) {
      return null;
    }
    if (
      !validAlert(expected.owner, alert) ||
      !validPublish(expected.owner, slot, expected, alert, proof)
    ) {
      return null;
    }

    const before = projectedAlert(radio);
    slot.ownerRevision += 1;
    slot.alert = cloneAlert(alert);
    slot.alertGeneration = slot.generation;
    const after = projectedAlert(radio);
    const event = this.#eventForProjectionChange(
      expected.radioId,
      radio,
      before,
      after,
      alert.startedAtMs,
      alert.source,
    );
    return {
      cursor: cursorFor(expected.radioId, expected.owner, slot),
      event: event === null ? null : cloneEvent(event),
    };
  }

  clear(
    expected: SafetyOwnerCursor,
    recoveredAtMs: number,
    proof: SafetyClearProof,
  ): SafetyMutation | null {
    const radio = this.#radio(expected.radioId);
    const slot = radio.owners[expected.owner];
    if (!sameVersion(slot, expected)) {
      return null;
    }
    if (
      !isNonNegativeSafeInteger(recoveredAtMs) ||
      !validClear(expected.owner, slot, expected, proof)
    ) {
      return null;
    }

    const before = projectedAlert(radio);
    slot.ownerRevision += 1;
    slot.alert = null;
    slot.alertGeneration = null;
    const after = projectedAlert(radio);
    const event = this.#eventForProjectionChange(
      expected.radioId,
      radio,
      before,
      after,
      recoveredAtMs,
      before?.source ?? recoverySource(proof),
    );
    return {
      cursor: cursorFor(expected.radioId, expected.owner, slot),
      event: event === null ? null : cloneEvent(event),
    };
  }

  snapshot(radioId: string): SafetyAlertSnapshot {
    const radio = this.#radios.get(radioId);
    return {
      t: "safety.snapshot",
      safetyEpoch: this.safetyEpoch,
      radioId,
      revision: radio?.revision ?? 0,
      alert: radio === undefined ? null : cloneNullableAlert(projectedAlert(radio)),
    };
  }

  subscribeControl(send: (value: SafetyStreamMessage) => void): () => void {
    const subscriber: Subscriber = {
      send,
      queue: [],
      bufferedEvents: [],
      bufferingSnapshot: true,
      delivering: false,
      active: true,
    };
    this.#subscribers.add(subscriber);

    let snapshots: SafetyAlertSnapshot[];
    try {
      const configured = [...new Set(this.#configuredRadioIds())];
      // Capture the entire set before invoking user code. Re-entrant publishes during
      // delivery are increments, never rewrites of later snapshots in the envelope.
      snapshots = configured.map((radioId) => this.snapshot(radioId));
    } catch (error) {
      this.#detach(subscriber);
      throw error;
    }
    const capturedRevisions = new Map(
      snapshots.map((value) => [value.radioId, value.revision] as const),
    );

    subscriber.queue.push(
      { t: "safety.snapshot.begin", safetyEpoch: this.safetyEpoch },
      ...snapshots.map(cloneStreamMessage),
      { t: "safety.snapshot.end", safetyEpoch: this.safetyEpoch },
    );
    this.#drain(subscriber);

    if (subscriber.active) {
      subscriber.bufferingSnapshot = false;
      for (const event of subscriber.bufferedEvents) {
        const capturedRevision = capturedRevisions.get(event.radioId);
        if (
          capturedRevision !== undefined &&
          event.safetyEpoch === this.safetyEpoch &&
          event.revision > capturedRevision
        ) {
          subscriber.queue.push(cloneEvent(event));
        }
      }
      subscriber.bufferedEvents.length = 0;
      this.#drain(subscriber);
    }

    return () => this.#detach(subscriber);
  }

  #radio(radioId: string): RadioState {
    let radio = this.#radios.get(radioId);
    if (radio === undefined) {
      radio = {
        revision: 0,
        owners: {
          transmit: emptySlot(),
          swr: emptySlot(),
          telemetry: emptySlot(),
        },
      };
      this.#radios.set(radioId, radio);
    }
    return radio;
  }

  #eventForProjectionChange(
    radioId: string,
    radio: RadioState,
    before: SafetyAlert | null,
    after: SafetyAlert | null,
    recoveredAtMs: number,
    recoveredSource: SafetyEvent["source"],
  ): SafetyEvent | null {
    if (sameAlert(before, after)) {
      return null;
    }
    radio.revision += 1;
    const event: SafetyEvent = after === null
      ? {
          t: "safety.event",
          safetyEpoch: this.safetyEpoch,
          radioId,
          revision: radio.revision,
          kind: "recovered",
          startedAtMs: recoveredAtMs,
          source: recoveredSource,
        }
      : {
          t: "safety.event",
          safetyEpoch: this.safetyEpoch,
          radioId,
          revision: radio.revision,
          kind: after.kind,
          startedAtMs: after.startedAtMs,
          source: after.source,
        };
    this.#broadcast(event);
    return event;
  }

  #broadcast(event: SafetyEvent): void {
    const targets = [...this.#subscribers].filter((value) => value.active);
    // Queue for every subscriber before invoking any callback. A callback may publish
    // another revision; pre-enqueueing preserves FIFO for subscribers not yet drained.
    for (const subscriber of targets) {
      if (subscriber.bufferingSnapshot) {
        subscriber.bufferedEvents.push(cloneEvent(event));
      } else {
        subscriber.queue.push(cloneEvent(event));
      }
    }
    for (const subscriber of targets) {
      if (!subscriber.bufferingSnapshot) {
        this.#drain(subscriber);
      }
    }
  }

  #drain(subscriber: Subscriber): void {
    if (!subscriber.active || subscriber.delivering) {
      return;
    }
    subscriber.delivering = true;
    try {
      while (subscriber.active && subscriber.queue.length > 0) {
        const value = subscriber.queue.shift();
        if (value !== undefined) {
          subscriber.send(value);
        }
      }
    } catch {
      this.#detach(subscriber);
    } finally {
      subscriber.delivering = false;
    }
  }

  #detach(subscriber: Subscriber): void {
    subscriber.active = false;
    subscriber.queue.length = 0;
    subscriber.bufferedEvents.length = 0;
    this.#subscribers.delete(subscriber);
  }
}

function emptySlot(): OwnerSlot {
  return {
    generation: 0,
    ownerRevision: 0,
    alert: null,
    alertGeneration: null,
  };
}

function cursorFor(
  radioId: string,
  owner: SafetyAlertOwner,
  slot: OwnerSlot,
): SafetyOwnerCursor {
  return {
    radioId,
    owner,
    generation: slot.generation,
    ownerRevision: slot.ownerRevision,
  };
}

function sameVersion(slot: OwnerSlot, expected: SafetyOwnerVersion): boolean {
  return (
    slot.generation === expected.generation &&
    slot.ownerRevision === expected.ownerRevision
  );
}

function validPublish(
  owner: SafetyAlertOwner,
  slot: OwnerSlot,
  cursor: SafetyOwnerCursor,
  alert: SafetyAlert,
  proof: SafetyPublishProof | undefined,
): boolean {
  const currentKind = slot.alert?.kind ?? null;
  switch (owner) {
    case "transmit":
      if (!isTransmitKind(alert.kind) || proof !== undefined) {
        return false;
      }
      return (
        (currentKind === null && alert.kind === "active") ||
        currentKind === alert.kind ||
        (currentKind === "active" && alert.kind === "dekey_required") ||
        (currentKind === "dekey_required" && alert.kind === "dekey_escalated")
      );
    case "swr":
      if (!isSwrKind(alert.kind)) {
        return false;
      }
      if (currentKind === "swr_trip_latched" && alert.kind === "swr_rearm_pending") {
        return (
          proof?.kind === "swr_reset_persisted" &&
          proof.generation === cursor.generation &&
          slot.alertGeneration !== null &&
          slot.alertGeneration < cursor.generation
        );
      }
      if (proof !== undefined) {
        return false;
      }
      return (
        (currentKind === null && alert.kind === "swr_trip_latched") ||
        currentKind === alert.kind ||
        (currentKind === "swr_rearm_pending" && alert.kind === "swr_trip_latched")
      );
    case "telemetry":
      if (!isTelemetryKind(alert.kind) || proof !== undefined) {
        return false;
      }
      return (
        (currentKind === null && isTelemetryKind(alert.kind)) ||
        currentKind === alert.kind ||
        (currentKind === "telemetry_uncertain" && alert.kind === "external_ptt")
      );
  }
}

function validAlert(owner: SafetyAlertOwner, alert: SafetyAlert): boolean {
  if (!isNonNegativeSafeInteger(alert.startedAtMs)) {
    return false;
  }
  switch (owner) {
    case "transmit":
    case "swr":
      return alert.source === "software";
    case "telemetry":
      return (
        (alert.kind === "external_ptt" && alert.source === "external") ||
        (alert.kind === "telemetry_uncertain" && alert.source === "telemetry")
      );
  }
}

function validClear(
  owner: SafetyAlertOwner,
  slot: OwnerSlot,
  cursor: SafetyOwnerCursor,
  proof: SafetyClearProof,
): boolean {
  if (slot.alert === null || proof.generation !== cursor.generation) {
    return false;
  }
  switch (owner) {
    case "transmit":
      return proof.kind === "ptt_off_confirmed";
    case "swr":
      return (
        proof.kind === "swr_rearm_safe" &&
        slot.alert.kind === "swr_rearm_pending"
      );
    case "telemetry":
      return proof.kind === "telemetry_recovered";
  }
}

function projectedAlert(radio: RadioState): SafetyAlert | null {
  let projected: SafetyAlert | null = null;
  for (const owner of ["transmit", "swr", "telemetry"] as const) {
    const alert = radio.owners[owner].alert;
    if (
      alert !== null &&
      (projected === null || PRIORITY[alert.kind] > PRIORITY[projected.kind])
    ) {
      projected = alert;
    }
  }
  return projected;
}

function sameAlert(left: SafetyAlert | null, right: SafetyAlert | null): boolean {
  return (
    left === right ||
    (left !== null &&
      right !== null &&
      left.kind === right.kind &&
      left.startedAtMs === right.startedAtMs &&
      left.source === right.source)
  );
}

function isTransmitKind(kind: PersistentSafetyAlertKind): boolean {
  return kind === "active" || kind === "dekey_required" || kind === "dekey_escalated";
}

function isSwrKind(kind: PersistentSafetyAlertKind): boolean {
  return kind === "swr_trip_latched" || kind === "swr_rearm_pending";
}

function isTelemetryKind(kind: PersistentSafetyAlertKind): boolean {
  return kind === "telemetry_uncertain" || kind === "external_ptt";
}

function recoverySource(proof: SafetyClearProof): SafetyEvent["source"] {
  return proof.kind === "telemetry_recovered" ? "telemetry" : "software";
}

function isNonNegativeSafeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function cloneAlert(alert: SafetyAlert): SafetyAlert {
  return { ...alert };
}

function cloneNullableAlert(alert: SafetyAlert | null): SafetyAlert | null {
  return alert === null ? null : cloneAlert(alert);
}

function cloneEvent(event: SafetyEvent): SafetyEvent {
  return { ...event };
}

function cloneStreamMessage(message: SafetyStreamMessage): SafetyStreamMessage {
  if (message.t === "safety.snapshot") {
    return {
      ...message,
      alert: cloneNullableAlert(message.alert),
    };
  }
  return { ...message };
}
