// An embedded browser: WebKit's WKWebView, in a profile of its own that is kept on disk, with an optional Cloudflare Access
// service token sent only to preview hosts.
import SwiftUI
import WebKit

/// The Cloudflare Access service token (`GET /preview/access`): sent as CF-Access-Client-Id and CF-Access-Client-Secret
/// with every navigation to a host ending in `.` + `hostSuffix`, and to no other.
struct WebAccess: Equatable {
    var clientID: String, clientSecret: String, hostSuffix: String
}

/// One browser and what it reports: its title, address, whether it is loading and why it failed.
@MainActor
final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published private(set) var title: String?
    @Published private(set) var url: String?
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    var access: WebAccess?
    private var observations: [NSKeyValueObservation] = []
    /// The address last asked for, which a reload opens again when nothing has loaded yet.
    private var requested: String?

    /// `profile` names the data store, so a sign-in lasts between runs and between launches.
    init(profile: String, access: WebAccess? = nil) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Browser.identifier(profile))
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        // Web apps such as WhatsApp Web only serve browsers they know; this is Safari's own.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        self.access = access
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in Task { @MainActor in self?.title = wv.title } },
            webView.observe(\.url) { [weak self] wv, _ in Task { @MainActor in self?.url = wv.url?.absoluteString } },
            webView.observe(\.isLoading) { [weak self] wv, _ in Task { @MainActor in self?.loading = wv.isLoading } },
            webView.observe(\.canGoBack) { [weak self] wv, _ in Task { @MainActor in self?.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] wv, _ in Task { @MainActor in self?.canGoForward = wv.canGoForward } },
        ]
    }

    /// A stable UUID for a profile name.
    private static func identifier(_ profile: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in ("briareus.web." + profile).utf8.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        bytes[6] = (bytes[6] & 0x0F) | 0x40; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func load(_ address: String) {
        guard let u = URL(string: address) else { error = "The address could not be opened."; return }
        requested = address
        error = nil
        webView.load(request(for: URLRequest(url: u)))
    }
    func reload() {
        if webView.url == nil, let address = url ?? requested { load(address) } else { webView.reload() }
    }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    private func request(for r: URLRequest) -> URLRequest {
        guard let access, let u = r.url?.absoluteString, previewAccessApplies(url: u, hostSuffix: access.hostSuffix) else { return r }
        var r = r
        r.setValue(access.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(access.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        return r
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // A navigation to a preview host without the service token is sent again with it. Only a new GET is: a form's
        // POST would lose its body, and a step back or forward, or a reload, would become a new page in the history
        // (clearing what Forward goes to); the Access cookie the first one earned already lets those through.
        if let access, let u = action.request.url?.absoluteString, action.targetFrame?.isMainFrame != false,
           (action.request.httpMethod ?? "GET").uppercased() == "GET",
           action.navigationType != .backForward && action.navigationType != .reload,
           previewAccessApplies(url: u, hostSuffix: access.hostSuffix),
           action.request.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil {
            decisionHandler(.cancel)
            webView.load(request(for: action.request))
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; error = nil }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { ready = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ e: Error) {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }   // frame load interrupted by a policy change
        error = e.localizedDescription
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // MARK: WKUIDelegate

    /// A link that opens a new window opens in the default browser instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url, u.scheme == "https" || u.scheme == "http" { NSWorkspace.shared.open(u) }
        return nil
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.prompt) }
}

/// The browser's view, edge to edge.
struct BrowserView: NSViewRepresentable {
    @ObservedObject var browser: Browser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The address bar over a Run tab's browser (the Windows client's run_browser_bar): back, forward and reload, the page's
/// address, which can be edited and opened with Enter once the browser is up, and Open in your browser. Until the browser
/// starts (its Cloudflare Access token is being read) the served address shows, greyed controls around it.
struct RunBrowserBar: View {
    var browser: Browser?
    var url: String?

    var body: some View {
        if let browser { LiveRunBrowserBar(browser: browser, url: url) } else {
            HStack(spacing: 2) {
                BarIcon(symbol: "arrow.left", tip: "Back", enabled: false) {}
                BarIcon(symbol: Glyph.symbol(0xE72A), tip: "Forward", enabled: false) {}
                BarIcon(symbol: Glyph.symbol(0xE72C), tip: "Reload the page", enabled: false) {}
                HStack(spacing: 8) {
                    Image(systemName: url?.hasPrefix("https://") == true ? "lock.fill" : Glyph.symbol(0xE774))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 16)
                    Text(url ?? "").font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
                .padding(.horizontal, 6)
                BarIcon(symbol: Glyph.symbol(0xE8A7), tip: "Open in your browser", enabled: url != nil) { openWebURL(url) }
            }
            .padding(.bottom, 8)
        }
    }
}

private struct LiveRunBrowserBar: View {
    @ObservedObject var browser: Browser
    /// The served address, shown until the browser reports its own.
    var url: String?
    @State private var address = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    private var shown: String? { browser.url ?? url }

    var body: some View {
        let ready = browser.ready
        HStack(spacing: 2) {
            BarIcon(symbol: "arrow.left", tip: "Back", enabled: ready && browser.canGoBack) { browser.goBack() }
            BarIcon(symbol: Glyph.symbol(0xE72A), tip: "Forward", enabled: ready && browser.canGoForward) { browser.goForward() }
            BarIcon(symbol: Glyph.symbol(0xE72C), tip: "Reload the page", enabled: ready) { browser.reload() }
            HStack(spacing: 8) {
                Image(systemName: shown?.hasPrefix("https://") == true ? "lock.fill" : Glyph.symbol(0xE774))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 16)
                TextField("Enter a web address", text: $address)
                    .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit(go)
                    .onExitCommand { address = shown ?? ""; invalid = false; focused = false }
                    .onChange(of: address) { _, _ in invalid = false }
                    .help(invalid ? "Enter a web address: http, https or about:blank." : "")
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(invalid ? Theme.danger : focused ? Theme.accentDim : Theme.line, lineWidth: 1))
            .padding(.horizontal, 6)
            BarIcon(symbol: Glyph.symbol(0xE8A7), tip: "Open in your browser", enabled: shown != nil) { openWebURL(shown) }
        }
        .padding(.bottom, 8)
        .onAppear { address = shown ?? "" }
        // Page events must not replace an address while it is being typed.
        .onChange(of: shown) { _, s in if !focused { address = s ?? "" } }
        .onChange(of: focused) { _, f in
            if f { selectAllOnMouseUp { focused } } else { address = shown ?? ""; invalid = false }
        }
    }

    /// Enter opens the typed address once the browser is up; until then the address can be copied, not opened.
    private func go() {
        guard browser.ready else { return }
        guard let u = browserAddress(address) else { invalid = true; NSSound.beep(); return }
        browser.load(u)
        focused = false
        address = u
    }
}

/// A click into an address field takes the whole address, as a browser's does, so typing replaces it. The field editor
/// places the caret when the button comes up, so the selection waits for that; `stillFocused` drops it once the field
/// has lost focus meanwhile.
@MainActor
func selectAllOnMouseUp(tries: Int = 50, _ stillFocused: @escaping @MainActor () -> Bool) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
        guard stillFocused() else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 && tries > 0 { selectAllOnMouseUp(tries: tries - 1, stillFocused); return }
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }
}
