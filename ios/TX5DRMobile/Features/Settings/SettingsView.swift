import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket

    var body: some View {
        List {
            Section("当前连接") {
                LabeledContent("服务器", value: session.serverAddress)
                LabeledContent("账户", value: session.currentUser?.label ?? "—")
                LabeledContent("角色", value: roleName)
                LabeledContent("控制通道") {
                    Text(radio.state.label)
                        .foregroundStyle(radio.state == .ready ? RadioPalette.accent : RadioPalette.warning)
                }
            }

            Section("电台服务") {
                Button { radio.startEngine() } label: {
                    Label("启动 TX-5DR 引擎", systemImage: "play.fill")
                }
                Button { radio.stopEngine() } label: {
                    Label("停止 TX-5DR 引擎", systemImage: "stop.fill")
                }
                Button { radio.reconnectRadio() } label: {
                    Label("重新连接电台", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button { radio.retryAudio() } label: {
                    Label("重试服务端音频设备", systemImage: "waveform.badge.exclamationmark")
                }
                Button(role: .destructive) { session.forceStopTransmission() } label: {
                    Label("强制停止所有发射", systemImage: "stop.circle.fill")
                }
            }

            Section("控制与配置") {
                NavigationLink {
                    OperatorsView()
                } label: {
                    Label("操作员与 FT8 身份", systemImage: "person.wave.2")
                }
                NavigationLink {
                    DynamicCapabilitiesView()
                } label: {
                    Label("全部电台能力", systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    Label("TX-5DR 服务端设置", systemImage: "server.rack")
                }
                NavigationLink {
                    ProtocolConsoleView()
                } label: {
                    Label("协议控制台", systemImage: "terminal")
                }
            }

            if session.isAdmin {
                Section("管理") {
                    NavigationLink {
                        AccountsView()
                    } label: {
                        Label("账户与 6 位配对", systemImage: "person.2.badge.gearshape")
                    }
                }
            }

            Section {
                Button(role: .destructive) { session.logout() } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var roleName: String {
        switch session.currentUser?.role {
        case .admin: "管理员"
        case .operator: "操作员"
        case .viewer: "观察员（不受支持）"
        case nil: "—"
        }
    }
}

private struct DynamicCapabilitiesView: View {
    @EnvironmentObject private var radio: RadioWebSocket

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(categories, id: \.self) { category in
                    RadioPanel {
                        VStack(alignment: .leading, spacing: 13) {
                            Text(categoryName(category))
                                .font(.headline)
                            ForEach(descriptors(in: category)) { descriptor in
                                CapabilityControlRow(descriptor: descriptor, state: radio.capabilities[descriptor.id])
                                if descriptor.id != descriptors(in: category).last?.id { Divider().opacity(0.25) }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("电台能力")
        .toolbar {
            Button { radio.refreshCapabilities() } label: { Image(systemName: "arrow.clockwise") }
        }
    }

    private var categories: [String] {
        Array(Set(radio.capabilityDescriptors.map(\.category))).sorted()
    }

    private func descriptors(in category: String) -> [CapabilityDescriptor] {
        radio.capabilityDescriptors.filter { $0.category == category && $0.supported(in: radio.capabilities) }
    }

    private func categoryName(_ value: String) -> String {
        ["antenna": "天线", "rf": "射频", "audio": "音频", "operation": "操作", "system": "系统"][value] ?? value
    }
}

private extension CapabilityDescriptor {
    func supported(in states: [String: CapabilityState]) -> Bool {
        states[id]?.supported == true
    }
}
