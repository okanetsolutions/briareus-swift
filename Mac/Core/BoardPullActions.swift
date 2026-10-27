// The project and cross-project pull request rows offer the same errands and merge confirmation.
import Foundation

struct BoardPullActions: Equatable, Sendable {
    let errands: [BoardAction]
    let canMerge: Bool
    let suggested: BoardAction?
    /// The phone offers Run in the pull request's tab instead of its context menu.
    var menuErrands: [BoardAction] { errands.filter { $0.id != "run" } }

    init(pull: PullSummary, catalog: JSON, canManage: Bool, supports: (String) -> Bool) {
        errands = pull.branch.isEmpty ? [] : BoardAction.startable(catalog: catalog, pull: pull, failedChecks: 0,
                                                                  canManage: canManage, supports: supports)
        canMerge = !pull.draft && canManage && supports("pull") && supports("merge_pull")
        suggested = errands.first { $0.isSuggested(for: pull) }
    }
}

struct BoardPullRuns: Equatable, Sendable {
    let total: Int
    let active: Int

    init(_ sessions: [Session], number: Int) {
        let runs = sessions.filter { $0.pullNumber == number }
        total = runs.count
        active = runs.filter(\.isActive).count
    }
}

/// A row has only the summary: warn about its conflicts and checks before reading the head to merge.
func boardPullMergeQuestion(_ pull: PullSummary) -> String {
    var message = "\u{201C}\(pull.title)\u{201D} is squash-merged into \(pull.baseBranch.isEmpty ? "its base branch" : pull.baseBranch) on GitHub."
    if pull.conflicting { message += "\n\nThis branch has conflicts that must be resolved before it can merge." }
    if pull.checksFailed { message += "\n\nSome checks failed." }
    else if pull.checks == "pending" || pull.checks == "expected" { message += "\n\nSome checks are still running." }
    return message
}
