import SwiftUI

struct RadioLiteControlDashboardView: View {
    @EnvironmentObject private var session: RadioLiteSession

    let isTransmitting: Bool
    let hasControl: Bool

    @State private var selectedCategory: RadioLiteControlDashboardCategory?

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 14) {
                header
                if dashboard.sections.isEmpty {
                    ContentUnavailableView(
                        "没有可用的电台控制",
                        systemImage: "slider.horizontal.3",
                        description: Text("当前电台没有报告可调整的控制项目。")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(dashboard.sections) { section in
                            Button {
                                selectedCategory = section.id
                            } label: {
                                categoryCard(section)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(section.id.label)，\(section.summary)")
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedCategory) { category in
            RadioLiteControlSectionSheet(
                category: category,
                isTransmitting: isTransmitting,
                hasControl: hasControl
            )
            .environmentObject(session)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(RadioPalette.background)
        }
    }

    private var dashboard: RadioLiteControlDashboard {
        RadioLiteControlDashboard(
            controls: session.radioCapabilities,
            isTuning: session.isTuning
        )
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("电台控制")
                    .font(.headline)
                Text("选择功能后再调整参数")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
            Spacer()
            Button {
                Task { await refreshCapabilities() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 34, height: 34)
                    .background(RadioPalette.panelRaised, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RadioPalette.accent)
            .disabled(session.selectedRadioId == nil)
            .accessibilityLabel("刷新电台控制")
        }
    }

    private func categoryCard(_ section: RadioLiteControlDashboardSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: section.id.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(RadioPalette.accent)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RadioPalette.muted)
            }
            Spacer(minLength: 0)
            Text(section.id.label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.white)
            Text(section.summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(RadioPalette.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .padding(13)
        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06))
        }
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func refreshCapabilities() async {
        do {
            try await session.refreshRadioCapabilities()
        } catch {
            session.errorMessage = "读取电台控制失败：\(error.localizedDescription)"
        }
    }
}

private struct RadioLiteControlSectionSheet: View {
    @EnvironmentObject private var session: RadioLiteSession
    @Environment(\.dismiss) private var dismiss

    let category: RadioLiteControlDashboardCategory
    let isTransmitting: Bool
    let hasControl: Bool

