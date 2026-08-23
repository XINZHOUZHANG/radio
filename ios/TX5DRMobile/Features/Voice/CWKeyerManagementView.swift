import SwiftUI

struct CWKeyerManagementView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket

    var body: some View {
        VStack(spacing: 14) {
            if let config = session.cwKeyerConfig {
                CWKeyerConfigCard(config: config)
                    .id("\(config.backend.rawValue)-\(config.wpm)-\(config.keyPort)")
            }
            RadioPanel {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if session.keyerCallsign == nil {
                        ContentUnavailableView(
                            "请选择操作员",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text("CW 报文槽按操作员呼号分别保存。")
                        )
                        .frame(minHeight: 180)
                    } else if let panel = session.cwMessagePanel {
                        Text("支持 {MYCALL}、{HISCALL}、{TRST}、{RRST} 占位符，发射时由当前操作上下文替换。")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.muted)
                        let slots = Array(panel.slots.prefix(panel.slotCount))
                        ForEach(Array(slots.enumerated()), id: \.element.id) { offset, slot in
                            CWMessageSlotCard(
                                slot: slot,
                                previousSlotId: offset > 0 ? slots[offset - 1].id : nil,
                                nextSlotId: offset + 1 < slots.count ? slots[offset + 1].id : nil,
                                activeSlotId: activeSlotId,
                                statusMode: statusMode
                            )
                            .id("\(slot.id)-\(slot.label)-\(slot.text)-\(slot.repeatEnabled)-\(slot.repeatIntervalSec)")
                        }
                    } else {
                        ProgressView("读取 CW 报文槽")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label("CW 预设报文", systemImage: "text.badge.checkmark")
                    .font(.headline)
                Text(session.keyerCallsign ?? "未选择呼号")
                    .font(.caption.monospaced())
                    .foregroundStyle(RadioPalette.muted)
            }
            Spacer()
            if let panel = session.cwMessagePanel {
                Button {
                    Task { await session.updateCWMessageSlotCount(panel.slotCount - 1) }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.muted))
                .disabled(panel.slotCount <= 3 || session.isWorking)

                Text("\(panel.slotCount)")
                    .font(.caption.monospacedDigit().weight(.bold))

                Button {
                    Task { await session.updateCWMessageSlotCount(panel.slotCount + 1) }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent))
                .disabled(panel.slotCount >= min(12, panel.maxSlotCount) || session.isWorking)
            }
        }
    }

    private var activeSlotId: String? { radio.cwKeyerStatus?["messageId"]?.stringValue }
    private var statusMode: String { radio.cwKeyerStatus?["mode"]?.stringValue ?? "idle" }
}

private struct CWKeyerConfigCard: View {
    @EnvironmentObject private var session: TX5DRSession
    let config: CWKeyerConfig
    @State private var backend: CWKeyerBackend
    @State private var wpm: Int

    init(config: CWKeyerConfig) {
        self.config = config
        _backend = State(initialValue: config.backend)
        _wpm = State(initialValue: config.wpm)
    }

    var body: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("CW 键控配置", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Picker("后端", selection: $backend) {
                    Text("CAT / Hamlib").tag(CWKeyerBackend.cat)
                    Text("串口 DTR/RTS").tag(CWKeyerBackend.serial)
                }
                .pickerStyle(.segmented)
                Stepper("速度 \(wpm) WPM", value: $wpm, in: 5...60)
                    .font(.subheadline.monospacedDigit())
                if backend == .serial {
                    LabeledContent("键控串口", value: config.keyPort.isEmpty ? "尚未配置" : config.keyPort)
                        .font(.caption)
                        .foregroundStyle(config.keyPort.isEmpty ? RadioPalette.warning : RadioPalette.muted)
                }
                Button("保存 CW 配置") {
                    Task { await session.updateCWKeyerConfig(backend: backend, wpm: wpm) }
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
                .disabled((backend == config.backend && wpm == config.wpm) || session.isWorking)
            }
        }
    }
}

private struct CWMessageSlotCard: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket

    let slot: CWMessageSlot
    let previousSlotId: String?
    let nextSlotId: String?
    let activeSlotId: String?
    let statusMode: String

    @State private var label: String
    @State private var text: String
    @State private var repeatEnabled: Bool
    @State private var repeatIntervalSec: Int
    @State private var confirmingClear = false

    init(
        slot: CWMessageSlot,
        previousSlotId: String?,
        nextSlotId: String?,
        activeSlotId: String?,
        statusMode: String
    ) {
        self.slot = slot
        self.previousSlotId = previousSlotId
        self.nextSlotId = nextSlotId
        self.activeSlotId = activeSlotId
        self.statusMode = statusMode
        _label = State(initialValue: slot.label)
        _text = State(initialValue: slot.text)
        _repeatEnabled = State(initialValue: slot.repeatEnabled)
        _repeatIntervalSec = State(initialValue: slot.repeatIntervalSec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("C\(slot.index)")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(isActive ? RadioPalette.transmit : RadioPalette.accent)
                TextField("标签", text: $label)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { move(to: previousSlotId) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.muted))
                    .disabled(previousSlotId == nil || isActive)
                Button { move(to: nextSlotId) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.muted))
                    .disabled(nextSlotId == nil || isActive)
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 68)
                .padding(8)
                .background(RadioPalette.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Button(isActive ? "停止" : "发射") {
                    if isActive { radio.stopCWMessage() }
                    else { session.playCWMessageSlot(slot) }
                }
                .buttonStyle(RadioActionButtonStyle(tint: isActive ? RadioPalette.transmit : RadioPalette.accent, prominent: isActive))
                .disabled(slot.text.isEmpty || (activeSlotId != nil && !isActive))

                Toggle("循环", isOn: $repeatEnabled)
                    .labelsHidden()
                Text("循环").font(.caption)
                Stepper("\(repeatIntervalSec) 秒", value: $repeatIntervalSec, in: 1...300)
                    .font(.caption.monospacedDigit())
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent))
                    .disabled(!hasChanges || session.isWorking || isActive)
                Button(role: .destructive) { confirmingClear = true } label: {
                    Image(systemName: "eraser")
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.transmit))
                .disabled(slot.text.isEmpty || isActive)
            }
        }
        .padding(12)
        .background(
            isActive ? RadioPalette.transmit.opacity(0.10) : RadioPalette.panelRaised,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? RadioPalette.transmit.opacity(0.5) : Color.white.opacity(0.06))
        }
        .confirmationDialog("清空 C\(slot.index) 报文？", isPresented: $confirmingClear) {
            Button("清空报文", role: .destructive) {
                Task { await session.clearCWMessageSlot(slot.id) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var isActive: Bool { activeSlotId == slot.id && statusMode != "idle" }
    private var hasChanges: Bool {
        label != slot.label || text != slot.text || repeatEnabled != slot.repeatEnabled
            || repeatIntervalSec != slot.repeatIntervalSec
    }

    private func save() {
        let cleanLabel = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        let cleanText = String(text.uppercased().prefix(500))
        Task {
            await session.updateCWMessageSlot(
                slot.id,
                update: CWMessageSlotUpdate(
                    label: cleanLabel,
                    text: cleanText,
                    repeatEnabled: repeatEnabled,
                    repeatIntervalSec: repeatIntervalSec
                )
            )
        }
    }

    private func move(to otherSlotId: String?) {
        guard let otherSlotId else { return }
        Task { await session.swapCWMessageSlots(slot.id, otherSlotId) }
    }
}
