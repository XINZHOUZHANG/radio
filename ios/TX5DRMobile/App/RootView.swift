import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket

    var body: some View {
        Group {
            switch session.phase {
            case .launching:
                launchView
            case .signedOut, .authenticating:
                LoginView()
            case .ready:
                RadioShellView()
            case .failed(let message):
                ContentUnavailableView(
                    "连接失败",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text(message)
                )
            }
        }
        .task {
            if case .launching = session.phase {
                await session.restoreSession()
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            ),
            actions: { Button("好") { session.errorMessage = nil } },
            message: { Text(session.errorMessage ?? "未知错误") }
        )
        .overlay(alignment: .top) {
            if let notice = session.noticeMessage ?? radio.lastNotice {
                NoticeBanner(text: notice) {
                    if session.noticeMessage != nil {
                        session.noticeMessage = nil
                    } else {
                        radio.dismissLastNotice()
                    }
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: session.noticeMessage ?? radio.lastNotice)
        .sheet(item: Binding(
            get: { radio.openWebRXProfileRequest },
            set: { if $0 == nil { radio.dismissOpenWebRXProfileRequest() } }
        )) { request in
            OpenWebRXProfileSelectionView(request: request)
        }
    }

    private var launchView: some View {
        ZStack {
            RadioPalette.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(RadioPalette.accent)
                Text("TX-5DR Remote")
                    .font(.title2.weight(.semibold))
                ProgressView()
                    .tint(RadioPalette.accent)
            }
        }
    }
}
private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(RadioPalette.accent)
            Text(text)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        }
        .padding(.horizontal)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        .onTapGesture(perform: dismiss)
    }
}
