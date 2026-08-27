import type { RadioConfigFile, RadioProfile } from "../config/types.ts";
import type { DeKeyOutcome } from "../safety/dekey.ts";
import type { TransmitMode } from "../safety/transmit-interlock.ts";
import { type MediaPolicy, AdaptiveMediaPolicy, type NetworkReport } from "./adaptive-policy.ts";
import { encodeMediaFrame, MediaKind, type MediaFrame } from "./frame.ts";
import { encodeSpectrumPayload, type SpectrumPayload } from "./spectrum-payload.ts";

export type MediaWorkerOutput = {
  audioDownlink(payload: Uint8Array, timestampUs?: bigint, flags?: number): void;
  spectrum(value: SpectrumPayload, timestampUs?: bigint, flags?: number): void;
  pcmCapture?(value: PcmCaptureChunk): void;
  fault(error: unknown): void;
};

export type SpectrumCapability = {
  available: boolean;
  source: "audio-fft" | "synthetic" | "none";
  simulated: boolean;
  supportsWaterfall: boolean;
  maxBins: 0 | 128 | 256 | 512;
  maxFps: 0 | 1 | 3 | 5;
  spanHz: number | null;
  reason?: string;
};

const unavailableSpectrumCapability: SpectrumCapability = {
  available: false,
  source: "none",
  simulated: false,
  supportsWaterfall: false,
  maxBins: 0,
  maxFps: 0,
  spanHz: null,
  reason: "spectrum_source_unavailable",
};

export type PcmCaptureChunk = {
  /** Signed 16-bit little-endian mono PCM. */
  pcm: Buffer;
  sampleRate: number;
  startedAtMs: number;
};

export type DigitalAudioPlayback = {
  readonly sampleRate: number;
  play(pcm: Int16Array, sampleRate: number, signal: AbortSignal): Promise<void>;
  stop(): Promise<void>;
};

export type MediaWorker = {
  readonly digitalAudio?: DigitalAudioPlayback;
  readonly spectrumCapability?: SpectrumCapability;
  updatePolicy(policy: MediaPolicy): void | Promise<void>;
  writeAudioUplink(frame: MediaFrame): boolean;
  close(): Promise<void>;
};

export type DigitalAudioConsumer = {
  pcm(value: PcmCaptureChunk): void;
  fault(error: unknown): void;
};

export type DigitalAudioPort = {
  readonly sampleRate: number;
  play(pcm: Int16Array, sampleRate: number, signal: AbortSignal): Promise<void>;
  stop(): Promise<void>;
  close(): Promise<void>;
};

export type MediaWorkerFactory = (
  profile: RadioProfile,
  radioSlot: number,
  output: MediaWorkerOutput,
) => Promise<MediaWorker>;

export type MediaClientTransport = {
  readonly bufferedAmount: number;
  sendBinary(value: Buffer): void;
  sendJson(value: unknown): void;
};

export type StopVoiceTransmitRequest = {
  radioId: string;
  ownerId: string;
  transmitToken: string;
  reason: "media_disconnected" | "media_unsubscribed" | "transmit_expired" | "uplink_bind_timeout" | "audio_uplink_failed" | "media_worker_failed" | "media_configuration_changed" | "control_owner_revoked";
};

export type RegisteredTransmit = {
  radioId: string;
  ownerId: string;
  principalId: string;
  userId: string;
  transmitToken: string;
  mode: TransmitMode;
  heartbeatDeadlineMs: number;
  hardDeadlineMs: number;
};

export type MediaHubOptions = {
  radios: () => RadioConfigFile;
  workerFactory: MediaWorkerFactory;
  stopVoiceTransmit(request: StopVoiceTransmitRequest): Promise<DeKeyOutcome>;
  now?: () => number;
  maxBufferedBytes?: number;
  uplinkBindTimeoutMs?: number;
};

export const createIdleMediaWorker: MediaWorkerFactory = async () => ({
  spectrumCapability: { ...unavailableSpectrumCapability },
  updatePolicy: () => undefined,
  writeAudioUplink: () => true,
  close: async () => undefined,
});

type MediaClient = {
  id: string;
  principalId: string;
  userId: string;
  transport: MediaClientTransport;
  adaptive: AdaptiveMediaPolicy;
  radioId: string | null;
  radioSlot: number | null;
  policy: MediaPolicy;
  spectrumCapability: SpectrumCapability;
  lastSpectrumSentAtUs: bigint | null;
  boundTransmitToken: string | null;
  lastUplinkSequence: number | null;
  droppedFrames: number;
};

