// The global pull list's state and intents; PullsGate shares each repository's cooldown with its board.
import Combine
import Foundation

@MainActor
final class GlobalPullsModel: ObservableObject {
    @Published private(set) var state: GlobalPullsState {
        didSet { filter = filter.reconciled(in: state) }
    }
    @Published var filter = GlobalPullsFilter() {
        didSet { rows = filter.rows(in: state) }
    }
    @Published private(set) var rows: [GlobalPullRow]
    private let reader: GlobalPullsReader

    init() {
        reader = GlobalPullsReader(saved: { Store.shared.cache.value($0) })
        state = reader.state
        rows = reader.state.rows
    }

    var emptyTitle: String { state.emptyTitle(filtered: filter.isOn) }
    func clearFilters() { filter = GlobalPullsFilter() }

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
}
