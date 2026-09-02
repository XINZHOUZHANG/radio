import type { DeviceCredentialBundle } from "./device-store.ts";
import { DeviceStore } from "./device-store.ts";
import { SixDigitCodeVault, type IssuedCode } from "./six-digit-codes.ts";

export class PairingService {
  readonly #codes: SixDigitCodeVault;
  readonly #devices: DeviceStore;
  readonly #pairingLifetimeMs: number;

  constructor(
    codes: SixDigitCodeVault,
    devices: DeviceStore,
    pairingLifetimeMs = 2 * 60_000,
  ) {
    if (!Number.isSafeInteger(pairingLifetimeMs) || pairingLifetimeMs <= 0) {
      throw new Error("pairing code lifetime must be a positive integer");
    }
    this.#codes = codes;
    this.#devices = devices;
    this.#pairingLifetimeMs = pairingLifetimeMs;
  }

  issueForUser(userId: string): IssuedCode {
    this.#codes.invalidateSubject(userId, "device_pairing");
    return this.#codes.issue(userId, "device_pairing", this.#pairingLifetimeMs);
  }

  async redeem(
    code: string,
    deviceName: string,
    sourceKey: string,
  ): Promise<DeviceCredentialBundle> {
    const userId = this.#codes.redeem(code, "device_pairing", sourceKey);
    return this.#devices.pair(userId, deviceName);
  }
}
