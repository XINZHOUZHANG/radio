import SwiftUI
import UIKit
import WebKit

struct PluginPageView: View {
    @EnvironmentObject private var session: TX5DRSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let plugin: TX5DRPluginStatus
    let page: TX5DRPluginUIPage
    let params: [String: String]
    let title: String

    @State private var configuration: TX5DRPluginPageConfiguration?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadToken = 0

    init(
        plugin: TX5DRPluginStatus,
        page: TX5DRPluginUIPage,
        params: [String: String] = [:],
        title: String? = nil
    ) {
        self.plugin = plugin
        self.page = page
        self.params = params
        self.title = title ?? page.title
    }

    var body: some View {
        ZStack {
            RadioPalette.background.ignoresSafeArea()

            if let configuration {
                PluginPageWebView(
                    session: session,
                    configuration: configuration,
                    locale: locale.identifier,
                    theme: theme,
                    isLoading: $isLoading,
                    loadError: $loadError,
                    onRequestClose: { dismiss() }
                )
                .id(reloadToken)
            }

            if isLoading && loadError == nil {
                ProgressView("正在连接插件页面")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            if let loadError {
                ContentUnavailableView {
                    Label("插件页面不可用", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重新加载") { reload() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .background(RadioPalette.background.opacity(0.96))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(configuration == nil)
            }
        }
        .task(id: configurationKey) {
            configurePage()
        }
    }

    private var theme: String { colorScheme == .dark ? "dark" : "light" }

    private var configurationKey: String {
        let encodedParams = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined(separator: "&")
        return [
            plugin.name,
            page.id,
            session.selectedOperatorId ?? "",
            session.keyerCallsign ?? "",
            locale.identifier,
            encodedParams,
        ].joined(separator: "|")
    }

    private func configurePage() {
        isLoading = true
        loadError = nil
        do {
            configuration = try session.pluginPageConfiguration(
                plugin: plugin,
                page: page,
                params: params,
                locale: locale.identifier,
                theme: theme
            )
        } catch {
            configuration = nil
            isLoading = false
            loadError = error.localizedDescription
        }
    }

    private func reload() {
        loadError = nil
        isLoading = true
        reloadToken += 1
    }
}

private struct PluginPageWebView: UIViewRepresentable {
    static let messageHandlerName = "tx5drNative"

    let session: TX5DRSession
    let configuration: TX5DRPluginPageConfiguration
    let locale: String
    let theme: String
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    let onRequestClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(
            source: Self.nativeBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        contentController.add(context.coordinator, name: Self.messageHandlerName)

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.userContentController = contentController
        webConfiguration.allowsInlineMediaPlayback = true
        webConfiguration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
#if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
#endif

        context.coordinator.attach(webView)
        context.coordinator.load(configuration.pageURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(parent: self)
        if context.coordinator.loadedPageURL != configuration.pageURL {
            context.coordinator.load(configuration.pageURL)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private static let nativeBridgeScript = #"""
    (function () {
      if (window.__TX5DR_IOS_HOST_INSTALLED__) return;
      window.__TX5DR_IOS_HOST_INSTALLED__ = true;
      var accepted = {
        'tx5dr:invoke': true,
        'tx5dr:store:get': true,
        'tx5dr:store:set': true,
        'tx5dr:store:delete': true,
        'tx5dr:file:upload': true,
        'tx5dr:file:read': true,
        'tx5dr:file:delete': true,
        'tx5dr:file:list': true,
        'tx5dr:resize': true,
        'tx5dr:request-close': true
      };
      window.addEventListener('message', function (event) {
        var message = event.data;
        if (!message || typeof message.type !== 'string' || !accepted[message.type]) return;
        try {
          window.webkit.messageHandlers.tx5drNative.postMessage(message);
        } catch (_) {}
      }, true);
    })();
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var parent: PluginPageWebView
        weak var webView: WKWebView?
        private(set) var loadedPageURL: URL?

        private var pageSessionId: String?
        private var pendingRequests: [TX5DRPluginPageBridgeRequest] = []
        private var heartbeatTask: Task<Void, Never>?
        private var pushTask: Task<Void, Never>?
        private var lastTheme: String

        init(parent: PluginPageWebView) {
            self.parent = parent
            lastTheme = parent.theme
        }

        deinit {
            heartbeatTask?.cancel()
            pushTask?.cancel()
        }

        func attach(_ webView: WKWebView) { self.webView = webView }

        func update(parent: PluginPageWebView) {
            let previousTheme = lastTheme
            self.parent = parent
            lastTheme = parent.theme
            if previousTheme != parent.theme, pageSessionId != nil {
                postMessage(.object([
                    "type": .string("tx5dr:theme-changed"),
                    "theme": .string(parent.theme),
                ]))
            }
        }

        func load(_ url: URL) {
            resetPageSession(dropPendingWithError: false)
            loadedPageURL = url
            parent.isLoading = true
            parent.loadError = nil
            var request = TX5DRNetworkPolicy.request(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            webView?.load(request)
        }

        func stop() {
            resetPageSession(dropPendingWithError: false)
            webView = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            resetPageSession(dropPendingWithError: true)
            parent.isLoading = true
            parent.loadError = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(
                "typeof window.__TX5DR_PAGE_SESSION_ID__ === 'string' ? window.__TX5DR_PAGE_SESSION_ID__ : null"
            ) { [weak self, weak webView] value, _ in
                guard let self, self.webView === webView else { return }
                let sessionId = value as? String
                self.lockPageSession(sessionId)
                self.postInit()
                self.parent.isLoading = false
                if sessionId == nil {
                    self.parent.loadError = "TX-5DR 没有建立插件页面会话。请检查页面权限、操作员绑定和插件状态。"
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            showNavigationError(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showNavigationError(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            guard parent.configuration.isAllowedNavigation(url) else {
                if navigationAction.navigationType == .linkActivated {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else { return nil }
            if parent.configuration.isAllowedNavigation(url) {
                webView.load(TX5DRNetworkPolicy.request(url: url))
            } else {
                UIApplication.shared.open(url)
            }
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == PluginPageWebView.messageHandlerName,
                  JSONSerialization.isValidJSONObject(message.body),
                  let data = try? JSONSerialization.data(withJSONObject: message.body),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let type = value["type"]?.stringValue else { return }

            switch type {
            case "tx5dr:request-close":
                parent.onRequestClose()
            case "tx5dr:resize":
                break
            default:
                do {
                    let request = try TX5DRPluginPageBridgeRequest(message: value)
                    if let pageSessionId {
                        forward(request, lockedPageSessionId: pageSessionId)
                    } else if pendingRequests.count < 100 {
                        pendingRequests.append(request)
                    } else {
                        postResponse(requestId: request.requestId, error: "插件页面请求队列已满")
                    }
                } catch {
                    if let requestId = value["requestId"]?.stringValue {
                        postResponse(requestId: requestId, error: error.localizedDescription)
                    }
                }
            }
        }

        private func lockPageSession(_ sessionId: String?) {
            pageSessionId = sessionId
            guard let sessionId else {
                let pending = pendingRequests
                pendingRequests.removeAll()
                pending.forEach { postResponse(requestId: $0.requestId, error: "插件页面会话尚未就绪") }
                return
            }

            let pending = pendingRequests
            pendingRequests.removeAll()
            pending.forEach { forward($0, lockedPageSessionId: sessionId) }
            startSessionTasks(sessionId: sessionId)
        }

        private func forward(_ request: TX5DRPluginPageBridgeRequest, lockedPageSessionId: String) {
            let pluginName = parent.configuration.pluginName
            let pageId = parent.configuration.pageId
            let body = request.body(pageId: pageId, pageSessionId: lockedPageSessionId)

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.parent.session.performPluginPageRequest(
                        pluginName: pluginName,
                        endpoint: request.endpoint,
                        body: body
                    )
                    guard self.pageSessionId == lockedPageSessionId else { return }
                    self.postResponse(requestId: request.requestId, result: result)
                } catch {
                    guard self.pageSessionId == lockedPageSessionId else { return }
                    self.postResponse(requestId: request.requestId, error: error.localizedDescription)
                }
            }
        }

        private func startSessionTasks(sessionId: String) {
            heartbeatTask?.cancel()
            pushTask?.cancel()

            heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.sendHeartbeat(lockedPageSessionId: sessionId)
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                }
            }
            pushTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.pollPushes(lockedPageSessionId: sessionId)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        @MainActor
        private func sendHeartbeat(lockedPageSessionId: String) async {
            guard pageSessionId == lockedPageSessionId else { return }
            let body = sessionBody(pageSessionId: lockedPageSessionId)
            _ = try? await parent.session.performPluginPageRequest(
                pluginName: parent.configuration.pluginName,
                endpoint: .heartbeat,
                body: body
            )
        }

        @MainActor
        private func pollPushes(lockedPageSessionId: String) async {
            guard pageSessionId == lockedPageSessionId else { return }
            do {
                let result = try await parent.session.performPluginPageRequest(
                    pluginName: parent.configuration.pluginName,
                    endpoint: .pushes,
                    body: sessionBody(pageSessionId: lockedPageSessionId)
                )
                guard pageSessionId == lockedPageSessionId else { return }
                for push in result?.arrayValue ?? [] {
                    guard push["pluginName"]?.stringValue == parent.configuration.pluginName,
                          push["pageId"]?.stringValue == parent.configuration.pageId,
                          push["pageSessionId"]?.stringValue == lockedPageSessionId,
                          let action = push["action"]?.stringValue else { continue }
                    var message: [String: JSONValue] = [
                        "type": .string("tx5dr:push"),
                        "action": .string(action),
                    ]
                    if let data = push["data"] { message["data"] = data }
                    postMessage(.object(message))
                }
            } catch {
                // Polling is best-effort; direct bridge request failures are returned to the page.
            }
        }

        private func sessionBody(pageSessionId: String) -> JSONValue {
            .object([
                "pageId": .string(parent.configuration.pageId),
                "pageSessionId": .string(pageSessionId),
            ])
        }

        private func postInit() {
            postMessage(.object([
                "type": .string("tx5dr:init"),
                "params": .object(parent.configuration.params.mapValues(JSONValue.string)),
                "theme": .string(parent.theme),
                "locale": .string(parent.locale),
            ]))
        }

        private func postResponse(requestId: String, result: JSONValue? = nil, error: String? = nil) {
            var message: [String: JSONValue] = [
                "type": .string("tx5dr:response"),
                "requestId": .string(requestId),
            ]
            if let result { message["result"] = result }
            if let error { message["error"] = .string(error) }
            postMessage(.object(message))
        }

        private func postMessage(_ message: JSONValue) {
            guard let webView,
                  let data = try? JSONEncoder().encode(message),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.postMessage(\(json), '*');")
        }

        private func resetPageSession(dropPendingWithError: Bool) {
            heartbeatTask?.cancel()
            pushTask?.cancel()
            heartbeatTask = nil
            pushTask = nil
            pageSessionId = nil
            if dropPendingWithError {
                let pending = pendingRequests
                pendingRequests.removeAll()
                pending.forEach { postResponse(requestId: $0.requestId, error: "插件页面已重新载入") }
            } else {
                pendingRequests.removeAll()
            }
        }

        private func showNavigationError(_ error: Error) {
            resetPageSession(dropPendingWithError: true)
            parent.isLoading = false
            parent.loadError = error.localizedDescription
        }
    }
}
