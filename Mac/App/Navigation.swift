// The main window's columns and the navigation between them: the sidebar, the detail pane's stack of screens, and the
// column beside a conversation (the Windows client's pull request panel).
import Combine
import SwiftUI

@MainActor
final class Navigator: ObservableObject {
    /// The main window's.
    static let main = Navigator()
    /// The navigator of the window in front: a page popped out into a window of its own opens what it opens there.
    static var shared: Navigator { DetachedWindows.shared.keyNavigator ?? main }

    /// A window of its own (DetachedWindows), not the main window.
    let detached: Bool
    init(stack: [Screen] = [.placeholder], detached: Bool = false) {
        self.stack = stack
        self.detached = detached
    }

    enum SidebarMode { case projects, settings }

    /// The detail pane's stack: its root first.
    @Published private(set) var stack: [Screen] = [.placeholder] {
        didSet { Navigator.stacksChanged.send() }
    }
    /// Any window's stack changed, or a window closed.
    static let stacksChanged = PassthroughSubject<Void, Never>()
    /// Whether any window has the screen on its stack.
    static func anyHas(_ screen: Screen) -> Bool {
        main.stack.contains(screen) || DetachedWindows.shared.navigators.contains { $0.stack.contains(screen) }
    }
    @Published var sidebarMode: SidebarMode = .projects
    /// The session whose column shows beside its conversation; nil takes the column away.
    @Published var panelSession: JSON?
    /// In one column, whether the detail is the visible pane.
    @Published var narrowShowsDetail = false
    /// The window is below the Windows client's `lg` breakpoint, one column at a time (set by the main window).
    var isNarrow = false

    /// A form with unsaved changes registers here; it answers whether another screen may replace it (asking first).
    var leaveGuard: (() -> Bool)?

    var root: Screen { stack.first ?? .placeholder }
    var top: Screen { stack.last ?? .placeholder }
    /// The row the sidebar highlights: the detail pane's root screen id.
    var selectedID: String? { root == .placeholder ? nil : root.id }

    private func mayLeave() -> Bool {
        guard let leaveGuard else { return true }
        if leaveGuard() { self.leaveGuard = nil; return true }
        return false
    }

    /// Shows a screen as the detail pane's root, unless one with the same id already is. A page already in another window
    /// brings that window forward instead.
    func show(_ screen: Screen) {
        if stack.count == 1 && root == screen { narrowShowsDetail = true; return }
        if DetachedWindows.shared.bringForward(screen, from: self) { return }
        guard mayLeave() else { return }
        panelSession = nil
        if !detached { BrowserDock.shared.detailChanged(to: screen) }
        stack = [screen]
        narrowShowsDetail = true
    }
    /// Pops the page out into a window of its own, as it is, leaving the detail empty (the main window's alone).
    func popOut() {
        guard !detached, DetachedWindows.detachable(root), mayLeave() else { return }
        let moved = stack, panel = panelSession
        panelSession = nil
        BrowserDock.shared.dock(nil)
        stack = [.placeholder]
        narrowShowsDetail = false
        DetachedWindows.shared.open(moved, panel: panel)
    }
    /// The main window takes a popped-out page back, as it is.
    func adopt(_ moved: [Screen], panel: JSON?) {
        guard !detached, mayLeave() else { return }
        BrowserDock.shared.detailChanged(to: moved.first ?? .placeholder)
        stack = moved.isEmpty ? [.placeholder] : moved
        panelSession = panel
        narrowShowsDetail = true
    }
    /// Back to the page at the bottom of the stack.
    func popToRoot() {
        guard stack.count > 1, mayLeave() else { narrowShowsDetail = true; return }
        if top.id.hasPrefix("conversation:") { panelSession = nil }
        stack = [root]
    }
    func push(_ screen: Screen) {
        if top == screen { return }
        stack.append(screen)
        narrowShowsDetail = true
    }
    func pop() {
        if stack.count > 1 {
            // A pushed form with unsaved changes (⚡ Webhook, ✉ Mail wake) asks first.
            guard mayLeave() else { return }
            if top.id.hasPrefix("conversation:") { panelSession = nil }
            stack.removeLast()
        } else { narrowShowsDetail = false }
    }
    /// Backspace, Escape or ⌥← in the detail pane (pane.c WM_KEYDOWN): a pushed screen goes back, and in one column the
    /// root goes back to the sidebar. False when there is nowhere to go.
    func goBack() -> Bool {
        if stack.count > 1 { pop(); return true }
        if isNarrow && narrowShowsDetail && root != .placeholder { narrowShowsDetail = false; return true }
        return false
    }
    /// Empties the detail pane after its conversation was deleted, unless a form there keeps its unsaved changes.
    func clear() {
        guard mayLeave() else { return }
        panelSession = nil
        BrowserDock.shared.dock(nil)
        stack = [.placeholder]
        narrowShowsDetail = false
    }
    /// Signing out or a revoked token: everything goes.
    func reset() {
        leaveGuard = nil
        panelSession = nil
        BrowserDock.shared.reset()
        DetachedWindows.shared.closeAll()
        stack = [.placeholder]
        sidebarMode = .projects
        narrowShowsDetail = false
    }
}
