// What an issue's row on the board says, the same in both apps: its line of facts with their tones, whether it is an epic
// and how far along, the epic it belongs to, and whether a pull request answers it. Each app only draws it.
import Foundation

/// One fact on a row's line, in the tone it is drawn in.
struct RowFact: Equatable, Sendable {
    let text: String
    var tone: RowTone = .muted
}

/// How much of an epic is done, over every sub-issue GitHub knows, which may be more than the rows under it.
struct SubIssueProgress: Equatable, Sendable {
    let done: Int
    let total: Int

    init(done: Int, total: Int) { self.done = done; self.total = total }
    init(_ issue: IssueSummary) { self.init(done: issue.subIssuesDone, total: issue.subIssues) }

    /// The bar's filled share, 0 to 1, whatever the counts say.
    var fraction: Double { total > 0 ? Double(min(max(done, 0), total)) / Double(total) : 0 }
    var text: String { "\(done)/\(total) done" }
    var spoken: String { "\(done) of \(total) sub-issues closed" }
}

/// An issue's row: "#12 · @author · assigned @a · 3 comments · milestone · 1 pull request", the epic's progress, and
/// "Part of #4 epic" unless the row is drawn under that epic.
struct IssueRowContent: Equatable, Sendable {
    let facts: [RowFact]
    /// Set for an epic.
    let progress: SubIssueProgress?
    /// "Part of #4 Its title"; nil without a parent, or on a row nested under it, where the indent already says whose it is.
    let parentLine: String?
    /// A pull request is linked to close it.
    let answered: Bool

    init(issue: IssueSummary, repo: String?, nested: Bool = false) {
        var facts = [RowFact(text: "#\(issue.number)")]
        if let author = issue.author { facts.append(RowFact(text: "@\(author)")) }
        if issue.assignees.isEmpty { facts.append(RowFact(text: "unassigned", tone: .faint)) }
        else { facts.append(RowFact(text: "assigned \(people(issue.assignees, limit: 2))")) }
        if issue.comments > 0 { facts.append(RowFact(text: "\(issue.comments) comment\(issue.comments == 1 ? "" : "s")")) }
        if let milestone = issue.milestone { facts.append(RowFact(text: milestone)) }
        let pulls = issue.pulls.count
        if pulls > 0 { facts.append(RowFact(text: "\(pulls) pull request\(pulls == 1 ? "" : "s")", tone: .ok)) }
        self.facts = facts

        progress = issue.isEpic ? SubIssueProgress(issue) : nil
        parentLine = nested ? nil : issue.parent.map { "Part of \($0.reference(repo)) \($0.title)" }
        answered = pulls > 0
    }
}
