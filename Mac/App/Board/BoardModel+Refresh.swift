// The PR list's polling and tab-opening refresh share the same GitHub freshness rule.
import Foundation

extension BoardModel {
    /// Before the first read, use the saved response's sync time rather than treating every opening as stale.
    private var savedBoard: JSON {
        board.isObject ? board : Store.shared.cache.value("pulls:\(repo)") ?? .null
    }

    func pollBoard() async -> APIError? {
        guard !dialogOpen, !reading else { return nil }
        return await load(fresh: pullsNeedRefresh(savedBoard, now: Store.shared.client?.serverNow))
    }

    /// The model owns the request so switching tabs cannot cancel a refresh another tab still needs.
    func openPulls() {
        Task {
            guard tab == .pulls || tab == .review, !dialogOpen, !reading,
                  pullsNeedRefresh(savedBoard, now: Store.shared.client?.serverNow) else { return }
            await load(fresh: true)
        }
    }
}
