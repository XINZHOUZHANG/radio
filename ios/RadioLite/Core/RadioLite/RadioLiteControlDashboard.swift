import Foundation

enum RadioLiteControlDashboardCategory: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case rf
    case audio
    case noiseReduction
    case filter
    case tuner
    case modeAndOffset
    case cw
    case repeater
    case spectrumAndDisplay
    case systemAndOther

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rf: "射频"
        case .audio: "音频"
        case .noiseReduction: "降噪"
        case .filter: "滤波器"
        case .tuner: "天调"
        case .modeAndOffset: "模式与频偏"
        case .cw: "CW"
        case .repeater: "中继"
        case .spectrumAndDisplay: "频谱与显示"
        case .systemAndOther: "系统与其他"
        }
    }

    var systemImage: String {
        switch self {
        case .rf: "wave.3.right"
        case .audio: "speaker.wave.2.fill"
        case .noiseReduction: "waveform.path.ecg"
        case .filter: "slider.horizontal.below.rectangle"
        case .tuner: "tuningfork"
        case .modeAndOffset: "dial.medium"
        case .cw: "waveform.path.ecg"
        case .repeater: "repeat"
        case .spectrumAndDisplay: "chart.bar.xaxis"
        case .systemAndOther: "gearshape.fill"
        }
    }
}

struct RadioLiteControlDashboardMember: Identifiable, Equatable, Sendable {
    let control: RadioLiteCapabilityControl
    let label: String

    var id: String { control.id }
}

struct RadioLiteControlDashboardItem: Identifiable, Equatable, Sendable {
    let id: String
    let category: RadioLiteControlDashboardCategory
    let title: String
    let members: [RadioLiteControlDashboardMember]
    let summary: String
}

struct RadioLiteControlDashboardSection: Identifiable, Equatable, Sendable {
    let id: RadioLiteControlDashboardCategory
    let items: [RadioLiteControlDashboardItem]
    let summary: String
}

struct RadioLiteControlDashboard: Equatable, Sendable {
    private static let tunerActionID = "action:TUNER"
    private static let tunerSwitchID = "function:TUNER"
    private static let noiseBlankerPairIDs = ["function:NB", "level:NB"]
    private static let noiseReductionPairIDs = ["function:NR", "level:NR"]
    private static let compressorPairIDs = ["function:COMP", "level:COMP"]
    private static let monitorPairIDs = ["function:MON", "level:MONITOR_GAIN"]
    private static let audioPeakFilterPairIDs = ["function:APF", "level:APF"]

    let sections: [RadioLiteControlDashboardSection]

    init(controls: [RadioLiteCapabilityControl], isTuning: Bool) {
        let visibleControls = controls.filter {
            $0.presentation.isSupported && $0.presentation != .meter
        }
        var grouped: [RadioLiteControlDashboardCategory: [String: [RadioLiteCapabilityControl]]] = [:]
        var keyOrder: [RadioLiteControlDashboardCategory: [String]] = [:]

        for control in visibleControls {
            let category = Self.category(for: control)
            let key = Self.itemKey(for: control)
            if grouped[category]?[key] == nil {
                keyOrder[category, default: []].append(key)
            }
            grouped[category, default: [:]][key, default: []].append(control)
        }

        sections = RadioLiteControlDashboardCategory.allCases.compactMap { category in
            guard let controlsByKey = grouped[category],
                  let keys = keyOrder[category],
                  !keys.isEmpty else { return nil }
            let items = keys.compactMap { key -> RadioLiteControlDashboardItem? in
                guard let controls = controlsByKey[key], !controls.isEmpty else { return nil }
                return Self.item(
                    key: key,
                    category: category,
                    controls: controls,
                    isTuning: isTuning
                )
            }
            .sorted { Self.priority(for: $0) < Self.priority(for: $1) }
            guard !items.isEmpty else { return nil }
            return RadioLiteControlDashboardSection(
                id: category,
                items: items,
                summary: Self.sectionSummary(category: category, items: items, isTuning: isTuning)
            )
        }
    }

    func section(for category: RadioLiteControlDashboardCategory) -> RadioLiteControlDashboardSection? {
        sections.first { $0.id == category }
    }

