// The board across every project: its pull requests, issues and Review List tabs, their state and intents; project feeds
// keep its reads and cooldowns shared with each board.
import Combine
import Foundation

@MainActor
final class GlobalPullsModel: ObservableObject {
    @Published private(set) var state: GlobalPullsState {
        didSet { refilter() }
    }
    @Published var filter = GlobalPullsFilter() {
        didSet { refilter() }
    }
    @Published var tab = GlobalBoardTab.pulls
    /// Each tab's rows under the filters, and without them for the tabs' labels. The Review List waits on the saved
    /// GitHub login's review, or on each project's author's without one.
    @Published private(set) var shown = GlobalBoardRows()
    @Published private(set) var totals = GlobalBoardRows()
    @Published private(set) var actions: [String: BoardPullActionsModel] = [:]
    private let reader: GlobalPullsReader
    private var boardSinks: [String: AnyCancellable] = [:]

    init() {
        reader = GlobalPullsReader(saved: { Store.shared.cache.value($0) })
        state = reader.state
        filter = GlobalPullsFilter(saved: Store.shared.cache.value("global-board-filters") ?? .null)
        refilter()
        reconcileActions()
    }

    var emptyTitle: String { state.emptyTitle(tab, filter: filter, me: GitHubLogin.current) }
    var currentFilter: BoardFilter {
        get { filter[tab] }
        set {
            filter[tab] = newValue
            Store.shared.cache.store(filter.saved, "global-board-filters")
        }
    }
    var filterRows: [BoardRow] { filter.optionsRows(in: state, tab: tab) }
    func clearFilters() { currentFilter = BoardFilter() }

    /// The saved GitHub login changed, and with it the Review List.
    func loginChanged() { refilter() }

    private func refilter() {
        shown = filter.board(in: state, me: GitHubLogin.current)
        totals = GlobalPullsFilter().board(in: state, me: GitHubLogin.current)
    }

    private func reconcileActions() {
        let repos = Set(state.projects.map(\.project.repo))
        actions = actions.filter { repos.contains($0.key) }
        boardSinks = boardSinks.filter { repos.contains($0.key) }
        for repo in repos where actions[repo] == nil {
            let model = BoardPullActionsModel(repo: repo)
            actions[repo] = model
            let client = Store.shared.client
            boardSinks[repo] = model.feed.$board.dropFirst().removeDuplicates().sink { [weak self] value in
                guard let self, Store.shared.client === client else { return }
                do {
                    try reader.adopt(value, repo: repo)
                    state = reader.state
                } catch { /* Keep the last valid rows if a board answer cannot be parsed. */ }
            }
        }
    }

    @discardableResult
    func load(fresh: Bool = false) async -> APIError? {
        guard let client = Store.shared.client else { return APIError(.cancelled) }
        if fresh { for model in actions.values { model.checked() } }
        async let catalog: Void = ErrandCatalog.shared.load()
        let error = await withTaskGroup(of: Void.self) { group in
            await reader.load(fresh: fresh, projects: {
                try await Store.shared.call("projects")
            }, saved: { Store.shared.cache.value("pulls:\($0)") }, keepProjects: {
                Store.shared.cache.store($0, "projects")
            }, cooldownError: { ProjectFeed.boardCooldownError($0) }, read: { repo in
                guard ProjectFeed.boardDeadline(repo) == nil else { return nil }
                let feed = Store.shared.feed(repo)
                try await feed.loadBoard(fresh: fresh)
                if Store.shared.client === client, Store.shared.supports("sessions") {
                    group.addTask { try? await feed.loadSessions(fresh: fresh) }
                }
                return feed.board
            }, current: { Store.shared.client === client }, changed: { [weak self] in
                self?.state = $0
                self?.reconcileActions()
            })
        }
        await catalog
        return error
    }
}
