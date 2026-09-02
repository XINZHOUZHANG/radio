export type DeKeyMode = "voice" | "digital" | "tuning";

export type DeKeyTransport = {
  deactivate(mode: DeKeyMode): Promise<void>;
  emergencyOff(): Promise<void>;
  readPtt(): Promise<boolean>;
};

export type DeKeyOutcome =
  | { kind: "offConfirmed"; generation: number }
  | { kind: "recoveryPending"; generation: number }
  | { kind: "notResponsible"; generation: number };

export type DeKeyAttempt =
  | { confirmed: true; generation: number }
  | { confirmed: false; generation: number; reason: string };