    private static func category(for control: RadioLiteCapabilityControl) -> RadioLiteControlDashboardCategory {
        let token = control.normalizedDashboardToken
        if control.id == tunerActionID || token == "TUNER" { return .tuner }
        if ["NB", "NR", "ANF"].contains(token) { return .noiseReduction }
        if ["PASSBAND", "PBT_IN", "PBT_OUT", "NOTCHF", "APF", "MN"].contains(token) {
            return .filter
        }
        switch control.group {
        case .rf: return .rf
        case .audio: return .audio
        case .mode: return .modeAndOffset
        case .cw: return .cw
        case .repeater: return .repeater
        case .spectrum: return .spectrumAndDisplay
        case .antenna, .system, .unknown: return .systemAndOther
        }
    }

    private static func itemKey(for control: RadioLiteCapabilityControl) -> String {
        switch control.id {
        case noiseBlankerPairIDs[0], noiseBlankerPairIDs[1]: "pair:NB"
        case noiseReductionPairIDs[0], noiseReductionPairIDs[1]: "pair:NR"
        case compressorPairIDs[0], compressorPairIDs[1]: "pair:COMP"
        case monitorPairIDs[0], monitorPairIDs[1]: "pair:MONITOR"
        case audioPeakFilterPairIDs[0], audioPeakFilterPairIDs[1]: "pair:APF"
        default: control.id
        }
    }

    private static func item(
        key: String,
        category: RadioLiteControlDashboardCategory,
        controls: [RadioLiteCapabilityControl],
        isTuning: Bool
    ) -> RadioLiteControlDashboardItem {
        let orderedControls = controls.sorted { memberPriority($0) < memberPriority($1) }
        let title: String
        switch key {
        case "pair:NB": title = "脉冲噪声抑制"
        case "pair:NR": title = "降噪"
        case "pair:COMP": title = "语音压缩"
        case "pair:MONITOR": title = "监听"
        case "pair:APF": title = "音频峰值滤波"
        default: title = orderedControls[0].dashboardLabel
        }
        let members = orderedControls.map { control in
            RadioLiteControlDashboardMember(
                control: control,
                label: memberLabel(control, itemCount: orderedControls.count)
            )
        }
        let summary = key == tunerActionID
            ? (isTuning ? "调谐中" : "就绪")
            : itemSummary(controls: orderedControls)
        return RadioLiteControlDashboardItem(
            id: key,
            category: category,
            title: title,
            members: members,
            summary: summary
        )
    }

    private static func memberLabel(_ control: RadioLiteCapabilityControl, itemCount: Int) -> String {
        guard itemCount > 1 else { return control.dashboardLabel }
        if control.presentation == .toggle { return "启用" }
        switch control.normalizedDashboardToken {
        case "NB", "NR", "APF": return "强度"
        case "COMP": return "压缩强度"
        case "MONITOR_GAIN": return "监听音量"
        default: return control.dashboardLabel
        }
    }

    private static func itemSummary(controls: [RadioLiteCapabilityControl]) -> String {
        let toggle = controls.first { $0.presentation == .toggle }
        let numeric = controls.first { $0.presentation != .toggle && $0.presentation != .button }
        if let toggle, case .boolean(let enabled) = toggle.value {
            if let numeric {
                return "\(enabled ? "开启" : "关闭") · \(numeric.dashboardFormattedValue)"
            }
            return enabled ? "开启" : "关闭"
        }
        if let first = controls.first {
            return first.dashboardFormattedValue
        }
        return "—"
    }

    private static func sectionSummary(
        category: RadioLiteControlDashboardCategory,
        items: [RadioLiteControlDashboardItem],
        isTuning: Bool
    ) -> String {
        switch category {
        case .tuner:
            if isTuning { return "调谐中" }
            if let tunerSwitch = items
                .flatMap(\.members)
                .first(where: { $0.control.id == tunerSwitchID }),
               case .boolean(let enabled) = tunerSwitch.control.value {
                return enabled ? "已接入" : "旁路"
            }
            return "可调谐"
        case .rf:
            if let power = items.first(where: { item in
                item.members.contains { $0.control.normalizedDashboardToken == "RFPOWER" }
            }) {
                return "功率 \(power.summary)"
            }
        case .audio:
            if let volume = items.first(where: { item in
                item.members.contains { $0.control.normalizedDashboardToken == "AF" }
            }) {
                return "音量 \(volume.summary)"
            }
        case .noiseReduction:
            if let active = items.first(where: { item in
                item.members.contains { $0.control.value.booleanValue == true }
            }) {
                return "\(active.title)已开启"
            }
            return "全部关闭"
        case .filter:
            if let passband = items.first(where: { item in
                item.members.contains { $0.control.normalizedDashboardToken == "PASSBAND" }
            }) {
                return passband.summary
            }
        case .modeAndOffset, .cw, .repeater, .spectrumAndDisplay, .systemAndOther:
            break
        }
        if items.count == 1 { return items[0].summary }
        return "\(items.count) 项"
    }

