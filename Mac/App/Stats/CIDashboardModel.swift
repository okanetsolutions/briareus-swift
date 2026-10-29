// Loads one fixed CI window and pages its history while the CI tab is visible.
import Foundation
import Combine

@MainActor
final class CIDashboardModel: ObservableObject {
    @Published var query = CIQuery()
    @Published private(set) var reading: CIReading?
    @Published private(set) var history = CIHistory()
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var error: String?
    @Published private(set) var historyError: String?
    private var window: JSON = [:]
    private var generation = 0

    var hasStats: Bool { Store.shared.supports("ci_stats") }
    var hasHistory: Bool { Store.shared.supports("ci_runs") }
    var connectionID: ObjectIdentifier? { Store.shared.client.map(ObjectIdentifier.init) }

    func load() async {
        generation += 1
        let gen = generation, connection = connectionID
        window = query.arguments(now: Store.shared.client?.serverNow ?? Date())
        let args = window
        reading = nil; history = CIHistory(); error = nil; historyError = nil
        loading = true; loadingMore = false
        defer { if gen == generation { loading = false } }
        if hasStats {
            do {
                let answer = try await Store.shared.call("ci_stats", args)
                guard gen == generation, connection == connectionID, !Task.isCancelled else { return }
                guard let parsed = CIReading(answer) else { throw APIError(.nonJSON) }
                reading = parsed
            } catch {
                guard gen == generation, connection == connectionID, !Task.isCancelled else { return }
                self.error = (error as? APIError)?.description ?? error.localizedDescription
            }
        }
        guard gen == generation, connection == connectionID, !Task.isCancelled else { return }
        if hasHistory { await page(offset: 0, generation: gen, connection: connection) }
    }

    func more() async {
        guard !loading, !loadingMore, let offset = history.nextOffset else { return }
        await page(offset: offset, generation: generation, connection: connectionID)
    }
    private func page(offset: Int, generation gen: Int, connection: ObjectIdentifier?) async {
        loadingMore = true; historyError = nil
        defer { if gen == generation { loadingMore = false } }
        let args = CIHistory.arguments(window: window, offset: offset)
        do {
            let answer = try await Store.shared.call("ci_runs", args)
            guard gen == generation, connection == connectionID, !Task.isCancelled else { return }
            try history.receive(answer, offset: offset)
        } catch {
            guard gen == generation, connection == connectionID, !Task.isCancelled else { return }
            historyError = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}
