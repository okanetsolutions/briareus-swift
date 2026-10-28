// One pull request as its screen reads it, the same on the iPhone and the Mac: what it is (from the `pull` answer once it has
// come, from the board's row until then), when it can be merged, have its branch updated or take errands, what those
// writes send, what an edit's answer changes, and what is saved to open it again at once. The models keep the reading and
// writing; the rules are here.
import Foundation

struct PullRecord {
    enum MergeBlocker: Equatable, Sendable {
        case notOpen, draft, missingCommit

        var message: String {
            switch self {
            case .notOpen: return "This pull request is no longer open."
            case .draft: return "This pull request is now a draft."
            case .missingCommit: return "The server did not say which commit to merge."
            }
        }
    }

    let number: Int
    /// The `pull` answer's `pr`; null until it has come.
    var pr: JSON
    /// The board's row for it, when the board lists it.
    var row: PullSummary?
    /// Who wrote the description, when `pull_description` named them.
    var descriptionAuthor: String? = nil

    /// Until the pull request itself answers, being on the board says it is open.
    var isOpen: Bool { pr.isNull ? row != nil : pr["state"].string == "open" }
    var draft: Bool { pr["draft"].is(true) || (pr.isNull && (row?.draft ?? false)) }
    var author: String? { pr["author"].string ?? row?.author ?? descriptionAuthor }
    var commitCount: Int { pr["commits"].int32 ?? pr["commitList"].count }
    var title: String { pr["title"].string ?? row?.title ?? "Pull request #\(number)" }
    var url: String? { pr["url"].string ?? row?.url }
    var head: String? { pr["headRef"].string ?? row.flatMap { $0.branch.isEmpty ? nil : $0.branch } }
    var base: String? { pr["baseRef"].string ?? row.flatMap { $0.baseBranch.isEmpty ? nil : $0.baseBranch } }
    /// The issues it closes: the board's links, or what the pull request names.
    var closes: [BoardLink] { row.map(\.issues).flatMap { $0.isEmpty ? nil : $0 } ?? BoardLink.parseList(pr["issues"]) }
    var failedChecks: Int { pr["checks"]["failed"].int32 ?? 0 }
    var pendingChecks: Int { pr["checks"]["pending"].int32 ?? 0 }
    /// The description as last read, given the one `pull_description` read; an edit starts from it.
    func body(described: String?) -> String? { pr["body"].string ?? described }

    // MARK: Writes

    /// The head and base the pull request was read at: a merge or a branch update names both, so a push meanwhile is refused.
    private var readAt: (head: String, base: String)? {
        guard pr["state"].string == "open", let head = pr["headSha"].string, let base = pr["baseRef"].string else { return nil }
        return (head, base)
    }
    /// Merge is offered on an open pull request read at a known head and base, and not on a draft.
    var mergeable: Bool { mergeBlocker == nil }
    /// A fresh read may refuse a merge that the board's older summary offered.
    var mergeBlocker: MergeBlocker? {
        guard pr["state"].string == "open" else { return .notOpen }
        guard !pr["draft"].is(true) else { return .draft }
        guard readAt != nil else { return .missingCommit }
        return nil
    }
    var branchUpdatable: Bool { readAt != nil }
    /// Errands start on an open pull request with a branch.
    var takesErrands: Bool { isOpen && pr["headRef"].string != nil }

    /// `merge_pull`'s body: a squash merge at the head and base read; nil when it cannot be merged.
    func mergeArguments(repo: String) -> JSON? {
        guard mergeable, let at = readAt else { return nil }
        return ["repo": .string(repo), "pr": JSON(number), "headSha": .string(at.head), "baseRef": .string(at.base), "method": "squash"]
    }
    /// `update_pull_branch`'s body: the base merged into the head read; nil when the branch cannot be updated.
    func updateBranchArguments(repo: String) -> JSON? {
        guard let at = readAt else { return nil }
        return ["repo": .string(repo), "pr": JSON(number), "headSha": .string(at.head), "baseRef": .string(at.base)]
    }
    /// The errands on its screen, from those the device can start: none unless it takes errands, and never ▶ Run, which is
    /// the Run tab there.
    func errands(_ startable: [BoardAction]) -> [BoardAction] { takesErrands ? startable.filter { $0.id != "run" } : [] }

