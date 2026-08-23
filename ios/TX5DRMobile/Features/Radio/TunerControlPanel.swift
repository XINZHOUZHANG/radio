import SwiftUI

struct TunerControlState: Equatable {
    enum SWRQuality: Equatable {
        case good
        case caution
        case high
    }

    let hasCapabilitySnapshot: Bool
    let builtInSupported: Bool
    let switchSupported: Bool
    let tuneSupported: Bool
    let tunerEnabled: Bool
    let isTuning: Bool
    let status: String?
    let swr: Double?
    let lastError: String?
    let unavailableMessage: String?
    let canToggleSwitch: Bool
    let canStartManualTune: Bool
    let tuneToneActive: Bool
    let tuneToneBusy: Bool
    let tuneToneElapsedSeconds: Int
    let tuneToneRemainingSeconds: Int
    let tuneToneError: String?
    let canToggleTuneTone: Bool

    init(
        switchState: CapabilityState?,
        tuneState: CapabilityState?,
        ptt: PTTStatus,
        tuneTone: TuneToneStatus,
        socketReady: Bool,
        nowMilliseconds: Double
    ) {
        let switchAvailable = Self.isAvailable(switchState)
        let tuneAvailable = Self.isAvailable(tuneState)
        let status = switchState?.meta?["status"]?.stringValue
        let elapsedMilliseconds = tuneTone.startedAt.map { max(0, nowMilliseconds - $0) } ?? 0

        hasCapabilitySnapshot = switchState != nil || tuneState != nil
        switchSupported = switchState?.supported == true
        tuneSupported = tuneState?.supported == true
        builtInSupported = switchSupported || tuneSupported
        tunerEnabled = switchState?.value?.boolValue == true
        isTuning = status == "tuning"
        self.status = status
        swr = switchState?.meta?["swr"]?.doubleValue
        lastError = Self.firstNonempty(switchState?.lastError, tuneState?.lastError)
        unavailableMessage = Self.unavailableMessage(
            switchState: switchState,
            tuneState: tuneState
        )
        canToggleSwitch = socketReady && switchSupported && switchAvailable
        canStartManualTune = socketReady
            && switchSupported
            && tuneSupported
            && switchAvailable
            && tuneAvailable
            && tunerEnabled
            && !isTuning
        tuneToneActive = tuneTone.active
        tuneToneBusy = ptt.isTransmitting && !tuneTone.active
        tuneToneElapsedSeconds = tuneTone.active ? Int(elapsedMilliseconds / 1_000) : 0
        tuneToneRemainingSeconds = tuneTone.active
            ? max(0, Int(ceil((tuneTone.maxDurationMs - elapsedMilliseconds) / 1_000)))
            : Int(ceil(tuneTone.maxDurationMs / 1_000))
        tuneToneError = Self.nonempty(tuneTone.error)
        canToggleTuneTone = socketReady && !tuneToneBusy
    }

    var swrQuality: SWRQuality? {
        guard let swr else { return nil }
        if swr < 1.5 { return .good }
        if swr < 2 { return .caution }
        return .high
    }

    var builtInStatusText: String? {
        switch status {
        case "tuning": "正在调谐"
        case "success": "调谐成功"
        case "failed": "调谐失败"
        case "idle": tunerEnabled ? "天调已启用" : "天调已旁路"
        case .some(let status): "状态：\(status)"
        case nil: nil
        }
    }

    private static func isAvailable(_ state: CapabilityState?) -> Bool {
        state?.supported == true && state?.availability != "unavailable"
    }

    private static func unavailableMessage(
        switchState: CapabilityState?,
        tuneState: CapabilityState?
    ) -> String? {
        let supportedStates = [switchState, tuneState].compactMap { $0 }.filter(\.supported)
        guard !supportedStates.isEmpty,
              supportedStates.contains(where: { $0.availability == "unavailable" }) else {
            return nil
        }
        return "天调未连接或当前不可用"
    }

