// A session's shared browser, as the Mac's browser column (SharedBrowserScreen.swift) on a phone: the headless Chromium on
// the server that the session's agent drives, shown full screen as the frames its event stream sends
// (`GET …/browser/stream`) and driven by touch (`POST …/browser/input`), on the same tabs at the same time. A tap clicks,
// a drag scrolls the page (or, in Drag mode, presses, moves and lets go), and the keyboard types into the page, with
// Escape, Tab and the arrows over it. The tabs, the address and switching the browser on and off are above the picture.
// The stream's parser, the tabs, the fit of the picture, the input queue and typed addresses are the core's
// (Mac/Core/SharedBrowser.swift).
import ImageIO
import SwiftUI
import UIKit

// MARK: - The feed

/// One picture of the tab in view, and the page's size in CSS pixels, the space input coordinates are in.
struct BrowserPicture {
    let image: CGImage
    let width: Int
    let height: Int
}

/// The event stream's side of the screen: frames are decoded on the stream's own queue, and the latest tabs and picture
/// wait here until the main thread takes them; older ones are dropped.
final class BrowserFeedSink: @unchecked Sendable {
    private static let maxSide = 8192
    private let lock = NSLock()
    private weak var model: SharedBrowserModel?
    private var tabs: JSON?
    private var picture: BrowserPicture?
    private var heard = false, closed = false, posted = false, detached = false

    init(model: SharedBrowserModel) { self.model = model }

    /// Nothing more is handed on.
    func detach() { lock.lock(); detached = true; lock.unlock() }

    func take(_ event: String, _ data: String) {
        switch event {
        case "frame":
            guard let j = JSON.parse(Data(data.utf8)), let bytes = base64Decode(j["data"].string),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width <= BrowserFeedSink.maxSide, image.height <= BrowserFeedSink.maxSide else { return }
            let fw = j["width"].int ?? 0, fh = j["height"].int ?? 0
            let p = BrowserPicture(image: image, width: fw > 0 ? fw : image.width, height: fh > 0 ? fh : image.height)
            lock.lock(); picture = p; heard = true; postLocked(); lock.unlock()
        case "tabs":
            guard let j = JSON.parse(Data(data.utf8)) else { return }
            lock.lock(); tabs = j; heard = true; postLocked(); lock.unlock()
        case "closed":
            lock.lock(); closed = true; postLocked(); lock.unlock()
        default: break
        }
    }

    /// With the lock held.
    private func postLocked() {
        guard !posted, !detached else { return }
        posted = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let model = self.model else { return }
                model.drain(self)
            }
        }
    }

    func takeAll() -> (tabs: JSON?, picture: BrowserPicture?, heard: Bool, closed: Bool) {
        lock.lock(); defer { lock.unlock() }
        let out = (tabs, picture, heard, closed)
        tabs = nil; picture = nil; heard = false; closed = false; posted = false
        return out
    }
}

// MARK: - The model

@MainActor
final class SharedBrowserModel: ObservableObject {
    let session: JSON
    let sessionID: String
    @Published private(set) var state: BrowserState
    @Published private(set) var stateRead = false
    @Published private(set) var starting = false
    @Published private(set) var stopping = false
    /// The conversation is closed, and its browser with it until it is reopened.
    @Published private(set) var closedSession = false
    /// The last failure of an action, shown over the picture.
    @Published private(set) var error: String?
    /// Why the state could not be read; gone once it or the stream comes through.
    @Published private(set) var stateError: String?
    @Published private(set) var feeding = false
    @Published var address = ""
    /// A drag presses, moves and lets go in the page instead of scrolling it.
    @Published var dragMode = false
    /// The keyboard types into the page.
    @Published var typing = false
    var addressFocused = false

    weak var canvas: BrowserCanvas? { didSet { canvas?.picture = picture; canvas?.note = note } }
    private(set) var picture: BrowserPicture?
    private var inputs = BrowserInputs()
    private var sendingInput = false
    private var stateLoading = false
    private var sink: BrowserFeedSink?
    private var feedTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Reads the state while the browser is down: the agent's next turn starts it.
    private var pollTask: Task<Void, Never>?
    private var failures = 0
    private var shown = false

    init(session: JSON) {
        self.session = session
        sessionID = session["id"].string ?? ""
        // The session record says whether the browser is on before the first read does.
        let on = BrowserState.sessionOn(session)
        state = BrowserState(on: on.on, running: on.running)
    }

