import SwiftUI
import UIKit

/// View-local editing state. Every adjustment still uses the existing confirmed
/// session command; no CAT, protocol, or transmit policy is implemented here.
struct RadioLiteFrequencyControls: View {
    @EnvironmentObject private var session: RadioLiteSession
    @Environment(\.scenePhase) private var scenePhase
    @Binding var isEditing: Bool
    @State private var stepHz: Int64 = 100
    @State private var selectedDigit = 5
    @State private var dragStartHz: Int64?
    @State private var dragUnitHz: Int64 = 1
    @State private var dragUnits = 0
    @GestureState private var draggingDigit = false
    @State private var desiredHz: Int64?
    @State private var pendingHz: Int64?
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var showEntry = false
    @State private var entryMHz = ""
    @FocusState private var entryFocused: Bool

    private let steps: [(hz: Int64, label: String)] = [
        (10, "10 Hz"), (100, "100 Hz"), (1_000, "1 kHz"), (10_000, "10 kHz"),
    ]
    // These are receive-frequency shortcuts, not a mode or transmit preset.
    private let bands: [(label: String, hz: Int64, range: ClosedRange<Int64>)] = [
        ("160", 1_840_000, 1_800_000...2_000_000),
        ("80", 3_573_000, 3_500_000...4_000_000),
        ("40", 7_074_000, 7_000_000...7_300_000),
        ("30", 10_136_000, 10_100_000...10_150_000),
        ("20", 14_074_000, 14_000_000...14_350_000),
        ("17", 18_100_000, 18_068_000...18_168_000),
        ("15", 21_074_000, 21_000_000...21_450_000),
        ("12", 24_915_000, 24_890_000...24_990_000),
        ("10", 28_074_000, 28_000_000...29_700_000),
    ]

