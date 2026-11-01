// What the CI/CD screen reads (the Mac's CI stats): the totals and trends of `GET /stats/ci` for a window and filters,
// and the runs of `GET /ci/runs` in that same window a page at a time. Core's CIFilter builds the query and CIStats and
// CIRunsPage read the answers; the model sequences the calls and holds what the screen draws.
import Foundation

@MainActor
final class CIStatsModel: ObservableObject {
    /// The window and filters; a change reads everything again.
    @Published var filter = CIFilter() {
        didSet { if filter != oldValue { Task { await reload() } } }
    }
    @Published private(set) var stats: CIStats?
    /// The window's runs read so far, and which page to read next or again.
    @Published private(set) var feed = CIRunsFeed()
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var error: String?
    /// The window `stats` was read for, so every page of runs comes from the same one.
    private var window: JSON = [:]
    /// The filter `stats` was read for, so a failed read for another one does not leave its figures above the new runs.
    private var statsFilter: CIFilter?
    /// Bumped by each reload, so a slower earlier answer does not land over a newer one.
    private var generation = 0

    var runs: [CIRun] { feed.runs }
    var canLoadMore: Bool { feed.canLoadMore }
    var truncated: Bool { feed.truncated }
    /// Why the last read of runs failed, above Retry.
    var runsError: String? { feed.error }

    /// Back to every project and checks, keeping a longer window; the change reads everything again.
    func clearFilters() { filter = filter.cleared }

    /// Reads the figures and the first page of runs afresh, for a window ending now.
    func reload() async {
        generation += 1
        let mine = generation
        let filter = self.filter, query = filter.query()
        window = query
        loading = true
        feed.reading()
        defer { if mine == generation { loading = false } }
        do {
            let answer = try await Store.shared.call("ci_stats", query)
            guard mine == generation else { return }
            stats = CIStats(answer)
            statsFilter = filter
            error = nil
        } catch {
            guard mine == generation else { return }
            if let said = failure(error) {
                self.error = said
                if statsFilter != filter { stats = nil }
            }
        }
        await readRuns(offset: 0, generation: mine)
    }

    /// The next page of runs, in the window already read.
    func loadMoreRuns() async {
        guard canLoadMore, let offset = feed.nextOffset else { return }
        await readMore(from: offset)
    }
    /// The page of runs that failed, read again without reading the figures.
    func retryRuns() async {
        guard let offset = feed.failedOffset else { return }
        await readMore(from: offset)
    }
    private func readMore(from offset: Int) async {
        guard !loadingMore, !loading else { return }
        loadingMore = true
        feed.reading()
        defer { loadingMore = false }
        await readRuns(offset: offset, generation: generation)
    }

    private func readRuns(offset: Int, generation mine: Int) async {
        guard Store.shared.supports("ci_runs") else { return }
        do {
            let page = CIRunsPage(try await Store.shared.call("ci_runs", filter.runsQuery(window: window, offset: offset)))
            guard mine == generation else { return }
            feed.receive(page, offset: offset)
        } catch {
            guard mine == generation else { return }
            if let said = failure(error) { feed.fail(offset: offset, error: said) }
        }
    }
}
