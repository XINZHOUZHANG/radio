export type MediaQualityTier = "normal" | "constrained" | "severe";

export type MediaPolicy = {
  tier: MediaQualityTier;
  opusBitrate: number;
  opusFrameMs: 20;
  spectrumBins: 0 | 128 | 256 | 512;
  spectrumFps: 0 | 1 | 3 | 5;
};

export type NetworkReport = {
  rttMs: number;
  packetLossPercent: number;
  bufferedBytes: number;
  spectrumVisible: boolean;
};

const POLICIES: Record<MediaQualityTier, Omit<MediaPolicy, "tier">> = {
  normal: {
    opusBitrate: 20_000,
    opusFrameMs: 20,
    spectrumBins: 512,
    spectrumFps: 5,
  },
  constrained: {
    opusBitrate: 16_000,
    opusFrameMs: 20,
    spectrumBins: 256,
    spectrumFps: 3,
  },
  severe: {
    opusBitrate: 12_000,
    opusFrameMs: 20,
    spectrumBins: 128,
    spectrumFps: 1,
  },
};

export class AdaptiveMediaPolicy {
  #tier: MediaQualityTier = "normal";
  #goodReports = 0;

  update(report: NetworkReport): MediaPolicy {
    validateReport(report);
    const desired = desiredTier(report);
    if (tierRank(desired) > tierRank(this.#tier)) {
      this.#tier = desired;
      this.#goodReports = 0;
    } else if (tierRank(desired) < tierRank(this.#tier)) {
      this.#goodReports += 1;
      if (this.#goodReports >= 5) {
        this.#tier = desired;
        this.#goodReports = 0;
      }
    } else {
      this.#goodReports = 0;
    }
    return this.current(report.spectrumVisible);
  }

  current(spectrumVisible = true): MediaPolicy {
    const base = POLICIES[this.#tier];
    return {
      tier: this.#tier,
      ...base,
      spectrumBins: spectrumVisible ? base.spectrumBins : 0,
      spectrumFps: spectrumVisible ? base.spectrumFps : 0,
    };
  }
}

export function estimateMediaBytesPerHour(
  policy: MediaPolicy,
  duplexAudio = false,
): number {
  const audioDirections = duplexAudio ? 2 : 1;
  const packetsPerSecond = 1_000 / policy.opusFrameMs;
  const webSocketAndMediaOverheadBytes = 22;
  const audioBytesPerSecond = audioDirections * (
    policy.opusBitrate / 8 + packetsPerSecond * webSocketAndMediaOverheadBytes
  );
  const spectrumBytesPerSecond = policy.spectrumFps * (
    policy.spectrumBins === 0 ? 0 : policy.spectrumBins + 16 + 16 + 8
  );
  return Math.ceil((audioBytesPerSecond + spectrumBytesPerSecond) * 3_600);
}

function desiredTier(report: NetworkReport): MediaQualityTier {
  if (report.packetLossPercent >= 8 || report.rttMs >= 2_000 || report.bufferedBytes >= 512_000) {
    return "severe";
  }
  if (report.packetLossPercent >= 2 || report.rttMs >= 500 || report.bufferedBytes >= 128_000) {
    return "constrained";
  }
  return "normal";
}

function tierRank(tier: MediaQualityTier): number {
  return tier === "normal" ? 0 : tier === "constrained" ? 1 : 2;
}

function validateReport(report: NetworkReport): void {
  for (const [field, value] of Object.entries(report)) {
    if (field === "spectrumVisible") {
      if (typeof value !== "boolean") throw new Error("spectrumVisible must be boolean");
    } else if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
      throw new Error(`${field} must be a non-negative finite number`);
    }
  }
}
