// The project and cross-project lists share each repository's errand runner and merge progress.
import Combine
import Foundation

@MainActor
final class BoardPullActionsModel: ObservableObject {
    let repo: String
    let feed: ProjectFeed
    let errands: ErrandRunner
    @Published var mergeAsked: PullSummary?
    @Published private(set) var mergingNumber = 0
    @Published private(set) var mergeNote: String?
    private var errandSink: AnyCancellable?

    init(repo: String) {
        self.repo = repo
        feed = Store.shared.feed(repo)
        errands = ErrandRunner(repo: repo)
        errandSink = errands.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func rowActions(for pull: PullSummary) -> BoardPullActions {
        BoardPullActions(pull: pull, catalog: ErrandCatalog.shared.catalog, canManage: Store.shared.canManage,
                         supports: { Store.shared.supports($0) })
    }

    func checked() { errands.checked(); mergeNote = nil }

    func runs(on number: Int) -> BoardPullRuns { BoardPullRuns(feed.sessions, number: number) }

    /// Read the current head before merging: a list summary never authorizes a different commit.
    func merge(_ pull: PullSummary) {
        guard mergingNumber == 0 else { return }
        let number = pull.number
        mergingNumber = number; mergeNote = nil
        Task {
            defer { mergingNumber = 0 }
            let pr: JSON
            do { pr = try await Store.shared.call("pull", ["repo": .string(repo), "pr": JSON(number)])["pr"] }
            catch { mergeNote = failure(error); return }
            let record = PullRecord(number: number, pr: pr, row: pull)
            guard let arguments = record.mergeArguments(repo: repo) else {
                mergeNote = record.mergeBlocker?.message
                return
            }
            do {
                let value = try await Store.shared.call("merge_pull", arguments)
                mergeNote = value["status"].string == "pending"
                    ? "GitHub accepted the merge and is still finishing it; the pull request leaves the list once it lands." : nil
            } catch {
                if let said = failure(error) {
                    mergeNote = (error as? APIError)?.isRefusal == true ? said
                        : "\(said) The merge may still have completed; pull down to refresh before trying again."
                }
            }
            mergingNumber = 0
            do { try await feed.loadBoard(fresh: true) }
            catch { if let said = failure(error), mergeNote == nil { mergeNote = said } }
        }
    }
}
