// The PR list's polling and tab-opening refresh share the same GitHub freshness rule.
import Foundation

extension BoardModel {
    /// Before the first read, use the saved response's sync time rather than treating every opening as stale.
    private var savedBoard: JSON {
        board.isObject ? board : Store.shared.cache.value("pulls:\(repo)") ?? .null
    }

    func pollBoard() async -> APIError? {
        guard !dialogOpen, !reading else { return nil }
        return await load(fresh: pullsNeedRefresh(savedBoard))
    }

    func openPulls() async {
        guard tab == .pulls || tab == .review, !dialogOpen, !reading,
              pullsNeedRefresh(savedBoard) else { return }
        await load(fresh: true)
    }
}
