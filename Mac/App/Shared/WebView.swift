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
    /// The session serving the page, which feedback goes to; nil offers none.
    var session: String? = nil
    var feedback: PreviewFeedback? = nil

    var body: some View {
        if let browser {
            HStack(spacing: 0) {
                LiveRunBrowserBar(browser: browser, url: url)
                if let feedback, session != nil, PreviewFeedback.offered {
                    PreviewFeedbackButton(feedback: feedback, browser: browser).padding(.bottom, 8)
                }
            }
        } else {
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

// MARK: - Feedback on a preview

/// Feedback on the page a session serves (core /sessions/{id}/preview/feedback): a point marked on the page, a comment,
/// and a snapshot of the page with the point drawn on it, sent to the session's agent as a message.
@MainActor
final class PreviewFeedback: ObservableObject {
    /// Waiting for the click that marks the point.
    @Published var marking = false
    @Published var sending = false
    @Published var result: String?

    static var offered: Bool { Store.shared.canManage && Store.shared.supports("preview_feedback") && Store.shared.supports("upload") }

    /// The page was clicked at `point` (in the browser view's coordinates): asks the comment, snapshots the page with the
    /// point drawn, uploads it and sends the feedback.
    func mark(_ point: CGPoint, browser: Browser, session: String) {
        marking = false
        guard let url = browser.url ?? browser.webView.url?.absoluteString,
              let text = Dialogs.text("Feedback on this spot", label: "What should change here? The agent gets it with a screenshot of the page, the spot marked.",
                                      okLabel: "Send", multiline: true)?.cTrimmed, !text.isEmpty else { return }
        sending = true; result = nil
        let config = WKSnapshotConfiguration()
        browser.webView.takeSnapshot(with: config) { image, error in
            Task { @MainActor in
                guard let image, let png = Self.annotated(image, point: point, viewSize: browser.webView.bounds.size) else {
                    self.sending = false; self.result = error?.localizedDescription ?? "The page could not be captured."; return
                }
                do {
                    let uploadID = try await Store.shared.upload(name: "preview-feedback.png", bytes: png.data)
                    let r = await boardCall("preview_feedback", ["sessionId": .string(session), "url": .string(url), "text": .string(text),
                                                                "uploadId": .string(uploadID), "width": JSON(png.width), "height": JSON(png.height),
                                                                "x": JSON(png.x), "y": JSON(png.y)])
                    self.result = r.error.map { $0.message ?? $0.description } ?? "Sent to the session's agent."
                } catch {
                    self.result = errorText(error)
                }
                self.sending = false
            }
        }
    }

    /// The snapshot as a PNG with a ring around the point, and the point in its pixels.
    static func annotated(_ image: NSImage, point: CGPoint, viewSize: CGSize) -> (data: Data, width: Int, height: Int, x: Double, y: Double)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), viewSize.width > 0, viewSize.height > 0 else { return nil }
        let w = cg.width, h = cg.height
        let sx = Double(w) / viewSize.width, sy = Double(h) / viewSize.height
        let px = min(max(point.x * sx, 0), Double(w - 1)), py = min(max(point.y * sy, 0), Double(h - 1))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The image's origin is at the bottom left.
        let r = 18 * sx
        ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineWidth(4 * sx)
        ctx.strokeEllipse(in: CGRect(x: px - r, y: Double(h) - py - r, width: 2 * r, height: 2 * r))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, w, h, px, py)
    }
}

/// While marking, a layer over the page that takes the click.
struct PreviewFeedbackLayer: View {
    @ObservedObject var feedback: PreviewFeedback
    var browser: Browser
    var session: String
    var body: some View {
        if feedback.marking {
            GeometryReader { _ in
                Color.accentColor.opacity(0.06)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in feedback.mark(p, browser: browser, session: session) }
                    .overlay(alignment: .top) {
                        Text("Click the spot your feedback is about · Esc cancels").font(Theme.footnote).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Theme.accent)).padding(.top, 10)
                    }
                    .onExitCommand { feedback.marking = false }
            }
            .onHover { $0 ? NSCursor.crosshair.push() : NSCursor.pop() }
        }
    }
}

/// 💬 in the address bar: marks a spot, then sends the feedback.
struct PreviewFeedbackButton: View {
    @ObservedObject var feedback: PreviewFeedback
    /// Observed, so the button comes alive once the page is up.
    @ObservedObject var browser: Browser
    private var enabled: Bool { browser.ready }
    var body: some View {
        HStack(spacing: 6) {
            BarIcon(symbol: "text.bubble", tip: feedback.marking ? "Cancel marking" : "Feedback on a spot of this page, to the session's agent",
                    enabled: enabled && !feedback.sending) { feedback.marking.toggle() }
            if feedback.sending { Text("Sending…").font(Theme.caption).foregroundStyle(Theme.muted) }
            else if let r = feedback.result { Text(r).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
        }
    }
}
