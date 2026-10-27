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
    @Published private(set) var rows: [GlobalPullRow]
    @Published private(set) var issueRows: [GlobalIssueRow]
    /// The pull requests waiting on the saved GitHub login's review, or on each project's author's without one.
    @Published private(set) var reviewRows: [GlobalPullRow] = []
    private let reader: GlobalPullsReader

    init() {
        reader = GlobalPullsReader(saved: { Store.shared.cache.value($0) })
        state = reader.state
        rows = reader.state.rows
        issueRows = reader.state.issueRows
        reviewRows = reader.state.reviewRows(me: BoardEdits.login)
    }

    var emptyTitle: String { state.emptyTitle(tab, filtered: filter.isOn) }
    /// How many rows the tab on show lists.
    var shownCount: Int {
        switch tab {
        case .pulls: return rows.count
        case .issues: return issueRows.count
        case .review: return reviewRows.count
        }
    }
    func clearFilters() { filter = GlobalPullsFilter() }

    /// Asks for the GitHub login whose review the Review List waits on.
    func setLogin() { if BoardEdits.askLogin() { refilter() } }

    private func refilter() {
        rows = filter.rows(in: state)
        issueRows = filter.issueRows(in: state)
        reviewRows = filter.reviewRows(in: state, me: BoardEdits.login)
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
