import SwiftUI

struct RadioLiteDeviceConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: RadioLiteSession

    private let original: RadioLiteRadioProfile
    @State private var draft: RadioLiteRadioConfigurationDraft
    @State private var discovery: RadioLiteHardwareDiscovery?
    @State private var loading = true
    @State private var saving = false
    @State private var testingHardware = false
    @State private var loadError: String?
    @State private var hardwareTestError: String?
    @State private var hardwareTestResult: RadioLiteHardwarePreflightResult?
    @State private var showModelPicker = false
    @State private var activeAlert: DeviceConfigurationAlert?
    @FocusState private var editingText: Bool

    init(profile: RadioLiteRadioProfile) {
        original = profile
        _draft = State(initialValue: RadioLiteRadioConfigurationDraft(profile: profile))
    }

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在读取 Debian 主机上的 Hamlib 与音频设备…")
                                .foregroundStyle(RadioPalette.muted)
                        }
                    }
                } else if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(RadioPalette.warning)
                        Button("重新扫描硬件") { Task { await loadDiscovery() } }
                    } footer: {
                        Text("仍可手动填写设备路径；重新扫描不会中断当前收听。")
                    }
                }

                Section {
                    TextField("显示名称", text: $draft.name)
                        .focused($editingText)
                    TextField("本站呼号", text: $draft.callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($editingText)
                    TextField("本站网格（可选）", text: $draft.grid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($editingText)
                    Toggle("允许真实硬件发射", isOn: $draft.hardwareTxEnabled)
                        .disabled(draft.connectionKind == .hamlibDummy)
                } header: {
                    Text("电台")
                } footer: {
                    Text("启用真实发射需要保存时再次确认。Dummy 电台不会驱动射频硬件。")
                }

                Section {
                    Button {
                        showModelPicker = true
                    } label: {
                        LabeledContent("电台型号", value: selectedModelName)
                    }
                    TextField("Hamlib 数字 ID", value: $draft.hamlibModelId, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .focused($editingText)
                    Picker("连接方式", selection: $draft.connectionKind) {
                        ForEach(RadioLiteConnectionKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }

                    switch draft.connectionKind {
                    case .managedSerial:
                        serialDevicePicker(title: "已发现 CAT 串口", selection: $draft.catDevicePath)
                        TextField("CAT 设备路径", text: $draft.catDevicePath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($editingText)
                        Picker("波特率", selection: $draft.baudRate) {
                            ForEach(discovery?.baudRates ?? RadioLiteRadioConfigurationDraft.standardBaudRates, id: \.self) {
                                Text(String($0)).tag($0)
                            }
                        }
                    case .networkRigctld:
                        TextField("rigctld 主机或 Tailscale 地址", text: $draft.rigctldHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($editingText)
                        TextField("rigctld 端口", value: $draft.rigctldPort, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .focused($editingText)
                    case .hamlibDummy:
                        Label("安全模拟，不访问串口", systemImage: "testtube.2")
                            .foregroundStyle(RadioPalette.accent)
                    }
                } header: {
                    Text("Hamlib 与 CAT")
                } footer: {
                    Text("型号来自服务器当前安装的 rigctl -l，可按厂商、机型或 Hamlib 数字 ID 搜索。")
                }

                Section {
                    Picker("控制方式", selection: $draft.pttMethod) {
                        ForEach(discovery?.pttMethods ?? RadioLitePTTMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    .disabled(draft.connectionKind != .managedSerial)

                    if draft.connectionKind == .networkRigctld {
                        Label("网络 rigctld 由远端服务管理 PTT，本客户端固定使用电台 CAT。", systemImage: "network")
                            .font(.footnote)
                            .foregroundStyle(RadioPalette.muted)
                    }

                    if draft.connectionKind == .managedSerial, draft.pttMethod.requiresDevicePath {
                        serialDevicePicker(title: "可用设备", selection: $draft.pttDevicePath)
                        TextField("PTT 设备路径", text: $draft.pttDevicePath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($editingText)
                    }
                    if draft.connectionKind == .managedSerial, draft.pttMethod.requiresBit {
                        Stepper("GPIO 位：\(draft.pttBit)", value: $draft.pttBit, in: 0...7)
                    }
                } header: {
                    Text("PTT 控制")
                } footer: {
                    Text("DTR、RTS、并口、CM108 与 GPIO 需要设备路径；GPIO/GPION 还需选择 0–7 位。")
                }

                Section {
                    RadioLiteAudioEndpointEditor(
                        title: "音频输入（电台 → iPhone）",
                        endpoint: $draft.audioInput,
                        devices: discovery?.audioInputs ?? [],
                        focus: $editingText
                    )
                    RadioLiteAudioEndpointEditor(
                        title: "音频输出（iPhone/FT8 → 电台）",
                        endpoint: $draft.audioOutput,
                        devices: discovery?.audioOutputs ?? [],
                        focus: $editingText
                    )
                } header: {
                    Text("服务器音频端口")
                } footer: {
                    Text("列表来自服务器的 PulseAudio/PipeWire 或 ALSA；设备未被发现时也可手动填写 ID。")
                }

                if let warnings = discovery?.warnings, !warnings.isEmpty {
                    Section("扫描提示") {
                        ForEach(warnings, id: \.self) { warning in
                            Label(discoveryWarning(warning), systemImage: "info.circle")
                                .foregroundStyle(RadioPalette.muted)
                        }
                    }
                }

                if let validation = draft.validationMessage {
                    Section {
                        Label(validation, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(RadioPalette.warning)
                    }
                }

                Section {
                    Button {
                        Task { await testHardware() }
                    } label: {
                        HStack {
                            Label(
                                testingHardware ? "正在测试 CAT 与音频端点…" : "测试 CAT 与音频端点",
                                systemImage: "stethoscope"
                            )
                            Spacer()
                            if testingHardware { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(testingHardware || saving || draft.validationMessage != nil)

                    if let hardwareTestError {
                        Label(hardwareTestError, systemImage: "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(RadioPalette.transmit)
                    }

                    if let result = hardwareTestResult {
                        Label(
                            preflightSummary(result.overallStatus),
                            systemImage: preflightIcon(result.overallStatus)
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(preflightColor(result.overallStatus))

                        ForEach(result.checks) { check in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Label(preflightTitle(check.id), systemImage: preflightIcon(check.status))
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(preflightStatusLabel(check.status))
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(preflightColor(check.status))
                                }
                                Text(check.message)
                                    .font(.caption)
                                    .foregroundStyle(RadioPalette.muted)
                                if let detail = preflightDetail(check), !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(RadioPalette.cyan)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } header: {
                    Text("只读连接测试")
                } footer: {
                    Text("测试不会保存配置或取得控制权；CAT 预检只发送读取查询，不会发送 PTT、天调、频率或模式写命令。")
                }

                Section {
                    Label("保存会停止当前 PTT/天调、释放旧设备并重新连接电台与音频，通常只会短暂中断。", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(RadioPalette.muted)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设备配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        requestSave()
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(saving || testingHardware || draft.validationMessage != nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { editingText = false }
                }
            }
            .task { await loadDiscovery() }
            .sheet(isPresented: $showModelPicker) {
                RadioLiteHamlibModelPicker(
                    models: discovery?.hamlibModels ?? [],
                    presets: discovery?.curatedPresets ?? [],
                    selectedModelId: draft.hamlibModelId
                ) { modelId in
                    draft.hamlibModelId = modelId
                    if modelId == 1 {
                        draft.connectionKind = .hamlibDummy
                        draft.pttMethod = .none
                        draft.hardwareTxEnabled = false
                    } else if draft.connectionKind == .hamlibDummy {
                        draft.connectionKind = .managedSerial
                        draft.pttMethod = .rig
                    }
                }
            }
            .onChange(of: draft.connectionKind) { _, kind in
                if kind == .hamlibDummy {
                    draft.hamlibModelId = 1
                    draft.pttMethod = .none
                    draft.hardwareTxEnabled = false
                } else if kind == .networkRigctld {
                    draft.pttMethod = .rig
                } else if draft.hamlibModelId == 1 {
                    draft.pttMethod = .rig
                }
            }
            .onChange(of: draft.hamlibModelId) { _, modelId in
                if modelId == 1, draft.connectionKind != .hamlibDummy {
                    draft.connectionKind = .hamlibDummy
                } else if modelId > 1, draft.connectionKind == .hamlibDummy {
                    draft.connectionKind = .managedSerial
                    draft.pttMethod = .rig
                }
            }
            .onChange(of: draft) { _, _ in
                hardwareTestResult = nil
                hardwareTestError = nil
            }
            .alert(item: $activeAlert) { item in
                switch item {
                case .confirmHardwareTransmit:
                    Alert(
                        title: Text("确认启用真实发射？"),
                        message: Text("保存后 PTT、FT8/FT4 与天调可以驱动 \(draft.name) 发射。请确认负载、天线和功率设置安全。"),
                        primaryButton: .destructive(Text("确认并保存")) {
                            Task { await save(confirmHardwareTransmission: true) }
                        },
                        secondaryButton: .cancel(Text("取消"))
                    )
                case .error(let message):
                    Alert(title: Text("保存失败"), message: Text(message), dismissButton: .default(Text("好")))
                case .saved(let message):
                    Alert(
                        title: Text("保存完成"),
                        message: Text(message),
                        dismissButton: .default(Text("完成")) { dismiss() }
                    )
                }
            }
        }
    }

    private var selectedModelName: String {
        if let model = discovery?.hamlibModels.first(where: { $0.modelId == draft.hamlibModelId }) {
            return "\(model.displayName) · \(model.modelId)"
        }
        return draft.hamlibModelId == 1 ? "Hamlib Dummy · 1" : "Hamlib ID \(draft.hamlibModelId)"
    }

    @ViewBuilder
    private func serialDevicePicker(title: String, selection: Binding<String>) -> some View {
        let devices = discovery?.serialDevices ?? []
        if !devices.isEmpty {
            Picker(title, selection: selection) {
                if !devices.contains(where: { $0.path == selection.wrappedValue }) {
                    Text("当前/手动：\(selection.wrappedValue)").tag(selection.wrappedValue)
                }
                ForEach(devices) { device in
                    Text(device.stable ? device.label : "\(device.label)（路径可能变化）")
                        .tag(device.path)
                }
            }
        }
    }

    private func requestSave() {
        editingText = false
        guard draft.validationMessage == nil else { return }
        if draft.hardwareTxEnabled && !original.hardwareTxEnabled {
            activeAlert = .confirmHardwareTransmit
        } else {
            Task { await save(confirmHardwareTransmission: draft.hardwareTxEnabled) }
        }
    }

    private func testHardware() async {
        guard !testingHardware else { return }
        editingText = false
        let ownership = RadioLiteHardwarePreflightOwnership(
            draft: draft,
            serverAddress: session.serverAddress,
            userId: session.principal?.userId
        )
        testingHardware = true
        hardwareTestError = nil
        hardwareTestResult = nil
        defer { testingHardware = false }
        do {
            let result = try await session.testRadioConfiguration(ownership.makeProfile())
            guard ownership.isCurrent(
                draft,
                serverAddress: session.serverAddress,
                userId: session.principal?.userId
            ) else { return }
            hardwareTestResult = result
        } catch {
            guard ownership.isCurrent(
                draft,
                serverAddress: session.serverAddress,
                userId: session.principal?.userId
            ) else { return }
            hardwareTestError = "连接测试失败：\(error.localizedDescription)"
        }
    }

    private func save(confirmHardwareTransmission: Bool) async {
        saving = true
        defer { saving = false }
        do {
            let profile = try draft.makeProfile()
            let reconnected = try await session.saveRadioConfiguration(
                profile,
                confirmHardwareTransmission: confirmHardwareTransmission
            )
            activeAlert = .saved(
                reconnected
                    ? "新型号、CAT/PTT 与音频端口已经生效。"
                    : "配置已写入服务器；弱网重连仍在后台继续。"
            )
        } catch {
            activeAlert = .error(error.localizedDescription)
        }
    }

    private func loadDiscovery() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            discovery = try await session.loadHardwareDiscovery()
        } catch {
            loadError = "硬件扫描失败：\(error.localizedDescription)"
        }
    }

    private func discoveryWarning(_ value: String) -> String {
        switch value {
        case "hamlib_model_discovery_unavailable": "无法读取 Hamlib 型号列表，可继续使用当前数字 ID"
        case "serial_discovery_unavailable": "无法扫描串口，可手动输入 /dev 路径"
        case "pulseaudio_discovery_unavailable_using_alsa": "PulseAudio 不可用，已改用 ALSA 设备"
        case "audio_discovery_unavailable": "无法扫描音频设备，可手动输入 ALSA/PulseAudio ID"
        default: value
        }
    }

    private func preflightTitle(_ id: RadioLiteHardwarePreflightCheckID) -> String {
        switch id {
        case .cat: "CAT 读回"
        case .capabilities: "Hamlib 能力"
        case .audioInput: "接收音频输入"
        case .audioOutput: "发射音频输出"
        }
    }

    private func preflightStatusLabel(_ status: RadioLiteHardwarePreflightStatus) -> String {
        switch status {
        case .passed: "通过"
        case .warning: "警告"
        case .failed: "失败"
        }
    }

    private func preflightSummary(_ status: RadioLiteHardwarePreflightStatus) -> String {
        switch status {
        case .passed: "所有只读检查均已通过"
        case .warning: "CAT 可用，但部分能力或音频端点需要确认"
        case .failed: "CAT 连接或读回失败，请修正配置后重试"
        }
    }

    private func preflightIcon(_ status: RadioLiteHardwarePreflightStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func preflightColor(_ status: RadioLiteHardwarePreflightStatus) -> Color {
        switch status {
        case .passed: RadioPalette.accent
        case .warning: RadioPalette.warning
        case .failed: RadioPalette.transmit
        }
    }

    private func preflightDetail(_ check: RadioLiteHardwarePreflightCheck) -> String? {
        switch check.id {
        case .cat:
            let frequency = check.details["frequencyHz"].flatMap(Int64.init)
                .map { String(format: "%.6f MHz", Double($0) / 1_000_000) }
                ?? "—"
            return "\(frequency) · \(check.details["mode"] ?? "—") · \(check.details["passbandHz"] ?? "—") Hz"
        case .capabilities:
            let levels = check.details["readableLevels"] ?? ""
            let functions = check.details["readableFunctions"] ?? ""
            return [levels.isEmpty ? nil : "LEVEL \(levels)", functions.isEmpty ? nil : "FUNC \(functions)"]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .audioInput, .audioOutput:
            guard let backend = check.details["backend"], let id = check.details["id"] else { return nil }
            return "\(backend.uppercased()) · \(id)"
        }
    }
}

private enum DeviceConfigurationAlert: Identifiable {
    case confirmHardwareTransmit
    case error(String)
    case saved(String)

    var id: String {
        switch self {
        case .confirmHardwareTransmit: "confirm-hardware-transmit"
        case .error(let message): "error:\(message)"
        case .saved(let message): "saved:\(message)"
        }
    }
}

private struct RadioLiteHamlibModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    let models: [RadioLiteHamlibModel]
    let presets: [RadioLiteCuratedRigPreset]
    let selectedModelId: Int
    let onSelect: (Int) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section("常用机型") {
                        ForEach(presets.filter { $0.available && $0.hamlibModelId != nil }) { preset in
                            if let modelId = preset.hamlibModelId {
                                modelRow(
                                    title: preset.displayName,
                                    detail: preset.defaultBaudRate.map { "推荐 \($0) baud · ID \(modelId)" } ?? "Hamlib ID \(modelId)",
                                    modelId: modelId
                                )
                            }
                        }
                    }
                }

                Section(query.isEmpty ? "全部 Hamlib 型号" : "搜索结果") {
                    if filteredModels.isEmpty {
                        ContentUnavailableView(
                            "没有匹配型号",
                            systemImage: "radio",
                            description: Text("可搜索厂商、型号或 Hamlib 数字 ID")
                        )
                    } else {
                        ForEach(filteredModels) { model in
                            modelRow(
                                title: model.displayName,
                                detail: "ID \(model.modelId) · \(model.status)",
                                modelId: model.modelId
                            )
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Icom、IC-7300 或 3073")
            .navigationTitle("选择电台型号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var filteredModels: [RadioLiteHamlibModel] {
        models.filter { $0.matches(query) }
    }

    private func modelRow(title: String, detail: String, modelId: Int) -> some View {
        Button {
            onSelect(modelId)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(RadioPalette.muted)
                }
                Spacer()
                if selectedModelId == modelId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RadioPalette.accent)
                }
            }
        }
    }
}

private struct RadioLiteAudioEndpointEditor: View {
    let title: String
    @Binding var endpoint: RadioLiteAudioEndpoint
    let devices: [RadioLiteDiscoveredAudioDevice]
    let focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if !devices.isEmpty {
                Picker("系统设备", selection: endpointSelection) {
                    if !devices.contains(where: { key($0.endpoint) == key(endpoint) }) {
                        Text(endpoint.label ?? "当前/手动：\(endpoint.id)").tag(key(endpoint))
                    }
                    ForEach(devices) { device in
                        Text(device.label).tag(key(device.endpoint))
                    }
                }
            }
            Picker("音频后端", selection: backendSelection) {
                Text("ALSA").tag("alsa")
                Text("PulseAudio / PipeWire").tag("pulse")
            }
            TextField("设备 ID", text: idSelection)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)
            Text(endpoint.label ?? endpoint.id)
                .font(.caption)
                .foregroundStyle(RadioPalette.muted)
        }
        .padding(.vertical, 4)
    }

    private var endpointSelection: Binding<String> {
        Binding(
            get: { key(endpoint) },
            set: { selected in
                if let device = devices.first(where: { key($0.endpoint) == selected }) {
                    endpoint = device.endpoint
                }
            }
        )
    }

    private var backendSelection: Binding<String> {
        Binding(
            get: { endpoint.backend },
            set: { endpoint = .init(backend: $0, id: endpoint.id, label: nil) }
        )
    }

    private var idSelection: Binding<String> {
        Binding(
            get: { endpoint.id },
            set: { endpoint = .init(backend: endpoint.backend, id: $0, label: nil) }
        )
    }

    private func key(_ value: RadioLiteAudioEndpoint) -> String {
        "\(value.backend):\(value.id)"
    }
}
