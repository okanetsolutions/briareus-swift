// Pages in windows of their own (the Windows client's detached.c): a conversation, Findings, Usage, WhatsApp or Slack
// pops out of the main window's detail, as it is, into a window over where it was, so several can sit side by side; the
// window's dock button puts it back. Each window has a navigator of its own, so what a page there opens stays there, and
// picking a page that already has a window brings that window forward.
import AppKit
import SwiftUI

@MainActor
final class DetachedWindows: NSObject, NSWindowDelegate {
    static let shared = DetachedWindows()
    private var entries: [(window: NSWindow, navigator: Navigator)] = []

    /// The pages that can have a window of their own.
    static func detachable(_ screen: Screen) -> Bool {
        switch screen {
        case .conversation, .findings, .usage, .webApp: return true
        default: return false
        }
    }

    /// The navigator of the window in front, when it is one of these.
    var keyNavigator: Navigator? {
        guard let key = NSApp.keyWindow else { return nil }
        return entries.first { $0.window === key }?.navigator
    }
    func owns(_ window: NSWindow) -> Bool { entries.contains { $0.window === window } }
    var navigators: [Navigator] { entries.map(\.navigator) }

    /// A page asked for in one window that another already shows: that window comes forward and keeps it. A window's own
    /// page asked for from deeper in that window goes back to it there.
    func bringForward(_ screen: Screen, from asking: Navigator) -> Bool {
        if asking.detached && asking.root == screen {
            asking.popToRoot()
            return true
        }
        if let e = entries.first(where: { $0.navigator !== asking && $0.navigator.root == screen }) {
            front(e.window)
            return true
        }
        if asking.detached && Navigator.main.root == screen, let main = BrowserWindows.mainWindow {
            front(main)
            return true
        }
        return false
    }

    /// Opens a window on `stack`, over the main window's detail.
    func open(_ stack: [Screen], panel: JSON?) {
        let nav = Navigator(stack: stack, detached: true)
        nav.panelSession = panel
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 420, height: 360)
        w.title = Self.title(stack.first ?? .placeholder)
        w.delegate = self
        if let main = BrowserWindows.mainWindow {
            // Over the detail it left, a little down and to the right so it reads as a new window.
            let f = main.frame
            let x = f.minX + Theme.sidebarWidth + 24
            var frame = NSRect(x: x, y: f.minY + 24, width: max(f.width - Theme.sidebarWidth - 48, 600), height: max(f.height - 48, 480))
            if let area = (main.screen ?? NSScreen.main)?.visibleFrame {
                frame.size.width = min(frame.width, area.width); frame.size.height = min(frame.height, area.height)
                frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
            }
            w.setFrame(frame, display: false)
        } else {
            w.center()
        }
        entries.append((w, nav))
        // In front before its page is built, so the page's own reads of the navigator find this window's.
        w.makeKeyAndOrderFront(nil)
        w.contentView = NSHostingView(rootView: DetachedWindowView()
            .environmentObject(Store.shared).environmentObject(nav)
            .frame(minWidth: 420, minHeight: 360).noWritingTools())
    }

    /// The window's page, as it is, goes back to the main window's detail, and the window closes.
    func dock(_ nav: Navigator) {
        guard let i = entries.firstIndex(where: { $0.navigator === nav }) else { return }
        let w = entries[i].window, stack = nav.stack, panel = nav.panelSession
        entries.remove(at: i)
        w.contentView = nil
        w.close()
        // A step later, so the page's views (a web page's own view among them) have left the closed window. Its models
        // are checked only once the main window has taken the page, so they live on through the move.
        DispatchQueue.main.async {
            Navigator.main.adopt(stack, panel: panel)
            Navigator.stacksChanged.send()
            if let main = BrowserWindows.mainWindow { self.front(main) }
        }
    }

    /// Signing out: every window goes.
    func closeAll() { for e in entries { e.window.close() } }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let i = entries.firstIndex(where: { $0.window === w }) else { return }
        entries.remove(at: i)
        // The page goes with its window, and its polling with it.
        w.contentView = nil
        Navigator.stacksChanged.send()
    }

    private func front(_ w: NSWindow) {
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }

    static func title(_ screen: Screen) -> String {
        switch screen {
        case .conversation(_, let session): return session.flatMap { Session($0) }?.displayTitle ?? "Conversation"
        case .findings: return "Findings"
        case .usage: return "Usage"
        case .webApp(let app): return app.name
        default: return "Briareus"
        }
    }
}

/// A window's page: the detail pane on its navigator, and beside a conversation, its pull request column.
private struct DetachedWindowView: View {
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        HStack(spacing: 0) {
            DetailPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let session = navigator.panelSession {
                SessionPanel(session: session)
                    .id(session["id"].string ?? "")
                    .frame(width: Theme.panelWidth)
                    .frame(maxHeight: .infinity)
                    .background(Theme.sidebar)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
            }
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.ink)
    }
}