type TransmitBinding = RegisteredTransmit & {
  boundClientId: string | null;
  bindTimer: ReturnType<typeof setTimeout> | null;
  pendingStop: Promise<DeKeyOutcome> | null;
};

type WorkerEntry = {
  radioId: string;
  radioSlot: number;
  worker: MediaWorker;
  audioSequence: number;
  spectrumSequence: number;
};

type DigitalAudioSubscription = {
  id: number;
  consumer: DigitalAudioConsumer;
  faulted: boolean;
  closed: boolean;
};

const MAX_OPUS_PACKET_BYTES = 1_500;

export class MediaHub {
  readonly #radios: () => RadioConfigFile;
  readonly #workerFactory: MediaWorkerFactory;
  readonly #stopVoiceTransmit: (
    request: StopVoiceTransmitRequest,
  ) => Promise<DeKeyOutcome>;
  readonly #now: () => number;
  readonly #maxBufferedBytes: number;
  readonly #uplinkBindTimeoutMs: number;
  readonly #clients = new Map<string, MediaClient>();
  readonly #transmits = new Map<string, TransmitBinding>();
  readonly #workers = new Map<string, WorkerEntry>();
  readonly #startingWorkers = new Map<string, Promise<WorkerEntry>>();
  readonly #digitalAudioSubscriptions = new Map<string, Map<number, DigitalAudioSubscription>>();
  readonly #digitalPlaybackOwners = new Map<string, number>();
  #nextDigitalAudioSubscriptionId = 1;
  #closed = false;

  constructor(options: MediaHubOptions) {
    this.#radios = options.radios;
    this.#workerFactory = options.workerFactory;
    this.#stopVoiceTransmit = options.stopVoiceTransmit;
    this.#now = options.now ?? Date.now;
    this.#maxBufferedBytes = positiveInteger(
      options.maxBufferedBytes ?? 64 * 1_024,
      "maximum buffered media bytes",
    );
    this.#uplinkBindTimeoutMs = positiveInteger(
      options.uplinkBindTimeoutMs ?? 3_000,
      "microphone uplink bind timeout",
    );
  }

  connect(value: {
    id: string;
    principalId: string;
    userId: string;
    transport: MediaClientTransport;
  }): void {
    this.#assertOpen();
    if (!value.id || !value.principalId || !value.userId) {
      throw new Error("media client identity is required");
    }
    if (this.#clients.has(value.id)) {
      throw new Error("media client is already connected");
    }
    const adaptive = new AdaptiveMediaPolicy();
    this.#clients.set(value.id, {
      ...value,
      adaptive,
      radioId: null,
      radioSlot: null,
      policy: adaptive.current(),
      spectrumCapability: { ...unavailableSpectrumCapability },
      lastSpectrumSentAtUs: null,
      boundTransmitToken: null,
      lastUplinkSequence: null,
      droppedFrames: 0,
    });
  }

  async subscribe(
    clientId: string,
    radioId: string,
    spectrumVisible: boolean,
  ): Promise<{
    radioId: string;
    radioSlot: number;
    policy: MediaPolicy;
    spectrum: SpectrumCapability;
  }> {
    const client = this.#client(clientId);
    if (client.boundTransmitToken !== null && client.radioId !== radioId) {
      throw new Error("cannot change radio while microphone uplink is bound");
    }
    const config = this.#radios();
    const radioSlot = config.radios.findIndex((radio) => radio.id === radioId);
    if (radioSlot < 0 || radioSlot > 255) {
      throw new Error("radio does not exist or has no media slot");
    }
    const worker = await this.#worker(config.radios[radioSlot], radioSlot);
    const spectrum = normalizeSpectrumCapability(worker.worker.spectrumCapability);
    const previousRadioId = client.radioId;
    client.radioId = radioId;
    client.radioSlot = radioSlot;
    client.spectrumCapability = spectrum;
    client.policy = applySpectrumCapability(client.adaptive.current(spectrumVisible), spectrum);
    client.lastSpectrumSentAtUs = null;
    client.lastUplinkSequence = null;
    if (previousRadioId !== null && previousRadioId !== radioId) {
      this.#updateWorkerPolicy(previousRadioId);
    }
    this.#updateWorkerPolicy(radioId);
    return { radioId, radioSlot, policy: client.policy, spectrum };
  }

  updateNetwork(clientId: string, report: NetworkReport): MediaPolicy {
    const client = this.#client(clientId);
    if (client.radioId === null) {
      throw new Error("media subscription is required");
    }
    const previousSpectrumFps = client.policy.spectrumFps;
    client.policy = applySpectrumCapability(
      client.adaptive.update(report),
      client.spectrumCapability,
    );
    if (client.policy.spectrumFps > previousSpectrumFps) {
      client.lastSpectrumSentAtUs = null;
    }
    this.#updateWorkerPolicy(client.radioId);
    return client.policy;
  }

  async unsubscribe(clientId: string): Promise<string | null> {
    const client = this.#client(clientId);
    const radioId = client.radioId;
    if (client.boundTransmitToken !== null) {
      await this.#stopBoundTransmit(client.boundTransmitToken, "media_unsubscribed");
    }
    client.radioId = null;
    client.radioSlot = null;
    client.lastUplinkSequence = null;
    client.spectrumCapability = { ...unavailableSpectrumCapability };
    client.lastSpectrumSentAtUs = null;
    if (radioId !== null) {
      this.#updateWorkerPolicy(radioId);
    }
    return radioId;
  }

  registerTransmit(value: RegisteredTransmit): void {
    this.#assertOpen();
    if (this.#transmits.has(value.transmitToken)) {
      throw new Error("transmit token is already registered");
    }
    validateDeadline(value.heartbeatDeadlineMs, "heartbeatDeadlineMs");
    validateDeadline(value.hardDeadlineMs, "hardDeadlineMs");
    const transmit: TransmitBinding = {
      ...value,
      boundClientId: null,
      bindTimer: null,
      pendingStop: null,
    };
    if (value.mode === "voice") {
      const remaining = Math.max(1, value.heartbeatDeadlineMs - this.#now());
      transmit.bindTimer = setTimeout(() => {
        void this.#stopBoundTransmit(value.transmitToken, "uplink_bind_timeout")
          .catch(() => undefined);
      }, Math.min(this.#uplinkBindTimeoutMs, remaining));
      transmit.bindTimer.unref();
    }
    this.#transmits.set(value.transmitToken, transmit);
  }

  hasReadySubscription(principalId: string, userId: string, radioId: string): boolean {
    return this.#workers.has(radioId) && [...this.#clients.values()].some((client) =>
      client.principalId === principalId &&
      client.userId === userId &&
      client.radioId === radioId,
    );
  }

  async openDigitalAudio(
    radioId: string,
    consumer: DigitalAudioConsumer,
  ): Promise<DigitalAudioPort> {
    this.#assertOpen();
    const config = this.#radios();
    const radioSlot = config.radios.findIndex((radio) => radio.id === radioId);
    if (radioSlot < 0 || radioSlot > 255) {
      throw new Error("radio does not exist or has no media slot");
    }
    const entry = await this.#worker(config.radios[radioSlot], radioSlot);
    const playback = entry.worker.digitalAudio;
    if (playback === undefined) {
      throw new Error("shared PCM audio is unavailable for this radio");
    }
    const id = this.#nextDigitalAudioSubscriptionId++;
    const subscription: DigitalAudioSubscription = {
      id,
      consumer,
      faulted: false,
      closed: false,
    };
    let subscriptions = this.#digitalAudioSubscriptions.get(radioId);
    if (subscriptions === undefined) {
      subscriptions = new Map();
      this.#digitalAudioSubscriptions.set(radioId, subscriptions);
    }
    subscriptions.set(id, subscription);

    const assertUsable = (): void => {
      if (subscription.closed) {
        throw new Error("digital audio port is closed");
      }
      if (subscription.faulted || this.#workers.get(radioId)?.worker !== entry.worker) {
        throw new Error("digital audio port is unavailable");
      }
    };
    const stop = async (): Promise<void> => {
      if (this.#digitalPlaybackOwners.get(radioId) !== id) {
        return;
      }
      this.#digitalPlaybackOwners.delete(radioId);
      await playback.stop();
    };
    return {
      sampleRate: playback.sampleRate,
      play: async (pcm, sampleRate, signal) => {
        assertUsable();
        const owner = this.#digitalPlaybackOwners.get(radioId);
        if (owner !== undefined && owner !== id) {
          throw new Error("digital audio playback is already active");
        }
        this.#digitalPlaybackOwners.set(radioId, id);
        try {
          await playback.play(pcm, sampleRate, signal);
        } finally {
          if (this.#digitalPlaybackOwners.get(radioId) === id) {
            this.#digitalPlaybackOwners.delete(radioId);
          }
        }
      },
      stop,
      close: async () => {
        if (subscription.closed) {
          return;
        }
        subscription.closed = true;
        await stop().catch(() => undefined);
        const active = this.#digitalAudioSubscriptions.get(radioId);
        active?.delete(id);
        if (active?.size === 0) {
          this.#digitalAudioSubscriptions.delete(radioId);
        }
      },
    };
  }

  refreshTransmit(
    transmitToken: string,
    heartbeatDeadlineMs: number,
    hardDeadlineMs?: number,
  ): void {
    const transmit = this.#transmits.get(transmitToken);
    if (transmit === undefined) {
      return;
    }
    validateDeadline(heartbeatDeadlineMs, "heartbeatDeadlineMs");
    transmit.heartbeatDeadlineMs = heartbeatDeadlineMs;
    if (hardDeadlineMs !== undefined) {
      validateDeadline(hardDeadlineMs, "hardDeadlineMs");
      transmit.hardDeadlineMs = hardDeadlineMs;
    }
  }

  async bindUplink(
    clientId: string,
    radioId: string,
    transmitToken: string,
  ): Promise<{ radioId: string; transmitToken: string }> {
    const client = this.#client(clientId);
    if (client.radioId !== radioId || client.radioSlot === null) {
      throw new Error("matching media subscription is required before uplink binding");
    }
    const transmit = this.#transmits.get(transmitToken);
    if (transmit === undefined || transmit.radioId !== radioId || transmit.mode !== "voice") {
      throw new Error("active voice transmit token is invalid");
    }
    if (transmit.pendingStop !== null) {
      throw new Error("voice transmit token is already stopping");
    }
    if (transmit.principalId !== client.principalId || transmit.userId !== client.userId) {
      throw new Error("voice transmit and media must use the same authenticated principal");
    }
    if (this.#expired(transmit)) {
      await this.#stopBoundTransmit(transmitToken, "transmit_expired");
      throw new Error("voice transmit token has expired");
    }
    if (transmit.boundClientId !== null && transmit.boundClientId !== clientId) {
      throw new Error("voice transmit token is already bound to another media connection");
    }
    if (client.boundTransmitToken !== null && client.boundTransmitToken !== transmitToken) {
      throw new Error("media connection already has a microphone uplink binding");
    }
    transmit.boundClientId = clientId;
    if (transmit.bindTimer !== null) {
      clearTimeout(transmit.bindTimer);
      transmit.bindTimer = null;
    }
    client.boundTransmitToken = transmitToken;
    client.lastUplinkSequence = null;
    return { radioId, transmitToken };
  }

  receiveUplink(clientId: string, frame: MediaFrame): boolean {
    const client = this.#client(clientId);
    if (frame.kind !== MediaKind.audioUplink) {
      throw new Error("client may send only audio uplink frames");
    }
    if (client.radioSlot === null || frame.radioSlot !== client.radioSlot) {
      throw new Error("media frame does not match an active subscription");
    }
    if (frame.payload.length < 1 || frame.payload.length > MAX_OPUS_PACKET_BYTES) {
      throw new Error(`Opus uplink payload must be 1..${MAX_OPUS_PACKET_BYTES} bytes`);
    }
    const token = client.boundTransmitToken;
    const transmit = token === null ? undefined : this.#transmits.get(token);
    if (transmit?.pendingStop !== null && transmit?.pendingStop !== undefined) {
      throw new Error("voice PTT stop is pending; microphone uplink is disabled");
    }
    if (
      token === null ||
      transmit === undefined ||
      transmit.boundClientId !== clientId ||
      transmit.radioId !== client.radioId ||
      transmit.mode !== "voice"
    ) {
      throw new Error("voice PTT must bind an audio uplink before microphone frames");
    }
    if (this.#expired(transmit)) {
      void this.#stopBoundTransmit(token, "transmit_expired")
        .catch(() => undefined);
      throw new Error("voice transmit token has expired");
    }
    if (
      client.lastUplinkSequence !== null &&
      !isNewerSequence(frame.sequence, client.lastUplinkSequence)
    ) {
      throw new Error("audio uplink sequence is duplicated or out of order");
    }
    const worker = this.#workers.get(transmit.radioId)?.worker;
    if (worker === undefined) {
      void this.#stopBoundTransmit(token, "media_worker_failed")
        .catch(() => undefined);
      throw new Error("media worker is unavailable");
    }
    client.lastUplinkSequence = frame.sequence;
    try {
      return worker.writeAudioUplink(frame);
    } catch (error) {
      void this.#stopBoundTransmit(token, "audio_uplink_failed")
        .catch(() => undefined);
      throw error;
    }
  }

  endTransmit(transmitToken: string): void {
    const transmit = this.#transmits.get(transmitToken);
    if (transmit === undefined) {
      return;
    }
    this.#transmits.delete(transmitToken);
    if (transmit.bindTimer !== null) {
      clearTimeout(transmit.bindTimer);
    }
    if (transmit.boundClientId !== null) {
      const client = this.#clients.get(transmit.boundClientId);
      if (client?.boundTransmitToken === transmitToken) {
        client.boundTransmitToken = null;
        client.lastUplinkSequence = null;
        client.transport.sendJson({
          t: "media.uplink.ended",
          radioId: transmit.radioId,
          transmitToken,
          reason: "transmit_ended",
        });
      }
    }
  }

  async revokeOwner(ownerId: string): Promise<void> {
    const active = [...this.#transmits.values()].filter(
      (transmit) => transmit.ownerId === ownerId && transmit.mode === "voice",
    );
    await Promise.all(active.map((transmit) =>
      this.#stopBoundTransmit(transmit.transmitToken, "control_owner_revoked")
        .then(() => undefined)
    ));
  }

  /** Remove voice bindings only after an upstream runtime confirmed physical PTT OFF. */
  ownerStoppedWithProof(ownerId: string): void {
    for (const transmit of [...this.#transmits.values()]) {
      if (transmit.ownerId === ownerId && transmit.mode === "voice") {
        try {
          this.endTransmit(transmit.transmitToken);
        } catch {
          // The upstream physical OFF proof remains authoritative if the old
          // media socket cannot receive its local binding cleanup notice.
        }
      }
    }
  }

  async disconnect(clientId: string): Promise<void> {
    const client = this.#clients.get(clientId);
    if (client === undefined) {
      return;
    }
    const radioId = client.radioId;
    try {
      if (client.boundTransmitToken !== null) {
        await this.#stopBoundTransmit(client.boundTransmitToken, "media_disconnected");
      }
    } finally {
      this.#clients.delete(clientId);
      if (radioId !== null) {
        this.#updateWorkerPolicy(radioId);
      }
    }
  }

  statistics(clientId: string): { droppedFrames: number } {
    return { droppedFrames: this.#client(clientId).droppedFrames };
  }

  async invalidate(radioId: string): Promise<void> {
    this.#assertOpen();
    const starting = this.#startingWorkers.get(radioId);
    if (starting !== undefined) {
      await starting.catch(() => undefined);
    }
    this.#startingWorkers.delete(radioId);

    const active = [...this.#transmits.values()].filter(
      (transmit) => transmit.radioId === radioId && transmit.mode === "voice",
    );
    await Promise.all(active.map(async (transmit) => {
      await this.#stopBoundTransmit(
        transmit.transmitToken,
        "media_configuration_changed",
      ).catch(() => undefined);
    }));

    const error = new Error("radio media configuration changed");
    this.#digitalPlaybackOwners.delete(radioId);
    const digitalSubscriptions = this.#digitalAudioSubscriptions.get(radioId);
    this.#digitalAudioSubscriptions.delete(radioId);
    if (digitalSubscriptions !== undefined) {
      for (const subscription of digitalSubscriptions.values()) {
        if (subscription.closed || subscription.faulted) {
          continue;
        }
        subscription.faulted = true;
        try {
          subscription.consumer.fault(error);
        } catch {
          // Configuration invalidation remains authoritative if a consumer fails.
        }
      }
    }

    for (const client of this.#subscribers(radioId)) {
      client.radioId = null;
      client.radioSlot = null;
      client.boundTransmitToken = null;
      client.lastUplinkSequence = null;
      client.spectrumCapability = { ...unavailableSpectrumCapability };
      client.lastSpectrumSentAtUs = null;
      try {
        client.transport.sendJson({
          t: "media.error",
          code: "media_configuration_changed",
          message: error.message,
          reconnectRequired: true,
        });
      } catch {
        // The server-side subscription is already invalidated. A failed
        // notification must not keep the old worker or rig runtime alive.
      }
    }

    const worker = this.#workers.get(radioId);
    this.#workers.delete(radioId);
    await worker?.worker.close().catch(() => undefined);
  }

  async close(): Promise<void> {
    if (this.#closed) {
      return;
    }
    this.#closed = true;
    await Promise.all([...this.#clients.keys()].map((clientId) => this.disconnect(clientId)));
    const workers = [...this.#workers.values()].map((entry) => entry.worker);
    this.#workers.clear();
    await Promise.all(workers.map((worker) => worker.close().catch(() => undefined)));
  }

  async #worker(profile: RadioProfile, radioSlot: number): Promise<WorkerEntry> {
    const ready = this.#workers.get(profile.id);
    if (ready !== undefined) {
      return ready;
    }
    const starting = this.#startingWorkers.get(profile.id);
    if (starting !== undefined) {
      return starting;
    }
    const output: MediaWorkerOutput = {
      audioDownlink: (payload, timestampUs, flags) => {
        this.#broadcastAudio(profile.id, radioSlot, payload, timestampUs, flags);
      },
      spectrum: (value, timestampUs, flags) => {
        this.#broadcastSpectrum(profile.id, radioSlot, value, timestampUs, flags);
      },
      pcmCapture: (value) => {
        this.#broadcastPcmCapture(profile.id, value);
      },
      fault: (error) => { void this.#workerFault(profile.id, error); },
    };
    const promise = this.#workerFactory(profile, radioSlot, output).then((worker) => {
      const entry: WorkerEntry = {
        radioId: profile.id,
        radioSlot,
        worker,
        audioSequence: 0,
        spectrumSequence: 0,
      };
      this.#workers.set(profile.id, entry);
      this.#startingWorkers.delete(profile.id);
      return entry;
    }, (error) => {
      this.#startingWorkers.delete(profile.id);
      throw error;
    });
    this.#startingWorkers.set(profile.id, promise);
    return promise;
  }

  #broadcastAudio(
    radioId: string,
    radioSlot: number,
    payload: Uint8Array,
    timestampUs = this.#timestampUs(),
    flags = 0,
  ): void {
    const worker = this.#workers.get(radioId);
    if (worker === undefined || payload.byteLength < 1 || payload.byteLength > MAX_OPUS_PACKET_BYTES) {
      return;
    }
    const frame = encodeMediaFrame({
      kind: MediaKind.audioDownlink,
      flags,
      radioSlot,
      sequence: worker.audioSequence,
      timestampUs,
      payload: Buffer.from(payload.buffer, payload.byteOffset, payload.byteLength),
    });
    worker.audioSequence = nextSequence(worker.audioSequence);
    for (const client of this.#subscribers(radioId)) {
      this.#sendOrDrop(client, frame);
    }
  }

  #broadcastSpectrum(
    radioId: string,
    radioSlot: number,
    value: SpectrumPayload,
    timestampUs = this.#timestampUs(),
    flags = 0,
  ): void {
    const worker = this.#workers.get(radioId);
    if (worker === undefined) {
      return;
    }
    const sequence = worker.spectrumSequence;
    worker.spectrumSequence = nextSequence(sequence);
    for (const client of this.#subscribers(radioId)) {
      if (client.policy.spectrumBins === 0) {
        continue;
      }
      if (!spectrumFrameIsDue(client, timestampUs)) {
        continue;
      }
      client.lastSpectrumSentAtUs = timestampUs;
      const bins = resampleBins(value.bins, client.policy.spectrumBins);
      const payload = encodeSpectrumPayload({ ...value, bins });
      const frame = encodeMediaFrame({
        kind: MediaKind.spectrum,
        flags,
        radioSlot,
        sequence,
        timestampUs,
        payload,
      });
      this.#sendOrDrop(client, frame);
    }
  }

  #broadcastPcmCapture(radioId: string, value: PcmCaptureChunk): void {
    const subscriptions = this.#digitalAudioSubscriptions.get(radioId);
    if (subscriptions === undefined || value.pcm.length === 0) {
      return;
    }
    for (const subscription of subscriptions.values()) {
      if (subscription.closed || subscription.faulted) {
        continue;
      }
      try {
        subscription.consumer.pcm(value);
      } catch (error) {
        subscription.faulted = true;
        try {
          subscription.consumer.fault(error);
        } catch {
          // A digital consumer failure must not interrupt radio audio capture.
        }
      }
    }
  }

  #sendOrDrop(client: MediaClient, frame: Buffer): void {
    if (client.transport.bufferedAmount > this.#maxBufferedBytes) {
      client.droppedFrames += 1;
      return;
    }
    client.transport.sendBinary(frame);
  }

  #subscribers(radioId: string): MediaClient[] {
    return [...this.#clients.values()].filter((client) => client.radioId === radioId);
  }

  #updateWorkerPolicy(radioId: string): void {
    const worker = this.#workers.get(radioId)?.worker;
    if (worker === undefined) {
      return;
    }
    const clients = this.#subscribers(radioId);
    if (clients.length === 0) {
      return;
    }
    const audioPolicy = clients.reduce((selected, client) =>
      tierRank(client.policy.tier) > tierRank(selected.tier) ? client.policy : selected,
    clients[0].policy);
    const policy: MediaPolicy = {
      ...audioPolicy,
      spectrumBins: clients.reduce<number>(
        (maximum, client) => Math.max(maximum, client.policy.spectrumBins),
        0,
      ) as MediaPolicy["spectrumBins"],
      spectrumFps: clients.reduce<number>(
        (maximum, client) => Math.max(maximum, client.policy.spectrumFps),
        0,
      ) as MediaPolicy["spectrumFps"],
    };
    try {
      const result = worker.updatePolicy(policy);
      if (result !== undefined) {
        void result.catch((error) => this.#workerFault(radioId, error));
      }
    } catch (error) {
      void this.#workerFault(radioId, error);
    }
  }

  async #workerFault(radioId: string, error: unknown): Promise<void> {
    const worker = this.#workers.get(radioId);
    this.#workers.delete(radioId);
    this.#digitalPlaybackOwners.delete(radioId);
    const digitalSubscriptions = this.#digitalAudioSubscriptions.get(radioId);
    if (digitalSubscriptions !== undefined) {
      for (const subscription of digitalSubscriptions.values()) {
        if (subscription.closed || subscription.faulted) {
          continue;
        }
        subscription.faulted = true;
        try {
          subscription.consumer.fault(error);
        } catch {
          // The media fault remains authoritative even if a consumer also fails.
        }
      }
    }
    for (const client of this.#subscribers(radioId)) {
      const spectrum: SpectrumCapability = {
        ...unavailableSpectrumCapability,
        reason: "media_worker_failed",
      };
      client.spectrumCapability = spectrum;
      client.policy = { ...client.policy, spectrumBins: 0, spectrumFps: 0 };
      client.lastSpectrumSentAtUs = null;
      client.transport.sendJson({
        t: "media.error",
        code: "media_worker_failed",
        message: error instanceof Error ? error.message : "media worker failed",
        reconnectRequired: true,
        spectrum,
        policy: client.policy,
      });
    }
    const active = [...this.#transmits.values()].filter(
      (transmit) => transmit.radioId === radioId && transmit.mode === "voice",
    );
    await Promise.all(active.map(async (transmit) => {
      await this.#stopBoundTransmit(transmit.transmitToken, "media_worker_failed")
        .catch(() => undefined);
    }));
    await worker?.worker.close().catch(() => undefined);
  }

  #notifyStopFailure(radioId: string, failure: unknown): void {
    for (const client of this.#subscribers(radioId)) {
      try {
        client.transport.sendJson({
          t: "media.error",
          code: "ptt_stop_failed",
          message: dekeyFailureMessage(failure),
        });
      } catch {
        // Hardware recovery remains authoritative if a disconnected client
        // cannot receive the advisory notification.
      }
    }
  }

  async #stopBoundTransmit(
    transmitToken: string,
    reason: StopVoiceTransmitRequest["reason"],
  ): Promise<DeKeyOutcome | undefined> {
    const transmit = this.#transmits.get(transmitToken);
    if (transmit === undefined) {
      return;
    }
    if (transmit.pendingStop !== null) {
      return transmit.pendingStop;
    }
    if (transmit.bindTimer !== null) {
      clearTimeout(transmit.bindTimer);
      transmit.bindTimer = null;
    }

    const pending = Promise.resolve().then(async (): Promise<DeKeyOutcome> => {
      try {
        const outcome = await this.#stopVoiceTransmit({
          radioId: transmit.radioId,
          ownerId: transmit.ownerId,
          transmitToken,
          reason,
        });
        if (outcome.kind !== "offConfirmed") {
          this.#notifyStopFailure(transmit.radioId, outcome);
        }
        return outcome;
      } catch (error) {
        this.#notifyStopFailure(transmit.radioId, error);
        throw error;
      } finally {
        if (this.#transmits.get(transmitToken) === transmit) {
          this.#transmits.delete(transmitToken);
          if (transmit.boundClientId !== null) {
            const client = this.#clients.get(transmit.boundClientId);
            if (client?.boundTransmitToken === transmitToken) {
              client.boundTransmitToken = null;
              client.lastUplinkSequence = null;
            }
          }
        }
      }
    });
    transmit.pendingStop = pending;
    return pending;
  }

  #expired(transmit: TransmitBinding): boolean {
    const now = this.#now();
    return now >= transmit.heartbeatDeadlineMs || now >= transmit.hardDeadlineMs;
  }

  #client(clientId: string): MediaClient {
    const client = this.#clients.get(clientId);
    if (client === undefined) {
      throw new Error("media client is not connected");
    }
    return client;
  }

  #timestampUs(): bigint {
    return BigInt(Math.max(0, Math.trunc(this.#now()))) * 1_000n;
  }

  #assertOpen(): void {
    if (this.#closed) {
      throw new Error("media hub is closed");
    }
  }
}

