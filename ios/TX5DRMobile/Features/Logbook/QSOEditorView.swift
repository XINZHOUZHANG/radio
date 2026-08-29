import SwiftUI

struct QSOEditorView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @Environment(\.dismiss) private var dismiss

    let qso: QSORecord?

    @State private var callsign: String
    @State private var grid: String
    @State private var myCallsign: String
    @State private var myGrid: String
    @State private var frequencyMHz: String
    @State private var mode: String
    @State private var startTime: Date
    @State private var hasEndTime: Bool
    @State private var endTime: Date
    @State private var reportSent: String
    @State private var reportReceived: String
    @State private var qth: String
    @State private var comment: String
    @State private var notes: String
    @State private var lotwSent: Bool
    @State private var lotwReceived: Bool
    @State private var qrzSent: Bool
    @State private var qrzReceived: Bool
    @State private var saving = false
    @State private var seededFromRadio = false

    init(qso: QSORecord?) {
        self.qso = qso
        _callsign = State(initialValue: qso?.callsign ?? "")
        _grid = State(initialValue: qso?.grid ?? "")
        _myCallsign = State(initialValue: qso?.myCallsign ?? "")
        _myGrid = State(initialValue: qso?.myGrid ?? "")
        _frequencyMHz = State(initialValue: qso.map { String(format: "%.6f", $0.frequency / 1_000_000) } ?? "14.074000")
        _mode = State(initialValue: qso?.submode ?? qso?.mode ?? "FT8")
        _startTime = State(initialValue: qso.map { Self.date(from: $0.startTime) } ?? Date())
        _hasEndTime = State(initialValue: qso?.endTime != nil)
        let initialEndTime = qso.flatMap { $0.endTime }.map { Self.date(from: $0) } ?? Date()
        _endTime = State(initialValue: initialEndTime)
        _reportSent = State(initialValue: qso?.reportSent ?? "")
        _reportReceived = State(initialValue: qso?.reportReceived ?? "")
        _qth = State(initialValue: qso?.qth ?? "")
        _comment = State(initialValue: qso?.comment ?? qso?.notes ?? qso?.messageHistory.joined(separator: " | ") ?? "")
        _notes = State(initialValue: qso?.notes ?? "")
        _lotwSent = State(initialValue: qso?.lotwQslSent == "Y")
        _lotwReceived = State(initialValue: qso?.lotwQslReceived == "Y" || qso?.lotwQslReceived == "V")
        _qrzSent = State(initialValue: qso?.qrzQslSent == "Y")
        _qrzReceived = State(initialValue: qso?.qrzQslReceived == "Y")
    }

    var body: some View {
        Form {
            Section("通联") {
                DatePicker("开始时间", selection: $startTime)
                Toggle("记录结束时间", isOn: $hasEndTime)
                if hasEndTime {
                    DatePicker("结束时间", selection: $endTime, in: startTime...)
                }

                TextField("呼号", text: $callsign)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("网格", text: $grid)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("对方 QTH", text: $qth)
                TextField("频率 MHz", text: $frequencyMHz)
                    .keyboardType(.decimalPad)
                Picker("模式", selection: $mode) {
                    ForEach(Self.modes, id: \.self) { Text($0).tag($0) }
                }
            }

            Section("本站") {
                TextField("我的呼号", text: $myCallsign)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("我的网格", text: $myGrid)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section("信号报告") {
                TextField("发送", text: $reportSent)
                TextField("接收", text: $reportReceived)
            }

            if let qso, hasDXCCData(qso) {
                Section("DXCC 自动分析") {
                    if let entity = qso.dxccEntity { LabeledContent("实体", value: entity) }
                    if let id = qso.dxccId { LabeledContent("DXCC 编号", value: String(id)) }
                    if let status = qso.dxccStatus { LabeledContent("状态", value: status) }
                    if let source = qso.dxccSource { LabeledContent("来源", value: source) }
                    if let confidence = qso.dxccConfidence { LabeledContent("置信度", value: confidence) }
                    if let cqZone = qso.cqZone { LabeledContent("CQ 分区", value: String(cqZone)) }
                    if let ituZone = qso.ituZone { LabeledContent("ITU 分区", value: String(ituZone)) }
                    if let countryCode = qso.countryCode { LabeledContent("国家代码", value: countryCode) }
                    if qso.dxccNeedsReview == true {
                        Label("TX-5DR 标记此记录需要人工复核", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(RadioPalette.warning)
                    }
                }
            }

            Section("QSL 确认") {
                Toggle("LoTW 已上传", isOn: $lotwSent)
                Toggle("LoTW 已确认", isOn: $lotwReceived)
                Toggle("QRZ 已上传", isOn: $qrzSent)
                Toggle("QRZ 已确认", isOn: $qrzReceived)
            }

            Section("备注") {
                TextField("Comment", text: $comment, axis: .vertical)
                    .lineLimit(2...7)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...7)
            }

            if qso != nil {
                Section {
                    Label("保存会重写服务端 ADIF 记录，并通过实时日志通道通知其他客户端。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.warning)
                }
            }
        }
        .navigationTitle(qso == nil ? "补录 QSO" : "编辑 QSO")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中" : "保存") { Task { await save() } }
                    .disabled(!isValid || saving)
            }
        }
        .onAppear { seedNewRecordFromRadio() }
    }

    private var isValid: Bool {
        !callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (Double(frequencyMHz.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0
            && !mode.isEmpty
            && (!hasEndTime || endTime >= startTime)
    }

    private func seedNewRecordFromRadio() {
        guard qso == nil, !seededFromRadio else { return }
        seededFromRadio = true
        if let hz = radio.frequency?.frequency {
            frequencyMHz = String(format: "%.6f", hz / 1_000_000)
        }
        mode = radio.currentMode.name
        myCallsign = session.keyerCallsign ?? myCallsign
        myGrid = session.selectedOperator?.myGrid ?? myGrid
    }

    private func save() async {
        guard let mhz = Double(frequencyMHz.replacingOccurrences(of: ",", with: ".")) else { return }
        saving = true
        defer { saving = false }

        let normalizedCallsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedGrid = clean(grid)?.uppercased()
        let normalizedMyCallsign = clean(myCallsign)?.uppercased()
        let normalizedMyGrid = clean(myGrid)?.uppercased()
        let startMilliseconds = startTime.timeIntervalSince1970 * 1_000
        let endMilliseconds = hasEndTime ? endTime.timeIntervalSince1970 * 1_000 : nil

        if let qso {
            let request = UpdateQSORequest(
                callsign: normalizedCallsign,
                frequency: mhz * 1_000_000,
                mode: mode,
                submode: nil,
                startTime: startMilliseconds,
                endTime: endMilliseconds,
                grid: normalizedGrid,
                qth: clean(qth),
                reportSent: clean(reportSent),
                reportReceived: clean(reportReceived),
                messageHistory: qso.messageHistory,
                comment: clean(comment),
                myCallsign: normalizedMyCallsign,
                myGrid: normalizedMyGrid,
                lotwQslSent: lotwSent ? "Y" : "N",
                lotwQslReceived: lotwReceived ? preservedLoTWReceived(qso) : "N",
                qrzQslSent: qrzSent ? "Y" : "N",
                qrzQslReceived: qrzReceived ? "Y" : "N",
                notes: clean(notes)
            )
            if await session.updateQSO(qso, request: request) { dismiss() }
        } else {
            let request = CreateQSORequest(
                callsign: normalizedCallsign,
                frequency: mhz * 1_000_000,
                mode: mode,
                submode: nil,
                startTime: startMilliseconds,
                endTime: endMilliseconds,
                grid: normalizedGrid,
                qth: clean(qth),
                reportSent: clean(reportSent),
                reportReceived: clean(reportReceived),
                messageHistory: [],
                comment: clean(comment),
                notes: clean(notes)
            )
            if await session.createQSO(request) { dismiss() }
        }
    }

    private func clean(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func preservedLoTWReceived(_ qso: QSORecord) -> String {
        qso.lotwQslReceived == "V" ? "V" : "Y"
    }

    private func hasDXCCData(_ qso: QSORecord) -> Bool {
        qso.dxccId != nil
            || qso.dxccEntity != nil
            || qso.dxccStatus != nil
            || qso.countryCode != nil
            || qso.dxccNeedsReview == true
    }

    private static func date(from timestamp: Double) -> Date {
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }

    private static let modes = ["FT8", "FT4", "SSB", "USB", "LSB", "CW", "AM", "FM", "RTTY", "PSK31", "JS8", "MSK144"]
}
