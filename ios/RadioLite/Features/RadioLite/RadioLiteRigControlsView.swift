import SwiftUI

struct RadioLiteRigControlsView: View {
    @EnvironmentObject private var session: RadioLiteSession
    @State private var showCompatibilityInfo = false

    let isTransmitting: Bool
    let hasControl: Bool

    var body: some View {
        if session.radioCapabilitiesAvailable {
            RadioLiteControlDashboardView(
                isTransmitting: isTransmitting,
                hasControl: hasControl
            )
        } else {
            legacyPanel
        }
    }

    private var legacyPanel: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 14) {
                header
                if generalControls.isEmpty {
                    ContentUnavailableView(
                        "兼容控制不可用",
                        systemImage: "dial.low",
                        description: Text("服务器尚未提供分组能力描述或兼容 Hamlib 控件。")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(generalControls) { control in
                        RadioLiteRigControlRow(
                            control: control,
                            isTransmitting: isTransmitting,
                            hasControl: hasControl
                        )
                        if control.id != generalControls.last?.id {
                            Divider().overlay(TX.divider)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("电台控制")
                .font(TX.ui(17, .semibold))
            Spacer()
            Button { showCompatibilityInfo = true } label: {
                Image(systemName: "info.circle")
                    .frame(width: TX.hitMin, height: TX.hitMin)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("兼容电台控制说明")
            .popover(isPresented: $showCompatibilityInfo) {
                Text("服务器未提供新版分组控制，当前使用兼容电台控制。可用参数以服务器实际返回为准。")
                    .font(TX.ui(14))
                    .foregroundStyle(TX.text2)
                    .padding(TX.pagePad)
                    .presentationCompactAdaptation(.popover)
            }
            Button {
                Task { await refreshLegacyControls() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(TX.teal)
            .disabled(session.selectedRadioId == nil)
            .accessibilityLabel("刷新兼容电台控制")
        }
    }

    private var generalControls: [RadioLiteRigControl] {
        let meterTokens = Set(["STRENGTH", "SWR", "ALC", "RFPOWER_METER", "RFPOWER_METER_WATTS"])
        return RadioLiteTunerInteractionPolicy.generalControls(in: session.rigControls)
            .filter { !meterTokens.contains($0.token.uppercased()) }
    }

    private func refreshLegacyControls() async {
        do {
            try await session.refreshRigControls()
        } catch {
            session.errorMessage = "读取兼容电台控制失败：\(error.localizedDescription)"
        }
    }
}

private struct RadioLiteRigControlRow: View {
    @EnvironmentObject private var session: RadioLiteSession
    @Environment(\.radioLiteSliderEditing) private var sliderEditing
    @State private var sliderID = UUID()

    let control: RadioLiteRigControl
    let isTransmitting: Bool
    let hasControl: Bool

    @State private var draftValue: Double
    @State private var isAdjusting = false
    @State private var isSubmitting = false

    init(control: RadioLiteRigControl, isTransmitting: Bool, hasControl: Bool) {
        self.control = control
        self.isTransmitting = isTransmitting
        self.hasControl = hasControl
        _draftValue = State(initialValue: control.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.label)
                    .font(TX.ui(15, .semibold))
                Spacer()
                if isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Text(display.formattedValue(draftValue))
                    .font(TX.data(12, .semibold))
                    .foregroundStyle(TX.teal)
            }

            controlEditor

            if let reason = disabledReason {
                Label(reason, systemImage: "lock.fill")
                    .font(TX.ui(12))
                    .foregroundStyle(TX.text3)
            }
        }
        .onChange(of: control.value) { _, confirmedValue in
            guard !isAdjusting, !isSubmitting else { return }
            draftValue = confirmedValue
        }
        .onDisappear { sliderEditing(sliderID, false) }
    }

    @ViewBuilder
    private var controlEditor: some View {
        switch display.kind {
        case .function:
            Toggle(isOn: functionBinding) {
                Text(draftValue >= 0.5 ? "开启" : "关闭")
                    .font(TX.ui(12))
                    .foregroundStyle(TX.text3)
            }
            .tint(TX.teal)
            .disabled(!canWrite)
        case .level, .filter:
            Slider(
                value: sliderBinding,
                in: sliderBounds,
                step: sliderStep,
                onEditingChanged: { editing in
                    isAdjusting = editing
                    sliderEditing(sliderID, editing)
                    if !editing { submit(draftValue) }
                }
            )
            .tint(display.kind == .filter ? TX.teal : TX.teal)
            .padding(.vertical, TX.pagePad)
            .disabled(!canWrite || !hasUsableSliderRange)
        case .unknown:
            Text("当前 App 版本尚不支持这种 Hamlib 控件类型")
                .font(TX.ui(12))
                .foregroundStyle(TX.text3)
        }
    }

    private var display: RadioLiteRigControlDisplayState {
        control.displayState(isTransmitting: isTransmitting)
    }

    private var canWrite: Bool {
        hasControl && display.writable && !isSubmitting
    }

    private var disabledReason: String? {
        if let lockedReason = display.lockedReason { return lockedReason }
        if !hasControl { return "需要先取得电台控制权" }
        if !hasUsableSliderRange, display.kind != .function { return "电台返回的调节范围无效" }
        return nil
    }

    private var hasUsableSliderRange: Bool {
        display.minimum.isFinite
            && display.maximum.isFinite
            && display.minimum < display.maximum
    }

    private var sliderBounds: ClosedRange<Double> {
        guard hasUsableSliderRange else { return 0...1 }
        return display.minimum...display.maximum
    }

    private var sliderStep: Double {
        let span = sliderBounds.upperBound - sliderBounds.lowerBound
        guard span.isFinite, span > 0 else { return 1 }
        guard display.step.isFinite, display.step > 0 else { return span / 100 }
        return min(display.step, span)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { min(sliderBounds.upperBound, max(sliderBounds.lowerBound, draftValue)) },
            set: { draftValue = $0 }
        )
    }

    private var functionBinding: Binding<Bool> {
        Binding(
            get: { draftValue >= 0.5 },
            set: { enabled in
                let nextValue = enabled ? 1.0 : 0.0
                draftValue = nextValue
                submit(nextValue)
            }
        )
    }

    private func submit(_ value: Double) {
        guard canWrite else {
            draftValue = control.value
            return
        }
        isSubmitting = true
        Task {
            let confirmed = await session.setRigControl(control.id, value: value)
            draftValue = confirmed?.value ?? control.value
            isSubmitting = false
        }
    }
}
