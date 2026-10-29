// Pages in windows of their own, as the Mac's DetachedWindows: on an iPad, a conversation, Findings, Usage or a
// session's shared browser opens in a window (a scene) of its own beside the app's, so several can sit side by side on
// the one Store. Each window has a navigation stack of its own, so what its page opens stays there, and asking again for
// a page that already has a window brings that window forward. A phone, which has one window, offers none of this.
import SwiftUI
import UIKit

/// A page that can have a window of its own. Each case's `id` names what it shows, so a repeated choice brings its window
/// forward rather than opening another; the record it carries is only what is shown until the server answers.
enum DetachedPage: Codable, Hashable, Identifiable {
    /// A conversation; `session` is the record the list had.
    case conversation(id: String, session: JSON?)
    /// The review rounds waiting: one project's, or every project's with nil.
    case findings(repo: String?)
    case usage
    /// A session's shared browser, on its session record.
    case browser(session: JSON)

    /// The scene group the pages open in.
    static let scene = "page"

    var id: String {
        switch self {
        case .conversation(let id, _): return "conversation:\(id)"
        case .findings(let repo): return "findings:\(repo ?? "")"
        case .usage: return "usage"
        case .browser(let session): return "browser:\(session["id"].string ?? "")"
        }
    }
    static func == (a: DetachedPage, b: DetachedPage) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A window's page on a stack of its own, where what it opens is pushed.
struct DetachedPageView: View {
    let page: DetachedPage
    var body: some View {
        switch page {
        case .conversation(let id, let session): NavigationRoot { ConversationScreen(sessionID: id, initial: session) }
        case .findings(let repo): NavigationRoot { FindingsScreen(repo: repo) }
        case .usage: NavigationRoot { UsageEntry() }
        // The browser holds its own navigation bar.
        case .browser(let session): SharedBrowserScreen(session: session)
        }
    }
}

private struct OwnWindowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Whether the page on show is in a window of its own rather than the app's, so it offers no window again.
    var inOwnWindow: Bool {
        get { self[OwnWindowKey.self] }
        set { self[OwnWindowKey.self] = newValue }
    }
}

/// Opens a page in a window of its own, or nil where there is no second window to have: on a phone, or in the page's
/// own window.
struct OpenInWindow {
    fileprivate var open: (DetachedPage) -> Void
    func callAsFunction(_ page: DetachedPage) { open(page) }
}

/// Reads `OpenInWindow` from a view's environment.
@propertyWrapper
struct WindowOpener: DynamicProperty {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var multiple
    @Environment(\.inOwnWindow) private var own
    init() {}
    var wrappedValue: OpenInWindow? {
        guard multiple, !own, UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        let openWindow = openWindow
        return OpenInWindow { openWindow(id: DetachedPage.scene, value: $0) }
    }
}

/// The toolbar button that opens a page in a window of its own, where one can be had.
struct OpenInWindowButton: View {
    let page: DetachedPage
    @WindowOpener private var openInWindow
    var body: some View {
        if let openInWindow {
            Button { openInWindow(page) } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                .accessibilityLabel("Open in New Window")
        }
    }
}