    @State private var expandedItemID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if category == .tuner {
                        tunerPanel
                    } else if let section {
                        ForEach(section.items) { item in
                            RadioLiteDashboardControlItemView(
                                item: item,
                                isExpanded: expandedItemID == item.id,
                                isTransmitting: isTransmitting,
                                hasControl: hasControl
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedItemID = expandedItemID == item.id ? nil : item.id
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "控制项目已更新",
                            systemImage: "arrow.clockwise",
                            description: Text("关闭面板后重新选择功能。")
                        )
                    }
                }
                .padding(14)
            }
            .background(RadioPalette.background)
            .navigationTitle(category.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var dashboard: RadioLiteControlDashboard {
        RadioLiteControlDashboard(
            controls: session.radioCapabilities,
            isTuning: session.isTuning
        )
    }

    private var section: RadioLiteControlDashboardSection? {
        dashboard.section(for: category)
    }

    private var tunerPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("机内天调", systemImage: "tuningfork")
                    .font(.headline)
                Spacer()
                Text(tunerStatusText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(
                        session.isTuning || session.isTuningPending
                            ? RadioPalette.warning
                            : RadioPalette.cyan
                    )
            }
            Text("调谐会短暂进入发射状态。请确认天线系统已连接并保持现场安全。")
                .font(.caption)
                .foregroundStyle(RadioPalette.muted)
            Button {
                session.beginTuning()
            } label: {
                Label(
                    session.isTuningPending ? "正在启动…" : "开始调谐",
                    systemImage: "tuningfork"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning, prominent: false))
            .disabled(!canStartTuner)
            if RadioLiteTunerInteractionPolicy.canEmergencyStop(isTuning: session.isTuning) {
                Button {
                    session.endTuning()
                } label: {
                    Label("停止调谐", systemImage: "stop.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.transmit, prominent: true))
                .disabled(!hasControl)
                Text("仅在电台未自动结束调谐时使用。")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
            if !hasControl {
                Label("需要先取得电台控制权", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
        }
        .padding(16)
        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var tunerStatusText: String {
        if session.isTuningPending { return "正在启动" }
        if session.isTuning { return "调谐中" }
        return "就绪"
    }

    private var canStartTuner: Bool {
        guard !session.isTuning, !session.isTuningPending else { return false }
        guard let capability = session.tunerActionCapability else { return false }
        return session.canUseInternalTuner
            && capability.displayState(
                isTransmitting: isTransmitting,
                hasControl: hasControl
            ).isEnabled
    }
}

private struct RadioLiteDashboardControlItemView: View {
    let item: RadioLiteControlDashboardItem
    let isExpanded: Bool
    let isTransmitting: Bool
    let hasControl: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.white)
                        Text(item.summary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(RadioPalette.cyan)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RadioPalette.muted)
                }
                .padding(15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().overlay(Color.white.opacity(0.08))
                VStack(spacing: 15) {
                    ForEach(item.members) { member in
                        RadioLiteDashboardControlEditor(
                            control: member.control,
                            label: member.label,
                            isTransmitting: isTransmitting,
                            hasControl: hasControl
                        )
                        if member.id != item.members.last?.id {
                            Divider().overlay(Color.white.opacity(0.08))
                        }
                    }
                }
                .padding(15)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RadioLiteDashboardControlEditor: View {
    @EnvironmentObject private var session: RadioLiteSession

    let control: RadioLiteCapabilityControl
    let label: String
    let isTransmitting: Bool
    let hasControl: Bool

    @State private var draftValue: RadioLiteControlValue
    @State private var isAdjusting = false
    @State private var isSubmitting = false

    init(
        control: RadioLiteCapabilityControl,
        label: String,
        isTransmitting: Bool,
        hasControl: Bool
    ) {
        self.control = control
        self.label = label
        self.isTransmitting = isTransmitting
        self.hasControl = hasControl
        _draftValue = State(initialValue: control.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption.weight(.semibold))
                Spacer()
                if isSubmitting {
                    ProgressView().controlSize(.small)
                }
                if control.presentation != .button {
                    Text(control.formattedValue(draftValue))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(RadioPalette.cyan)
                }
            }

            nativeControl

            if let reason = display.disabledReason,
               control.access != .readOnly,
               control.presentation != .meter {
                Label(reason, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
        }
        .onChange(of: control.value) { _, confirmedValue in
            guard !isAdjusting, !isSubmitting else { return }
            draftValue = confirmedValue
        }
    }

    @ViewBuilder
    private var nativeControl: some View {
        switch control.presentation {
        case .meter:
            EmptyView()
        case .toggle:
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .tint(RadioPalette.accent)
                .disabled(!canMutate)
        case .slider:
            Slider(
                value: numericBinding,
                in: numericRange,
                step: numericStep,
                onEditingChanged: submitWhenEditingEnds
            )
            .tint(RadioPalette.accent)
            .disabled(!canMutate || !hasNumericRange)
        case .discrete:
            if let options = control.options, !options.isEmpty {
                if options.count <= 4 {
                    optionPicker(options: options)
                        .pickerStyle(.segmented)
                } else {
                    optionPicker(options: options)
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Stepper(value: numericBinding, in: numericRange, step: numericStep) {
                    Text(control.formattedValue(draftValue))
                        .font(.caption.monospacedDigit())
                }
                .disabled(!canMutate || !hasNumericRange)
            }
        case .enumeration:
            optionPicker(options: control.options ?? [])
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .offset:
            Stepper(value: numericBinding, in: numericRange, step: numericStep) {
                Text(control.formattedValue(draftValue))
                    .font(.caption.monospacedDigit())
            }
            .disabled(!canMutate || !hasNumericRange)
        case .button:
            Button(label) { submitAction() }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent))
                .disabled(!canMutate)
        case .unknown:
            EmptyView()
        }
    }

    private func optionPicker(options: [RadioLiteCapabilityOption]) -> some View {
        Picker("选择\(label)", selection: optionBinding) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .disabled(!canMutate || options.isEmpty)
    }

    private var display: RadioLiteCapabilityDisplayState {
        control.displayState(isTransmitting: isTransmitting, hasControl: hasControl)
    }

    private var canMutate: Bool {
        display.isEnabled && !isSubmitting
    }

    private var hasNumericRange: Bool {
        guard let minimum = control.minimum, let maximum = control.maximum else { return false }
        return minimum.isFinite && maximum.isFinite && minimum < maximum
    }

    private var numericRange: ClosedRange<Double> {
        guard let minimum = control.minimum,
              let maximum = control.maximum,
              minimum.isFinite,
              maximum.isFinite,
              minimum < maximum else { return 0...1 }
        return minimum...maximum
    }

    private var numericStep: Double {
        let span = numericRange.upperBound - numericRange.lowerBound
        guard span.isFinite, span > 0 else { return 1 }
        guard let step = control.step, step.isFinite, step > 0 else { return span / 100 }
        return min(step, span)
    }

    private var numericValue: Double {
        guard case .number(let value) = draftValue else { return numericRange.lowerBound }
        return min(numericRange.upperBound, max(numericRange.lowerBound, value))
    }

    private var numericBinding: Binding<Double> {
        Binding(
            get: { numericValue },
            set: { value in
                draftValue = .number(value)
                if control.presentation == .offset || control.presentation == .discrete {
                    submit(.number(value))
                }
            }
        )
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { draftValue.booleanValue ?? false },
            set: { enabled in
                draftValue = .boolean(enabled)
                submit(.boolean(enabled))
            }
        )
    }

    private var optionBinding: Binding<RadioLiteControlValue> {
        Binding(
            get: { draftValue },
            set: { value in
                draftValue = value
                submit(value)
            }
        )
    }

    private func submitWhenEditingEnds(_ editing: Bool) {
        isAdjusting = editing
        if !editing { submit(draftValue) }
    }

    private func submit(_ value: RadioLiteControlValue) {
        guard canMutate else {
            draftValue = control.value
            return
        }
        isSubmitting = true
        Task {
            let confirmed = await session.setCapabilityControl(control.id, value: value)
            draftValue = confirmed?.value ?? control.value
            isSubmitting = false
        }
    }

    private func submitAction() {
        guard canMutate else { return }
        isSubmitting = true
        Task {
            _ = await session.invokeCapabilityAction(control.id)
            isSubmitting = false
        }
    }
}
