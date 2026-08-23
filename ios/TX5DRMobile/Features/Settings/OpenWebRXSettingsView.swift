import SwiftUI

struct OpenWebRXSettingsView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var editorTarget: OpenWebRXEditorTarget?
    @State private var listenStation: OpenWebRXStation?
    @State private var testingStationId: String?
    @State private var testPresentation: OpenWebRXTestPresentation?
    @State private var pendingDelete: OpenWebRXStation?

    var body: some View {
        List {
            Section {
                Text("管理 TX-5DR 使用的 OpenWebRX SDR 站点，并通过独立的实时音频通道试听。")
                    .font(.subheadline)
                    .foregroundStyle(RadioPalette.muted)
                LabeledContent("远端客户端", value: "\(radio.openWebRXClientCount)")
                if let cooldownUntil = radio.openWebRXCooldownUntil, cooldownUntil > Date() {
                    LabeledContent("Profile 冷却至") {
                        Text(cooldownUntil, style: .timer)
                            .foregroundStyle(RadioPalette.warning)
                    }
                }
            }

            Section("站点") {
                if session.openWebRXStations.isEmpty {
                    ContentUnavailableView(
                        "尚未配置站点",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("添加 OpenWebRX WebSocket 地址后即可测试和试听。")
                    )
                }

                ForEach(session.openWebRXStations) { station in
                    stationRow(station)
                }
            }

            if let status = session.openWebRXListenStatus, status.isListening {
                Section("当前试听") {
                    LabeledContent("站点", value: stationName(status.stationId))
                    LabeledContent("连接") {
                        Label(status.connected ? "已连接" : "已断开", systemImage: status.connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(status.connected ? RadioPalette.accent : RadioPalette.transmit)
                    }
                    if let frequency = status.frequency {
                        LabeledContent("频率", value: String(format: "%.6f MHz", frequency / 1_000_000))
                    }
                    Button(role: .destructive) {
                        Task { await session.stopOpenWebRXListen() }
                    } label: {
                        Label("停止 OpenWebRX 试听", systemImage: "stop.fill")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("OpenWebRX")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        await session.refreshOpenWebRXStations()
                        await session.refreshOpenWebRXListenStatus()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button {
                    editorTarget = OpenWebRXEditorTarget(station: nil)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await session.refreshOpenWebRXStations()
            await session.refreshOpenWebRXListenStatus()
        }
        .sheet(item: $editorTarget) { target in
            OpenWebRXStationEditorView(station: target.station)
        }
        .sheet(item: $listenStation) { station in
            OpenWebRXListenView(station: station, previewAudio: session.openWebRXAudio)
        }
        .alert(item: $testPresentation) { presentation in
            Alert(
                title: Text(presentation.result.success ? "连接成功" : "连接失败"),
                message: Text(presentation.message),
                dismissButton: .default(Text("好"))
            )
        }
        .confirmationDialog(
            "删除 OpenWebRX 站点？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { station in
            Button("删除 \(station.name)", role: .destructive) {
                Task { await session.deleteOpenWebRXStation(station) }
            }
        } message: { station in
            Text("此操作只删除 TX-5DR 中保存的站点配置，不会修改远端 OpenWebRX。\n\(station.url)")
        }
    }

    private func stationRow(_ station: OpenWebRXStation) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isListening(station) ? RadioPalette.accent.opacity(0.18) : RadioPalette.panelRaised)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(isListening(station) ? RadioPalette.accent : RadioPalette.cyan)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(station.name)
                        .font(.headline)
                    if isListening(station) {
                        Text("试听中")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(RadioPalette.accent)
                    }
                }
                Text(station.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(RadioPalette.muted)
                    .lineLimit(1)
                if let description = station.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if testingStationId == station.id {
                ProgressView()
                    .tint(RadioPalette.accent)
            } else {
                Menu {
                    Button {
                        test(station)
                    } label: {
                        Label("测试连接", systemImage: "network")
                    }
                    Button {
                        listenStation = station
                    } label: {
                        Label(isListening(station) ? "打开试听控制" : "开始试听", systemImage: "headphones")
                    }
                    Button {
                        editorTarget = OpenWebRXEditorTarget(station: station)
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDelete = station
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { listenStation = station }
    }

    private func test(_ station: OpenWebRXStation) {
        testingStationId = station.id
        Task {
            let result = await session.testOpenWebRX(url: station.url)
            testingStationId = nil
            if let result {
                testPresentation = OpenWebRXTestPresentation(stationName: station.name, result: result)
            }
        }
    }

    private func isListening(_ station: OpenWebRXStation) -> Bool {
        session.openWebRXListenStatus?.stationId == station.id && session.openWebRXListenStatus?.isListening == true
    }

    private func stationName(_ id: String) -> String {
        session.openWebRXStations.first { $0.id == id }?.name ?? id
    }
}

private struct OpenWebRXEditorTarget: Identifiable {
    let id = UUID()
    let station: OpenWebRXStation?
}

private struct OpenWebRXTestPresentation: Identifiable {
    let id = UUID()
    let stationName: String
    let result: OpenWebRXTestResult

    var message: String {
        if result.success {
            let version = result.serverVersion.map { "版本 \($0)" } ?? "版本未知"
            return "\(stationName) 已连接，\(version)，发现 \(result.profiles?.count ?? 0) 个 Profile。"
        }
        return result.error ?? "OpenWebRX 返回未知错误"
    }
}

private struct OpenWebRXStationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: TX5DRSession
    let station: OpenWebRXStation?
    @State private var name: String
    @State private var url: String
    @State private var stationDescription: String
    @State private var isTesting = false
    @State private var testResult: OpenWebRXTestResult?

    init(station: OpenWebRXStation?) {
        self.station = station
        _name = State(initialValue: station?.name ?? "")
        _url = State(initialValue: station?.url ?? "ws://")
        _stationDescription = State(initialValue: station?.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("站点") {
                    TextField("名称", text: $name)
                    TextField("ws://host:8073", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("说明（可选）", text: $stationDescription, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Button {
                        isTesting = true
                        testResult = nil
                        Task {
                            testResult = await session.testOpenWebRX(url: url)
                            isTesting = false
                        }
                    } label: {
                        HStack {
                            Label("测试连接", systemImage: "network")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                    if let testResult {
                        Label(
                            testResult.success
                                ? "连接成功，发现 \(testResult.profiles?.count ?? 0) 个 Profile"
                                : (testResult.error ?? "连接失败"),
                            systemImage: testResult.success ? "checkmark.circle.fill" : "xmark.octagon.fill"
                        )
                        .foregroundStyle(testResult.success ? RadioPalette.accent : RadioPalette.transmit)
                    }
                }
            }
            .navigationTitle(station == nil ? "添加 OpenWebRX" : "编辑 OpenWebRX")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave || session.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(session.isWorking)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        Task {
            let description = stationDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let success: Bool
            if let station {
                success = await session.updateOpenWebRXStation(
                    id: station.id,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description.isEmpty ? nil : description
                )
            } else {
                success = await session.addOpenWebRXStation(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description.isEmpty ? nil : description
                )
            }
            if success { dismiss() }
        }
    }
}

private struct OpenWebRXListenView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: TX5DRSession
    let station: OpenWebRXStation
    @ObservedObject var previewAudio: TX5DRAudioClient
    @State private var profiles: [OpenWebRXProfile] = []
    @State private var selectedProfileId = ""
    @State private var frequency = "14074000"
    @State private var modulation = "usb"
    @State private var bandpassLow = ""
    @State private var bandpassHigh = ""
    @State private var isLoadingProfiles = false
    @State private var profileError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    LabeledContent("站点", value: station.name)
                    LabeledContent("服务器", value: activeStatus?.serverVersion ?? "—")
                    LabeledContent("状态") {
                        Label(
                            activeStatus?.connected == true ? "已连接" : (isActive ? "连接中" : "未试听"),
                            systemImage: activeStatus?.connected == true ? "checkmark.circle.fill" : "circle.dotted"
                        )
                        .foregroundStyle(activeStatus?.connected == true ? RadioPalette.accent : RadioPalette.warning)
                    }
                    LabeledContent("音频", value: previewAudio.listeningState.label)
                    if let smeter = activeStatus?.smeterDb {
                        LabeledContent("S-Meter", value: String(format: "%.1f dBFS", smeter))
                    }
                }

                Section("接收参数") {
                    if isLoadingProfiles {
                        HStack {
                            ProgressView()
                            Text("读取 Profile…")
                        }
                    } else {
                        Picker("Profile", selection: $selectedProfileId) {
                            Text("请选择").tag("")
                            ForEach(profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }

                    TextField("频率（Hz）", text: $frequency)
                        .keyboardType(.numberPad)
                    if let hz = parsedFrequency {
                        Text(String(format: "%.6f MHz", hz / 1_000_000))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(RadioPalette.muted)
                    }

                    Picker("调制", selection: $modulation) {
                        ForEach(["usb", "lsb", "am", "fm", "cw"], id: \.self) { value in
                            Text(value.uppercased()).tag(value)
                        }
                    }

                    DisclosureGroup("带通滤波器（可选）") {
                        TextField("低端 Hz", text: $bandpassLow)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("高端 Hz", text: $bandpassHigh)
                            .keyboardType(.numbersAndPunctuation)
                    }

                    if let profileError {
                        Label(profileError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(RadioPalette.warning)
                    }
                }

                if let status = activeStatus {
                    Section("信号") {
                        if let center = status.centerFreq {
                            LabeledContent("中心频率", value: String(format: "%.6f MHz", center / 1_000_000))
                        }
                        if let rate = status.sampleRate {
                            LabeledContent("采样带宽", value: String(format: "%.0f kHz", rate / 1_000))
                        }
                        if let error = status.error {
                            Label(error, systemImage: "xmark.octagon.fill")
                                .foregroundStyle(RadioPalette.transmit)
                        }
                    }
                }

                Section {
                    if isActive {
                        Button {
                            applyTune()
                        } label: {
                            Label("应用调谐", systemImage: "dial.medium")
                        }
                        .disabled(parsedFrequency == nil || session.isWorking)

                        if previewAudio.listeningState == .stopped || isAudioFailed {
                            Button {
                                Task { _ = await session.connectOpenWebRXPreviewAudio() }
                            } label: {
                                Label("重新连接试听音频", systemImage: "speaker.wave.2.fill")
                            }
                        }

                        Button(role: .destructive) {
                            Task {
                                await session.stopOpenWebRXListen()
                                dismiss()
                            }
                        } label: {
                            Label("停止试听", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            startListen()
                        } label: {
                            Label("开始试听", systemImage: "play.fill")
                        }
                        .disabled(selectedProfileId.isEmpty || parsedFrequency == nil || session.isWorking)
                    }
                }
            }
            .navigationTitle("OpenWebRX 试听")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await loadProfiles() }
        .task(id: isActive) {
            while !Task.isCancelled && isActive {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await session.refreshOpenWebRXListenStatus()
            }
        }
        .onChange(of: session.openWebRXListenStatus) { _, status in
            guard status?.stationId == station.id else { return }
            if let profileId = status?.currentProfileId { selectedProfileId = profileId }
            if let value = status?.frequency { frequency = String(Int(value.rounded())) }
            if let value = status?.modulation { modulation = value }
            if let serverProfiles = status?.profiles, !serverProfiles.isEmpty { profiles = serverProfiles }
        }
    }

    private var activeStatus: OpenWebRXListenStatus? {
        guard session.openWebRXListenStatus?.stationId == station.id else { return nil }
        return session.openWebRXListenStatus
    }

    private var isActive: Bool { activeStatus?.isListening == true }

    private var isAudioFailed: Bool {
        if case .failed = previewAudio.listeningState { return true }
        return false
    }

    private var parsedFrequency: Double? {
        guard let value = Double(frequency), value > 0 else { return nil }
        return value
    }

    private func loadProfiles() async {
        if let status = activeStatus {
            profiles = status.profiles
            selectedProfileId = status.currentProfileId ?? profiles.first?.id ?? ""
            if let value = status.frequency { frequency = String(Int(value.rounded())) }
            if let value = status.modulation { modulation = value }
            return
        }

        isLoadingProfiles = true
        defer { isLoadingProfiles = false }
        guard let result = await session.testOpenWebRX(url: station.url) else { return }
        if result.success {
            profiles = result.profiles ?? []
            selectedProfileId = profiles.first?.id ?? ""
            profileError = profiles.isEmpty ? "远端站点没有返回可用 Profile" : nil
        } else {
            profileError = result.error ?? "连接测试失败"
        }
    }

    private func startListen() {
        guard let parsedFrequency else { return }
        Task {
            _ = await session.startOpenWebRXListen(
                stationId: station.id,
                profileId: selectedProfileId,
                frequency: parsedFrequency,
                modulation: modulation
            )
        }
    }

    private func applyTune() {
        Task {
            _ = await session.tuneOpenWebRXListen(
                profileId: selectedProfileId.isEmpty ? nil : selectedProfileId,
                frequency: parsedFrequency,
                modulation: modulation,
                bandpassLow: Double(bandpassLow),
                bandpassHigh: Double(bandpassHigh)
            )
        }
    }
}
