import Foundation
import SwiftUI
import UIKit

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
    let transmitAudioFrequencyHz: Int?

    @State private var isExpanded = false

    init(
        spectrum: RadioLiteSpectrumFrame?,
        capability: RadioLiteSpectrumCapability?,
        history: [[UInt8]],
        policy: RadioLiteMediaPolicy?,
        compact: Bool = false,
        selectedAudioFrequencyHz: Int? = nil,
        transmitAudioFrequencyHz: Int? = nil
    ) {
        self.spectrum = spectrum
        self.capability = capability
        self.history = history
        self.policy = policy
        self.compact = compact
        self.selectedAudioFrequencyHz = selectedAudioFrequencyHz
        self.transmitAudioFrequencyHz = transmitAudioFrequencyHz
    }

    @ViewBuilder
    var body: some View {
        if compact {
            spectrumContent
                .padding(10)
                .background(
                    TX.card,
                    in: RoundedRectangle(cornerRadius: TX.cardRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: TX.cardRadius, style: .continuous)
                        .strokeBorder(TX.divider)
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
                .font(TX.data(compact ? 10.5 : 12))
                .foregroundStyle(TX.text3)
            spectrumPlot
            frequencyAxisLabels

            if let selectedFrequencyRangeMessage {
                Label(selectedFrequencyRangeMessage, systemImage: "arrow.left.and.right")
                    .font(TX.ui(11, .semibold))
                    .foregroundStyle(TX.amber)
            }

            if let statusMessage {
                Label(statusMessage, systemImage: statusIcon)
                    .font(TX.ui(12))
                    .foregroundStyle(TX.text3)
                    .frame(maxWidth: .infinity)
            }

            if capability?.supportsWaterfall == true {
                waterfall
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(audioRangeTitle, systemImage: "waveform.path")
                .font(TX.ui(compact ? 13 : 15, .semibold))
                .foregroundStyle(TX.text1)
            Spacer(minLength: 4)
            sourceBadge
            if !compact {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(TX.ui(12, .bold))
                        .frame(width: 30, height: 30)
                        .background(
                            TX.raised,
                            in: RoundedRectangle(cornerRadius: TX.chipRadius, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(TX.teal)
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
            context.stroke(grid, with: .color(TX.stroke), lineWidth: 0.5)

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
                    Gradient(colors: [TX.teal.opacity(0.5), TX.teal.opacity(0.03)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
                context.stroke(line, with: .color(TX.teal), lineWidth: compact ? 1.1 : 1.4)
            }

            if let markerPosition = transmitMarker.normalizedPosition {
                let x = size.width * CGFloat(markerPosition)
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    marker,
                    with: .color(TX.amber),
                    style: StrokeStyle(lineWidth: compact ? 1.2 : 1.6, dash: [4, 3])
                )
            }
        }
        .frame(height: compact ? 58 : (isExpanded ? 145 : 80))
        .background(
            TX.bg,
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
        .font(TX.data(10.5))
        .foregroundStyle(TX.text3)
    }

    private var waterfall: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if !compact {
                Text("瀑布图")
                    .font(TX.ui(12, .semibold))
                    .foregroundStyle(TX.text3)
            }
            Canvas { context, size in
                let rows = Array(history.reversed())
                let rowHeight = size.height / CGFloat(max(1, rows.count))
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
                // Both plots use the same audio axis and full canvas width.
                if let markerPosition = transmitMarker.normalizedPosition {
                    let x = size.width * CGFloat(markerPosition)
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: 0))
                    marker.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(
                        marker,
                        with: .color(TX.amber),
                        style: StrokeStyle(lineWidth: compact ? 1.2 : 1.6, dash: [4, 3])
                    )
                }
            }
            .frame(height: compact ? 64 : (isExpanded ? 112 : 82))
            .background(
                TX.bg,
                in: RoundedRectangle(cornerRadius: compact ? 8 : 11, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if capability?.available == false {
            sourceBadge("不可用", color: TX.amber)
        } else if capability?.simulated == true {
            sourceBadge("模拟数据", color: TX.amber)
        } else if capability == nil {
            sourceBadge("协商中", color: TX.text3)
        }
    }

    private func sourceBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(TX.ui(10.5, .bold))
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

    private var transmitMarker: RadioLiteSpectrumMarker {
        frequencyAxis.marker(for: transmitAudioFrequencyHz)
    }

    private var audioRangeTitle: String {
        guard displaySpanHz > 0 else { return "接收音频频谱" }
        return String(format: "音频 0–%.1f kHz", Double(displaySpanHz) / 1_000)
    }

    private var axisDescription: String {
        let points = spectrum?.bins.count ?? policy?.spectrumBins ?? 0
        guard let spectrum, spectrum.centerFrequencyHz > 0 else {
            return "\(points) 点\(transmitMarkerDescription)"
        }
        return String(
            format: "RX %.6f MHz · %d 点%@",
            Double(spectrum.centerFrequencyHz) / 1_000_000,
            points,
            transmitMarkerDescription
        )
    }

    private var transmitMarkerDescription: String {
        guard let transmitAudioFrequencyHz else { return "" }
        return " · TX \(transmitAudioFrequencyHz) Hz"
    }

    private var markerAccessibilityValue: String {
        guard let selectedAudioFrequencyHz else { return "\(audioRangeTitle)，\(axisDescription)" }
        if selectedMarker.outOfRangeFrequencyHz != nil {
            return "\(axisDescription)，已选 \(selectedAudioFrequencyHz) Hz，超出当前频谱范围"
        }
        return "\(axisDescription)，已选 \(selectedAudioFrequencyHz) Hz"
    }

    private var selectedFrequencyRangeMessage: String? {
        if let frequencyHz = transmitMarker.outOfRangeFrequencyHz {
            return "TX \(frequencyHz) Hz，超出 0–\(displaySpanHz) Hz 频谱范围"
        }
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
        Self.waterfallPalette[Int(value)]
    }

    // The media client has already AGC-normalized these 8-bit display values.
    // Do not apply a second AGC or infer a physical 30-second noise floor here.
    // Cache the seven-stop palette once instead of resolving colours per pixel.
    private static let waterfallPalette: [Color] = (0...255).map { value in
        let level = Double(value) / 255
        let stops = TX.waterfallStops
        let upperIndex = stops.firstIndex(where: { $0.0 >= level }) ?? (stops.count - 1)
        guard upperIndex > 0 else { return stops[0].1 }
        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let amount = (level - lower.0) / (upper.0 - lower.0)
        var lowerR: CGFloat = 0, lowerG: CGFloat = 0, lowerB: CGFloat = 0, lowerA: CGFloat = 0
        var upperR: CGFloat = 0, upperG: CGFloat = 0, upperB: CGFloat = 0, upperA: CGFloat = 0
        UIColor(lower.1).getRed(&lowerR, green: &lowerG, blue: &lowerB, alpha: &lowerA)
        UIColor(upper.1).getRed(&upperR, green: &upperG, blue: &upperB, alpha: &upperA)
        return Color(
            red: Double(lowerR) + Double(upperR - lowerR) * amount,
            green: Double(lowerG) + Double(upperG - lowerG) * amount,
            blue: Double(lowerB) + Double(upperB - lowerB) * amount
        )
    }
}
