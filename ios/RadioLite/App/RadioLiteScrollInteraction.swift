import SwiftUI

private struct RadioLiteSliderEditingKey: EnvironmentKey {
    static let defaultValue: (UUID, Bool) -> Void = { _, _ in }
}

extension EnvironmentValues {
    /// A slider owns the vertical scroll lock until editing ends or its view disappears.
    var radioLiteSliderEditing: (UUID, Bool) -> Void {
        get { self[RadioLiteSliderEditingKey.self] }
        set { self[RadioLiteSliderEditingKey.self] = newValue }
    }
}