    /// What stands in the way of a merge, said before asking: GitHub's merge state, a repository without squash merges,
    /// failing and running checks, and requested changes. `files` is the `pull_files` answer, whose `pr` GitHub read last.
    func mergeNotes(files: JSON) -> [String] {
        var notes: [String] = []
        let p = files["pr"]
        if p.isObject { notes += mergeWarnings(mergeable: p["mergeable"], state: p["mergeableState"].string) }
        if let methods = p["mergeMethods"].array, !methods.isEmpty, !methods.contains("squash") {
            notes.append("This repository does not allow squash merges; GitHub will refuse this one.")
        }
        let failed = failedChecks, pending = pendingChecks
        if failed > 0 { notes.append("\(failed) check\(failed == 1 ? " is" : "s are") failing.") }
        if pending > 0 { notes.append("\(pending) check\(pending == 1 ? " is" : "s are") still running.") }
        if case .changesRequested = ReviewStatus(decision: row?.reviewDecision, reviews: pr["reviews"]) {
            notes.append("A reviewer has requested changes.")
        }
        return notes
    }
    /// The `pull_files` answer read a newer head than this record: the screen reads the pull request again before asking.
    func headMoved(files: JSON) -> Bool {
        guard let head = files["pr"]["headSha"].string else { return false }
        return head != pr["headSha"].string
    }

    /// What `update_pull`'s answer changes on screen at once: its title, and its description when `sent` changed it. The
    /// labels and assignees come back with the board's row.
    static func editEcho(_ answer: JSON, sent: JSON) -> (title: String?, body: String?) {
        (answer["pr"]["title"].string, sent["body"].string != nil ? answer["pr"]["body"].string : nil)
    }
    /// Applies an edit's echo to the record's `pr`, which keeps its description only when it already held one.
    mutating func apply(title: String?, body: String?) {
        guard pr.isObject else { return }
        if let title { pr["title"] = .string(title) }
        if let body, pr["body"].string != nil { pr["body"] = .string(body) }
    }
}

/// What a pull request's screen saves to open again at once: the pull request, its findings, its board row and stack, and
/// its description and who wrote it.
struct PullSnapshot {
    var pr: JSON
    var findings: JSON
    var row: PullSummary?
    var stack: StackPosition?
    var body: String?
    var bodyAuthor: String?

    init(pr: JSON, findings: JSON, row: PullSummary?, stack: StackPosition?, body: String?, bodyAuthor: String?) {
        self.pr = pr; self.findings = findings; self.row = row; self.stack = stack; self.body = body; self.bodyAuthor = bodyAuthor
    }
    /// What `json` saved; nil for nothing saved.
    init?(_ saved: JSON?) {
        guard let saved, saved.isObject else { return nil }
        pr = saved["pr"]; findings = saved["findings"]
        row = PullSummary(saved["row"]); stack = StackPosition(restoring: saved["stack"])
        body = saved["body"].string; bodyAuthor = saved["bodyAuthor"].string
    }
    /// Nil until the pull request has been read: there is nothing worth saving before.
    var json: JSON? {
        guard !pr.isNull else { return nil }
        var saved: JSON = ["pr": pr, "findings": findings, "row": row?.raw ?? .null, "stack": stack?.json ?? .null]
        if let body { saved["body"] = .string(body) }
        if let bodyAuthor { saved["bodyAuthor"] = .string(bodyAuthor) }
        return saved
    }
    static func key(repo: String, number: Int) -> String { "pull:\(repo)#\(number)" }
}
