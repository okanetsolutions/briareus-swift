// A session's shared browser (screen_browser.c), as the dashboard's browser panel: the headless Chromium on the server that
// the session's agent drives through Playwright, shown here as the frames its event stream sends and driven with this
// Mac's mouse and keyboard (`POST …/browser/input`), on the same tabs at the same time. As Claude's browser pane, it docks
// as a column beside the conversation under a compact bar of its own (the tabs and ＋, pop out, ⋯, expand and close, then
// back, forward, reload and the address), and pops out into a window of its own that can dock again.
import AppKit
import ImageIO
import SwiftUI

// MARK: - Docked, or in a window of its own

/// Where a session's browser is shown: docked in the main window, in the pull request panel's place, or in a window of
/// its own (BrowserWindows). The main window's layout reads this.
@MainActor
final class BrowserDock: ObservableObject {
    static let shared = BrowserDock()
    nonisolated static let minWidth: CGFloat = 360, detailMinWidth: CGFloat = 380, dividerWidth: CGFloat = 6

    /// The session whose browser docks beside its conversation; nil when none does.
    @Published private(set) var session: JSON?
    /// Expanded over the conversation.
    @Published var expanded = false
    /// The column's width as its divider left it; nil for 45% of what is beside the sidebar.
    @Published var width: CGFloat?
    @Published var dragging = false

    var sessionID: String? { session?["id"].string }

    func dock(_ session: JSON?) {
        if session == nil { expanded = false }
        self.session = session
    }
    /// The docked browser belongs to the conversation beside it: another page in the detail takes it away.
    func detailChanged(to screen: Screen) {
        guard let id = sessionID, screen.id != "conversation:\(id)" else { return }
        dock(nil)
    }
    /// Signing out: the docked browser and every window go.
    func reset() {
        dock(nil)
        BrowserWindows.shared.closeAll()
    }

    /// The main window has room for the column and is on show.
    var dockable: Bool { !Navigator.shared.isNarrow && !(BrowserWindows.mainWindow?.isMiniaturized ?? false) }
    /// Whether the session's conversation is the page in the detail, which the browser can dock beside.
    static func conversationShown(_ id: String) -> Bool { Navigator.shared.root.id == "conversation:\(id)" }

    /// The browser's width beside the detail in a window `total` wide, the divider not counted (main.c browser_split).
    nonisolated static func columnWidth(total: CGFloat, expanded: Bool, width: CGFloat?) -> CGFloat {
        let avail = total - Theme.sidebarWidth
        if expanded { return avail }
        let hi = avail - dividerWidth - detailMinWidth
        var w = width ?? avail * 0.45
        if w > hi { w = hi }
        if w < minWidth { w = hi < minWidth ? avail / 2 : minWidth }
        return w
    }

    /// The conversation's 🌐 Browser: brings the session's own window forward when it has one, closes the docked browser
    /// when it is the one docked, and otherwise docks it beside the conversation, or, in a window too narrow for the
    /// column, opens it in a window of its own.
    static func open(_ session: Session) {
        let dock = BrowserDock.shared
        if BrowserWindows.shared.bringForward(session.id) { return }
        if dock.sessionID == session.id { dock.dock(nil); return }
        if dock.dockable { dock.dock(session.raw); return }
        BrowserWindows.shared.open(session.raw, at: nil)
    }
}

/// The popped-out browsers: a window each, titled after the page in view, with a taskbar presence of its own.
@MainActor
final class BrowserWindows: NSObject, NSWindowDelegate {
    static let shared = BrowserWindows()
    private var windows: [String: NSWindow] = [:]

    /// The main window: the one that is neither a browser's nor a panel.
    static var mainWindow: NSWindow? {
        let others = NSApp.windows.filter { w in !(w is NSPanel) && !shared.windows.values.contains { $0 === w } && w.contentView != nil }
        return others.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? others.first
    }