    private static func memberPriority(_ control: RadioLiteCapabilityControl) -> Int {
        if control.presentation == .toggle { return 0 }
        return 1
    }

    private static func priority(for item: RadioLiteControlDashboardItem) -> Int {
        let tokens = item.members.map { $0.control.normalizedDashboardToken }
        let preferred: [String]
        switch item.category {
        case .rf: preferred = ["RFPOWER", "RF", "PREAMP", "ATT", "AGC"]
        case .audio: preferred = ["AF", "SQL", "MICGAIN", "COMP", "MONITOR_GAIN", "VOX"]
        case .noiseReduction: preferred = ["NB", "NR", "ANF"]
        case .filter: preferred = ["PASSBAND", "PBT_IN", "PBT_OUT", "APF", "NOTCHF", "MN"]
        case .tuner: preferred = ["TUNER"]
        case .modeAndOffset: preferred = ["CURRENT", "SPLIT", "RIT", "XIT", "TUNING_STEP"]
        case .cw: preferred = ["KEYSPD", "CWPITCH", "BKINDL", "BKIN_DLYMS", "SBKIN", "FBKIN"]
        case .repeater: preferred = ["SHIFT", "OFFSET", "CTCSS", "DCS"]
        case .spectrumAndDisplay, .systemAndOther: preferred = []
        }
        return tokens.compactMap { preferred.firstIndex(of: $0) }.min() ?? (preferred.count + 100)
    }
}

extension RadioLiteCapabilityControl {
    var normalizedDashboardToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var dashboardLabel: String {
        switch normalizedDashboardToken {
        case "RFPOWER": return "发射功率设置"
        case "RFPOWER_METER", "RFPOWER_METER_WATTS": return "实时输出功率"
        case "SWR": return "驻波比"
        case "ALC": return "ALC"
        case "STRENGTH": return "信号强度"
        case "AF": return "音量"
        case "RF": return "射频增益"
        case "SQL": return "静噪"
        case "MICGAIN": return "麦克风增益"
        case "COMP": return id.hasPrefix("level:") ? "压缩强度" : "语音压缩"
        case "AGC": return "自动增益控制"
        case "ATT": return "衰减器"
        case "PREAMP": return "前置放大器"
        case "NB": return id.hasPrefix("level:") ? "脉冲噪声抑制强度" : "脉冲噪声抑制"
        case "NR": return id.hasPrefix("level:") ? "降噪强度" : "降噪"
        case "ANF": return "自动陷波"
        case "APF": return id.hasPrefix("level:") ? "音频峰值滤波强度" : "音频峰值滤波"
        case "MON": return "监听"
        case "MONITOR_GAIN": return "监听音量"
        case "TUNER": return id == "function:TUNER" ? "机内天调接入" : "开始调谐"
        case "CWPITCH": return "CW 音调"
        case "KEYSPD": return "CW 速度"
        case "PASSBAND", "CURRENT": return "滤波器带宽"
        case "RIT": return "接收增量调谐"
        case "XIT": return "发射增量调谐"
        case "TUNING_STEP": return "调谐步进"
        case "SPLIT": return "异频收发"
        case "REPEATER_SHIFT", "SHIFT": return "中继频移方向"
        case "REPEATER_OFFSET", "OFFSET": return "中继频差"
        default: return normalizedDashboardToken.isEmpty ? "电台控件" : normalizedDashboardToken
        }
    }

    var dashboardFormattedValue: String {
        if normalizedDashboardToken == "SWR", case .number(let value) = self.value {
            return String(format: "%.2f:1", value)
        }
        return formattedValue()
    }
}
