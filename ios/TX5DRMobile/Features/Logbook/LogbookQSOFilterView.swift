import SwiftUI

struct LogbookQSOFilterView: View {
    @Environment(\.dismiss) private var dismiss

    let initialQuery: LogbookQSOQuery
    let onApply: (LogbookQSOQuery) -> Void

    @State private var draft: LogbookQSOQuery
    @State private var useStartDate: Bool
    @State private var useEndDate: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var validationError: String?

    init(initialQuery: LogbookQSOQuery, onApply: @escaping (LogbookQSOQuery) -> Void) {
        self.initialQuery = initialQuery
        self.onApply = onApply
        let parsedStart = Self.parseDate(initialQuery.startDate)
        let parsedEnd = Self.parseDate(initialQuery.endDate)
        _draft = State(initialValue: initialQuery)
        _useStartDate = State(initialValue: parsedStart != nil)
        _useEndDate = State(initialValue: parsedEnd != nil)
        _startDate = State(initialValue: parsedStart ?? Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date())
        _endDate = State(initialValue: parsedEnd ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("目标") {
                    TextField("呼号", text: optionalBinding(\.callsign))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("网格（2–8 位）", text: optionalBinding(\.grid))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("频段", selection: optionalBinding(\.band)) {
                        Text("全部频段").tag("")
                        ForEach(Self.bands, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("模式", selection: optionalBinding(\.mode)) {
                        Text("全部模式").tag("")
                        ForEach(Self.modes, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("排除模式（逗号分隔）", text: optionalBinding(\.excludeModes))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("日期范围") {
                    Toggle("限制开始日期", isOn: $useStartDate)
                    if useStartDate {
                        DatePicker("开始", selection: $startDate, displayedComponents: .date)
                    }
                    Toggle("限制结束日期", isOn: $useEndDate)
                    if useEndDate {
                        DatePicker("结束", selection: $endDate, displayedComponents: .date)
                    }
                }

                Section("确认与 DXCC") {
                    Picker("QSL 状态", selection: optionalBinding(\.qslStatus)) {
                        Text("全部").tag("")
                        Text("未确认").tag("none")
                        Text("已确认").tag("confirmed")
                        Text("已上传").tag("uploaded")
                    }
                    Picker("双向确认", selection: optionalBinding(\.qslFlow)) {
                        Text("全部").tag("")
                        Text("双向已确认").tag("two_way_confirmed")
                        Text("尚未双向确认").tag("not_two_way_confirmed")
                    }
                    Picker("DXCC 状态", selection: optionalBinding(\.dxccStatus)) {
                        Text("全部").tag("")
                        Text("已删除实体").tag("deleted")
                    }
                }

                Section("分页") {
                    Picker("每页记录", selection: $draft.limit) {
                        ForEach([25, 50, 100, 200], id: \.self) { value in
                            Text("\(value) 条").tag(value)
                        }
                    }
                }
            }
            .navigationTitle("日志筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("重置") { reset() }
                    Button("应用") { apply() }
                        .fontWeight(.semibold)
                }
            }
            .alert("日期范围无效", isPresented: Binding(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("好") { validationError = nil }
            } message: {
                Text(validationError ?? "")
            }
        }
        .presentationDetents([.large])
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<LogbookQSOQuery, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func reset() {
        let pageSize = draft.limit
        draft = LogbookQSOQuery()
        draft.limit = pageSize
        useStartDate = false
        useEndDate = false
    }

    private func apply() {
        if useStartDate, useEndDate,
           Calendar.current.startOfDay(for: endDate) < Calendar.current.startOfDay(for: startDate) {
            validationError = "结束日期不能早于开始日期。"
            return
        }

        draft.callsign = normalized(draft.callsign, uppercase: true)
        draft.grid = normalized(draft.grid, uppercase: true)
        draft.excludeModes = normalized(draft.excludeModes, uppercase: true)
        draft.startDate = useStartDate ? Self.formatDate(startDate) : nil
        draft.endDate = useEndDate ? Self.formatDate(endDate) : nil
        draft.offset = 0
        onApply(draft)
        dismiss()
    }

    private func normalized(_ value: String?, uppercase: Bool) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clean.isEmpty else { return nil }
        return uppercase ? clean.uppercased() : clean
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return dateFormatter.date(from: value)
    }

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static let modes = ["FT8", "FT4", "SSB", "USB", "LSB", "AM", "FM", "CW", "RTTY", "PSK31", "JS8", "MSK144"]
    private static let bands = ["160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m", "4m", "2m", "1.25m", "70cm", "33cm", "23cm"]
}