    func isOpen(_ id: String) -> Bool { windows[id] != nil }
    /// Brings a session's window forward; false when it has none.
    func bringForward(_ id: String) -> Bool {
        guard let w = windows[id] else { return false }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        return true
    }

    /// Opens a session's browser in a window, over `at` (screen coordinates) when given: where it was docked.
    func open(_ session: JSON, at: NSRect?) {
        guard let id = session["id"].string else { return }
        if bringForward(id) { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 420, height: 320)
        w.title = "Browser"
        w.contentView = NSHostingView(rootView: SharedBrowserScreen(session: session, detached: true)
            .environmentObject(Store.shared).environmentObject(Navigator.shared)
            .foregroundStyle(Theme.ink))
        w.delegate = self
        if let at, at.width > 0, at.height > 0 {
            var frame = w.frameRect(forContentRect: NSRect(x: at.minX + 24, y: at.minY - 24, width: at.width, height: at.height))
            // Kept on the screen it popped out on.
            if let area = (NSScreen.screens.first { $0.frame.intersects(at) } ?? NSScreen.main)?.visibleFrame {
                frame.size.width = min(frame.width, area.width); frame.size.height = min(frame.height, area.height)
                frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
            }
            w.setFrame(frame, display: false)
        } else {
            w.center()
        }
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
    }

    func setTitle(_ title: String, for id: String) {
        if let w = windows[id], w.title != title { w.title = title }
    }
    func close(_ id: String) { windows[id]?.close() }
    func closeAll() { for w in Array(windows.values) { w.close() } }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = windows.first(where: { $0.value === w })?.key else { return }
        windows[id] = nil
        // The screen goes with its window, and its stream with it.
        w.contentView = nil
    }
}

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
    let detached: Bool
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
    @Published private(set) var focusAddressTick = 0
    var addressFocused = false
    /// The screen's frame in its window, for a pop out to open where the column was.
    var frameInWindow: CGRect = .zero

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

    init(session: JSON, detached: Bool) {
        self.session = session
        sessionID = session["id"].string ?? ""
        self.detached = detached
        // The session record says whether the browser is on before the first read does.
        let on = BrowserState.sessionOn(session)
        state = BrowserState(on: on.on, running: on.running)
    }

    var title: String { Session(raw: session).displayTitle }
    var canDrive: Bool { Store.shared.canManage && Store.shared.supports("browser_input") }
    var note: String { feeding ? "Waiting for the first picture\u{2026}" : "Connecting to the browser\u{2026}" }

    // MARK: Shown or not

    /// Frames are only sent while somebody watches: hidden, the stream stops.
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

    func switchBrowser(on: Bool) {
        guard !starting, !stopping, Store.shared.supports(on ? "browser_on" : "browser_off") else { return }
        if !on && !Dialogs.confirm("Switch the browser off?",
                                   "The agent loses its browser tools until it is switched on again. Its tabs close; cookies and logins are kept until the conversation is deleted.",
                                   continueLabel: "Switch off") { return }
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
                let repo = Session(raw: session).repo
                post(.sessionsChanged, repo.map { ["repo": $0] } ?? [:])
            } catch {
                starting = false; stopping = false
                if error.isCancellation { return }
                self.error = errorText(error)
                // 409: the conversation is closed, and its browser with it until it is reopened.
                if on, let e = error as? APIError, e.kind == .http, e.status == 409 { closedSession = true }
            }
        }
    }

    /// F5 or ⌘R: the page reloads and the state is read again.
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

    func tab(_ id: String, close: Bool = false) { send(["type": .string(close ? "closeTab" : "tab"), "tab": .string(id)]) }
    func closeActiveTab() { if let t = state.activeTab { tab(t.id, close: true) } }
    func newTab() {
        send(["type": "newTab"])
        focusAddress()
    }

    func navigate() {
        guard let url = browserAddress(address) else { error = "Enter a web address: http, https or about:blank."; return }
        send(["type": "navigate", "url": .string(url)])
        focusCanvas()
    }
    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        send(["type": "type", "text": .string(text.replacingOccurrences(of: "\r\n", with: "\n"))])
    }
    func focusAddress() { focusAddressTick += 1 }
    func focusCanvas() {
        if let canvas { canvas.window?.makeFirstResponder(canvas) }
    }
    /// The address field shows the tab in view's address, unless it is being typed in.
    func syncAddress() {
        guard !addressFocused else { return }
        let t = state.activeTab
        address = t.map { $0.url == "about:blank" ? "" : $0.url } ?? ""
    }
}