function validateDeadline(value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${field} must be a non-negative safe integer`);
  }
}

function dekeyFailureMessage(failure: unknown): string {
  if (failure instanceof Error) {
    return failure.message;
  }
  if (failure === undefined) {
    return "runtime returned no physical PTT OFF confirmation";
  }
  if (
    typeof failure === "object" &&
    failure !== null &&
    "kind" in failure &&
    "generation" in failure
  ) {
    const outcome = failure as DeKeyOutcome;
    if (outcome.kind === "recoveryPending") {
      return `physical PTT OFF recovery remains pending (generation ${outcome.generation})`;
    }
    if (outcome.kind === "notResponsible") {
      return `stop caller was not responsible for PTT state (generation ${outcome.generation})`;
    }
  }
  return "failed to confirm physical PTT OFF";
}

function positiveInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${field} must be a positive integer`);
  }
  return value;
}

function isNewerSequence(value: number, previous: number): boolean {
  const difference = (value - previous) >>> 0;
  return difference > 0 && difference < 0x8000_0000;
}

function nextSequence(value: number): number {
  return value === 0xffff_ffff ? 0 : value + 1;
}

function tierRank(tier: MediaPolicy["tier"]): number {
  return tier === "normal" ? 0 : tier === "constrained" ? 1 : 2;
}

