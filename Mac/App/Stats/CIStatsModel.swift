// The CI/CD screen's state (`GET /stats/ci` and `GET /ci/runs`): the window and filters, the figures they give, and the
// recent runs read a page at a time. One window (`since`/`until` pinned when the figures were read) serves the figures and
// every page of runs, so Load more continues the same list instead of a moving one.
import Foundation

@MainActor
final class CIStatsModel: ObservableObject {
    @Published private(set) var filter = CIFilter()
    @Published private(set) var stats: CIStats?
    /// The window's runs read so far, and which page to read next or again.
    @Published private(set) var feed = CIRunsFeed()
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var error: String?

    /// The query the figures were read with, which each page of runs repeats.
    private var window: JSON = [:]
    /// The filter `stats` was read for, so a failed read for another one does not leave its figures above the new runs.
    private var statsFilter: CIFilter?
    private var generation = 0

    var runs: [CIRun] { feed.runs }
    var canLoadMore: Bool { feed.canLoadMore }
    var truncated: Bool { feed.truncated }
    /// Why the last read of runs failed, above Retry.
    var runsError: String? { feed.error }

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
    /// Back to every project and checks, keeping a longer window.
    func clearFilters() {
        guard filter.isFiltered else { return }
        filter = filter.cleared
        reload()
    }

    // MARK: Reading

    /// The figures and the first page of runs, over a window that ends now.
    func reload() {
        guard Self.offered else { return }
        generation += 1
        let mine = generation
        let filter = self.filter, window = filter.query()
        self.window = window
        loading = true; loadingMore = false; feed.reading()
        Task {
            async let figures = boardCall("ci_stats", window)
            async let page: Result<JSON, APIError>? = runsOffered ? boardCall("ci_runs", filter.runsQuery(window: window)) : nil
            let (f, p) = await (figures, page)
            guard mine == generation else { return }
            loading = false
            switch f {
            case .success(let v): stats = CIStats(v); statsFilter = filter; error = nil
            case .failure(let e):
                guard e.kind != .cancelled else { break }
                error = e.description
                if statsFilter != filter { stats = nil }
            }
            switch p {
            case .success(let v)?: feed.receive(CIRunsPage(v), offset: 0)
            case .failure(let e)?: if e.kind != .cancelled { feed.fail(offset: 0, error: e.description) }
            case nil: feed = CIRunsFeed()
            }
        }
    }

    /// The next page of runs in the same window.
    func loadMoreRuns() {
        guard canLoadMore, let offset = feed.nextOffset else { return }
        readMore(from: offset)
    }
    /// The page of runs that failed, read again without reading the figures.
    func retryRuns() {
        guard let offset = feed.failedOffset else { return }
        readMore(from: offset)
    }
    private func readMore(from offset: Int) {
        guard !loadingMore, !loading, runsOffered else { return }
        let mine = generation
        loadingMore = true; feed.reading()
        Task {
            let r = await boardCall("ci_runs", filter.runsQuery(window: window, offset: offset))
            guard mine == generation else { return }
            loadingMore = false
            switch r {
            case .success(let v): feed.receive(CIRunsPage(v), offset: offset)
            case .failure(let e): if e.kind != .cancelled { feed.fail(offset: offset, error: e.description) }
            }
        }
    }

    /// A run's page on GitHub.
    func open(_ run: CIRun) { openWebURL(run.url) }
}