// MARK: - The picture

/// The page as its frames show it, driven with the mouse and keyboard: a press becomes a click when it is let go where it
/// started, else a drag of down, moves and up; the wheel scrolls; keys go to the page while it has the keyboard (a ring in
/// the accent says so). ⌘ stands for the page's Ctrl, as the shortcut key: ⌘A, ⌘C and ⌘V do there what they do here.
final class BrowserCanvas: NSView {
    weak var model: SharedBrowserModel?
    var picture: BrowserPicture? { didSet { needsDisplay = true } }
    var note = "" { didSet { if oldValue != note { needsDisplay = true } } }
    /// Where the picture was last drawn.
    private var drawn = BrowserRect()
    private var pressing = false, dragging = false
    private var pressAt = NSPoint.zero
    private var clicks = 1
    private var button = "left"

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingType: NSFocusRingType { get { .none } set {} }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The picture is centred: redrawn whole on a resize.
        needsDisplay = true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.sunken).setFill()
        bounds.fill()
        if let p = picture {
            var r = browserFit(viewW: Int(bounds.width) - 2, viewH: Int(bounds.height) - 2, frameW: p.width, frameH: p.height)
            r.left += 1; r.right += 1; r.top += 1; r.bottom += 1
            drawn = r
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: p.image, size: NSSize(width: p.image.width, height: p.image.height))
                .draw(in: NSRect(x: r.left, y: r.top, width: r.width, height: r.height), from: .zero, operation: .copy, fraction: 1,
                      respectFlipped: true, hints: nil)
        } else {
            drawn = BrowserRect()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(Theme.muted)]
            let s = NSAttributedString(string: note, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
        // A ring in the accent while keys go to the page.
        NSColor(window?.firstResponder === self ? Theme.accent : Theme.line).setStroke()
        let ring = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags, shift: Bool = true) -> [String] {
        var out: [String] = []
        if flags.contains(.option) { out.append("alt") }
        if flags.contains(.control) || flags.contains(.command) { out.append("ctrl") }
        if shift && flags.contains(.shift) { out.append("shift") }
        return out
    }
    private static func withModifiers(_ input: JSON, _ flags: NSEvent.ModifierFlags) -> JSON {
        var j = input
        let mods = modifiers(flags)
        if !mods.isEmpty { j["modifiers"] = JSON(mods) }
        return j
    }
    /// A pointer input at a view point, or nil off the picture.
    private func pointer(_ type: String, _ p: NSPoint, _ event: NSEvent) -> JSON? {
        guard let pic = picture,
              let page = browserPagePoint(drawn: drawn, frameW: pic.width, frameH: pic.height, x: Int(floor(p.x)), y: Int(floor(p.y))) else { return nil }
        return BrowserCanvas.withModifiers(["type": .string(type), "x": JSON(floor(page.x)), "y": JSON(floor(page.y))], event.modifierFlags)
    }

    // MARK: Mouse

    private func press(_ event: NSEvent, _ which: String) {
        window?.makeFirstResponder(self)
        if pressing { return }
        pressing = true; dragging = false
        pressAt = convert(event.locationInWindow, from: nil)
        clicks = event.clickCount >= 2 ? 2 : 1
        button = which
    }
    private func release(_ event: NSEvent) {
        guard pressing else { return }
        pressing = false
        if dragging {
            let at = convert(event.locationInWindow, from: nil), c = drawn.clamped(x: at.x, y: at.y)
            model?.send(pointer("up", at, event) ?? pointer("up", NSPoint(x: c.x, y: c.y), event) ?? ["type": "up"])
            return
        }
        guard var click = pointer("click", pressAt, event) else { return }
        if button != "left" { click["button"] = .string(button) }
        if clicks > 1 { click["clickCount"] = JSON(clicks) }
        model?.send(click)
    }
    override func mouseDown(with event: NSEvent) { press(event, "left") }
    override func rightMouseDown(with event: NSEvent) { press(event, "right") }
    override func otherMouseDown(with event: NSEvent) { press(event, "middle") }
    override func mouseUp(with event: NSEvent) { release(event) }
    override func rightMouseUp(with event: NSEvent) { release(event) }
    override func otherMouseUp(with event: NSEvent) { release(event) }
    override func mouseDragged(with event: NSEvent) {
        guard pressing, button == "left" else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragging && abs(p.x - pressAt.x) + abs(p.y - pressAt.y) > 4, let down = pointer("down", pressAt, event) {
            dragging = true
            model?.send(down)
        }
        if dragging { model?.send(pointer("move", p, event)) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard var wheel = pointer("wheel", convert(event.locationInWindow, from: nil), event) else { return }
        // A wheel's notch scrolls 100 pixels, as Chromium does; a trackpad scrolls by its own pixels.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 100
        let dx = -event.scrollingDeltaX * scale, dy = -event.scrollingDeltaY * scale
        guard dx != 0 || dy != 0 else { return }
        wheel["deltaX"] = JSON(Double(dx))
        wheel["deltaY"] = JSON(Double(dy))
        model?.send(wheel)
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command), control = flags.contains(.control)
        let letter = event.charactersIgnoringModifiers?.lowercased()
        if command && letter == "v" { model?.paste(); return }
        if command && letter == "l" { model?.focusAddress(); return }
        let name = browserKeyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        // Letters and digits are typed as text, unless a shortcut holds ⌘ or ⌃.
        if let name, name.count > 1 || command || control {
            model?.send(BrowserCanvas.withModifiers(["type": "key", "key": .string(name)], flags))
            return
        }
        if command || control { return }
        // Control characters came as keys already (Enter, Tab, Backspace), and the function keys have none to type.
        let text = String(String.UnicodeScalarView((event.characters ?? "").unicodeScalars.filter { s in
            s.value >= 0x20 && s.value != 0x7F && !(0xF700...0xF8FF).contains(s.value)
        }))
        if !text.isEmpty { model?.send(["type": "type", "text": .string(text)]) }
    }
}

