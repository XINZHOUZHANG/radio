import Foundation
import SwiftUI

struct RadioLiteSpectrumAxisTick: Equatable, Identifiable, Sendable {
    let index: Int
    let frequencyHz: Int
    let normalizedPosition: Double

    var id: Int { index }
}

enum RadioLiteSpectrumMarker: Equatable, Sendable {
    case none
    case visible(frequencyHz: Int, normalizedPosition: Double)
    case belowRange(frequencyHz: Int)
    case aboveRange(frequencyHz: Int)

    var normalizedPosition: Double? {
        guard case let .visible(_, normalizedPosition) = self else { return nil }
        return normalizedPosition
    }

    var outOfRangeFrequencyHz: Int? {
        switch self {
        case let .belowRange(frequencyHz), let .aboveRange(frequencyHz): frequencyHz
        case .none, .visible: nil
        }
    }
}

struct RadioLiteSpectrumAxis: Equatable, Sendable {
    let spanHz: Int

    init(spanHz: Int) {
        self.spanHz = max(0, spanHz)
    }

    func marker(for audioFrequencyHz: Int?) -> RadioLiteSpectrumMarker {
        guard let audioFrequencyHz, spanHz > 0 else { return .none }
        if audioFrequencyHz < 0 {
            return .belowRange(frequencyHz: audioFrequencyHz)
        }
        if audioFrequencyHz > spanHz {
            return .aboveRange(frequencyHz: audioFrequencyHz)
        }
        return .visible(
            frequencyHz: audioFrequencyHz,
            normalizedPosition: Double(audioFrequencyHz) / Double(spanHz)
        )
    }

    var ticks: [RadioLiteSpectrumAxisTick] {
        guard spanHz > 0 else {
            return [RadioLiteSpectrumAxisTick(index: 0, frequencyHz: 0, normalizedPosition: 0)]
        }
        return (0...4).map { index in
            RadioLiteSpectrumAxisTick(
                index: index,
                frequencyHz: index * spanHz / 4,
                normalizedPosition: Double(index) / 4
            )
        }
    }
}

struct RadioLiteSpectrumView: View {
    let spectrum: RadioLiteSpectrumFrame?
    let capability: RadioLiteSpectrumCapability?
    let history: [[UInt8]]
    let policy: RadioLiteMediaPolicy?
    let compact: Bool
    let selectedAudioFrequencyHz: Int?

    @State private var isExpanded = false

    init(
        spectrum: RadioLiteSpectrumFrame?,
        capability: RadioLiteSpectrumCapability?,
        history: [[UInt8]],
        policy: RadioLiteMediaPolicy?,
        compact: Bool = false,
        selectedAudioFrequencyHz: Int? = nil
    ) {
        self.spectrum = spectrum
        self.capability = capability
        self.history = history
        self.policy = policy
        self.compact = compact
        self.selectedAudioFrequencyHz = selectedAudioFrequencyHz
    }

