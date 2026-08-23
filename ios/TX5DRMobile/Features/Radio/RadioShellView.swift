import SwiftUI

struct RadioShellView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket

    var body: some View {
        TabView {
            NavigationStack { RadioControlView() }
                .tabItem { Label("电台", systemImage: "dot.radiowaves.left.and.right") }

            NavigationStack { FT8View() }
                .tabItem { Label("FT8", systemImage: "waveform.path.ecg.rectangle") }

            NavigationStack { VoiceCWView() }
                .tabItem { Label("语音 / CW", systemImage: "mic.and.signal.meter") }

            NavigationStack { LogbookView() }
                .tabItem { Label("日志", systemImage: "book.closed") }

            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(RadioPalette.accent)
        .background(RadioPalette.background)
        .onChange(of: radio.state) { _, state in
            if case .failed(let message) = state {
                session.noticeMessage = "控制通道：\(message)"
            }
        }
    }
}