private struct BrowserCanvasView: NSViewRepresentable {
    let model: SharedBrowserModel
    func makeNSView(context: Context) -> BrowserCanvas {
        let v = BrowserCanvas(frame: .zero)
        v.model = model
        model.canvas = v
        return v
    }
    func updateNSView(_ v: BrowserCanvas, context: Context) {
        v.model = model
        if model.canvas !== v { model.canvas = v }
    }
}

// MARK: - The screen

struct SharedBrowserScreen: View {
    var visible: Bool
    @StateObject private var model: SharedBrowserModel
    @ObservedObject private var store = Store.shared
    @ObservedObject private var dock = BrowserDock.shared
    @ObservedObject private var navigator = Navigator.shared
    @FocusState private var addressFocused: Bool

    init(session: JSON, detached: Bool, visible: Bool = true) {
        self.visible = visible
        _model = StateObject(wrappedValue: SharedBrowserModel(session: session, detached: detached))
    }

    private var state: BrowserState { model.state }
    private var canDock: Bool { dock.dockable && BrowserDock.conversationShown(model.sessionID) }
    private var windowTitle: String {
        let tab = state.running ? state.activeTab : nil
        return "\(tab?.label ?? "Browser") \u{00B7} \(model.title)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar.padding(.top, 4).padding(.bottom, 4)
            if !model.stateRead || !state.running { off } else { running }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.frameInWindow = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in model.frameInWindow = f }
        })
        .onAppear { model.setShown(visible); model.syncAddress(); titleWindow() }
        .onDisappear { model.setShown(false) }
        .onChange(of: visible) { _, v in model.setShown(v) }
        .onChange(of: windowTitle) { _, _ in titleWindow() }
        .onChange(of: model.focusAddressTick) { _, _ in addressFocused = true }
        .onChange(of: addressFocused) { _, focused in
            model.addressFocused = focused
            if focused {
                selectAllOnMouseUp { addressFocused }
            } else {
                model.syncAddress()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in if visible { model.refresh() } }
    }

    private func titleWindow() {
        if model.detached { BrowserWindows.shared.setTitle(windowTitle, for: model.sessionID) }
    }

    // MARK: The bar

    /// The tabs and ＋ on the left; pop out (or dock), ⋯, expand and close on the right.
    private var topBar: some View {
        HStack(spacing: 2) {
            if state.running && !state.tabs.isEmpty {
                TabStrip(plus: model.canDrive) {
                    ForEach(state.tabs, id: \.id) { t in
                        BrowserTabButton(tab: t, active: t.id == state.active, canDrive: model.canDrive, model: model)
                    }
                    if model.canDrive { BarIcon(symbol: Glyph.symbol(0xE710), tip: "New tab") { model.newTab() } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            } else {
                Text("Browser").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Color.clear.frame(width: 6, height: 1)
            if model.detached {
                BarIcon(symbol: "rectangle.righthalf.inset.filled",
                        tip: canDock ? "Dock beside the conversation" : "Dock beside the conversation (open the conversation first)",
                        enabled: canDock) { dockBack() }
            } else {
                BarIcon(symbol: Glyph.symbol(0xE8A7), tip: "Open in a separate window") { popOut() }
            }
            BarIcon(symbol: "ellipsis", tip: "More") { more() }
            if !model.detached {
                BarIcon(symbol: dock.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        tip: dock.expanded ? "Show the conversation again" : "Expand over the conversation") { dock.expanded.toggle() }
            }
            BarIcon(symbol: Glyph.symbol(0xE711), tip: model.detached ? "Close the window" : "Close the browser") { close() }
        }
        .frame(height: 36)
    }

    // MARK: Off, or reading

    @ViewBuilder private var off: some View {
        let notice = model.error ?? model.stateError
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 8)
            if let notice { NoticeBox(message: notice).padding(.bottom, 10) }
            if !model.stateRead {
                LoadingNote(text: "Reading the browser\u{2026}")
            } else {
                let title = model.starting ? "Starting the browser\u{2026}" : state.on ? "The browser is switched on but not running" : "The shared browser is off"
                let detail = model.closedSession ? "This conversation is closed. Reopen it, then start the browser."
                    : state.on ? "It starts with the agent\u{2019}s next turn, or start it now. Its cookies and logins are still there."
                    : "Switch on a Chromium of this session\u{2019}s own: the agent drives it with its browser tools, and you watch and use it here at the same time, on the same tabs. You can log in for the agent or take over a step and hand back with a message."
                VStack(spacing: 8) {
                    Image(systemName: Glyph.symbol(0xE774)).font(.system(size: 28)).foregroundStyle(Theme.muted)
                    Text(title).font(Theme.headline).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                    Text(detail).font(Theme.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
                    if store.canManage && store.supports("browser_on") {
                        Button(model.starting ? "Starting\u{2026}" : "\u{25B6} Start the browser") { model.switchBrowser(on: true) }
                            .dashButton(.prominent).disabled(model.starting || model.stopping).padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
    }

    // MARK: Running

    @ViewBuilder private var running: some View {
        let drive = model.canDrive
        let notice = model.error ?? model.stateError
        // The address bar: back, forward and reload, then the tab in view's address, and where to go on Enter.
        HStack(spacing: 2) {
            BarIcon(symbol: "arrow.left", tip: "Back", enabled: drive) { model.send(["type": "back"]) }
            BarIcon(symbol: Glyph.symbol(0xE72A), tip: "Forward", enabled: drive) { model.send(["type": "forward"]) }
            BarIcon(symbol: Glyph.symbol(0xE72C), tip: "Reload", enabled: drive) { model.send(["type": "reload"]) }
            HStack(spacing: 8) {
                Image(systemName: state.activeTab?.url.hasPrefix("https://") == true ? "lock.fill" : Glyph.symbol(0xE774))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 16)
                TextField("Enter a web address", text: $model.address)
                    .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.ink)
                    .focused($addressFocused)
                    .disabled(!drive)
                    .onSubmit { model.navigate() }
                    .onExitCommand { model.focusCanvas(); model.syncAddress() }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(addressFocused ? Theme.accentDim : Theme.line, lineWidth: 1))
            .padding(.leading, 6)
        }
        .padding(.bottom, 8)
        if let notice { NoticeBox(message: notice).padding(.bottom, 6) }
        if !drive {
            Text("Watching only: this token cannot act in the browser.").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                .padding(.bottom, 6)
        }
        // The picture fills what is left.
        BrowserCanvasView(model: model)
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            .padding(.bottom, 10)
    }

    // MARK: Actions

    /// ⋯: the tabs the strip may have no room for, the tab in view's reload and close, switching the browser on or off,
    /// and where it is shown.
    private func more() {
        enum Choice { case tab(String), reload, closeTab, start, stop, popOut, dock }
        let drive = model.canDrive && state.running
        var items: [PopupMenu.Item] = [], choices: [Choice?] = []
        func add(_ title: String, _ c: Choice, enabled: Bool = true, checked: Bool = false) {
            items.append(PopupMenu.Item(title: title, checked: checked, enabled: enabled)); choices.append(c)
        }
        func separator() { items.append(.separatorItem); choices.append(nil) }
        if state.running && state.tabs.count > 1 {
            for t in state.tabs.prefix(50) { add(t.label, .tab(t.id), enabled: drive, checked: t.id == state.active) }
            separator()
        }
        add("Reload", .reload, enabled: drive)
        add("Close this tab", .closeTab, enabled: drive && state.activeTab != nil)
        let busy = model.starting || model.stopping
        if store.canManage && state.on && store.supports("browser_off") {
            separator(); add("Switch the browser off\u{2026}", .stop, enabled: !busy)
        } else if store.canManage && store.supports("browser_on") {
            separator(); add("Start the browser", .start, enabled: !busy)
        }
        separator()
        if model.detached { add("Dock beside the conversation", .dock, enabled: canDock) } else { add("Open in a separate window", .popOut) }
        guard let i = PopupMenu.choose(items), let choice = choices[i] else { return }
        switch choice {
        case .tab(let id): model.tab(id)
        case .reload: model.send(["type": "reload"])
        case .closeTab: model.closeActiveTab()
        case .start: model.switchBrowser(on: true)
        case .stop: model.switchBrowser(on: false)
        case .popOut: popOut()
        case .dock: dockBack()
        }
    }

    // Where the browser is shown changes once the click that asked for it is over: the screen that asked goes with it.
    private func close() {
        let id = model.sessionID, detached = model.detached
        DispatchQueue.main.async {
            if detached { BrowserWindows.shared.close(id) } else if BrowserDock.shared.sessionID == id { BrowserDock.shared.dock(nil) }
        }
    }
    private func popOut() {
        let session = model.session, frame = model.frameInWindow
        let window = BrowserWindows.mainWindow
        DispatchQueue.main.async {
            var at: NSRect?
            if let window, let content = window.contentView, frame.width > 0 {
                at = window.convertToScreen(NSRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height))
            }
            BrowserDock.shared.dock(nil)
            BrowserWindows.shared.open(session, at: at)
        }
    }
    private func dockBack() {
        let session = model.session, id = model.sessionID
        DispatchQueue.main.async {
            guard BrowserDock.shared.dockable, BrowserDock.conversationShown(id) else { return }
            BrowserWindows.shared.close(id)
            BrowserDock.shared.dock(session)
            BrowserWindows.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}

/// The docked column: the divider, dragged to resize it (in the accent while dragged), then the browser.
struct DockedBrowserColumn: View {
    var session: JSON
    var visible: Bool
    @ObservedObject private var dock = BrowserDock.shared
    @State private var startWidth: CGFloat?

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                if !dock.expanded {
                    ZStack {
                        Color.clear
                        Rectangle().fill(dock.dragging ? Theme.accent : Theme.line).frame(width: 1)
                    }
                    .frame(width: BrowserDock.dividerWidth)
                    .contentShape(Rectangle())
                    .onHover { on in if on { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let start = startWidth ?? g.size.width - BrowserDock.dividerWidth
                            if startWidth == nil { startWidth = start; dock.dragging = true }
                            dock.width = max(BrowserDock.minWidth, start - v.translation.width)
                        }
                        .onEnded { _ in startWidth = nil; dock.dragging = false })
                }
                SharedBrowserScreen(session: session, detached: false, visible: visible)
            }
        }
        .background(Theme.canvas)
    }
}

/// A toolbar glyph, as Claude's browser pane has them: no frame, tinted under the mouse, greyed while it cannot act.
/// A toolbar glyph: no frame, tinted under the mouse, greyed while it cannot act.
struct BarIcon: View {
    var symbol: String
    var tip: String
    var enabled = true
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(!enabled ? Theme.lineStrong : hovered ? Theme.ink : Theme.muted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered && enabled ? Theme.raise : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .help(tip)
    }
}

/// A tab in the strip: its title alone, the one in view in the ink and the others muted until hovered. A right click
/// shows or closes it, as a browser's tab menu would.
private struct BrowserTabButton: View {
    var tab: BrowserTab
    var active: Bool
    var canDrive: Bool
    var model: SharedBrowserModel
    @State private var hovered = false
    var body: some View {
        Button { if !active { model.tab(tab.id) } } label: {
            Text(tab.label).font(active ? Theme.footnoteSemibold : Theme.footnote)
                .foregroundStyle(active || hovered ? Theme.ink : Theme.muted)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.raise : hovered ? Theme.raise.opacity(0.6) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tab.label.count > 24 ? tab.label : "")
        .contextMenu {
            if canDrive {
                Button("Show this tab") { model.tab(tab.id) }
                Button("Close this tab") { model.tab(tab.id, close: true) }
            }
        }
    }
}

/// The tabs side by side, each as wide as its title up to an even share of the strip (72 to 200 points), then the ＋
/// when `plus`; tabs past the room left stay reachable from ⋯.
private struct TabStrip: Layout {
    var plus: Bool
    var gap: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 400, height: 28)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = subviews.count - (plus ? 1 : 0)
        guard n > 0 else { return }
        let plusWidth: CGFloat = plus ? 32 : 0
        let avail = bounds.width - plusWidth
        let share = min(max((avail - CGFloat(n) * gap) / CGFloat(n), 72), 200)
        var x: CGFloat = 0
        var hidden = false
        for i in 0..<n {
            let w = min(subviews[i].sizeThatFits(.unspecified).width, share)
            if hidden || x + w > avail {
                hidden = true
                subviews[i].place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: 28))
                continue
            }
            subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: 28))
            x += w + gap
        }
        if plus { subviews[n].place(at: CGPoint(x: bounds.minX + x + 2, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: 28, height: 28)) }
    }
}