function normalizeSpectrumCapability(
  value: SpectrumCapability | undefined,
): SpectrumCapability {
  if (value === undefined || !value.available) {
    return {
      ...unavailableSpectrumCapability,
      reason: value?.reason ?? unavailableSpectrumCapability.reason,
    };
  }
  return { ...value };
}

function applySpectrumCapability(
  policy: MediaPolicy,
  capability: SpectrumCapability,
): MediaPolicy {
  if (!capability.available || policy.spectrumBins === 0 || policy.spectrumFps === 0) {
    return { ...policy, spectrumBins: 0, spectrumFps: 0 };
  }
  return {
    ...policy,
    spectrumBins: Math.min(policy.spectrumBins, capability.maxBins) as MediaPolicy["spectrumBins"],
    spectrumFps: Math.min(policy.spectrumFps, capability.maxFps) as MediaPolicy["spectrumFps"],
  };
}

function spectrumFrameIsDue(client: MediaClient, timestampUs: bigint): boolean {
  const fps = client.policy.spectrumFps;
  if (fps === 0) {
    return false;
  }
  const previous = client.lastSpectrumSentAtUs;
  if (previous === null || timestampUs < previous) {
    return true;
  }
  const minimumIntervalUs = 1_000_000n / BigInt(fps);
  return timestampUs - previous >= minimumIntervalUs;
}

function resampleBins(source: Uint8Array, targetLength: number): Uint8Array {
  if (source.length === targetLength) {
    return source;
  }
  const target = new Uint8Array(targetLength);
  for (let index = 0; index < targetLength; index += 1) {
    const start = Math.floor(index * source.length / targetLength);
    const end = Math.max(start + 1, Math.floor((index + 1) * source.length / targetLength));
    let peak = 0;
    for (let sourceIndex = start; sourceIndex < Math.min(end, source.length); sourceIndex += 1) {
      peak = Math.max(peak, source[sourceIndex]);
    }
    target[index] = peak;
  }
  return target;
}
