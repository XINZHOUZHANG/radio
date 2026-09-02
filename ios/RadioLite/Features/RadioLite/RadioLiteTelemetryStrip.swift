import Foundation
import SwiftUI

struct RadioLiteTelemetryStrip: View {
    let telemetry: RadioLiteTelemetry?
    let isTransmitting: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if isTransmitting {
                    let nowMs = milliseconds(context.date)
                    let power = transmitPower(nowMs: nowMs)
                    HStack(spacing: 10) {
                        meter(
                            title: "PWR",
                            value: power?.value,
                            range: power?.range ?? 0...1,
                            suffix: power?.suffix ?? ""
                        )
                        meter(
                            title: "SWR",
                            value: transmitValue(
                                \.swr,
                                supported: telemetry?.supportsMeter("SWR") == true,
                                nowMs: nowMs
                            ),
                            range: 1...3,
                            suffix: ""
                        )
                        meter(
                            title: "ALC",
                            value: transmitValue(
                                \.alcRatio,
                                supported: telemetry?.supportsMeter("ALC") == true,
                                nowMs: nowMs
                            ),
                            range: 0...1,
                            suffix: ""
                        )
                    }
                } else {
                    meter(
                        title: "S",
                        value: receiveStrength(nowMs: milliseconds(context.date)),
                        range: -54...60,
                        suffix: " dB",
                        labels: "S0                         S9              S9+60"
                    )
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .frame(height: 52)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isTransmitting ? "发射遥测" : "接收信号强度")
    }

    private func receiveStrength(nowMs: UInt64) -> Double? {
        guard let telemetry,
              !telemetry.isStale(nowMs: nowMs, periodMs: 2_000),
              telemetry.supportsMeter("STRENGTH") else { return nil }
        return telemetry.meters.strengthDbRelativeS9
    }

    private func transmitValue(
        _ keyPath: KeyPath<RadioLiteMeterSample, Double?>,
        supported: Bool,
        nowMs: UInt64
    ) -> Double? {
        guard supported, let telemetry else { return nil }
        guard !telemetry.isStale(nowMs: nowMs, periodMs: 1_000) else { return nil }
        return telemetry.meters[keyPath: keyPath]
    }

    private func transmitPower(
        nowMs: UInt64
    ) -> (value: Double, range: ClosedRange<Double>, suffix: String)? {
        guard let telemetry,
              telemetry.hasActualPowerMeter,
              !telemetry.isStale(nowMs: nowMs, periodMs: 1_000) else { return nil }
        if let watts = telemetry.meters.rfPowerWatts {
            return (watts, 0...100, " W")
        }
        if let ratio = telemetry.meters.rfPowerRatio {
            return (ratio, 0...1, "%")
        }
        return nil
    }

    private func meter(
        title: String,
        value: Double?,
        range: ClosedRange<Double>,
        suffix: String,
        labels: String? = nil
    ) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(RadioPalette.muted)
                Spacer(minLength: 2)
                Text(formatted(value, title: title, suffix: suffix))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(value == nil ? RadioPalette.muted : meterTint)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    if let value {
                        Capsule()
                            .fill(meterTint)
                            .frame(width: geometry.size.width * normalized(value, in: range))
                    }
                }
            }
            .frame(height: 7)
            if let labels {
                Text(labels)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(RadioPalette.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var meterTint: Color {
        isTransmitting ? RadioPalette.transmit : RadioPalette.accent
    }

    private func formatted(_ value: Double?, title: String, suffix: String) -> String {
        guard let value, value.isFinite else { return "—" }
        if title == "PWR", suffix == "%" { return String(format: "%.0f%%", value * 100) }
        if title == "PWR" { return String(format: "%.1f%@", value, suffix) }
        if title == "SWR" { return String(format: "%.2f:1", value) }
        if title == "ALC" { return String(format: "%.0f%%", value * 100) }
        return String(format: "%+.0f%@", value, suffix)
    }

    private func normalized(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    private func milliseconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 * 1_000))
    }
}
