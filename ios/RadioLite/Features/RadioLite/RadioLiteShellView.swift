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
    @State private var selectedTab = Tab.radio

    private enum Tab: Hashable { case radio, ft8, logbook, settings }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { RadioLiteRadioView() }
                .tag(Tab.radio)
                .tabItem { Label("电台", systemImage: "dot.radiowaves.left.and.right") }
            NavigationStack { RadioLiteFT8View(onShowRadio: { selectedTab = .radio }) }
                .tag(Tab.ft8)
                .tabItem { Label("FT8", systemImage: "waveform.path.ecg.rectangle") }
            NavigationStack { RadioLiteLogbookView() }
                .tag(Tab.logbook)
                .tabItem { Label("日志", systemImage: "book.closed") }
            NavigationStack { RadioLiteSettingsView() }
                .tag(Tab.settings)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(TX.teal)
        .background(TX.bg)
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
