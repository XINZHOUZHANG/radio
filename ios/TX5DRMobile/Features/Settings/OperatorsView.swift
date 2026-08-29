import SwiftUI

struct OperatorsView: View {
    @EnvironmentObject private var session: TX5DRSession
    @State private var showingCreate = false

    var body: some View {
        List {
            if session.operators.isEmpty {
                ContentUnavailableView(
                    "还没有操作员",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("FT8、语音 PTT 与 CW 发射都需要操作员身份。")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(session.operators) { configuration in
                        HStack(spacing: 12) {
                            Button {
                                session.selectOperator(configuration.id)
                            } label: {
                                Image(systemName: session.selectedOperatorId == configuration.id ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(session.selectedOperatorId == configuration.id ? RadioPalette.accent : RadioPalette.muted)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(configuration.myCallsign)
                                    .font(.headline.monospaced())
                                Text(summary(configuration))
                                    .font(.caption)
                                    .foregroundStyle(RadioPalette.muted)
                            }
                            Spacer()
                            NavigationLink {
                                OperatorEditorView(configuration: configuration)
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundStyle(RadioPalette.cyan)
                            }
                            .buttonStyle(.plain)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await session.deleteOperator(id: configuration.id) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("绿色勾选表示 App 当前使用的身份。删除操作员前请先停止其自动呼叫和发射。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("操作员")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                OperatorEditorView(configuration: nil)
            }
            .environmentObject(session)
        }
    }

    private func summary(_ configuration: RadioOperatorConfig) -> String {
        let grid = configuration.myGrid?.isEmpty == false ? configuration.myGrid! : "无网格"
        let mode = configuration.mode?.name ?? "FT8"
        let cycle = configuration.transmitCycles.first == 1 ? "奇数时隙" : "偶数时隙"
        return "\(grid) · \(mode) · \(Int(configuration.frequency)) Hz · \(cycle)"
    }
}

private struct OperatorEditorView: View {
    @EnvironmentObject private var session: TX5DRSession
    @Environment(\.dismiss) private var dismiss

    let configuration: RadioOperatorConfig?
    @State private var callsign: String
    @State private var grid: String
    @State private var audioFrequency: String
    @State private var transmitCycle: Int
    @State private var modeName: String
    @State private var validationError: String?

    init(configuration: RadioOperatorConfig?) {
        self.configuration = configuration
        _callsign = State(initialValue: configuration?.myCallsign ?? "")
        _grid = State(initialValue: configuration?.myGrid ?? "")
        _audioFrequency = State(initialValue: String(Int(configuration?.frequency ?? 1_500)))
        _transmitCycle = State(initialValue: configuration?.transmitCycles.first == 1 ? 1 : 0)
        _modeName = State(initialValue: configuration?.mode?.name ?? "FT8")
    }

    var body: some View {
        Form {
            Section("台站身份") {
                TextField("呼号，例如 BG1ABC", text: $callsign)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("网格，例如 OM89", text: $grid)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section("数字模式") {
                Picker("模式", selection: $modeName) {
                    ForEach(digitalModes) { mode in
                        Text(mode.name).tag(mode.name)
                    }
                }
                TextField("音频频率（Hz）", text: $audioFrequency)
                    .keyboardType(.numberPad)
                Picker("发射时隙", selection: $transmitCycle) {
                    Text("偶数 / 第一时隙").tag(0)
                    Text("奇数 / 第二时隙").tag(1)
                }
            }

            Section {
                Text("这里的频率是瀑布图内的音频偏移，不是电台射频频率。常用范围为 500–3000 Hz。")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle(configuration == nil ? "新建操作员" : "编辑操作员")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if configuration == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await save() } }
                    .disabled(session.isWorking)
            }
        }
        .alert("无法保存", isPresented: Binding(
            get: { validationError != nil },
            set: { if !$0 { validationError = nil } }
        )) {
            Button("好") { validationError = nil }
        } message: {
            Text(validationError ?? "输入无效")
        }
    }

    private var digitalModes: [ModeDescriptor] {
        let advertised = session.availableModes.filter { ["FT8", "FT4"].contains($0.name.uppercased()) }
        return advertised.isEmpty ? [.ft8, .ft4] : advertised
    }

    private func save() async {
        let normalizedCallsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedGrid = grid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedCallsign.isEmpty else {
            validationError = "请输入呼号"
            return
        }
        guard let frequency = Double(audioFrequency), (0...4_000).contains(frequency) else {
            validationError = "音频频率必须在 0–4000 Hz 之间"
            return
        }
        let selectedMode = digitalModes.first { $0.name == modeName } ?? .ft8
        let request = SaveRadioOperatorRequest(
            myCallsign: normalizedCallsign,
            myGrid: normalizedGrid.isEmpty ? nil : normalizedGrid,
            frequency: frequency,
            transmitCycles: [Double(transmitCycle)],
            mode: selectedMode,
            logBookId: configuration?.logBookId
        )
        let saved: Bool
        if let configuration {
            saved = await session.updateOperator(id: configuration.id, request: request)
        } else {
            saved = await session.createOperator(request)
        }
        if saved { dismiss() }
    }
}
