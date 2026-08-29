import SwiftUI

private struct ProfileEditorRoute: Identifiable {
    let id = UUID()
    let profile: RadioProfile?
}

private struct PendingProfilePower: Identifiable {
    var id: String { "\(profile.id)-\(target.rawValue)" }
    let profile: RadioProfile
    let target: RadioPowerTarget
}

struct ProfileManagementView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var editorRoute: ProfileEditorRoute?
    @State private var pendingDelete: RadioProfile?
    @State private var pendingPower: PendingProfilePower?

    var body: some View {
        List {
            if session.profiles.isEmpty {
                ContentUnavailableView(
                    "尚未创建电台 Profile",
                    systemImage: "radio",
                    description: Text(session.isAdmin ? "创建 Profile 后即可配置并连接现有 TX-5DR 电台。" : "请由管理员先在 TX-5DR 中创建 Profile。")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(session.profiles) { profile in
                        profileRow(profile)
                    }
                    .onMove(perform: moveProfiles)
                } footer: {
                    Text("激活 Profile 会让 TX-5DR 切换电台与服务端音频设备。物理电源命令仅在 Hamlib 型号明确支持时显示。")
                }
            }

            if let state = radio.radioPowerState {
                Section("物理电源状态") {
                    LabeledContent("状态", value: state.state)
                    LabeledContent("阶段", value: state.stage)
                    if let detail = state.errorDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(RadioPalette.warning)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("Profile 与电源")
        .toolbar {
            if session.isAdmin {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editorRoute = ProfileEditorRoute(profile: nil) } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .task {
            await session.refreshProfiles()
            if session.isAdmin {
                await session.loadProfileEditorResources()
                for profile in session.profiles {
                    await session.loadPowerSupport(profileId: profile.id)
                }
            }
        }
        .refreshable {
            await session.refreshProfiles()
            if session.isAdmin {
                for profile in session.profiles {
                    await session.loadPowerSupport(profileId: profile.id)
                }
            }
        }
        .sheet(item: $editorRoute) { route in
            NavigationStack { ProfileEditorView(profile: route.profile) }
                .environmentObject(session)
        }
        .confirmationDialog(
            "删除 \(pendingDelete?.name ?? "Profile")？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let profile = pendingDelete else { return }
                pendingDelete = nil
                Task { await session.deleteProfile(profile) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("当前激活的 Profile 不能删除。")
        }
        .confirmationDialog(
            powerConfirmationTitle,
            isPresented: Binding(
                get: { pendingPower != nil },
                set: { if !$0 { pendingPower = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认执行", role: pendingPower?.target == .off ? .destructive : nil) {
                guard let request = pendingPower else { return }
                pendingPower = nil
                Task { await session.setRadioPower(profile: request.profile, target: request.target) }
            }
            Button("取消", role: .cancel) { pendingPower = nil }
        } message: {
            Text("这是物理电台电源操作，不只是停止 TX-5DR 软件引擎。")
        }
    }

    private func profileRow(_ profile: RadioProfile) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(profile.id == session.activeProfileId ? RadioPalette.accent : RadioPalette.muted.opacity(0.45))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(profile.name).font(.headline)
                    if profile.id == session.activeProfileId {
                        Text("当前")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(RadioPalette.accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(RadioPalette.accent)
                    }
                }
                Text(profile.endpointSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(RadioPalette.muted)
                if let description = profile.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                        .lineLimit(2)
                }
            }
            Spacer()
            if session.isAdmin {
                Menu {
                    Button(profile.id == session.activeProfileId ? "重新连接" : "激活并连接") {
                        Task { await session.activateProfile(profile) }
                    }
                    powerButtons(profile)
                    Divider()
                    Button("编辑") { editorRoute = ProfileEditorRoute(profile: profile) }
                    Button("删除", role: .destructive) { pendingDelete = profile }
                        .disabled(profile.id == session.activeProfileId)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func powerButtons(_ profile: RadioProfile) -> some View {
        if let support = session.powerSupport[profile.id] {
            if support.canPowerOn {
                Button("物理开机") { pendingPower = PendingProfilePower(profile: profile, target: .on) }
            }
            if support.supportedStates.contains(.operate) {
                Button("切换到工作") { pendingPower = PendingProfilePower(profile: profile, target: .operate) }
            }
            if support.supportedStates.contains(.standby) {
                Button("切换到待机") { pendingPower = PendingProfilePower(profile: profile, target: .standby) }
            }
            if support.canPowerOff || support.supportedStates.contains(.off) {
                Button("物理关机", role: .destructive) { pendingPower = PendingProfilePower(profile: profile, target: .off) }
            }
        }
    }

    private func moveProfiles(from source: IndexSet, to destination: Int) {
        var profiles = session.profiles
        profiles.move(fromOffsets: source, toOffset: destination)
        Task { await session.reorderProfiles(profiles.map(\.id)) }
    }

    private var powerConfirmationTitle: String {
        guard let pendingPower else { return "确认物理电源操作" }
        let action: String = switch pendingPower.target {
        case .on: "开机"
        case .off: "关机"
        case .standby: "进入待机"
        case .operate: "进入工作状态"
        }
        return "让 \(pendingPower.profile.name) \(action)？"
    }
}

private struct ProfileEditorView: View {
    @EnvironmentObject private var session: TX5DRSession
    @Environment(\.dismiss) private var dismiss
    let profile: RadioProfile?

    @State private var name: String
    @State private var description: String
    @State private var radioType: String
    @State private var networkHost: String
    @State private var networkPort: String
    @State private var serialPath: String
    @State private var rigModel: Int
    @State private var icomIP: String
    @State private var icomPort: String
    @State private var icomUsername: String
    @State private var icomPassword: String
    @State private var icomDataMode: Bool
    @State private var tciHost: String
    @State private var tciPort: String
    @State private var tciReceiver: String
    @State private var tciTRX: String
    @State private var tciVFO: String
    @State private var tciAudioEnabled: Bool
    @State private var tciSampleRate: String
    @State private var pttMethod: String
    @State private var digitalMode: String
    @State private var transmitCompensation: String
    @State private var fakeFrequencyEnabled: Bool
    @State private var inputDeviceName: String
    @State private var outputDeviceName: String
    @State private var inputSampleRate: String
    @State private var outputSampleRate: String
    @State private var inputBufferSize: String
    @State private var outputBufferSize: String
    @State private var outputSampleFormat: String
    @State private var outputChannelMode: String
    @State private var inputSignalType: String
    @State private var rawRadioJSON: String
    @State private var rawAudioJSON: String
    @State private var advancedExpanded = false
    @State private var localError: String?

    init(profile: RadioProfile?) {
        self.profile = profile
        let radio = profile?.radio ?? .object(["type": .string("none")])
        let audio = profile?.audio ?? .object([:])
        let network = radio["network"]
        let serial = radio["serial"]
        let icom = radio["icomWlan"]
        let tci = radio["tci"]
        _name = State(initialValue: profile?.name ?? "")
        _description = State(initialValue: profile?.description ?? "")
        _radioType = State(initialValue: radio["type"]?.stringValue ?? "none")
        _networkHost = State(initialValue: network?["host"]?.stringValue ?? "127.0.0.1")
        _networkPort = State(initialValue: network?["port"]?.intValue.map { String($0) } ?? "4532")
        _serialPath = State(initialValue: serial?["path"]?.stringValue ?? "")
        _rigModel = State(initialValue: serial?["rigModel"]?.intValue ?? 1)
        _icomIP = State(initialValue: icom?["ip"]?.stringValue ?? "")
        _icomPort = State(initialValue: icom?["port"]?.intValue.map { String($0) } ?? "50001")
        _icomUsername = State(initialValue: icom?["userName"]?.stringValue ?? "")
        _icomPassword = State(initialValue: icom?["password"]?.stringValue ?? "")
        _icomDataMode = State(initialValue: icom?["dataMode"]?.boolValue ?? true)
        _tciHost = State(initialValue: tci?["host"]?.stringValue ?? "127.0.0.1")
        _tciPort = State(initialValue: tci?["port"]?.intValue.map { String($0) } ?? "40001")
        _tciReceiver = State(initialValue: tci?["receiver"]?.intValue.map { String($0) } ?? "0")
        _tciTRX = State(initialValue: tci?["trx"]?.intValue.map { String($0) } ?? "0")
        _tciVFO = State(initialValue: tci?["vfo"]?.intValue.map { String($0) } ?? "0")
        _tciAudioEnabled = State(initialValue: tci?["audioEnabled"]?.boolValue ?? true)
        _tciSampleRate = State(initialValue: tci?["audioSampleRate"]?.intValue.map { String($0) } ?? "12000")
        _pttMethod = State(initialValue: radio["pttMethod"]?.stringValue ?? "cat")
        _digitalMode = State(initialValue: radio["digitalModeRadioMode"]?.stringValue ?? "none")
        _transmitCompensation = State(initialValue: radio["transmitCompensationMs"]?.intValue.map { String($0) } ?? "0")
        _fakeFrequencyEnabled = State(initialValue: radio["fakeFrequency"]?["enabled"]?.boolValue ?? false)
        _inputDeviceName = State(initialValue: audio["inputDeviceName"]?.stringValue ?? "")
        _outputDeviceName = State(initialValue: audio["outputDeviceName"]?.stringValue ?? "")
        _inputSampleRate = State(initialValue: audio["inputSampleRate"]?.intValue.map { String($0) } ?? "")
        _outputSampleRate = State(initialValue: audio["outputSampleRate"]?.intValue.map { String($0) } ?? "")
        _inputBufferSize = State(initialValue: audio["inputBufferSize"]?.intValue.map { String($0) } ?? "")
        _outputBufferSize = State(initialValue: audio["outputBufferSize"]?.intValue.map { String($0) } ?? "")
        _outputSampleFormat = State(initialValue: audio["outputSampleFormat"]?.stringValue ?? "float32")
        _outputChannelMode = State(initialValue: audio["outputChannelMode"]?.stringValue ?? "mono")
        _inputSignalType = State(initialValue: audio["inputSignalType"]?.stringValue ?? "af")
        _rawRadioJSON = State(initialValue: radio.prettyPrinted)
        _rawAudioJSON = State(initialValue: audio.prettyPrinted)
    }

    var body: some View {
        Form {
            Section("名称") {
                TextField("例如 IC-705 WiFi", text: $name)
                TextField("说明（可选）", text: $description, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section("电台连接") {
                Picker("类型", selection: $radioType) {
                    Text("仅监听").tag("none")
                    Text("Rigctld 网络").tag("network")
                    Text("Hamlib 串口").tag("serial")
                    Text("ICOM WLAN").tag("icom-wlan")
                    Text("TCI / SunSDR").tag("tci")
                }
                connectionFields
            }

            if radioType != "none" {
                Section("发射与数字模式") {
                    Picker("PTT 方式", selection: $pttMethod) {
                        Text("CAT").tag("cat")
                        Text("VOX").tag("vox")
                        Text("DTR").tag("dtr")
                        Text("RTS").tag("rts")
                    }
                    Picker("FT8/FT4 电台模式", selection: $digitalMode) {
                        Text("不切换").tag("none")
                        Text("USB").tag("usb")
                        Text("USB-DATA").tag("usb-data")
                    }
                    TextField("发射补偿 ms（-1000…1000）", text: $transmitCompensation)
                        .keyboardType(.numbersAndPunctuation)
                    Toggle("启用 Fake It 虚拟频差", isOn: $fakeFrequencyEnabled)
                }
            }

            Section("服务端音频设备") {
                deviceField("输入设备", value: $inputDeviceName, devices: session.audioDevices?.inputDevices ?? [])
                deviceField("输出设备", value: $outputDeviceName, devices: session.audioDevices?.outputDevices ?? [])
                TextField("输入采样率", text: $inputSampleRate).keyboardType(.numberPad)
                TextField("输出采样率", text: $outputSampleRate).keyboardType(.numberPad)
                TextField("输入缓冲区", text: $inputBufferSize).keyboardType(.numberPad)
                TextField("输出缓冲区", text: $outputBufferSize).keyboardType(.numberPad)
                Picker("输出格式", selection: $outputSampleFormat) {
                    Text("Float32").tag("float32")
                    Text("Int16").tag("int16")
                }
                Picker("输出声道", selection: $outputChannelMode) {
                    ForEach(["mono", "left", "right", "both"], id: \.self) { Text($0).tag($0) }
                }
                Picker("输入信号", selection: $inputSignalType) {
                    Text("AF 基带").tag("af")
                    Text("ICOM 12 kHz IF").tag("icom-12k-if")
                }
            }

            Section {
                DisclosureGroup("高级完整 JSON（保留 Hamlib 专用字段）", isExpanded: $advancedExpanded) {
                    Text("Radio JSON")
                        .font(.caption.weight(.semibold))
                    TextEditor(text: $rawRadioJSON)
                        .font(.caption.monospaced())
                        .frame(minHeight: 180)
                    Text("Audio JSON")
                        .font(.caption.weight(.semibold))
                    TextEditor(text: $rawAudioJSON)
                        .font(.caption.monospaced())
                        .frame(minHeight: 140)
                }
            } footer: {
                Text("表单会覆盖对应的常用字段；未显示的 serialConfig、backendConfig、频谱和独立 PTT/CW 串口字段会原样保留。")
            }
        }
        .navigationTitle(profile == nil ? "新建 Profile" : "编辑 Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(session.isWorking ? "保存中" : "保存") { save() }
                    .disabled(session.isWorking || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task {
            if session.supportedRigs.isEmpty || session.audioDevices == nil {
                await session.loadProfileEditorResources()
            }
        }
        .alert("Profile 配置无效", isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button("好") { localError = nil }
        } message: {
            Text(localError ?? "未知错误")
        }
    }

    @ViewBuilder
    private var connectionFields: some View {
        switch radioType {
        case "network":
            TextField("Rigctld 主机", text: $networkHost)
                .textInputAutocapitalization(.never)
            TextField("端口", text: $networkPort).keyboardType(.numberPad)
        case "serial":
            devicePathField
            if session.supportedRigs.isEmpty {
                TextField("Hamlib rigModel", value: $rigModel, format: .number)
                    .keyboardType(.numberPad)
            } else {
                Picker("电台型号", selection: $rigModel) {
                    ForEach(session.supportedRigs) { rig in
                        Text("\(rig.mfgName) \(rig.modelName)").tag(rig.rigModel)
                    }
                }
            }
        case "icom-wlan":
            TextField("电台 IP", text: $icomIP).textInputAutocapitalization(.never)
            TextField("端口", text: $icomPort).keyboardType(.numberPad)
            TextField("用户名（可选）", text: $icomUsername).textInputAutocapitalization(.never)
            SecureField("密码（可选）", text: $icomPassword)
            Toggle("数字模式", isOn: $icomDataMode)
        case "tci":
            TextField("TCI 主机", text: $tciHost).textInputAutocapitalization(.never)
            TextField("端口", text: $tciPort).keyboardType(.numberPad)
            TextField("Receiver", text: $tciReceiver).keyboardType(.numberPad)
            TextField("TRX", text: $tciTRX).keyboardType(.numberPad)
            TextField("VFO", text: $tciVFO).keyboardType(.numberPad)
            Toggle("使用 TCI 音频", isOn: $tciAudioEnabled)
            TextField("TCI 音频采样率", text: $tciSampleRate).keyboardType(.numberPad)
        default:
            Text("不连接物理电台，可配合 OpenWebRX 仅接收。")
                .font(.caption)
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private var devicePathField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("串口路径，例如 /dev/ttyUSB0", text: $serialPath)
                .textInputAutocapitalization(.never)
            if !session.serialPorts.isEmpty {
                Menu("从服务器串口选择") {
                    ForEach(session.serialPorts) { port in
                        Button(port.friendlyName.map { "\($0) · \(port.path)" } ?? port.path) {
                            serialPath = port.path
                        }
                    }
                }
            }
        }
    }

    private func deviceField(_ title: String, value: Binding<String>, devices: [AudioDeviceInfo]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField(title, text: value)
            if !devices.isEmpty {
                Menu("选择\(title)") {
                    Button("系统默认") { value.wrappedValue = "" }
                    ForEach(devices) { device in
                        Button(device.detail.map { "\(device.name) · \($0)" } ?? device.name) {
                            value.wrappedValue = device.name
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    private func save() {
        do {
            let radio = try buildRadioJSON()
            let audio = try buildAudioJSON()
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                let ok: Bool
                if let profile {
                    ok = await session.updateProfile(
                        id: profile.id,
                        name: cleanName,
                        description: cleanDescription.isEmpty ? nil : cleanDescription,
                        radio: radio,
                        audio: audio
                    )
                } else {
                    ok = await session.createProfile(
                        name: cleanName,
                        description: cleanDescription.isEmpty ? nil : cleanDescription,
                        radio: radio,
                        audio: audio
                    )
                }
                if ok { dismiss() }
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func buildRadioJSON() throws -> JSONValue {
        guard var root = try JSONValue.parse(rawRadioJSON).objectValue else {
            throw profileError("Radio JSON 顶层必须是对象")
        }
        root["type"] = .string(radioType)
        switch radioType {
        case "network":
            guard let port = validPort(networkPort), !networkHost.isEmpty else { throw profileError("请填写有效的 Rigctld 主机和端口") }
            var value = root["network"]?.objectValue ?? [:]
            value["host"] = .string(networkHost)
            value["port"] = .number(Double(port))
            root["network"] = .object(value)
        case "serial":
            guard !serialPath.isEmpty, rigModel > 0 else { throw profileError("请选择 Hamlib 型号并填写串口路径") }
            var value = root["serial"]?.objectValue ?? [:]
            value["path"] = .string(serialPath)
            value["rigModel"] = .number(Double(rigModel))
            root["serial"] = .object(value)
        case "icom-wlan":
            guard let port = validPort(icomPort), !icomIP.isEmpty else { throw profileError("请填写有效的 ICOM WLAN IP 和端口") }
            var value = root["icomWlan"]?.objectValue ?? [:]
            value["ip"] = .string(icomIP)
            value["port"] = .number(Double(port))
            setString(icomUsername, key: "userName", in: &value)
            setString(icomPassword, key: "password", in: &value)
            value["dataMode"] = .bool(icomDataMode)
            root["icomWlan"] = .object(value)
        case "tci":
            guard let port = validPort(tciPort), !tciHost.isEmpty else { throw profileError("请填写有效的 TCI 主机和端口") }
            var value = root["tci"]?.objectValue ?? [:]
            value["host"] = .string(tciHost)
            value["port"] = .number(Double(port))
            value["receiver"] = .number(Double(Int(tciReceiver) ?? 0))
            value["trx"] = .number(Double(Int(tciTRX) ?? 0))
            value["vfo"] = .number(Double(Int(tciVFO) ?? 0))
            value["audioEnabled"] = .bool(tciAudioEnabled)
            value["audioSampleRate"] = .number(Double(Int(tciSampleRate) ?? 12_000))
            root["tci"] = .object(value)
        default:
            break
        }
        root["pttMethod"] = .string(pttMethod)
        root["digitalModeRadioMode"] = .string(digitalMode)
        root["transmitCompensationMs"] = .number(Double(min(1_000, max(-1_000, Int(transmitCompensation) ?? 0))))
        root["fakeFrequency"] = .object(["enabled": .bool(fakeFrequencyEnabled)])
        return .object(root)
    }

    private func buildAudioJSON() throws -> JSONValue {
        guard var root = try JSONValue.parse(rawAudioJSON).objectValue else {
            throw profileError("Audio JSON 顶层必须是对象")
        }
        setString(inputDeviceName, key: "inputDeviceName", in: &root)
        setString(outputDeviceName, key: "outputDeviceName", in: &root)
        setNumber(inputSampleRate, key: "inputSampleRate", in: &root)
        setNumber(outputSampleRate, key: "outputSampleRate", in: &root)
        setNumber(inputBufferSize, key: "inputBufferSize", in: &root)
        setNumber(outputBufferSize, key: "outputBufferSize", in: &root)
        root["outputSampleFormat"] = .string(outputSampleFormat)
        root["outputChannelMode"] = .string(outputChannelMode)
        root["inputSignalType"] = .string(inputSignalType)
        return .object(root)
    }

    private func setString(_ value: String, key: String, in object: inout [String: JSONValue]) {
        if value.isEmpty { object[key] = nil }
        else { object[key] = .string(value) }
    }

    private func setNumber(_ value: String, key: String, in object: inout [String: JSONValue]) {
        if let number = Double(value), number > 0 { object[key] = .number(number) }
        else { object[key] = nil }
    }

    private func validPort(_ value: String) -> Int? {
        guard let port = Int(value), (1...65_535).contains(port) else { return nil }
        return port
    }

    private func profileError(_ message: String) -> NSError {
        NSError(domain: "TX5DRProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
