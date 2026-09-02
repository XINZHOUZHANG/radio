import SwiftUI

struct RadioLiteCapabilityGroupView: View {
    let group: RadioLiteCapabilityGroupSection
    let isTransmitting: Bool
    let hasControl: Bool

    var body: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 14) {
                Label(group.id.label, systemImage: group.id.systemImage)
                    .font(.headline)

                ForEach(group.controls) { control in
                    RadioLiteCapabilityControlRow(
                        control: control,
                        isTransmitting: isTransmitting,
                        hasControl: hasControl
                    )
                    if control.id != group.controls.last?.id {
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }
        }
    }
}
