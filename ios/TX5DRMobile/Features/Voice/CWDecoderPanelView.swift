import SwiftUI

struct CWDecoderPanelView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var showingConfiguration = false

    var body: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 12) {
                header
                controls
                transcript

                if let config = session.effectiveCWDecoderConfig {
                    CWDecoderTuningEditor(config: config)
                        .id("tune-\(config.targetFreqHz)-\(config.filterWidthHz)")

                    DisclosureGroup("解码器高级配置", isExpanded: $showingConfiguration) {
                        CWDecoderConfigEditor(config: config, backends: session.cwDecoderBackends)
                            .padding(.top, 10)
                            .id("config-\(config.backend.rawValue)-\(config.runtimeBackend.rawValue)-\(config.modelSize.rawValue)-\(config.updatedIdentity)")
                    }
                    .font(.subheadline.weight(.semibold))
                } else {
                    ProgressView("读取 CW 解码器")
                        .frame(maxWidth: .infinity, minHeight: 80)
                }

                if let error = radio.cwDecoderError ?? radio.cwDecoder?.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.warning)
                }
            }
        }
        .task { await session.loadCWDecoder() }
    }

    private var header: some View {
        HStack {
            Label("CW 实时解码", systemImage: "captions.bubble.fill")
                .font(.headline)
            Spacer()
            Text(statusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(isRunning ? "停止解码" : "开始解码") {
                Task {
                    if isRunning { await session.stopCWDecoder() }
                    else { await session.startCWDecoder() }
                }
            }
            .buttonStyle(RadioActionButtonStyle(tint: isRunning ? RadioPalette.transmit : RadioPalette.accent, prominent: isRunning))
            .disabled(session.isWorking || !hasAvailableBackend)

            Button("清屏") {
                Task { await session.clearCWDecoderTranscript() }
            }
            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning))
            .disabled(session.isWorking || (radio.cwDecoderSegments.isEmpty && radio.cwDecoderPending == nil))

            Button {
                Task { await session.loadCWDecoder() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.cyan))
            .disabled(session.isWorking)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("实时转写")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RadioPalette.muted)
                Spacer()
                if let status = radio.cwDecoder {
                    Text("\(status.config.targetFreqHz) Hz · \(status.config.filterWidthHz) Hz")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(RadioPalette.muted)
                }
            }
            ScrollView {
                Text(transcriptText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(RadioPalette.text)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(10)
            .background(RadioPalette.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var isRunning: Bool { radio.cwDecoder?.isRunning == true }
    private var hasAvailableBackend: Bool {
        session.cwDecoderBackends.contains(where: \.available) || session.cwDecoderBackends.isEmpty
    }

    private var statusLabel: String {
        switch radio.cwDecoder?.state {
        case .starting: "启动中"
        case .listening: "监听中"
        case .decoding: "解码中"
        case .muted: "发射静音"
        case .error: "故障"
        case .disabled, .none: "已停止"
        }
    }

    private var statusColor: Color {
        switch radio.cwDecoder?.state {
        case .listening, .decoding: RadioPalette.accent
        case .starting, .muted: RadioPalette.warning
        case .error: RadioPalette.transmit
        case .disabled, .none: RadioPalette.muted
        }
    }

    private var transcriptText: String {
        var value = ""
        for segment in radio.cwDecoderSegments {
            let text = segment.plainText ?? segment.text
            if !value.isEmpty, segment.prependSpace { value.append(" ") }
            value.append(text)
        }
        if let pending = radio.cwDecoderPending?.plainText ?? radio.cwDecoderPending?.text, !pending.isEmpty {
            if !value.isEmpty { value.append(" ") }
            value.append("▌\(pending)")
        }
        return value.isEmpty ? "等待 CW 信号…" : value
    }
}

private struct CWDecoderTuningEditor: View {
    @EnvironmentObject private var session: TX5DRSession
    let config: CWDecoderConfig
    @State private var targetFreqHz: Double
    @State private var filterWidthHz: Int

    init(config: CWDecoderConfig) {
        self.config = config
        _targetFreqHz = State(initialValue: Double(config.targetFreqHz))
        _filterWidthHz = State(initialValue: config.filterWidthHz)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("目标音调")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int(targetFreqHz)) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RadioPalette.accent)
            }
            Slider(value: $targetFreqHz, in: 100...1_500, step: 5)
                .tint(RadioPalette.accent)

            Picker("滤波宽度", selection: $filterWidthHz) {
                ForEach([100, 150, 250, 500, 800], id: \.self) { width in
                    Text("\(width)").tag(width)
                }
            }
            .pickerStyle(.segmented)

            Button("应用实时微调") {
                Task {
                    await session.tuneCWDecoder(
                        targetFreqHz: Int(targetFreqHz.rounded()),
                        filterWidthHz: filterWidthHz
                    )
                }
            }
            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.cyan))
            .disabled(
                (Int(targetFreqHz.rounded()) == config.targetFreqHz && filterWidthHz == config.filterWidthHz)
                    || session.isWorking
            )
        }
        .padding(10)
        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CWDecoderConfigEditor: View {
    @EnvironmentObject private var session: TX5DRSession
    let config: CWDecoderConfig
    let backends: [CWDecoderBackendDescriptor]

    @State private var backend: CWDecoderBackend
    @State private var runtime: CWDecoderRuntimeBackend
    @State private var modelSize: CWDecoderModelSize
    @State private var language: String
    @State private var windowSeconds: Double
    @State private var decodeIntervalMs: Int
    @State private var muteWhileTransmitting: Bool
    @State private var workerCount: Int
    @State private var minCommitChars: Int
    @State private var commitStability: Int
    @State private var maxPendingAgeMs: Int

    init(config: CWDecoderConfig, backends: [CWDecoderBackendDescriptor]) {
        self.config = config
        self.backends = backends
        _backend = State(initialValue: config.backend)
        _runtime = State(initialValue: config.runtimeBackend)
        _modelSize = State(initialValue: config.modelSize)
        _language = State(initialValue: config.language)
        _windowSeconds = State(initialValue: config.windowSeconds)
        _decodeIntervalMs = State(initialValue: config.decodeIntervalMs)
        _muteWhileTransmitting = State(initialValue: config.muteWhileTransmitting)
        _workerCount = State(initialValue: config.workerCount)
        _minCommitChars = State(initialValue: config.minCommitChars)
        _commitStability = State(initialValue: config.commitStability)
        _maxPendingAgeMs = State(initialValue: config.maxPendingAgeMs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("解码后端", selection: $backend) {
                ForEach(availableBackends) { descriptor in
                    Text(descriptor.label ?? descriptor.name).tag(descriptor.id)
                }
            }
            Picker("运行时", selection: $runtime) {
                ForEach(runtimeOptions) { value in Text(runtimeLabel(value)).tag(value) }
            }
            Picker("模型", selection: $modelSize) {
                ForEach(modelOptions) { value in Text(value.rawValue).tag(value) }
            }
            TextField("语言", text: $language)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Stepper("分析窗口 \(windowSeconds, specifier: "%.0f") 秒", value: $windowSeconds, in: 2...60, step: 1)
            Stepper("解码间隔 \(decodeIntervalMs) ms", value: $decodeIntervalMs, in: 100...5_000, step: 100)
            Toggle("发射时暂停解码", isOn: $muteWhileTransmitting)
            Stepper("工作线程 \(workerCount)", value: $workerCount, in: 1...4)
            Stepper("最少提交字符 \(minCommitChars)", value: $minCommitChars, in: 1...10)
            Stepper("提交稳定度 \(commitStability)", value: $commitStability, in: 1...10)
            Stepper("待定超时 \(maxPendingAgeMs) ms", value: $maxPendingAgeMs, in: 500...10_000, step: 500)

            Button("保存解码器配置") {
                let cleanLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await session.updateCWDecoder(.init(
                        backend: backend,
                        runtimeBackend: runtime,
                        modelSize: modelSize,
                        language: cleanLanguage.isEmpty ? "en" : cleanLanguage,
                        mode: "streaming",
                        windowSeconds: windowSeconds,
                        decodeIntervalMs: decodeIntervalMs,
                        muteWhileTransmitting: muteWhileTransmitting,
                        workerCount: workerCount,
                        minCommitChars: minCommitChars,
                        commitStability: commitStability,
                        maxPendingAgeMs: maxPendingAgeMs
                    ))
                }
            }
            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
            .disabled(session.isWorking || !hasChanges)
        }
        .font(.subheadline)
        .onChange(of: backend) { _, _ in normalizeBackendOptions() }
    }

    private var availableBackends: [CWDecoderBackendDescriptor] {
        let available = backends.filter(\.available)
        return available.isEmpty ? backends : available
    }

    private var selectedDescriptor: CWDecoderBackendDescriptor? {
        backends.first { $0.id == backend }
    }

    private var runtimeOptions: [CWDecoderRuntimeBackend] {
        let values = selectedDescriptor?.runtimeBackends ?? []
        return values.isEmpty ? [.cpu] : values
    }

    private var modelOptions: [CWDecoderModelSize] {
        let values = selectedDescriptor?.modelSizes ?? []
        return values.isEmpty ? [.tiny] : values
    }

    private var hasChanges: Bool {
        backend != config.backend || runtime != config.runtimeBackend || modelSize != config.modelSize
            || language != config.language || windowSeconds != config.windowSeconds
            || decodeIntervalMs != config.decodeIntervalMs || muteWhileTransmitting != config.muteWhileTransmitting
            || workerCount != config.workerCount || minCommitChars != config.minCommitChars
            || commitStability != config.commitStability || maxPendingAgeMs != config.maxPendingAgeMs
    }

    private func normalizeBackendOptions() {
        if !runtimeOptions.contains(runtime) { runtime = runtimeOptions.first ?? .cpu }
        if !modelOptions.contains(modelSize) { modelSize = modelOptions.first ?? .tiny }
    }

    private func runtimeLabel(_ value: CWDecoderRuntimeBackend) -> String {
        switch value {
        case .cpu: "CPU"
        case .cuda: "CUDA"
        case .coreml: "CoreML"
        case .directml: "DirectML"
        case .wasm: "WASM"
        case .webgpu: "WebGPU"
        }
    }
}

private extension CWDecoderConfig {
    var updatedIdentity: String {
        "\(windowSeconds)-\(decodeIntervalMs)-\(muteWhileTransmitting)-\(workerCount)-\(minCommitChars)-\(commitStability)-\(maxPendingAgeMs)"
    }
}