    var title: String { Session(raw: session).displayTitle }
    var canDrive: Bool { Store.shared.canManage && Store.shared.supports("browser_input") }
    var note: String { feeding ? "Waiting for the first picture\u{2026}" : "Connecting to the browser\u{2026}" }

    // MARK: Shown or not

    /// Frames are only sent while somebody watches: hidden, or with the app in the background, the stream stops.
    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        if on {
            readState()
            startFeed()
        } else {
            stopFeed()
            pollTask?.cancel(); pollTask = nil
        }
    }

    private func show(_ p: BrowserPicture?) {
        picture = p
        canvas?.picture = p
    }
    private func setFeeding(_ on: Bool) {
        feeding = on
        canvas?.note = note
    }

    private func startFeed() {
        guard feedTask == nil, shown, state.running, Store.shared.supports("browser_stream"), let client = Store.shared.client else { return }
        let sink = BrowserFeedSink(model: self)
        self.sink = sink
        setFeeding(true)
        let args: JSON = ["sessionId": .string(sessionID)]
        feedTask = Task { [weak self] in
            var failure: Error?
            do { try await client.stream("browser_stream", args) { event, data in sink.take(event, data) } } catch { failure = error }
            self?.feedEnded(sink, failure)
        }
    }
    private func stopFeed() {
        sink?.detach(); sink = nil
        feedTask?.cancel(); feedTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        setFeeding(false)
    }

    /// What the stream brought since last time.
    func drain(_ sink: BrowserFeedSink) {
        guard sink === self.sink else { return }
        let d = sink.takeAll()
        if d.heard { failures = 0; stateError = nil }
        if let p = d.picture { show(p) }
        if let tabs = d.tabs { state.read(tabs); syncAddress() }
        if d.closed { wentDown(); readState() }
    }
    private func feedEnded(_ sink: BrowserFeedSink, _ failure: Error?) {
        guard sink === self.sink else { return }
        drain(sink)
        guard sink === self.sink else { return }
        stopFeed()
        let e = failure as? APIError
        if let e, e.unauthorized {
            if Store.shared.connected { Store.shared.invalidateCredentials(e) }
        } else if let e, e.kind == .http, e.status == 409 {
            wentDown(); readState()
        } else if e?.kind != .cancelled && shown {
            // A dropped connection: back after a pause that grows while it keeps failing.
            let delay = pollDelay(base: 1, failures: failures, retryAfter: e?.retryAfter)
            failures += 1
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.reconnectTask = nil
                self.startFeed()
            }
        }
    }

    /// The browser went down: the stream stops and the picture goes; the state is polled until it comes back.
    private func wentDown() {
        state.running = false
        stopFeed()
        show(nil)
        inputs.removeAll()
        typing = false
        startPolling()
    }
    private func cameUp() {
        pollTask?.cancel(); pollTask = nil
        failures = 0
        startFeed()
        syncAddress()
    }
    private func startPolling() {
        guard shown, pollTask == nil else { return }
        pollTask = Task {
            await poll(every: 5, immediately: false) { [weak self] in await self?.readStateNow() }
        }
    }

    // MARK: Reading and switching

    func readState() { Task { await readStateNow() } }
    private func readStateNow() async -> APIError? {
        guard !stateLoading, Store.shared.supports("browser") else { return nil }
        stateLoading = true
        defer { stateLoading = false }
        do {
            let answer = try await Store.shared.call("browser", ["sessionId": .string(sessionID)])
            stateRead = true
            closedSession = false
            stateError = nil
            state.read(answer["browser"])
            if state.running { cameUp() } else { wentDown() }
            return nil
        } catch {
            stateRead = true
            if error.isCancellation { return APIError(.cancelled) }
            stateError = errorText(error)
            // A read that failed is tried again, sooner or later as the server says.
            startPolling()
            return error as? APIError ?? APIError(.network, message: errorText(error))
        }
    }

    /// Switching off is confirmed by the screen first.
    func switchBrowser(on: Bool) {
        guard !starting, !stopping, Store.shared.supports(on ? "browser_on" : "browser_off") else { return }
        if on { starting = true } else { stopping = true }
        error = nil
        Task {
            do {
                let answer = try await Store.shared.call(on ? "browser_on" : "browser_off", ["sessionId": .string(sessionID)])
                starting = false; stopping = false
                error = nil
                if on {
                    state.read(answer["browser"])
                    state.on = true
                    if state.running { cameUp() } else { wentDown() }
                } else {
                    state = BrowserState()
                    wentDown()
                }
                // The conversation's 🌐 line and menu read the session record.
                if let repo = Session(raw: session).repo { Task { try? await Store.shared.feed(repo).loadSessions(fresh: true) } }
            } catch {
                starting = false; stopping = false
                if error.isCancellation { return }
                self.error = errorText(error)
                // 409: the conversation is closed, and its browser with it until it is reopened.
                if on, let e = error as? APIError, e.kind == .http, e.status == 409 { closedSession = true }
            }
        }
    }

    /// The page reloads and the state is read again.
    func refresh() {
        if state.running { send(["type": "reload"]) }
        readState()
    }

    // MARK: Input

    /// Input goes one at a time, in order; what waits merges so a slow link catches up.
    func send(_ input: JSON?) {
        guard let input, canDrive, state.running else { return }
        inputs.push(input)
        pump()
    }
    private func pump() {
        guard !sendingInput, state.running, var input = inputs.pop() else { return }
        input["sessionId"] = .string(sessionID)
        sendingInput = true
        Task {
            do {
                _ = try await Store.shared.call("browser_input", input)
                sendingInput = false
                if error != nil { error = nil }
            } catch {
                sendingInput = false
                // 409: it stopped under us; what was waiting is for a page that is gone.
                if let e = error as? APIError, e.kind == .http, e.status == 409 { inputs.removeAll(); wentDown(); readState() }
                if !error.isCancellation { self.error = errorText(error) }
            }
            pump()
        }
    }

    func key(_ name: String, modifiers: [String] = []) {
        var j: JSON = ["type": "key", "key": .string(name)]
        if !modifiers.isEmpty { j["modifiers"] = JSON(modifiers) }
        send(j)
    }
    func type(_ text: String) {
        guard !text.isEmpty else { return }
        send(["type": "type", "text": .string(text.replacingOccurrences(of: "\r\n", with: "\n"))])
    }
    func tab(_ id: String, close: Bool = false) { send(["type": .string(close ? "closeTab" : "tab"), "tab": .string(id)]) }
    func closeActiveTab() { if let t = state.activeTab { tab(t.id, close: true) } }
    func newTab() { send(["type": "newTab"]) }

    /// Goes to the address typed; false when it is not one.
    @discardableResult
    func navigate() -> Bool {
        guard let url = browserAddress(address) else { error = "Enter a web address: http, https or about:blank."; return false }
        send(["type": "navigate", "url": .string(url)])
        return true
    }
    func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        type(text)
    }
    /// The address field shows the tab in view's address, unless it is being typed in.
    func syncAddress() {
        guard !addressFocused else { return }
        let t = state.activeTab
        address = t.map { $0.url == "about:blank" ? "" : $0.url } ?? ""
    }
    func setTyping(_ on: Bool) {
        typing = on && state.running && canDrive
        if typing { _ = canvas?.becomeFirstResponder() } else { _ = canvas?.resignFirstResponder() }
    }
}

