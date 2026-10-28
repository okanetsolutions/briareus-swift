// The board across every project: its pull requests, issues and Review List tabs, their state and intents; PullsGate shares
// each repository's cooldown with its board.
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
    @Published private(set) var boards: [String: BoardModel] = [:]
    private let reader: GlobalPullsReader
    private var boardSinks: [String: AnyCancellable] = [:]
    private var readingActions = false
    private var actionsRead: (client: APIClient, at: Date)?

    init() {
        reader = GlobalPullsReader(saved: { Store.shared.cache.value($0) })
        state = reader.state
        filter = GlobalPullsFilter(saved: Store.shared.cache.value("global-board-filters") ?? .null)
        refilter()
        reconcileBoards()
    }

    var emptyTitle: String { state.emptyTitle(tab, filter: filter, me: BoardEdits.login) }
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
        shown = filter.board(in: state, me: BoardEdits.login)
        totals = GlobalPullsFilter().board(in: state, me: BoardEdits.login)
    }

    private func reconcileBoards() {
        let repos = Set(state.projects.map(\.project.repo))
        boards = boards.filter { repos.contains($0.key) }
        boardSinks = boardSinks.filter { repos.contains($0.key) }
        for repo in repos where boards[repo] == nil {
            let board = BoardModel(repo: repo)
            if let saved = Store.shared.cache.value("pulls:\(repo)") { board.show(saved, saved: true) }
            if let saved = Store.shared.cache.value("actions") { board.catalog = saved["actions"] }
            if let saved = Store.shared.cache.value("sessions:\(repo)").flatMap(Session.parseList) { board.runs = saved }
            boards[repo] = board
            let client = Store.shared.client
            boardSinks[repo] = board.$board.dropFirst().removeDuplicates().sink { [weak self] value in
                guard let self, Store.shared.client === client else { return }
                do {
                    try reader.adopt(value, repo: repo)
                    state = reader.state
                } catch { /* Keep the last valid rows if a board answer cannot be parsed. */ }
            }
        }
    }

    private func loadActions() async {
        guard Store.shared.canManage, Store.shared.supports("actions"), !readingActions else { return }
        guard let client = Store.shared.client else { return }
        if let actionsRead, actionsRead.client === client, Date().timeIntervalSince(actionsRead.at) < 300 { return }
        readingActions = true
        defer { readingActions = false }
        let result = await boardCall("actions")
        guard Store.shared.client === client, let value = result.value else { return }
        actionsRead = (client, Date())
        Store.shared.cache.store(value, "actions")
        for board in boards.values { board.catalog = value["actions"] }
    }

    @discardableResult
    func load(fresh: Bool = false) async -> APIError? {
        guard let client = Store.shared.client else { return APIError(.cancelled) }
        if fresh {
            for board in boards.values { board.uncertain = false; board.writeError = nil }
        }
        async let actions: Void = loadActions()
        let error = await withTaskGroup(of: Void.self) { group in
            await reader.load(fresh: fresh, projects: {
                try await Store.shared.call("projects")
            }, saved: { Store.shared.cache.value("pulls:\($0)") }, keepProjects: {
                Store.shared.cache.store($0, "projects")
            }, cooldownError: { PullsGate.cooldown.error($0) }, read: { repo in
                guard let board = boards[repo], let result = await board.loadBoard(fresh: fresh) else { return nil }
                let answer = try result.get()
                if Store.shared.client === client, Store.shared.supports("sessions") {
                    group.addTask { await board.loadRuns() }
                }
                return answer
            }, current: { Store.shared.client === client }, changed: { [weak self] in
                self?.state = $0
                self?.reconcileBoards()
            })
        }
        await actions
        return error
    }

    func open(_ row: GlobalPullRow) {
        Navigator.shared.push(.pull(repo: row.project.repo, number: row.pull.number, stack: row.stack?.json, summary: row.pull.raw))
    }

    func open(_ row: GlobalIssueRow) { Navigator.shared.push(.issue(repo: row.project.repo, issue: row.raw)) }
}
