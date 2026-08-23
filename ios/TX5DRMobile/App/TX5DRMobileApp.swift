import SwiftUI

@main
struct TX5DRMobileApp: App {
    @StateObject private var session = TX5DRSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(session.radio)
                .environmentObject(session.audio)
                .preferredColorScheme(.dark)
        }
    }
}