// MARK: - The picture

/// The page as its frames show it, driven by touch: a tap clicks (two quick taps in one place double-click), a drag
/// scrolls the page by as much as the finger moved over it, or in Drag mode presses, moves and lets go; while typing,
/// the keyboard's text goes to the page, with Escape, Tab and the arrows on a bar above it. A hardware keyboard's
/// arrows, Escape and ⌘ shortcuts go too, ⌘ standing for the page's Ctrl as on the Mac.
final class BrowserCanvas: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    weak var model: SharedBrowserModel?
    var picture: BrowserPicture? { didSet { setNeedsDisplay() } }
    var note = "" { didSet { if oldValue != note { setNeedsDisplay() } } }
    /// Where the picture was last drawn.
    private var drawn = BrowserRect()
    private var dragging = false
    private var lastTap: (at: CGPoint, time: TimeInterval)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        isOpaque = true
        backgroundColor = UIColor(Theme.surface)
        isMultipleTouchEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityLabel = "Shared browser page"
        accessibilityTraits = .allowsDirectInteraction
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        UIColor(Theme.surface).setFill()
        UIRectFill(bounds)
        if let p = picture {
            let r = browserFit(viewW: Int(bounds.width), viewH: Int(bounds.height), frameW: p.width, frameH: p.height)
            drawn = r
            UIImage(cgImage: p.image).draw(in: CGRect(x: r.left, y: r.top, width: r.width, height: r.height))
        } else {
            drawn = BrowserRect()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.preferredFont(forTextStyle: .subheadline), .foregroundColor: UIColor.secondaryLabel]
            let s = NSAttributedString(string: note, attributes: attrs)
            let size = s.size()
            s.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
    }

    /// A pointer input at a view point, or nil off the picture.
    private func pointer(_ type: String, _ p: CGPoint) -> JSON? {
        guard let pic = picture,
              let page = browserPagePoint(drawn: drawn, frameW: pic.width, frameH: pic.height, x: Int(floor(p.x)), y: Int(floor(p.y))) else { return nil }
        return ["type": .string(type), "x": JSON(floor(page.x)), "y": JSON(floor(page.y))]
    }
    /// Page pixels per point of the picture on screen.
    private var scale: CGFloat {
        guard let pic = picture, drawn.width > 0 else { return 1 }
        return CGFloat(pic.width) / CGFloat(drawn.width)
    }

    // MARK: Touch

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        guard var click = pointer("click", p) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastTap, now - last.time < 0.35, abs(last.at.x - p.x) + abs(last.at.y - p.y) < 24 {
            click["clickCount"] = JSON(2)
            lastTap = nil
        } else {
            lastTap = (p, now)
        }
        model?.send(click)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let drag = model?.dragMode == true && g.numberOfTouches <= 1
        switch g.state {
        case .began:
            if drag, let down = pointer("down", g.location(in: self)) {
                dragging = true
                model?.send(down)
            }
        case .changed:
            if dragging {
                model?.send(pointer("move", g.location(in: self)))
            } else {
                let t = g.translation(in: self)
                g.setTranslation(.zero, in: self)
                guard var wheel = pointer("wheel", g.location(in: self)) ?? pointer("wheel", CGPoint(x: bounds.midX, y: bounds.midY)) else { return }
                // The page moves with the finger, as a scroll view does.
                let dx = -t.x * scale, dy = -t.y * scale
                guard dx != 0 || dy != 0 else { return }
                wheel["deltaX"] = JSON(Double(dx))
                wheel["deltaY"] = JSON(Double(dy))
                model?.send(wheel)
            }
        case .ended, .cancelled, .failed:
            if dragging {
                dragging = false
                let at = g.location(in: self), c = drawn.clamped(x: at.x, y: at.y)
                model?.send(pointer("up", at) ?? pointer("up", CGPoint(x: c.x, y: c.y)) ?? ["type": "up"])
            }
        default: break
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { model?.typing == true }
    override func resignFirstResponder() -> Bool {
        let done = super.resignFirstResponder()
        // The keyboard went some other way (another field took it): the Type button says so.
        if done, let model, model.typing { DispatchQueue.main.async { model.typing = false } }
        return done
    }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }

    func insertText(_ text: String) {
        // Return and Tab are keys in the page, not characters.
        var run = ""
        for c in text {
            if c == "\n" || c == "\r" || c == "\t" {
                model?.type(run); run = ""
                model?.key(c == "\t" ? "Tab" : "Enter")
            } else {
                run.append(c)
            }
        }
        model?.type(run)
    }
    func deleteBackward() { model?.key("Backspace") }

    /// Escape, Tab, the arrows and Paste over the keyboard, which a phone's keyboard has none of.
    private lazy var keyBar: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        func item(_ title: String?, _ symbol: String?, _ label: String, _ action: @escaping () -> Void) -> UIBarButtonItem {
            let a = UIAction { _ in action() }
            let b = symbol.map { UIBarButtonItem(image: UIImage(systemName: $0), primaryAction: a) } ?? UIBarButtonItem(title: title, primaryAction: a)
            b.accessibilityLabel = label
            return b
        }
        bar.items = [
            item("esc", nil, "Escape") { [weak self] in self?.model?.key("Escape") },
            item("tab", nil, "Tab") { [weak self] in self?.model?.key("Tab") },
            item(nil, "arrow.left", "Arrow left") { [weak self] in self?.model?.key("ArrowLeft") },
            item(nil, "arrow.up", "Arrow up") { [weak self] in self?.model?.key("ArrowUp") },
            item(nil, "arrow.down", "Arrow down") { [weak self] in self?.model?.key("ArrowDown") },
            item(nil, "arrow.right", "Arrow right") { [weak self] in self?.model?.key("ArrowRight") },
            item(nil, "doc.on.clipboard", "Paste") { [weak self] in self?.model?.paste() },
            .flexibleSpace(),
            item(nil, "keyboard.chevron.compact.down", "Hide keyboard") { [weak self] in self?.model?.setTyping(false) },
        ]
        bar.sizeToFit()
        return bar
    }()
    override var inputAccessoryView: UIView? { keyBar }

    override func paste(_ sender: Any?) { model?.paste() }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) ? UIPasteboard.general.hasStrings : false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key, model?.typing == true, let name = Self.keyName(key) else { rest.insert(press); continue }
            if name == "paste" { model?.paste(); continue }
            var mods: [String] = []
            if key.modifierFlags.contains(.alternate) { mods.append("alt") }
            if key.modifierFlags.contains(.command) || key.modifierFlags.contains(.control) { mods.append("ctrl") }
            if key.modifierFlags.contains(.shift) { mods.append("shift") }
            model?.key(name, modifiers: mods)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    /// The key a hardware key press sends to the page, or nil for one typed as text (Return, Tab and Backspace too).
    /// "paste" for ⌘V.
    private static func keyName(_ key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardLeftArrow: return "ArrowLeft"
        case .keyboardRightArrow: return "ArrowRight"
        case .keyboardUpArrow: return "ArrowUp"
        case .keyboardDownArrow: return "ArrowDown"
        case .keyboardEscape: return "Escape"
        case .keyboardHome: return "Home"
        case .keyboardEnd: return "End"
        case .keyboardPageUp: return "PageUp"
        case .keyboardPageDown: return "PageDown"
        case .keyboardDeleteForward: return "Delete"
        default: break
        }
        guard key.modifierFlags.contains(.command) || key.modifierFlags.contains(.control) else { return nil }
        let c = key.charactersIgnoringModifiers.lowercased()
        guard c.count == 1, let s = c.unicodeScalars.first, s.isASCII,
              ("a"..."z").contains(Character(s)) || ("0"..."9").contains(Character(s)) else { return nil }
        if c == "v" && key.modifierFlags.contains(.command) { return "paste" }
        return c
    }

    // MARK: Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
}

