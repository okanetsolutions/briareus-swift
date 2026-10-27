// The board across every project: its pull requests, issues and Review List tabs, their state and intents; project feeds
// keep its reads and cooldowns shared with each board.
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

    var emptyTitle: String { state.emptyTitle(tab, filter: filter, me: GitHubLogin.current) }
    func clearFilters() { filter = GlobalPullsFilter() }

    /// The saved GitHub login changed, and with it the Review List.
    func loginChanged() { refilter() }

    private func refilter() {
        shown = filter.board(in: state, me: GitHubLogin.current)
        totals = GlobalPullsFilter().board(in: state, me: GitHubLogin.current)
    }

    @discardableResult
    func load(fresh: Bool = false) async -> APIError? {
        guard let client = Store.shared.client else { return APIError(.cancelled) }
        return await reader.load(fresh: fresh, projects: {
            try await Store.shared.call("projects")
        }, saved: { Store.shared.cache.value("pulls:\($0)") }, keepProjects: {
            Store.shared.cache.store($0, "projects")
        }, cooldownError: { ProjectFeed.boardCooldownError($0) }, read: { repo in
            guard ProjectFeed.boardDeadline(repo) == nil else { return nil }
            let feed = Store.shared.feed(repo)
            try await feed.loadBoard(fresh: fresh)
            return feed.board
        }, current: { Store.shared.client === client }, changed: { [weak self] in self?.state = $0 })
    }
}
