import SwiftUI

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
            if value == .active {
                session.appDidBecomeActive()
            } else {
                session.appDidEnterBackground()
            }
        }
    }
}