private struct BrowserCanvasView: UIViewRepresentable {
    let model: SharedBrowserModel
    func makeUIView(context: Context) -> BrowserCanvas {
        let v = BrowserCanvas(frame: .zero)
        v.model = model
        model.canvas = v
        return v
    }
    func updateUIView(_ v: BrowserCanvas, context: Context) {
        v.model = model
        if model.canvas !== v { model.canvas = v }
    }
}

// MARK: - The screen

struct SharedBrowserScreen: View {
    @StateObject private var model: SharedBrowserModel
    @ObservedObject private var store = Store.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var addressFocused: Bool
    @State private var confirmOff = false

    init(session: JSON) {
        _model = StateObject(wrappedValue: SharedBrowserModel(session: session))
    }

    private var state: BrowserState { model.state }
    private var running: Bool { model.stateRead && state.running }
    private var busy: Bool { model.starting || model.stopping }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if running { live } else { off }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background)
            .navigationTitle(running ? state.activeTab?.label ?? "Browser" : "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar { toolbar }
        }
        .onAppear { model.setShown(store.active); model.syncAddress() }
        .onDisappear { model.setShown(false) }
        .onChange(of: store.active) { _, active in model.setShown(active) }
        .onChange(of: addressFocused) { _, focused in
            model.addressFocused = focused
            if focused { model.setTyping(false) } else { model.syncAddress() }
        }
        .alert("Switch the browser off?", isPresented: $confirmOff) {
            Button("Switch Off", role: .destructive) { model.switchBrowser(on: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent loses its browser tools until it is switched on again. Its tabs close; cookies and logins are kept until the conversation is deleted.")
        }
    }

    // MARK: The toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if running && !state.tabs.isEmpty { tabsMenu }
            moreMenu
        }
    }

    /// The tabs, the one in view ticked, with New Tab and Close This Tab.
    private var tabsMenu: some View {
        Menu {
            Section {
                ForEach(state.tabs.prefix(50), id: \.id) { t in
                    Button { if t.id != state.active { model.tab(t.id) } } label: {
                        if t.id == state.active { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                    }
                    .disabled(!model.canDrive)
                }
            }
            if model.canDrive {
                Section {
                    Button("New Tab", systemImage: "plus") { model.newTab(); addressFocused = true }
                    Button("Close This Tab", systemImage: "xmark", role: .destructive) { model.closeActiveTab() }
                        .disabled(state.activeTab == nil)
                }
            }
        } label: {
            Image(systemName: "square.on.square")
                .overlay(alignment: .topTrailing) {
                    Text(String(state.tabs.count)).font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15).background(Theme.accent, in: Capsule())
                        .offset(x: 8, y: -7)
                }
        }
        .accessibilityLabel("Tabs, \(state.tabs.count)")
    }

    /// Reload, and switching the browser on or off.
    private var moreMenu: some View {
        Menu {
            Button("Reload", systemImage: "arrow.clockwise") { model.refresh() }
            if store.canManage && state.on && store.supports("browser_off") {
                Button("Switch the Browser Off\u{2026}", systemImage: "power", role: .destructive) { confirmOff = true }.disabled(busy)
            } else if store.canManage && store.supports("browser_on") {
                Button("Start the Browser", systemImage: "play") { model.switchBrowser(on: true) }.disabled(busy)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Browser actions")
    }

    // MARK: Off, or reading

    @ViewBuilder private var off: some View {
        let notice = model.error ?? model.stateError
        ScrollView {
            VStack(spacing: 12) {
                if let notice { ErrorNotice(message: notice) }
                if !model.stateRead {
                    ProgressView("Reading the browser\u{2026}").padding(.top, 40)
                } else {
                    let title = model.starting ? "Starting the browser\u{2026}" : state.on ? "The browser is switched on but not running" : "The shared browser is off"
                    let detail = model.closedSession ? "This conversation is closed. Reopen it, then start the browser."
                        : state.on ? "It starts with the agent\u{2019}s next turn, or start it now. Its cookies and logins are still there."
                        : "Switch on a Chromium of this session\u{2019}s own: the agent drives it with its browser tools, and you watch and use it here at the same time, on the same tabs. You can log in for the agent or take over a step and hand back with a message."
                    ContentUnavailableView {
                        Label(title, systemImage: "globe")
                    } description: {
                        Text(detail)
                    } actions: {
                        if store.canManage && store.supports("browser_on") {
                            Button { model.switchBrowser(on: true) } label: {
                                Text(model.starting ? "Starting\u{2026}" : "Start the Browser").fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(busy)
                        }
                    }
                }
            }
            .padding(16)
        }
        .refreshable { model.readState() }
    }

    // MARK: Running

    @ViewBuilder private var live: some View {
        let drive = model.canDrive
        let notice = model.error ?? model.stateError
        VStack(spacing: 8) {
            // Back, forward and reload, then the tab in view's address, and where to go on Go.
            HStack(spacing: 4) {
                barButton("chevron.backward", "Back", enabled: drive) { model.send(["type": "back"]) }
                barButton("chevron.forward", "Forward", enabled: drive) { model.send(["type": "forward"]) }
                HStack(spacing: 6) {
                    Image(systemName: state.activeTab?.url.hasPrefix("https://") == true ? "lock.fill" : "globe")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Enter a web address", text: $model.address)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .disabled(!drive)
                        .onSubmit { if model.navigate() { addressFocused = false } }
                }
                .padding(.horizontal, 10).frame(height: 36)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                barButton("arrow.clockwise", "Reload", enabled: drive) { model.send(["type": "reload"]) }
            }
            if let notice { ErrorNotice(message: notice) }
            if drive {
                HStack(spacing: 12) {
                    Picker("A drag", selection: $model.dragMode) {
                        Text("Scroll").tag(false)
                        Text("Drag").tag(true)
                    }
                    .pickerStyle(.segmented).fixedSize()
                    Spacer(minLength: 0)
                    Button { addressFocused = false; model.setTyping(!model.typing) } label: {
                        Image(systemName: model.typing ? "keyboard.chevron.compact.down" : "keyboard")
                    }
                    .accessibilityLabel(model.typing ? "Hide keyboard" : "Type into the page")
                    Button { model.paste() } label: { Image(systemName: "doc.on.clipboard") }
                        .accessibilityLabel("Paste into the page")
                }
                .font(.body)
            } else {
                Text("Watching only: this token cannot act in the browser.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // The picture fills what is left.
        BrowserCanvasView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    private func barButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 34, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
