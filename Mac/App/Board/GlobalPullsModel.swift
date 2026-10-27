// The board across every project: its pull requests, issues and Review List tabs, their state and intents; PullsGate shares
// each repository's cooldown with its board.
import Combine
import Foundation

@MainActor
final class GlobalPullsModel: ObservableObject {
    @Published private(set) var state: GlobalPullsState {
        didSet { filter = filter.reconciled(in: state) }
    }
    @Published var filter = GlobalPullsFilter() {
        didSet { refilter() }
    }
    @Published var tab = GlobalBoardTab.pulls
    /// Each tab's rows under the filters, and without them for the tabs' labels. The Review List waits on the saved
    /// GitHub login's review, or on each project's author's without one.
    @Published private(set) var shown = GlobalBoardRows()
    @Published private(set) var totals = GlobalBoardRows()
    private let reader: GlobalPullsReader

    init() {
        reader = GlobalPullsReader(saved: { Store.shared.cache.value($0) })
        state = reader.state
        refilter()
    }

    var emptyTitle: String { state.emptyTitle(tab, filter: filter, me: BoardEdits.login) }
    func clearFilters() { filter = GlobalPullsFilter() }

    /// The saved GitHub login changed, and with it the Review List.
    func loginChanged() { refilter() }

    private func refilter() {
        shown = filter.board(in: state, me: BoardEdits.login)
        totals = GlobalPullsFilter().board(in: state, me: BoardEdits.login)
    }

    @discardableResult
    func load(fresh: Bool = false) async -> APIError? {
        guard let client = Store.shared.client else { return APIError(.cancelled) }
        return await reader.load(fresh: fresh, projects: {
            try await Store.shared.call("projects")
        }, saved: { Store.shared.cache.value("pulls:\($0)") }, keepProjects: {
            Store.shared.cache.store($0, "projects")
        }, cooldownError: { PullsGate.cooldown.error($0) }, read: { repo in
            guard let result = await PullsGate.read(repo, fresh: fresh) else { return nil }
            let answer = try result.get()
            if Store.shared.client === client { Store.shared.cache.store(answer, "pulls:\(repo)") }
            return answer
        }, current: { Store.shared.client === client }, changed: { [weak self] in self?.state = $0 })
    }

    func open(_ row: GlobalPullRow) {
        Navigator.shared.push(.pull(repo: row.project.repo, number: row.pull.number, stack: row.stack?.json, summary: row.pull.raw))
    }

    func open(_ row: GlobalIssueRow) { Navigator.shared.push(.issue(repo: row.project.repo, issue: row.raw)) }
}
