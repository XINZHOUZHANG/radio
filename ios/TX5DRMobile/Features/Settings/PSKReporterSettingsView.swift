import SwiftUI

struct PSKReporterSettingsView: View {
    @EnvironmentObject private var session: TX5DRSession

    @State private var enabled = false
    @State private var receiverCallsign = ""
    @State private var receiverLocator = ""
    @State private var antennaInformation = ""
    @State private var reportIntervalSeconds = 30
    @State private var useTestServer = false
    @State private var originalUpdate: PSKReporterConfigUpdate?
    @State private var showResetConfirmation = false

    private let intervalOptions = [10, 15, 30, 60]

    var body: some View {
        Form {
            if let config = session.pskReporterConfig {
                enablementSection(config: config)

                if enabled {
                    identitySection(config: config)
                    statusSection(config: config)
                    deliverySection(config: config)
                    actionsSection
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取 PSK Reporter 配置…")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("PSK Reporter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await session.loadPSKReporter() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(session.isWorking)

                Button("保存") {
                    save()
                }
                .disabled(!canSave || session.isWorking)
            }
        }
        .refreshable { await session.loadPSKReporter() }
        .task {
            if session.pskReporterConfig == nil {
                await session.loadPSKReporter()
            }
            if let config = session.pskReporterConfig {
                apply(config, force: originalUpdate == nil)
            }
        }
        .task(id: session.pskReporterConfig?.enabled) {
            guard session.pskReporterConfig?.enabled == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await session.refreshPSKReporterStatus()
            }
        }
        .onChange(of: session.pskReporterConfig) { _, config in
            guard let config else { return }
            apply(config)
        }
        .confirmationDialog(
            "重置 PSK Reporter 统计？",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("重置统计", role: .destructive) {
                Task { await session.resetPSKReporterStats() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("今日数量、总数量、连续失败和最后上报记录都会清零。")
        }
    }

    private func enablementSection(config: PSKReporterConfig) -> some View {
        Section {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用自动上报")
                    Text("把 TX-5DR 解码到的 FT8 / FT4 信号发送到 PSK Reporter")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                }
            }

            if enabled {
                LabeledContent("配置") {
                    Label(
                        status?.configValid == true ? "有效" : "不完整",
                        systemImage: status?.configValid == true
                            ? "checkmark.seal.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(status?.configValid == true ? RadioPalette.accent : RadioPalette.warning)
                }
                LabeledContent("解码软件", value: config.decodingSoftware)
            }
        } header: {
            Text("上报服务")
        } footer: {
            Text("配置修改只会在点击“保存”后发送到 TX-5DR。")
        }
    }

    private func identitySection(config: PSKReporterConfig) -> some View {
        Section("接收站身份") {
            TextField("接收呼号", text: $receiverCallsign)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: receiverCallsign) { _, value in
                    receiverCallsign = value.uppercased()
                }

            TextField("网格，例如 PL05 或 PL05QB", text: $receiverLocator)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: receiverLocator) { _, value in
                    receiverLocator = value.uppercased()
                }

            if !callsignIsValid {
                validationMessage("呼号格式无效，例如 BG2TEST 或 BG2TEST/P。")
            }
            if !locatorIsValid {
                validationMessage("网格必须是 4 或 6 位 Maidenhead 定位，例如 PL05 或 PL05QB。")
            }
            if identityUsesOperatorFallback {
                Label(
                    "呼号和网格需要同时填写；否则 TX-5DR 会使用第一个操作员的身份。",
                    systemImage: "info.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(RadioPalette.warning)
            } else if receiverCallsign.isEmpty && receiverLocator.isEmpty {
                Text(activeIdentityDescription(config: config))
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
        }
    }

    private func statusSection(config: PSKReporterConfig) -> some View {
        Section("运行状态") {
            LabeledContent("状态") {
                HStack(spacing: 6) {
                    if status?.isReporting == true {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(status?.isReporting == true ? "正在上报" : "等待")
                }
            }
            LabeledContent("有效呼号", value: status?.activeCallsign ?? "—")
            LabeledContent("有效网格", value: status?.activeLocator ?? "—")
            LabeledContent("待上报", value: "\(status?.pendingSpots ?? 0) 条")
            LabeledContent("今日已上报", value: "\(config.stats.todayReportCount) 条")
            LabeledContent("累计已上报", value: "\(config.stats.totalReportCount) 条")
            LabeledContent("连续失败", value: "\(config.stats.consecutiveFailures) 次")
            LabeledContent("最后上报", value: formattedReportTime(status?.lastReportTime ?? config.stats.lastReportTime))
            LabeledContent("下次上报", value: formattedNextReport(status?.nextReportIn))

            if let error = status?.lastError ?? config.stats.lastError, !error.isEmpty {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.transmit)
                    .textSelection(.enabled)
            }
        }
    }

    private func deliverySection(config: PSKReporterConfig) -> some View {
        Section("上报参数") {
            TextField("天线信息（可选）", text: $antennaInformation, axis: .vertical)
                .lineLimit(2...4)
                .onChange(of: antennaInformation) { _, value in
                    if value.count > 64 {
                        antennaInformation = String(value.prefix(64))
                    }
                }

            Picker("上报间隔", selection: $reportIntervalSeconds) {
                ForEach(intervalOptions, id: \.self) { seconds in
                    Text("\(seconds) 秒").tag(seconds)
                }
            }

            Toggle("使用测试服务器", isOn: $useTestServer)
                .tint(RadioPalette.warning)

            if useTestServer {
                Label("测试服务器仅用于调试，不会进入正式 PSK Reporter 数据流。", systemImage: "testtube.2")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.warning)
            }

            Text("天线信息 \(antennaInformation.count)/64 字符")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await session.sendPendingPSKReporterSpots() }
            } label: {
                Label("立即上报待处理信号", systemImage: "paperplane.fill")
            }
            .disabled(
                session.isWorking
                    || status?.enabled != true
                    || status?.configValid != true
            )

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label("重置上报统计", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(session.isWorking)
        } footer: {
            Text("“立即上报”调用 TX-5DR 自带的 UDP/IPFIX 上报服务，不会绕过服务端。")
        }
    }

    @ViewBuilder
    private func validationMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(RadioPalette.transmit)
    }

    private var status: PSKReporterStatus? { session.pskReporterStatus }

    private var currentUpdate: PSKReporterConfigUpdate {
        PSKReporterConfigUpdate(
            enabled: enabled,
            receiverCallsign: receiverCallsign.trimmingCharacters(in: .whitespacesAndNewlines),
            receiverLocator: receiverLocator.trimmingCharacters(in: .whitespacesAndNewlines),
            antennaInformation: antennaInformation.trimmingCharacters(in: .whitespacesAndNewlines),
            reportIntervalSeconds: reportIntervalSeconds,
            useTestServer: useTestServer
        )
    }

    private var hasChanges: Bool {
        guard let originalUpdate else { return false }
        return currentUpdate != originalUpdate
    }

    private var canSave: Bool {
        hasChanges && callsignIsValid && locatorIsValid && antennaInformation.count <= 64
    }

    private var callsignIsValid: Bool {
        let value = receiverCallsign.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.range(
            of: "^[A-Z0-9]{1,10}(/[A-Z0-9]{1,4})?$",
            options: .regularExpression
        ) != nil
    }

    private var locatorIsValid: Bool {
        let value = receiverLocator.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.range(
            of: "^[A-R]{2}[0-9]{2}([A-X]{2})?$",
            options: .regularExpression
        ) != nil
    }

    private var identityUsesOperatorFallback: Bool {
        receiverCallsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            != receiverLocator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func activeIdentityDescription(config: PSKReporterConfig) -> String {
        if let callsign = status?.activeCallsign, !callsign.isEmpty {
            return "留空时使用操作员身份：\(callsign) @ \(status?.activeLocator ?? "未设置网格")"
        }
        return "留空时 TX-5DR 会使用第一个操作员的呼号和网格。当前配置：\(config.receiverCallsign.isEmpty ? "自动" : config.receiverCallsign)。"
    }

    private func apply(_ config: PSKReporterConfig, force: Bool = false) {
        if !force, let originalUpdate, currentUpdate != originalUpdate {
            return
        }
        enabled = config.enabled
        receiverCallsign = config.receiverCallsign
        receiverLocator = config.receiverLocator
        antennaInformation = config.antennaInformation
        reportIntervalSeconds = config.reportIntervalSeconds
        useTestServer = config.useTestServer
        originalUpdate = currentUpdate
    }

    private func save() {
        let update = currentUpdate
        Task {
            guard await session.updatePSKReporter(update), let config = session.pskReporterConfig else { return }
            apply(config, force: true)
        }
    }

    private func formattedReportTime(_ timestamp: Double?) -> String {
        guard let timestamp, timestamp > 0 else { return "—" }
        return Date(timeIntervalSince1970: timestamp / 1_000).formatted(
            date: .abbreviated,
            time: .standard
        )
    }

    private func formattedNextReport(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "即将上报" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes) 分 \(remainder) 秒" : "\(remainder) 秒"
    }
}
