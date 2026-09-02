import SwiftUI

enum RadioLiteScenePhaseAction: Equatable, Sendable {
    case becameActive
    case enteredBackground
    case none
}

enum RadioLiteScenePhasePolicy {
    static func action(for phase: ScenePhase) -> RadioLiteScenePhaseAction {
        switch phase {
        case .active: .becameActive
        case .background: .enteredBackground
        case .inactive: .none
        @unknown default: .none
        }
    }
}

struct RadioLiteShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: RadioLiteSession

    var body: some View {
        TabView {
            NavigationStack { RadioLiteRadioView() }
                .tabItem { Label("电台", systemImage: "dot.radiowaves.left.and.right") }
            NavigationStack { RadioLiteFT8View() }
                .tabItem { Label("FT8", systemImage: "waveform.path.ecg.rectangle") }
            NavigationStack { RadioLiteLogbookView() }
                .tabItem { Label("日志", systemImage: "book.closed") }
            NavigationStack { RadioLiteSettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(RadioPalette.accent)
        .background(RadioPalette.background)
        .onChange(of: scenePhase) { _, value in
            switch RadioLiteScenePhasePolicy.action(for: value) {
            case .becameActive:
                session.appDidBecomeActive()
            case .enteredBackground:
                session.appDidEnterBackground()
            case .none:
                break
            }
        }
    }
}