    private static func firstNonempty(_ values: String?...) -> String? {
        values.compactMap { nonempty($0) }.first
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct TunerControlPanel: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var switchPending = false
    @State private var manualTunePending = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(model: model(at: context.date))
        }
        .onChange(of: switchState?.updatedAt) { _, _ in
            switchPending = false
            manualTunePending = false
        }
        .onDisappear {
            if radio.tuneTone.active { radio.stopTuneTone() }
        }
    }

    private func content(model: TunerControlState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.25)

            HStack(alignment: .firstTextBaseline) {
                Label("天线调谐", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let swr = model.swr {
                    Text("SWR \(swr, specifier: "%.2f")")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(swrColor(model.swrQuality))
                }
            }

            builtInControls(model: model)

            Divider().opacity(0.25)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("外置天调")
                            .font(.subheadline.weight(.semibold))
                        Text("持续发送 1 kHz 音，供外置天调匹配")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.muted)
                    }
                    Spacer()
                    if model.tuneToneActive {
                        Text("已发送 \(model.tuneToneElapsedSeconds)s · 剩余 \(model.tuneToneRemainingSeconds)s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(RadioPalette.warning)
                    }
                }

                Button {
                    if model.tuneToneActive {
                        radio.stopTuneTone()
                    } else {
                        radio.startTuneTone(operatorId: session.selectedOperatorId)
                    }
                } label: {
                    Label(
                        model.tuneToneActive ? "停止外置天调音" : "开始外置天调音",
                        systemImage: model.tuneToneActive ? "stop.fill" : "waveform"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(RadioActionButtonStyle(
                    tint: model.tuneToneActive ? RadioPalette.transmit : RadioPalette.warning,
                    prominent: model.tuneToneActive
                ))
                .disabled(!model.canToggleTuneTone)

                if model.tuneToneBusy {
                    warningText("PTT 正在由其他任务占用，不能启动调谐音")
                }
                if let error = model.tuneToneError {
                    errorText("调谐音错误：\(error)")
                }
            }
        }
    }

    @ViewBuilder
    private func builtInControls(model: TunerControlState) -> some View {
        if model.builtInSupported {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    if model.switchSupported {
                        Toggle("内置天调", isOn: Binding(
                            get: { model.tunerEnabled },
                            set: { enabled in setTuner(enabled: enabled, model: model) }
                        ))
                        .tint(RadioPalette.warning)
                        .disabled(!model.canToggleSwitch || switchPending)
                    }

                    if model.tuneSupported {
                        Button {
                            startManualTune(model: model)
                        } label: {
                            if manualTunePending || model.isTuning {
                                HStack(spacing: 7) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在调谐")
                                }
                            } else {
                                Text("手动调谐")
                            }
                        }
                        .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning))
                        .disabled(!model.canStartManualTune || manualTunePending)
                    }
                }

                if let status = model.builtInStatusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(model.isTuning ? RadioPalette.warning : RadioPalette.muted)
                }
                if !model.tunerEnabled, model.tuneSupported {
                    Text("先启用内置天调，才能执行手动调谐")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                }
                if let unavailable = model.unavailableMessage {
                    warningText(unavailable)
                }
                if let error = model.lastError {
                    errorText("电台返回：\(error)")
                }
            }
        } else {
            Text(model.hasCapabilitySnapshot ? "当前电台不支持内置天调" : "等待内置天调能力同步")
                .font(.caption)
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private var switchState: CapabilityState? { radio.capabilities["tuner_switch"] }
    private var tuneState: CapabilityState? { radio.capabilities["tuner_tune"] }

    private func model(at date: Date) -> TunerControlState {
        TunerControlState(
            switchState: switchState,
            tuneState: tuneState,
            ptt: radio.ptt,
            tuneTone: radio.tuneTone,
            socketReady: radio.state == .ready,
            nowMilliseconds: date.timeIntervalSince1970 * 1_000
        )
    }

    private func setTuner(enabled: Bool, model: TunerControlState) {
        guard model.canToggleSwitch, !switchPending else { return }
        switchPending = true
        radio.writeCapability(id: "tuner_switch", value: .bool(enabled))
        clearSwitchPendingAfterTimeout()
    }

    private func startManualTune(model: TunerControlState) {
        guard model.canStartManualTune, !manualTunePending else { return }
        manualTunePending = true
        radio.writeCapability(id: "tuner_tune", action: true)
        clearManualTunePendingAfterTimeout()
    }

    private func clearSwitchPendingAfterTimeout() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            switchPending = false
        }
    }

    private func clearManualTunePendingAfterTimeout() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            manualTunePending = false
        }
    }

    private func swrColor(_ quality: TunerControlState.SWRQuality?) -> Color {
        switch quality {
        case .good: RadioPalette.accent
        case .caution: RadioPalette.warning
        case .high: RadioPalette.transmit
        case nil: RadioPalette.muted
        }
    }

    private func warningText(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(RadioPalette.warning)
    }

    private func errorText(_ text: String) -> some View {
        Label(text, systemImage: "xmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(RadioPalette.transmit)
    }
}