    var body: some View {
        VStack(spacing: 8) {
            frequencyDigits
            adjustmentRow
            bandRow
        }
        .sheet(isPresented: $showEntry) { frequencyEntry }
        .onChange(of: draggingDigit) { _, dragging in
            if !dragging { finishDigitDrag() }
        }
        .onChange(of: canAdjust) { _, allowed in
            if !allowed { cancelEdits() }
        }
        .onChange(of: session.selectedRadioId) { _, _ in cancelEdits() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelEdits() }
        }
        .onDisappear { cancelEdits() }
    }

    private var frequencyDigits: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Spacer(minLength: 0)
            ForEach(Array(displayMHz.enumerated()), id: \.offset) { index, character in
                if character == "." {
                    Text(".").font(TX.data(32, .semibold)).foregroundStyle(TX.text3)
                } else {
                    Text(String(character))
                        .font(TX.data(32, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(selectedDigit == index ? TX.teal : TX.text1)
                        .frame(minWidth: 18, minHeight: TX.hitMin)
                        .background(alignment: .bottom) {
                            if selectedDigit == index {
                                Capsule().fill(TX.teal).frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedDigit = index }
                        .onLongPressGesture(minimumDuration: 0.5) { openEntry() }
                        .simultaneousGesture(digitDrag(index: index))
                        .accessibilityLabel("频率数字 \(character)")
                        .accessibilityHint("上下拖动调整这一位，长按输入完整频率")
                        .accessibilityAdjustableAction { direction in
                            guard canAdjust else { return }
                            switch direction {
                            case .increment: adjust(by: digitValue(at: index))
                            case .decrement: adjust(by: -digitValue(at: index))
                            @unknown default: break
                            }
                        }
                }
            }
            Text("MHz")
                .font(TX.ui(11, .semibold))
                .foregroundStyle(TX.text3)
                .padding(.leading, 5)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("电台频率 \(displayMHz) MHz")
    }

    private var adjustmentRow: some View {
        HStack(spacing: 4) {
            repeatButton(symbol: "minus", direction: -1)
            ForEach(steps, id: \.hz) { step in
                Button { stepHz = step.hz } label: {
                    Text(step.label)
                        .font(TX.data(10.5, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(stepHz == step.hz ? TX.teal : TX.text2)
                        .frame(maxWidth: .infinity, minHeight: TX.hitMin)
                        .background(
                            stepHz == step.hz ? TX.teal.opacity(0.12) : TX.raised,
                            in: RoundedRectangle(cornerRadius: TX.chipRadius)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("步进 \(step.label)")
                .accessibilityAddTraits(stepHz == step.hz ? .isSelected : [])
            }
            repeatButton(symbol: "plus", direction: 1)
        }
        .frame(height: TX.hitMin)
    }

    private func repeatButton(symbol: String, direction: Int64) -> some View {
        RadioLiteFrequencyRepeatButton(
            symbol: symbol,
            enabled: canAdjust,
            action: { adjust(by: direction * stepHz) },
            onRepeatEnded: { pendingHz = nil }
        )
        .frame(width: 46, height: TX.hitMin)
    }

    private var bandRow: some View {
        HStack(spacing: 3) {
            ForEach(bands, id: \.label) { band in
                let selected = displayHz.map { band.range.contains($0) } ?? false
                Button { queueFrequency(band.hz) } label: {
                    Text(band.label)
                        .font(TX.data(11, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? TX.teal : TX.text2)
                        .frame(maxWidth: .infinity, minHeight: TX.hitMin)
                        .background(
                            selected ? TX.teal.opacity(0.12) : TX.raised,
                            in: RoundedRectangle(cornerRadius: TX.chipRadius)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAdjust)
                .accessibilityLabel("\(band.label) 米波段")
            }
        }
        .accessibilityLabel("波段")
    }

    private var frequencyEntry: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("输入频率（MHz）").font(TX.ui(16, .semibold)).foregroundStyle(TX.text1)
                TextField("14.074000", text: $entryMHz)
                    .font(TX.data(30))
                    .foregroundStyle(TX.text1)
                    .keyboardType(.decimalPad)
                    .focused($entryFocused)
                    .padding(12)
                    .background(TX.raised, in: RoundedRectangle(cornerRadius: TX.chipRadius))
                Text("最终频率以电台读回为准。")
                    .font(TX.ui(12)).foregroundStyle(TX.text3)
                Spacer(minLength: 0)
            }
            .padding(TX.pagePad)
            .background(TX.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showEntry = false }
                        .font(TX.ui(15)).tint(TX.text2)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("设定") {
                        let value = entryMHz
                        showEntry = false
                        Task { await session.setFrequency(mhzText: value) }
                    }
                    .font(TX.ui(15, .semibold)).tint(TX.teal)
                    .disabled(!canAdjust)
                }
            }
            .onAppear { entryFocused = true }
        }
        .presentationDetents([.height(270)])
    }

    private var canAdjust: Bool {
        guard let hz = session.rigState?.frequencyHz,
              (100_000...9_000_000_000).contains(hz) else { return false }
        return session.hasControl && session.control.state == .ready
            && !session.isVoicePTTHeld && !session.isTuning && session.rigState?.ptt != true
    }

    private var displayHz: Int64? { desiredHz ?? session.rigState?.frequencyHz }
    private var displayMHz: String {
        guard let hz = displayHz else { return "—.——————" }
        return String(format: "%.6f", Double(hz) / 1_000_000)
    }

    private func digitValue(at index: Int) -> Int64 {
        let trailingDigits = displayMHz.dropFirst(index + 1).filter(\.isNumber).count
        return Int64(pow(10.0, Double(trailingDigits)))
    }

    private func digitDrag(index: Int) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($draggingDigit) { value, state, _ in
                if abs(value.translation.height) > abs(value.translation.width) { state = true }
            }
            .onChanged { value in
                guard canAdjust,
                      let currentHz = displayHz,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                if dragStartHz == nil {
                    dragStartHz = currentHz
                    dragUnitHz = digitValue(at: index)
                    dragUnits = 0
                    selectedDigit = index
                    isEditing = true
                }
                let units = Int(-value.translation.height / 18)
                guard units != dragUnits, let dragStartHz else { return }
                dragUnits = units
                queueFrequency(dragStartHz + Int64(units) * dragUnitHz)
            }
            .onEnded { _ in finishDigitDrag() }
    }

    private func finishDigitDrag() {
        dragStartHz = nil
        dragUnits = 0
        isEditing = false
        pendingHz = nil
    }

    private func openEntry() {
        guard canAdjust, dragStartHz == nil else { return }
        entryMHz = displayMHz
        showEntry = true
    }

    private func adjust(by delta: Int64) {
        guard let hz = displayHz else { return }
        queueFrequency(hz + delta)
    }

    private func queueFrequency(_ hz: Int64) {
        guard canAdjust, (100_000...9_000_000_000).contains(hz) else { return }
        desiredHz = hz
        pendingHz = hz
        guard requestTask == nil else { return }
        let id = UUID()
        requestID = id
        requestTask = Task { @MainActor in
            // Coalesce edits behind one in-flight command so a slow link cannot
            // accumulate a burst of frequency writes after the finger lifts.
            while !Task.isCancelled, canAdjust, let next = pendingHz {
                pendingHz = nil
                await session.setFrequency(hz: next)
            }
            guard requestID == id else { return }
            requestTask = nil
            requestID = nil
            desiredHz = nil
        }
    }

    private func cancelEdits() {
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        pendingHz = nil
        desiredHz = nil
        showEntry = false
        finishDigitDrag()
    }
}

private struct RadioLiteFrequencyRepeatButton: View {
    @Environment(\.scenePhase) private var scenePhase
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    let onRepeatEnded: () -> Void

    var body: some View {
        ZStack {
            Image(systemName: symbol)
                .font(TX.ui(18, .semibold))
                .foregroundStyle(enabled ? TX.teal : TX.text3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            RadioLiteFrequencyPressSurface(
                symbol: symbol,
                enabled: enabled && scenePhase == .active,
                action: action,
                onRepeatEnded: onRepeatEnded
            )
        }
        .background(TX.raised, in: RoundedRectangle(cornerRadius: TX.chipRadius))
        .overlay { RoundedRectangle(cornerRadius: TX.chipRadius).strokeBorder(TX.stroke) }
    }
}

/// Native touch events distinguish a completed tap from cancellation without
/// depending on SwiftUI GestureState reset ordering. This is only a UI control.
private struct RadioLiteFrequencyPressSurface: UIViewRepresentable {
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    let onRepeatEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FrequencyButton {
        let button = FrequencyButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchUpInside), for: .touchUpInside)
        button.addTarget(context.coordinator, action: #selector(Coordinator.cancelTouch), for: [.touchUpOutside, .touchCancel, .touchDragExit])
        button.accessibilityLabel = symbol == "plus" ? "增加频率" : "降低频率"
        button.accessibilityHint = "长按半秒后每秒调整八步"
        let coordinator = context.coordinator
        button.activate = { [weak coordinator] in coordinator?.activateAccessibleButton() ?? false }
        return button
    }

    func updateUIView(_ button: FrequencyButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
        if !enabled { context.coordinator.cancelTouch() }
    }

    static func dismantleUIView(_ button: FrequencyButton, coordinator: Coordinator) {
        coordinator.cancelTouch()
        button.activate = nil
    }

    final class FrequencyButton: UIButton {
        var activate: (() -> Bool)?
        override func accessibilityActivate() -> Bool { activate?() ?? false }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: RadioLiteFrequencyPressSurface
        private var pressing = false
        private var didRepeat = false
        private var repeatTask: Task<Void, Never>?

        init(_ parent: RadioLiteFrequencyPressSurface) { self.parent = parent }

        @objc func touchDown() {
            cancelTouch()
            guard parent.enabled else { return }
            pressing = true
            repeatTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    while !Task.isCancelled, self.parent.enabled, self.pressing {
                        self.didRepeat = true
                        self.parent.action()
                        try await Task.sleep(for: .milliseconds(125))
                    }
                } catch { /* A release/cancellation ends the repeating gesture. */ }
            }
        }

        @objc func touchUpInside() {
            let shouldTap = pressing && !didRepeat && parent.enabled
            cancelTouch()
            if shouldTap { parent.action() }
        }

        @objc func cancelTouch() {
            repeatTask?.cancel()
            repeatTask = nil
            pressing = false
            if didRepeat { parent.onRepeatEnded() }
            didRepeat = false
        }

        func activateAccessibleButton() -> Bool {
            guard parent.enabled else { return false }
            parent.action()
            return true
        }
    }
}
