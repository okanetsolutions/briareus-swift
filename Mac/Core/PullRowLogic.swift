// What a pull request's row on the board says, the same in both apps: the marks of its standing, in order, each with its
// words and tone, and who holds, wrote and reviews it. Each app only maps a mark to its own symbol and a tone to its colour.
import Foundation

/// The colour family a mark is drawn in; each app's Theme turns it into a colour. `faint` is a muted word that says
/// something is missing ("unassigned"); `running` is the working status's colour.
enum RowTone: Equatable, Sendable { case ok, danger, warn, muted, faint, accent, running }

/// A checks rollup as a row shows it: red only for a failure, a run still going is pending.
enum ChecksState: Equatable, Sendable {
    case passed, failed, pending

    init(rollup: String) {
        switch rollup {
        case "success": self = .passed
        case "failure", "error": self = .failed
        default: self = .pending
        }
    }
    var tone: RowTone {
        switch self {
        case .passed: return .ok
        case .failed: return .danger
        case .pending: return .warn
        }
    }
    /// The SF Symbol both apps draw it with.
    var symbol: String {
        switch self {
        case .passed: return "checkmark"
        case .failed: return "xmark"
        case .pending: return "clock"
        }
    }
}

extension ReviewStatus {
    var tone: RowTone {
        switch self {
        case .approved: return .ok
        case .changesRequested: return .danger
        case .feedback: return .warn
        case .requested, .none: return .muted
        }
    }
    /// The SF Symbol both apps draw it with (the Mac's, which mirror the Windows client's); nil for no review.
    var symbol: String? {
        switch self {
        case .approved: return "checkmark"
        case .changesRequested: return "xmark"
        case .feedback: return "text.bubble"
        case .requested: return "clock"
        case .none: return nil
        }
    }
}

/// One mark of a pull request's standing.
enum PullMark: Equatable, Sendable {
    /// Conversations at work on it now.
    case running(Int)
    case conflicts
    case checks(ChecksState)
    /// Its place in a stack, as "2/3".
    case stack(String)
    case review(ReviewStatus)
    case draft
    /// The errand its state asks for, by its label.
    case suggested(String)

    var text: String {
        switch self {
        case .running(let n): return "\(n) running"
        case .conflicts: return "Conflicts"
        case .checks: return "Checks"
        case .stack(let label): return "Stack \(label)"
        case .review(let status): return status.text
        case .draft: return "Draft"
        case .suggested(let label): return "Suggested: \(label)"
        }
    }
    var tone: RowTone {
        switch self {
        case .running: return .running
        case .conflicts: return .danger
        case .checks(let state): return state.tone
        case .stack, .suggested: return .accent
        case .review(let status): return status.tone
        case .draft: return .muted
        }
    }
    /// The SF Symbol both apps draw it with.
    var symbol: String? {
        switch self {
        case .running: return "bolt.fill"
        case .conflicts: return "exclamationmark.triangle"
        case .checks(let state): return state.symbol
        case .stack: return "square.3.layers.3d"
        case .review(let status): return status.symbol
        case .draft: return "pencil"
        case .suggested: return "sparkles"
        }
    }
    /// What VoiceOver says for it, where the words alone are not enough.
    var spoken: String {
        switch self {
        case .running(let n): return "\(n) conversation\(n == 1 ? "" : "s") at work"
        case .checks(.passed): return "Checks passed"
        case .checks(.failed): return "Checks failed"
        case .checks(.pending): return "Checks running"
        case .stack(let label): return "Stacked pull request \(label)"
        case .suggested(let label): return "Suggested errand: \(label)"
        default: return text
        }
    }
}

/// A pull request's row: its marks, then who holds, wrote and reviews it ("assignee @a", "author @b", "reviewers @c, @d").
/// The words say which login is which; the branch is the pull request's page's to show.
struct PullRowContent: Equatable, Sendable {
    let marks: [PullMark]
    let who: [String]
    /// Nobody is assigned: `who` opens with "unassigned", drawn faint.
    let unassigned: Bool

    init(pull: PullSummary, stack: StackPosition?, activeRuns: Int = 0, suggested: String? = nil) {
        var marks: [PullMark] = []
        if activeRuns > 0 { marks.append(.running(activeRuns)) }
        if pull.hasConflicts { marks.append(.conflicts) }
        if let checks = pull.checks { marks.append(.checks(ChecksState(rollup: checks))) }
        if let stack { marks.append(.stack(stack.label(pull.number))) }
        let review = ReviewStatus(decision: pull.reviewDecision, reviewers: pull.reviewers)
        if review != .none { marks.append(.review(review)) }
        if pull.draft { marks.append(.draft) }
        if let suggested { marks.append(.suggested(suggested)) }
        self.marks = marks

        unassigned = pull.assignees.isEmpty
        let assignees = unassigned ? "unassigned" : "assignee \(people(pull.assignees, limit: 2))"
        var parts = [assignees]
        if let author = pull.author { parts.append("author @\(author)") }
        let reviewers = pull.reviewers.map(\.user).filter { !$0.isEmpty }
        if !reviewers.isEmpty { parts.append("reviewers " + reviewers.map { "@\($0)" }.joined(separator: ", ")) }
        who = parts
    }
}
