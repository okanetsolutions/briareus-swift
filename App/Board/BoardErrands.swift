// The board's errands on a phone: the catalog the server lists, which ones a pull request offers, the symbol before
// each label, and the runner that starts one (its confirmation, its question in ErrandInputSheet).
import SwiftUI

/// The errands the server lists (`actions`), read once in a while and shared by every board screen.
@MainActor
final class ErrandCatalog: ObservableObject {
    static let shared = ErrandCatalog()
    @Published private(set) var catalog: JSON = []
    private var readAt: Date?
    private var reading = false

    private init() {
        if let saved = Store.shared.cache.value("actions") { catalog = saved["actions"] }
    }

    /// The list changes with a server release, so it is read again only after a few minutes.
    func load() async {
        guard Store.shared.canManage, Store.shared.supports("actions"), !reading else { return }
        if let readAt, Date().timeIntervalSince(readAt) < 300 { return }
        reading = true
        defer { reading = false }
        guard let v = try? await Store.shared.call("actions") else { return }
        readAt = Date()
        if v["actions"] != catalog { catalog = v["actions"] }
        Store.shared.cache.store(v, "actions")
    }
}

/// The errands this device can start on a pull request: what the server offers for it, less what the token or server lacks.
@MainActor
func boardErrands(catalog: JSON, pull: PullSummary?, failedChecks: Int) -> [BoardAction] {
    BoardAction.startable(catalog: catalog, pull: pull, failedChecks: failedChecks, canManage: Store.shared.canManage,
                          supports: { Store.shared.supports($0) })
}

/// The symbol before an errand's label.
func errandSymbol(_ id: String) -> String {
    switch id {
    case "run": return "play.fill"
    case "review": return "text.magnifyingglass"
    case "solve-conflicts": return "arrow.triangle.merge"
    case "fix-checks": return "wrench.and.screwdriver"
    case "implement-feedback": return "hammer"
    case "test-sheet": return "checklist"
    case "test-run": return "video"
    case "pr-body-summary": return "doc.text"
    case "delete-self-comments": return "trash"
    default: return "bolt"
    }
}

/// One errand about to start on one pull request.
struct PendingErrand: Identifiable {
    var action: BoardAction
    var number: Int
    var input: String?
    var id: String { "\(number):\(action.id)" }
}

/// Starts errands: every one is a paid session, so each asks first, in a dialog or in the sheet that takes its input. A
/// start that may have gone through (anything but a refusal) holds further starts until the user has looked.
@MainActor
final class ErrandRunner: ObservableObject {
    let repo: String
    @Published var confirming: PendingErrand?
    @Published var asking: PendingErrand?
    @Published private(set) var busy = false
    @Published private(set) var starting: PendingErrand?
    @Published var uncertain = false
    @Published var writeError: String?

    init(repo: String) { self.repo = repo }

    /// Asks for the errand's input when it takes one, else for a yes.
    func ask(_ action: BoardAction, number: Int) {
        guard !busy, !uncertain else { return }
        let p = PendingErrand(action: action, number: number)
        if action.input != nil { asking = p } else { confirming = p }
    }

    /// Starts it; the session it started, when the server named one.
    func run(_ p: PendingErrand) async -> Session? {
        guard !busy, !uncertain else { return nil }
        busy = true; starting = p
        defer { busy = false; starting = nil }
        let args = p.action.arguments(repo: repo, number: p.number, input: p.input)
        do {
            let v = try await Store.shared.call(p.action.operation, args, timeout: p.action.timeoutMs.map { TimeInterval($0) / 1000 })
            writeError = nil
            if Store.shared.supports("sessions") { try? await Store.shared.feed(repo).loadSessions(fresh: true) }
            return Session(v["session"])
        } catch {
            guard let said = failure(error) else { return nil }
            writeError = said
            // A refusal is definite; anything else may have started the session.
            if (error as? APIError)?.isRefusal != true { uncertain = true }
            return nil
        }
    }

    /// Looking at the project's conversations is how an uncertain start is checked.
    func checked() { uncertain = false; writeError = nil }
}

extension View {
    /// The runner's dialog and input sheet; a started session is opened.
    func errandPrompts(_ runner: ErrandRunner) -> some View { modifier(ErrandPrompts(runner: runner)) }
}

private struct ErrandPrompts: ViewModifier {
    @ObservedObject var runner: ErrandRunner
    @Environment(\.navigate) private var navigate

    func body(content: Content) -> some View {
        content
            .alert(runner.confirming.map { "Start \($0.action.label) on #\($0.number)?" } ?? "",
                   isPresented: Binding(get: { runner.confirming != nil }, set: { if !$0 { runner.confirming = nil } }), presenting: runner.confirming) { p in
                Button("Start paid session", role: p.action.isDestructive ? .destructive : nil) { start(p) }
                Button("Cancel", role: .cancel) {}
            } message: { p in
                Text(paidNote(p))
            }
            .sheet(item: $runner.asking) { p in
                ErrandInputSheet(pending: p, repo: runner.repo) { text in
                    var p = p
                    p.input = text
                    start(p)
                }
                .presentationDetents([.medium, .large])
            }
    }

    private func start(_ p: PendingErrand) {
        Task {
            if let s = await runner.run(p) { navigate(.conversation(id: s.id, session: s.raw)) }
        }
    }
}

func paidNote(_ p: PendingErrand) -> String {
    let hint = p.action.hint.isEmpty ? "" : "\(p.action.hint). "
    return "\(hint)This runs a paid agent on pull request #\(p.number) and may write to GitHub."
}
