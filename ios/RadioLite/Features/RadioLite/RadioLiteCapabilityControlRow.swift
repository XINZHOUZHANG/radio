import SwiftUI

struct RadioLiteCapabilityControlRow: View {
    @EnvironmentObject private var session: RadioLiteSession

    let control: RadioLiteCapabilityControl
    let isTransmitting: Bool
    let hasControl: Bool

    @State private var draftValue: RadioLiteControlValue
    @State private var isAdjusting = false
    @State private var isSubmitting = false

    init(control: RadioLiteCapabilityControl, isTransmitting: Bool, hasControl: Bool) {
        self.control = control
        self.isTransmitting = isTransmitting
        self.hasControl = hasControl
        _draftValue = State(initialValue: control.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.label)
                    .font(.subheadline.weight(.semibold))
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
            Gauge(value: numericValue, in: numericRange) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(RadioPalette.cyan)
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
                Picker("选择\(display.label)", selection: optionBinding) {
                    ForEach(options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!canMutate)
            } else {
                Stepper(
                    value: numericBinding,
                    in: numericRange,
                    step: numericStep
                ) {
                    Text(control.formattedValue(draftValue))
                        .font(.caption.monospacedDigit())
                }
                .disabled(!canMutate || !hasNumericRange)
            }
        case .enumeration:
            Picker("选择\(display.label)", selection: optionBinding) {
                ForEach(control.options ?? [], id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .disabled(!canMutate || control.options?.isEmpty != false)
        case .offset:
            Stepper(
                value: numericBinding,
                in: numericRange,
                step: numericStep
            ) {
                Text(control.formattedValue(draftValue))
                    .font(.caption.monospacedDigit())
            }
            .disabled(!canMutate || !hasNumericRange)
        case .button:
            Button(display.label) {
                submitAction()
            }
            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent))
            .disabled(!canMutate)
        case .unknown:
            EmptyView()
        }
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
