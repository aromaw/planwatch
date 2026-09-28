import AppKit
import WebKit

@MainActor
final class WebLoginController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    private let browser: WKWebView
    private let status = NSTextField(labelWithString: "在官网完成登录后，点击右侧按钮保存。")
    private let onLogin: (String) -> Void
    private let host: String
    private let isKimi: Bool
    private static let sessionNames = ["__Secure-commandcode_prod_.session_token", "commandcode_prod_.session_token",
                                       "__Host-commandcode_prod_.session_token", "__Host-better-auth.session_token",
                                       "__Secure-better-auth.session_token", "better-auth.session_token"]

    init(kimi: Bool = false, international: Bool = false, onLogin: @escaping (String) -> Void) {
        self.onLogin = onLogin
        isKimi = kimi
        host = kimi ? (international ? "kimi.ai" : "kimi.com") : "commandcode.ai"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        browser = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "登录 \(kimi ? "Kimi" : "Command Code") · PlanWatch"; window.center(); window.isReleasedWhenClosed = false
        super.init(window: window)
        browser.navigationDelegate = self; browser.uiDelegate = self
        let button = NSButton(title: "完成登录并连接", target: self, action: #selector(captureSession))
        button.bezelStyle = .rounded
        let toolbar = NSStackView(views: [status, button]); toolbar.orientation = .horizontal; toolbar.spacing = 12
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let content = NSView()
        window.contentView = content
        browser.translatesAutoresizingMaskIntoConstraints = false; toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(browser); content.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor), toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            browser.topAnchor.constraint(equalTo: toolbar.bottomAnchor), browser.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: content.trailingAnchor), browser.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let loginURL = kimi ? "https://www.\(host)/code/console" : "https://commandcode.ai/usage"
        browser.load(URLRequest(url: URL(string: loginURL)!))
    }
    required init?(coder: NSCoder) { return nil }

    @objc private func captureSession() {
        browser.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self else { return }
                let eligible = cookies.filter {
                    let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                    return (domain == host || domain == "api." + host || domain == "www." + host) && !($0.expiresDate.map { $0 < Date() } ?? false)
                }
                if isKimi {
                    if let cookie = eligible.first(where: { $0.name == "kimi-auth" && !$0.value.isEmpty }) {
                        onLogin("web:" + cookie.value); close(); return
                    }
                    status.stringValue = "尚未找到 Kimi 登录会话。请完成登录，或在设置中使用 API Key。"
                    return
                }
                for name in Self.sessionNames {
                    if let cookie = eligible.first(where: { $0.name == name && !$0.value.isEmpty }) {
                        onLogin("\(cookie.name)=\(cookie.value)"); close(); return
                    }
                }
                status.stringValue = "尚未找到登录会话。请先完成登录，或在账号设置中粘贴 Cookie。"
            }
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // OAuth popup links reuse this window so their session cookies stay in the same store.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "about" else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    static func clearSession(kimi: Bool) {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let hosts = kimi ? ["kimi.com", "kimi.ai"] : ["commandcode.ai"]
            let selected = records.filter { record in hosts.contains { record.displayName == $0 || record.displayName.hasSuffix("." + $0) } }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: selected, completionHandler: {})
        }
    }
}