    @ViewBuilder
    var body: some View {
        if compact {
            spectrumContent
                .padding(10)
                .background(
                    RadioPalette.panel,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.055))
                }
        } else {
            RadioPanel {
                spectrumContent
            }
        }
    }

    private var spectrumContent: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 11) {
            header
            Text(axisDescription)
                .font((compact ? Font.caption2 : Font.caption).monospacedDigit())
                .foregroundStyle(RadioPalette.muted)
            spectrumPlot
            frequencyAxisLabels

            if let selectedFrequencyRangeMessage {
                Label(selectedFrequencyRangeMessage, systemImage: "arrow.left.and.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RadioPalette.warning)
            }

            if let statusMessage {
                Label(statusMessage, systemImage: statusIcon)
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
                    .frame(maxWidth: .infinity)
            }

            if capability?.supportsWaterfall == true {
                waterfall
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("实时频谱", systemImage: "waveform.path")
                .font(compact ? .subheadline.weight(.semibold) : .headline)
            Spacer(minLength: 4)
            sourceBadge
            if !compact {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(
                            RadioPalette.panelRaised,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(RadioPalette.cyan)
                .accessibilityLabel(isExpanded ? "收起频谱" : "展开频谱")
            }
        }
    }

    private var spectrumPlot: some View {
        Canvas { context, size in
            var grid = Path()
            for division in 1..<4 {
                let x = size.width * CGFloat(division) / 4
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                let y = size.height * CGFloat(division) / 4
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(Color.white.opacity(0.075)), lineWidth: 0.5)

            if let bins = spectrum?.bins, bins.count > 1 {
                let step = size.width / CGFloat(bins.count - 1)
                var line = Path()
                var fill = Path()
                for (index, value) in bins.enumerated() {
                    let x = CGFloat(index) * step
                    let y = size.height * (1 - CGFloat(value) / 255)
                    if index == 0 {
                        line.move(to: CGPoint(x: x, y: y))
                        fill.move(to: CGPoint(x: x, y: size.height))
                        fill.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        line.addLine(to: CGPoint(x: x, y: y))
                        fill.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [RadioPalette.cyan.opacity(0.5), RadioPalette.accent.opacity(0.02)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
                context.stroke(line, with: .color(RadioPalette.cyan), lineWidth: compact ? 1.1 : 1.4)
            }

            if let markerPosition = selectedMarker.normalizedPosition {
                let x = size.width * CGFloat(markerPosition)
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    marker,
                    with: .color(RadioPalette.warning.opacity(0.95)),
                    style: StrokeStyle(lineWidth: compact ? 1.2 : 1.6, dash: [4, 3])
                )
            }
        }
        .frame(height: compact ? 58 : (isExpanded ? 145 : 80))
        .background(
            RadioPalette.background.opacity(0.9),
            in: RoundedRectangle(cornerRadius: compact ? 9 : 13, style: .continuous)
        )
        .accessibilityLabel("接收音频频谱")
        .accessibilityValue(markerAccessibilityValue)
    }

    private var frequencyAxisLabels: some View {
        let ticks = frequencyAxis.ticks
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                ForEach(ticks) { tick in
                    Text(frequencyLabel(
                        tick.frequencyHz,
                        isLast: tick.index == ticks.count - 1
                    ))
                    .frame(
                        width: geometry.size.width,
                        alignment: tickAlignment(index: tick.index, count: ticks.count)
                    )
                    .offset(x: tickLabelOffset(tick, width: geometry.size.width, count: ticks.count))
                }
            }
        }
        .frame(height: 14)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(RadioPalette.muted)
    }

    private var waterfall: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if !compact {
                Text("瀑布图")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RadioPalette.muted)
            }
            Canvas { context, size in
                let rows = Array(history.reversed())
                guard !rows.isEmpty else { return }
                let rowHeight = size.height / CGFloat(rows.count)
                for (rowIndex, bins) in rows.enumerated() where !bins.isEmpty {
                    let columnWidth = size.width / CGFloat(bins.count)
                    for (column, level) in bins.enumerated() {
                        let rectangle = CGRect(
                            x: CGFloat(column) * columnWidth,
                            y: CGFloat(rowIndex) * rowHeight,
                            width: columnWidth + 0.5,
                            height: rowHeight + 0.5
                        )
                        context.fill(Path(rectangle), with: .color(waterfallColor(level)))
                    }
                }
            }
            .frame(height: compact ? 64 : (isExpanded ? 112 : 82))
            .background(
                RadioPalette.background,
                in: RoundedRectangle(cornerRadius: compact ? 8 : 11, style: .continuous)
            )
        }
    }

    private var sourceBadge: some View {
        let text: String
        let color: Color
        if capability?.available == false {
            text = "不可用"
            color = RadioPalette.warning
        } else if capability?.simulated == true {
            text = "模拟数据"
            color = RadioPalette.warning
        } else if capability?.available == true {
            text = "真实声卡 FFT"
            color = RadioPalette.accent
        } else {
            text = "协商中"
            color = RadioPalette.muted
        }
        return Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var displaySpanHz: UInt32 {
        spectrum?.spanHz ?? UInt32(max(0, capability?.spanHz ?? 0))
    }

    private var frequencyAxis: RadioLiteSpectrumAxis {
        RadioLiteSpectrumAxis(spanHz: Int(displaySpanHz))
    }

    private var selectedMarker: RadioLiteSpectrumMarker {
        frequencyAxis.marker(for: selectedAudioFrequencyHz)
    }

    private var axisDescription: String {
        let points = spectrum?.bins.count ?? policy?.spectrumBins ?? 0
        guard let spectrum, spectrum.centerFrequencyHz > 0 else {
            return "接收音频 0–\(displaySpanHz) Hz · \(points) 点"
        }
        return String(
            format: "RX %.6f MHz · 音频 0–%.1f kHz · %d 点",
            Double(spectrum.centerFrequencyHz) / 1_000_000,
            Double(displaySpanHz) / 1_000,
            points
        )
    }

    private var markerAccessibilityValue: String {
        guard let selectedAudioFrequencyHz else { return axisDescription }
        if selectedMarker.outOfRangeFrequencyHz != nil {
            return "\(axisDescription)，已选 \(selectedAudioFrequencyHz) Hz，超出当前频谱范围"
        }
        return "\(axisDescription)，已选 \(selectedAudioFrequencyHz) Hz"
    }

    private var selectedFrequencyRangeMessage: String? {
        guard let frequencyHz = selectedMarker.outOfRangeFrequencyHz else { return nil }
        return "已选 \(frequencyHz) Hz，超出 0–\(displaySpanHz) Hz 频谱范围"
    }

    private var statusMessage: String? {
        if capability?.available == false {
            return "服务端没有可用的频谱源，请检查接收音频输入设备"
        }
        if policy?.spectrumBins == 0 {
            return "弱网或后台策略已暂停频谱传输"
        }
        if spectrum == nil {
            return "等待接收声卡 FFT 数据…"
        }
        return nil
    }

    private var statusIcon: String {
        capability?.available == false ? "exclamationmark.triangle" : "hourglass"
    }

    private func frequencyLabel(_ frequencyHz: Int, isLast: Bool) -> String {
        let number: String
        if frequencyHz == 0 {
            number = "0"
        } else if frequencyHz.isMultiple(of: 1_000) {
            number = "\(frequencyHz / 1_000)"
        } else if frequencyHz.isMultiple(of: 500) {
            number = String(format: "%.1f", Double(frequencyHz) / 1_000)
        } else {
            number = String(format: "%.2f", Double(frequencyHz) / 1_000)
        }
        return isLast ? "\(number) kHz" : number
    }

    private func tickAlignment(index: Int, count: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == count - 1 { return .trailing }
        return .center
    }

    private func tickLabelOffset(
        _ tick: RadioLiteSpectrumAxisTick,
        width: CGFloat,
        count: Int
    ) -> CGFloat {
        guard tick.index > 0, tick.index < count - 1 else { return 0 }
        return width * CGFloat(tick.normalizedPosition - 0.5)
    }

    private func waterfallColor(_ value: UInt8) -> Color {
        let level = pow(Double(value) / 255, 0.62)
        if level < 0.22 {
            return interpolateColor(
                from: (0.035, 0.055, 0.075),
                to: (0.085, 0.115, 0.145),
                progress: level / 0.22
            )
        }
        if level < 0.58 {
            return interpolateColor(
                from: (0.085, 0.115, 0.145),
                to: (0.16, 0.82, 0.72),
                progress: (level - 0.22) / 0.36
            )
        }
        if level < 0.86 {
            return interpolateColor(
                from: (0.16, 0.82, 0.72),
                to: (1, 0.68, 0.18),
                progress: (level - 0.58) / 0.28
            )
        }
        return interpolateColor(
            from: (1, 0.68, 0.18),
            to: (1, 1, 1),
            progress: (level - 0.86) / 0.14
        )
    }

    private func interpolateColor(
        from lower: (Double, Double, Double),
        to upper: (Double, Double, Double),
        progress: Double
    ) -> Color {
        let amount = min(1, max(0, progress))
        return Color(
            red: lower.0 + (upper.0 - lower.0) * amount,
            green: lower.1 + (upper.1 - lower.1) * amount,
            blue: lower.2 + (upper.2 - lower.2) * amount
        )
    }
}
