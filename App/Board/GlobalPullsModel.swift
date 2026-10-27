// The global pull list's state and intents; project feeds keep its reads and cooldowns shared with each board.
import Combine
import Foundation

@MainActor
final class GlobalPullsModel: ObservableObject {
    @Published private(set) var state: GlobalPullsState
    @Published var filter = GlobalPullsFilter()
    private let reader: GlobalPullsReader

    init() {
        reader = GlobalPullsReader(saved: { Store.shared.cache.value($0) })
        state = reader.state
    }

    var rows: [GlobalPullRow] { filter.rows(in: state) }
    var emptyTitle: String { state.emptyTitle(filtered: filter.isOn) }
    func clearFilters() { filter = GlobalPullsFilter() }

    @discardableResult
    func load(fresh: Bool = false) async -> APIError? {
        guard let client = Store.shared.client else { return APIError(.cancelled) }
        return await reader.load(projects: {
            let answer = try await Store.shared.call("projects")
            if Store.shared.client === client, Project.parseList(answer) != nil { Store.shared.cache.store(answer, "projects") }
            return answer
        }, saved: { Store.shared.cache.value("pulls:\($0)") }, read: { repo in
            guard ProjectFeed.boardDeadline(repo) == nil else { return nil }
            let feed = Store.shared.feed(repo)
            try await feed.loadBoard(fresh: fresh)
            return feed.board
        }, current: { Store.shared.client === client }, changed: { [weak self] in self?.state = $0 })
    }
}
