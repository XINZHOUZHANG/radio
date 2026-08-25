import SwiftUI

@main
struct TX5DRMobileApp: App {
    @StateObject private var session = RadioLiteSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(session.control)
                .environmentObject(session.media)
                .environmentObject(session.audio)
                .preferredColorScheme(.dark)
        }
    }
}
