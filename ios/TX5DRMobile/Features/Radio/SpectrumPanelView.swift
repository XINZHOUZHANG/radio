import SwiftUI

struct SpectrumPanelView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var showsRangeSettings = false
    @State private var automaticRange = true
    @State private var manualMinDB = -120.0
    @State private var manualMaxDB = 0.0
    @State private var localZoom = 1.0
    @State private var localCenter = 0.5

    var body: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 10) {
                header

                VStack(spacing: 0) {
                    SpectrumTraceCanvas(
                        bins: displayedBins,
                        range: effectiveDBRange,
                        markerRatio: radioFrequencyMarkerRatio
                    )
                    .frame(height: 92)

                    Divider()
                        .overlay(Color.white.opacity(0.09))

                    SpectrumWaterfallCanvas(
                        rows: radio.spectrumHistory,
                        range: effectiveDBRange,
                        zoom: localZoom,
                        center: localCenter,
                        markerRatio: radioFrequencyMarkerRatio
                    )
                    .frame(height: 132)
                }
                .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07))
                }
                .overlay {
                    if radio.spectrumBins.isEmpty {
                        VStack(spacing: 7) {
                            ProgressView()
                                .tint(RadioPalette.accent)
                            Text(waitingText)
                                .font(.caption)
                                .foregroundStyle(RadioPalette.muted)
                        }
                    }
                }

                frequencyAxis
                sessionControls
                presetMarkers
            }
        }
        .sheet(isPresented: $showsRangeSettings) {
            rangeSettings
        }
        .onAppear { resetDisplayForSource(radio.selectedSpectrumKind) }
        .onChange(of: radio.selectedSpectrumKind) { _, kind in
            resetDisplayForSource(kind)
        }
        .onChange(of: radio.spectrumRange) { _, _ in
            localCenter = 0.5
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    radio.selectAutomaticSpectrumSource()
                } label: {
                    if radio.spectrumSelectionIsAutomatic {
                        Label("自动选择", systemImage: "checkmark")
                    } else {
                        Text("自动选择")
                    }
                }

                if let capabilities = radio.spectrumCapabilities {
                    Divider()
                    ForEach(capabilities.sources, id: \.kind) { source in
                        Button {
                            radio.selectSpectrumSource(source.kind)
                        } label: {
                            if !radio.spectrumSelectionIsAutomatic && radio.selectedSpectrumKind == source.kind {
                                Label(source.kind.label, systemImage: "checkmark")
                            } else {
                                Text(source.available ? source.kind.label : "\(source.kind.label)（不可用）")
                            }
                        }
                        .disabled(!source.available)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: sourceIcon)
                    Text(radio.selectedSpectrumKind?.label ?? "频谱源")
                    if radio.spectrumSelectionIsAutomatic {
                        Text("AUTO")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(RadioPalette.accent)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(RadioPalette.muted)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 11)
                .frame(minHeight: 38)
                .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
            }

            Button {
                showsRangeSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 36, height: 36)
                    .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("频谱显示设置")
        }
    }

    private var frequencyAxis: some View {
        HStack {
            Text(formatFrequency(visibleFrequencyRange?.min))
            Spacer()
            if localZoom > 1 {
                Text(String(format: "本地 ×%.0f", localZoom))
                    .foregroundStyle(RadioPalette.accent)
            } else {
                Text(formatFrequency(visibleCenterFrequency))
            }
            Spacer()
            Text(formatFrequency(visibleFrequencyRange?.max))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(RadioPalette.muted)
    }

    @ViewBuilder
    private var sessionControls: some View {
        let controls = radio.spectrumSessionState?.controls.filter(\.visible) ?? []
        if !controls.isEmpty {
            HStack(spacing: 7) {
                ForEach(controls, id: \.key) { control in
                    Button {
                        perform(control)
                    } label: {
                        controlLabel(control)
                            .frame(minWidth: 32, minHeight: 32)
                            .padding(.horizontal, control.action == .toggle ? 5 : 0)
                            .background(
                                control.active ? RadioPalette.accent.opacity(0.22) : RadioPalette.panelRaised,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!control.enabled || control.pending || localControlDisabled(control))
                    .opacity(control.enabled && !localControlDisabled(control) ? 1 : 0.38)
                }

                Spacer()

                Button {
                    radio.clearSpectrumHistory()
                } label: {
                    Label("清除", systemImage: "trash")
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 32)
                        .padding(.horizontal, 8)
                        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(radio.spectrumHistory.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var presetMarkers: some View {
        let markers = radio.spectrumSessionState?.interaction.presetMarkers.filter(\.clickable) ?? []
        if !markers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(markers) { marker in
                        Button {
                            Task {
                                await session.setFrequency(
                                    mhzText: String(format: "%.6f", marker.frequency / 1_000_000)
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(marker.label)
                                    .font(.caption.weight(.semibold))
                                Text(formatFrequency(marker.frequency))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(RadioPalette.muted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var rangeSettings: some View {
        NavigationStack {
            Form {
                Section("动态范围") {
                    Toggle("自动范围", isOn: $automaticRange)
                    if !automaticRange {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("下限")
                                Spacer()
                                Text(String(format: "%.0f dB", manualMinDB))
                                    .monospacedDigit()
                            }
                            Slider(
                                value: $manualMinDB,
                                in: rangeLimits.lowerBound...min(rangeLimits.upperBound - 1, manualMaxDB - 1),
                                step: 1
                            )
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("上限")
                                Spacer()
                                Text(String(format: "%.0f dB", manualMaxDB))
                                    .monospacedDigit()
                            }
                            Slider(
                                value: $manualMaxDB,
                                in: max(rangeLimits.lowerBound + 1, manualMinDB + 1)...rangeLimits.upperBound,
                                step: 1
                            )
                        }
                    }
                }

                Section("数据") {
                    LabeledContent("当前来源", value: radio.subscribedSpectrumKind?.label ?? "未订阅")
                    LabeledContent("频谱点数", value: "\(radio.spectrumBins.count)")
                    LabeledContent("瀑布历史", value: "\(radio.spectrumHistory.count) / 120")
                    Button("清除瀑布历史", role: .destructive) {
                        radio.clearSpectrumHistory()
                    }
                }
            }
            .navigationTitle("频谱显示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsRangeSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var displayedBins: [Double] {
        SpectrumViewport.crop(radio.spectrumBins, zoom: localZoom, center: localCenter)
    }

    private var effectiveDBRange: ClosedRange<Double> {
        guard automaticRange else { return manualMinDB...manualMaxDB }
        let values = displayedBins.filter(\.isFinite).sorted()
        guard values.count > 1 else { return defaultDBRange }
        let low = values[Int(Double(values.count - 1) * 0.08)]
        let high = values[Int(Double(values.count - 1) * 0.985)]
        let span = max(1, high - low)
        return (low - span * 0.16)...(high + span * 0.08)
    }

    private var defaultDBRange: ClosedRange<Double> {
        switch radio.selectedSpectrumKind {
        case .radioSDR: 0...64
        case .openWebRXSDR: -120...0
        case .audio, .none: -120...0
        }
    }

    private var rangeLimits: ClosedRange<Double> {
        switch radio.selectedSpectrumKind {
        case .radioSDR: -64...255
        case .openWebRXSDR: -140...20
        case .audio, .none: -120...40
        }
    }

    private var visibleFrequencyRange: SpectrumFrame.FrequencyRange? {
        guard let fullRange = radio.spectrumRange else { return nil }
        return SpectrumViewport.crop(fullRange, zoom: localZoom, center: localCenter)
    }

    private var visibleCenterFrequency: Double? {
        guard let visibleFrequencyRange else { return nil }
        return (visibleFrequencyRange.min + visibleFrequencyRange.max) / 2
    }

    private var radioFrequencyMarkerRatio: Double? {
        guard let range = visibleFrequencyRange,
              range.max > range.min,
              let frequency = radio.spectrumSessionState?.currentRadioFrequency,
              frequency >= range.min,
              frequency <= range.max else { return nil }
        return (frequency - range.min) / (range.max - range.min)
    }

    private var sourceIcon: String {
        switch radio.selectedSpectrumKind {
        case .audio: "waveform"
        case .radioSDR: "radio"
        case .openWebRXSDR: "antenna.radiowaves.left.and.right"
        case nil: "chart.xyaxis.line"
        }
    }

    private var subscriptionPending: Bool {
        radio.requestedSpectrumKind != nil && radio.requestedSpectrumKind != radio.subscribedSpectrumKind
    }

    private var statusColor: Color {
        if radio.spectrumSubscription?.ok == false { return RadioPalette.transmit }
        if subscriptionPending { return RadioPalette.warning }
        return radio.spectrumBins.isEmpty ? RadioPalette.muted : RadioPalette.accent
    }

    private var statusText: String {
        if subscriptionPending { return "切换中" }
        if radio.spectrumSubscription?.ok == false { return "不可用" }
        if radio.spectrumBins.isEmpty { return "等待数据" }
        return "\(radio.spectrumBins.count) bins"
    }

    private var waitingText: String {
        if radio.spectrumCapabilities == nil { return "等待频谱能力" }
        if radio.selectedSpectrumKind == nil { return "没有可用频谱源" }
        return "等待 \(radio.selectedSpectrumKind?.label ?? "频谱") 数据"
    }

    private func resetDisplayForSource(_ kind: SpectrumKind?) {
        let range: ClosedRange<Double>
        switch kind {
        case .radioSDR: range = 0...64
        case .openWebRXSDR: range = -120...0
        case .audio, .none: range = -120...0
        }
        manualMinDB = range.lowerBound
        manualMaxDB = range.upperBound
        automaticRange = kind == .audio
        localZoom = 1
        localCenter = 0.5
    }

    private func perform(_ control: SpectrumSessionControl) {
        if control.kind == .server {
            radio.invokeSpectrumControl(id: control.id, action: control.action)
            return
        }
        guard control.id == .viewportZoom else { return }
        switch control.action {
        case .zoomIn: localZoom = min(16, localZoom * 2)
        case .zoomOut: localZoom = max(1, localZoom / 2)
        case .toggle: break
        }
    }

    private func localControlDisabled(_ control: SpectrumSessionControl) -> Bool {
        guard control.kind == .local, control.id == .viewportZoom else { return false }
        switch control.action {
        case .zoomIn: localZoom >= 16
        case .zoomOut: localZoom <= 1
        case .toggle: false
        }
    }

    @ViewBuilder
    private func controlLabel(_ control: SpectrumSessionControl) -> some View {
        switch (control.id, control.action) {
        case (.zoomStep, .zoomIn), (.viewportZoom, .zoomIn):
            Image(systemName: "plus")
        case (.zoomStep, .zoomOut), (.viewportZoom, .zoomOut):
            Image(systemName: "minus")
        case (.digitalWindowToggle, _):
            Text(control.active ? "固定" : "跟随")
                .font(.caption.weight(.semibold))
        case (.openWebRXDetailToggle, _):
            Text(control.active ? "细节" : "全景")
                .font(.caption.weight(.semibold))
        default:
            Image(systemName: "arrow.triangle.2.circlepath")
        }
    }

    private func formatFrequency(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if abs(value) >= 1_000_000 { return String(format: "%.6f MHz", value / 1_000_000) }
        if abs(value) >= 1_000 { return String(format: "%.3f kHz", value / 1_000) }
        return String(format: "%.0f Hz", value)
    }
}

private struct SpectrumTraceCanvas: View {
    let bins: [Double]
    let range: ClosedRange<Double>
    let markerRatio: Double?

    var body: some View {
        Canvas(opaque: true, colorMode: .linear, rendersAsynchronously: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.88)))
            for index in 1..<5 {
                let y = size.height * CGFloat(index) / 5
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(Color.white.opacity(0.07)), lineWidth: 0.7)
            }

            let values = SpectrumViewport.downsamplePeaks(bins, count: max(2, Int(size.width)))
            guard values.count > 1 else { return }
            let span = max(0.001, range.upperBound - range.lowerBound)
            var line = Path()
            var fill = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) / CGFloat(values.count - 1) * size.width
                let normalized = min(1, max(0, (value - range.lowerBound) / span))
                let y = size.height - CGFloat(normalized) * (size.height - 6) - 3
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
                Gradient(colors: [RadioPalette.accent.opacity(0.34), RadioPalette.cyan.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .linearGradient(
                Gradient(colors: [RadioPalette.cyan, RadioPalette.accent]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            ), lineWidth: 1.4)

            drawMarker(context: &context, size: size)
        }
    }

    private func drawMarker(context: inout GraphicsContext, size: CGSize) {
        guard let markerRatio else { return }
        let x = CGFloat(markerRatio) * size.width
        var marker = Path()
        marker.move(to: CGPoint(x: x, y: 0))
        marker.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(marker, with: .color(RadioPalette.transmit.opacity(0.9)), lineWidth: 1)
    }
}

private struct SpectrumWaterfallCanvas: View {
    let rows: [SpectrumWaterfallRow]
    let range: ClosedRange<Double>
    let zoom: Double
    let center: Double
    let markerRatio: Double?

    var body: some View {
        Canvas(opaque: true, colorMode: .linear, rendersAsynchronously: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            guard !rows.isEmpty else { return }

            let renderedRows = rows.suffix(120).reversed()
            let rowHeight = max(1, size.height / 120)
            let targetColumns = max(2, Int(size.width.rounded(.up)))
            for (rowIndex, row) in renderedRows.enumerated() {
                let visible = SpectrumViewport.crop(row.bins, zoom: zoom, center: center)
                let values = SpectrumViewport.downsamplePeaks(visible, count: targetColumns)
                guard !values.isEmpty else { continue }
                let columnWidth = size.width / CGFloat(values.count)
                let y = CGFloat(rowIndex) * rowHeight
                if y >= size.height { break }
                for (columnIndex, value) in values.enumerated() {
                    let normalized = (value - range.lowerBound) / max(0.001, range.upperBound - range.lowerBound)
                    let rect = CGRect(
                        x: CGFloat(columnIndex) * columnWidth,
                        y: y,
                        width: columnWidth + 0.35,
                        height: rowHeight + 0.35
                    )
                    context.fill(Path(rect), with: .color(SpectrumColorMap.color(normalized)))
                }
            }

            if let markerRatio {
                let x = CGFloat(markerRatio) * size.width
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(marker, with: .color(Color.white.opacity(0.42)), lineWidth: 0.7)
            }
        }
    }
}

enum SpectrumViewport {
    static func crop(_ bins: [Double], zoom: Double, center: Double) -> [Double] {
        guard bins.count > 1, zoom > 1 else { return bins }
        let visibleCount = max(2, min(bins.count, Int((Double(bins.count) / zoom).rounded())))
        let centerIndex = Int((Double(bins.count - 1) * min(1, max(0, center))).rounded())
        let start = min(max(0, centerIndex - visibleCount / 2), bins.count - visibleCount)
        return Array(bins[start..<(start + visibleCount)])
    }

    static func crop(
        _ range: SpectrumFrame.FrequencyRange,
        zoom: Double,
        center: Double
    ) -> SpectrumFrame.FrequencyRange {
        guard zoom > 1, range.max > range.min else { return range }
        let fullSpan = range.max - range.min
        let visibleSpan = fullSpan / zoom
        let requestedCenter = range.min + fullSpan * min(1, max(0, center))
        let lower = min(max(range.min, requestedCenter - visibleSpan / 2), range.max - visibleSpan)
        return SpectrumFrame.FrequencyRange(min: lower, max: lower + visibleSpan)
    }

    static func downsamplePeaks(_ values: [Double], count: Int) -> [Double] {
        guard count > 0, values.count > count else { return values }
        return (0..<count).map { outputIndex in
            let start = outputIndex * values.count / count
            let end = max(start + 1, (outputIndex + 1) * values.count / count)
            return values[start..<min(end, values.count)].filter(\.isFinite).max() ?? 0
        }
    }
}

private enum SpectrumColorMap {
    static func color(_ rawValue: Double) -> Color {
        let value = min(1, max(0, rawValue.isFinite ? rawValue : 0))
        if value < 0.22 {
            return interpolate(from: (0.005, 0.01, 0.04), to: (0.02, 0.08, 0.36), amount: value / 0.22)
        }
        if value < 0.48 {
            return interpolate(from: (0.02, 0.08, 0.36), to: (0.0, 0.72, 0.95), amount: (value - 0.22) / 0.26)
        }
        if value < 0.72 {
            return interpolate(from: (0.0, 0.72, 0.95), to: (0.44, 0.94, 0.34), amount: (value - 0.48) / 0.24)
        }
        if value < 0.9 {
            return interpolate(from: (0.44, 0.94, 0.34), to: (1.0, 0.68, 0.04), amount: (value - 0.72) / 0.18)
        }
        return interpolate(from: (1.0, 0.68, 0.04), to: (1.0, 0.12, 0.08), amount: (value - 0.9) / 0.1)
    }

    private static func interpolate(
        from: (Double, Double, Double),
        to: (Double, Double, Double),
        amount: Double
    ) -> Color {
        let amount = min(1, max(0, amount))
        return Color(
            red: from.0 + (to.0 - from.0) * amount,
            green: from.1 + (to.1 - from.1) * amount,
            blue: from.2 + (to.2 - from.2) * amount
        )
    }
}
