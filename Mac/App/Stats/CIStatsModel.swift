// The CI/CD screen's state (`GET /stats/ci` and `GET /ci/runs`): the window and filters, the figures they give, and the
// recent runs read a page at a time. One window (`since`/`until` pinned when the figures were read) serves the figures and
// every page of runs, so Load more continues the same list instead of a moving one.
import Foundation

@MainActor
final class CIStatsModel: ObservableObject {
    @Published private(set) var filter = CIFilter()
    @Published private(set) var stats: CIStats?
    @Published private(set) var runs: [CIRun] = []
    /// Where the next page of runs starts; nil at the end of the list.
    @Published private(set) var nextOffset: Int?
    /// The server stopped counting runs before the end of the window.
    @Published private(set) var truncated = false
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var error: String?
    /// Why the last Load more failed; the runs already read stay.
    @Published private(set) var runsError: String?

    /// The query the figures were read with, which each page of runs repeats.
    private var window: JSON = [:]
    private var generation = 0

    static var offered: Bool { Store.shared.supports("ci_stats") }
    var runsOffered: Bool { Store.shared.supports("ci_runs") }

    /// The project picked, or nil for every project the token reads.
    var projectTitle: String {
        guard let repo = filter.repo else { return "All projects" }
        return ProjectsModel.shared.project(repo)?.title ?? repo
    }

    // MARK: Filters

    func setDays(_ days: Int) {
        guard days != filter.days else { return }
        filter.days = days
        reload()
    }
    func setStatuses(_ statuses: Bool) {
        guard statuses != filter.statuses else { return }
        filter.statuses = statuses
        reload()
    }
    func pickProject() {
        let projects = ProjectsModel.shared.projects
        var items = [PopupMenu.Item(title: "All projects", checked: filter.repo == nil)]
        if !projects.isEmpty { items.append(.separatorItem) }
        items += projects.map { PopupMenu.Item(title: $0.title, checked: $0.repo == filter.repo) }
        guard let chosen = PopupMenu.choose(items) else { return }
        let repo: String? = chosen == 0 ? nil : projects[chosen - 2].repo
        guard repo != filter.repo else { return }
        filter.repo = repo
        reload()
    }

    // MARK: Reading

    /// The figures and the first page of runs, over a window that ends now.
    func reload() {
        guard Self.offered else { return }
        generation += 1
        let mine = generation
        let window = filter.query()
        self.window = window
        loading = true; loadingMore = false; runsError = nil
        Task {
            async let figures = boardCall("ci_stats", window)
            async let page: Result<JSON, APIError>? = runsOffered ? boardCall("ci_runs", filter.runsQuery(window: window)) : nil
            let (f, p) = await (figures, page)
            guard mine == generation else { return }
            loading = false
            switch f {
            case .success(let v): stats = CIStats(v); error = nil
            case .failure(let e): if e.kind != .cancelled { error = e.description }
            }
            switch p {
            case .success(let v)?: adopt(CIRunsPage(v), appending: false)
            case .failure(let e)?: if e.kind != .cancelled { runsError = e.description }
            case nil: runs = []; nextOffset = nil; truncated = false
            }
        }
    }

    /// The next page of runs in the same window.
    func loadMoreRuns() {
        guard let offset = nextOffset, !loadingMore, !loading, runsOffered else { return }
        let mine = generation
        loadingMore = true; runsError = nil
        Task {
            let r = await boardCall("ci_runs", filter.runsQuery(window: window, offset: offset))
            guard mine == generation else { return }
            loadingMore = false
            switch r {
            case .success(let v): adopt(CIRunsPage(v), appending: true)
            case .failure(let e): if e.kind != .cancelled { runsError = e.description }
            }
        }
    }

    private func adopt(_ page: CIRunsPage, appending: Bool) {
        runs = appending ? runs + page.runs : page.runs
        nextOffset = page.nextOffset
        truncated = page.truncated
    }

    /// A run's page on GitHub.
    func open(_ run: CIRun) { openWebURL(run.url) }
}
