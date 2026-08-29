import SwiftUI

struct OpenWebRXProfileSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var radio: RadioWebSocket
    let request: OpenWebRXProfileSelectRequest
    @State private var selectedProfileId: String
    @State private var isVerifying = false

    init(request: OpenWebRXProfileSelectRequest) {
        self.request = request
        _selectedProfileId = State(initialValue: request.currentProfileId ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("自动匹配不到覆盖目标频率的 OpenWebRX Profile，请手动选择并验证。")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(RadioPalette.warning)
                    }
                    LabeledContent("目标频率", value: String(
                        format: "%.6f MHz",
                        request.targetFrequency / 1_000_000
                    ))
                }

                Section("选择 Profile") {
                    Picker("Profile", selection: $selectedProfileId) {
                        Text("请选择").tag("")
                        ForEach(request.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                if let result = matchingResult {
                    Section("验证结果") {
                        if result.success {
                            Label("Profile 验证成功", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(RadioPalette.accent)
                        } else {
                            Label(result.error ?? "所选 Profile 不覆盖目标频率", systemImage: "xmark.octagon.fill")
                                .foregroundStyle(RadioPalette.transmit)
                            if let center = result.centerFreq, let sampleRate = result.sampRate {
                                LabeledContent("覆盖中心", value: String(format: "%.6f MHz", center / 1_000_000))
                                LabeledContent("采样带宽", value: String(format: "%.0f kHz", sampleRate / 1_000))
                            }
                        }
                    }
                }

                Section {
                    Text("OpenWebRX 可能要求约 11 秒的 Profile 切换冷却。频繁尝试可能触发远端站点的机器人检测。")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                }
            }
            .navigationTitle("选择 OpenWebRX Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        radio.dismissOpenWebRXProfileRequest()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isVerifying ? "验证中…" : "验证") {
                        isVerifying = true
                        radio.respondToOpenWebRXProfileRequest(profileId: selectedProfileId)
                    }
                    .disabled(selectedProfileId.isEmpty || isVerifying)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isVerifying)
        .onChange(of: radio.openWebRXProfileVerifyResult) { _, result in
            guard result?.requestId == request.requestId else { return }
            isVerifying = false
            guard result?.success == true else { return }
            Task {
                try? await Task.sleep(for: .seconds(1))
                radio.dismissOpenWebRXProfileRequest()
                dismiss()
            }
        }
    }

    private var matchingResult: OpenWebRXProfileVerifyResult? {
        guard radio.openWebRXProfileVerifyResult?.requestId == request.requestId else { return nil }
        return radio.openWebRXProfileVerifyResult
    }
}
