import SwiftUI

struct RadioLiteRigControlsView: View {
    @EnvironmentObject private var session: RadioLiteSession

    let isTransmitting: Bool
    let hasControl: Bool

    var body: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Hamlib 控件", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RadioPalette.accent)
                    .disabled(session.selectedRadioId == nil)
                    .accessibilityLabel("刷新 Hamlib 控件")
                }

                if generalControls.isEmpty {
                    ContentUnavailableView(
                        "没有可调控件",
                        systemImage: "dial.low",
                        description: Text("当前电台未报告其他可安全读写的 Hamlib 控件，可点右上角重新读取。")
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
                            Divider().overlay(Color.white.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    private var generalControls: [RadioLiteRigControl] {
        RadioLiteTunerInteractionPolicy.generalControls(in: session.rigControls)
    }

    private func refresh() async {
        do {
            try await session.refreshRigControls()
        } catch {
            session.errorMessage = "读取 Hamlib 控件失败：\(error.localizedDescription)"
        }
    }
}

private struct RadioLiteRigControlRow: View {
    @EnvironmentObject private var session: RadioLiteSession

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
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Text(display.formattedValue(draftValue))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(RadioPalette.cyan)
            }

            controlEditor

            if let reason = disabledReason {
                Label(reason, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
        }
        .onChange(of: control.value) { _, confirmedValue in
            guard !isAdjusting, !isSubmitting else { return }
            draftValue = confirmedValue
        }
    }

    @ViewBuilder
    private var controlEditor: some View {
        switch display.kind {
        case .function:
            Toggle(isOn: functionBinding) {
                Text(draftValue >= 0.5 ? "开启" : "关闭")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
            .tint(RadioPalette.accent)
            .disabled(!canWrite)
        case .level, .filter:
            Slider(
                value: sliderBinding,
                in: sliderBounds,
                step: sliderStep,
                onEditingChanged: { editing in
                    isAdjusting = editing
                    if !editing { submit(draftValue) }
                }
            )
            .tint(display.kind == .filter ? RadioPalette.cyan : RadioPalette.accent)
            .disabled(!canWrite || !hasUsableSliderRange)
        case .unknown:
            Text("当前 App 版本尚不支持这种 Hamlib 控件类型")
                .font(.caption)
                .foregroundStyle(RadioPalette.muted)
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
