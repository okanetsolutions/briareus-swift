// A pull request's code reviews as Briareus stored them (`GET /pulls/{number}/code-reviews`): each review session's run,
// its cost and summary, whether someone has handled its findings, and every finding it registered with the verification
// step's verdict. A person may mark a review handled or reopen it (`update_code_review`) and overrule a finding's verdict
// with a reason (`update_code_review_finding`); the answers are folded back into the list as read. Both apps' Code reviews
// tab, the voice and the meeting read these. No UI here.
import Foundation

/// The verify step's ruling on whether the pull request must change for a finding.
enum CodeReviewVerdict: String, Equatable, Sendable, CaseIterable {
    case fix, optional, dismiss

    var title: String {
        switch self {
        case .fix: return "Fix"
        case .optional: return "Optional"
        case .dismiss: return "Dismissed"
        }
    }
    var tone: RowTone {
        switch self {
        case .fix: return .danger
        case .optional: return .warn
        case .dismiss: return .muted
        }
    }
    /// What a verdict editor offers, in the same order on both apps; nil leaves the finding unverified.
    static let choices: [CodeReviewVerdict?] = allCases.map(Optional.some) + [nil]
    static func choiceTitle(_ verdict: CodeReviewVerdict?) -> String { verdict?.title ?? "None" }
}

/// Whether an independent check reproduced a finding, or it is only likely.
enum CodeReviewVerification: String, Equatable, Sendable {
    case confirmed, plausible

    var title: String { self == .confirmed ? "Confirmed" : "Plausible" }
    var tone: RowTone { self == .confirmed ? .ok : .warn }
}

/// One finding a code review registered.
struct CodeReviewFinding: Equatable, Sendable, Identifiable {
    var id: Int
    var severity: String
    /// What kind of defect: `correctness`, `security`, `efficiency`, …; nil when the review left it empty.
    var type: String?
    /// Nil until the verify step ruled.
    var verdict: CodeReviewVerdict?
    var verification: CodeReviewVerification?
    var title: String
    /// Its explanation, Markdown.
    var body: String?
    var filePath: String?
    var startLine: Int?
    var endLine: Int?
    /// Why the verdict is what it is.
    var comments: String?

    init?(_ j: JSON) {
        guard let id = j["id"].truncatedInt else { return nil }
        self.id = id
        severity = j["severity"].nonEmpty ?? "medium"
        type = j["type"].nonEmpty
        verdict = j["shouldFix"].string.flatMap(CodeReviewVerdict.init)
        verification = j["verification"].string.flatMap(CodeReviewVerification.init)
        title = j["title"].nonEmpty ?? "Finding"
        body = j["body"].nonEmpty
        filePath = j["filePath"].nonEmpty
        startLine = j["startLine"].truncatedInt
        endLine = j["endLine"].truncatedInt
        comments = j["comments"].nonEmpty
    }

    /// "CRIT", "HIGH", "MED" or "LOW".
    var severityLabel: String { findingSeverityLabel(severity) }
    var severityTone: RowTone {
        switch severityLabel {
        case "CRIT", "HIGH": return .danger
        case "LOW": return .muted
        default: return .warn
        }
    }
    /// "src/a.swift:12-18", "src/a.swift:12", "src/a.swift", or nil without a file.
    var location: String? {
        guard let filePath else { return nil }
        guard let start = startLine, start > 0 else { return filePath }
        if let end = endLine, end > start { return "\(filePath):\(start)-\(end)" }
        return "\(filePath):\(start)"
    }
}

/// Whether someone has dealt with a review's findings, by fixing them or deciding not to. A person sets it, apart from how
/// the run ended and from each finding's verdict; a rerun of the review puts it back to pending.
enum CodeReviewHandling: String, Equatable, Sendable {
    case pending, handled

    var title: String { self == .handled ? "Handled" : "Pending" }
    var tone: RowTone { self == .handled ? .ok : .muted }
}

/// What a person can do to a stopped review's handling: mark it handled, or reopen a handled one as pending.
enum CodeReviewHandlingAction: Equatable, Sendable {
    case markHandled, reopen

    var title: String { self == .markHandled ? "Mark handled" : "Reopen" }
    /// The SF Symbol before it.
    var symbol: String { self == .markHandled ? "checkmark.circle" : "arrow.uturn.backward" }
    /// The handling it sets: handled, or back to pending.
    var handles: Bool { self == .markHandled }
}

/// How a code review run ended.
enum CodeReviewStatus: String, Equatable, Sendable {
    case running, completed, failed

    var title: String { rawValue.asciiCapitalized }
    var tone: RowTone {
        switch self {
        case .running: return .running
        case .completed: return .ok
        case .failed: return .danger
        }
    }
}

/// A code review a session ran on a pull request.
struct CodeReview: Equatable, Sendable, Identifiable {
    var id: Int
    /// The review session, which keeps its transcript after it closes.
    var sessionID: String?
    var repo: String
    var prNumber: Int?
    var branch: String
    var headSha: String?
    var provider: String
    var model: String?
    var effort: String?
    var inputTokens: Double?
    var outputTokens: Double?
    var costUsd: Double?
    var costEstimated: Bool
    var unpricedTurns: Int
    var status: CodeReviewStatus
    /// Nil from a server that does not track it, which has no way to change it either.
    var handling: CodeReviewHandling?
    /// The summary comment it posted on the pull request, Markdown.
    var summary: String?
    var createdAt: Date?
    var completedAt: Date?
    var findings: [CodeReviewFinding]

    init?(_ j: JSON) {
        guard let id = j["id"].truncatedInt else { return nil }
        self.id = id
        sessionID = j["sessionId"].nonEmpty
        repo = j["repo"].string ?? ""
        prNumber = j["prNumber"].truncatedInt
        branch = j["branch"].string ?? ""
        headSha = j["headSha"].nonEmpty
        provider = j["provider"].string ?? ""
        model = j["model"].nonEmpty
        effort = j["effort"].nonEmpty
        inputTokens = j["inputTokens"].number
        outputTokens = j["outputTokens"].number
        costUsd = j["costUsd"].number
        costEstimated = j["costEstimated"].is(true)
        unpricedTurns = j["unpricedTurns"].truncatedInt ?? 0
        status = j["status"].string.flatMap(CodeReviewStatus.init) ?? .running
        handling = j["handlingStatus"].string.flatMap(CodeReviewHandling.init)
        summary = j["summary"].nonEmpty
        createdAt = j["createdAt"].string.flatMap(attentionDate)
        completedAt = j["completedAt"].string.flatMap(attentionDate)
        findings = j["findings"].items.compactMap(CodeReviewFinding.init)
    }

    /// The `code_reviews` answer, newest first as the server sends it.
    static func parse(_ answer: JSON) -> [CodeReview] { answer["codeReviews"].items.compactMap(CodeReview.init) }

    /// "Codex · gpt-5 · high · abc1234 · 12.3k tok · $0.42": what it ran on, the commit and what it cost.
    var meta: String {
        var parts = [provider.isEmpty ? nil : provider, model, effort, headSha.map { String($0.prefix(7)) }].compactMap { $0 }
        if inputTokens != nil || outputTokens != nil { parts.append("\(formatTokens((inputTokens ?? 0) + (outputTokens ?? 0))) tok") }
        if let costUsd { parts.append((costEstimated ? "~" : "") + formatCost(costUsd)) }
        return parts.joined(separator: " \u{00B7} ")
    }
    /// The review session to open, only while the review runs: the server deletes the session once it closes, and the
    /// review lives on here.
    var openableSessionID: String? { status == .running ? sessionID : nil }
    /// How many findings carry each verdict, and how many wait for one.
    var counts: CodeReviewCounts { CodeReviewCounts(findings) }

    /// What can be done to its handling once it stopped running (a running review is still writing its findings); nil
    /// while it runs, or from a server that does not track handling.
    var handlingAction: CodeReviewHandlingAction? {
        guard let handling, status != .running else { return nil }
        return handling == .handled ? .reopen : .markHandled
    }
    /// Its findings' verdicts can be overruled once it stopped running, when its own verify step is done with them.
    var canEditFindings: Bool { status != .running }

    /// What `update_code_review` sends to mark it handled, or to reopen it as pending.
    func handlingArguments(repo: String, number: Int, _ action: CodeReviewHandlingAction) -> JSON {
        ["repo": .string(repo), "pr": JSON(number), "reviewId": JSON(id),
         "handlingStatus": .string((action.handles ? CodeReviewHandling.handled : .pending).rawValue)]
    }

    /// The `code_reviews` list with `review` (as `update_code_review` answers it, findings and all) in place of the one with
    /// its id; the list as it was when it holds none.
    static func replacing(review: JSON, in list: JSON) -> JSON {
        guard let id = review["id"].truncatedInt, list.isArray else { return list }
        return .array(list.items.map { $0["id"].truncatedInt == id ? review : $0 })
    }
    /// The `code_reviews` list with `finding` (as `update_code_review_finding` answers it) in place of the one with its id
    /// in the review `reviewID`; the list as it was when that review or finding is not in it.
    static func replacing(finding: JSON, inReview reviewID: Int, in list: JSON) -> JSON {
        guard let id = finding["id"].truncatedInt, list.isArray else { return list }
        return .array(list.items.map { review in
            guard review["id"].truncatedInt == reviewID, review["findings"].isArray else { return review }
            var changed = review
            changed["findings"] = .array(review["findings"].items.map { $0["id"].truncatedInt == id ? finding : $0 })
            return changed
        })
    }
}

/// A person overruling one finding's verdict, and saying why (`update_code_review_finding`): a real issue they will not fix
/// is Optional, a refuted one Dismissed, and either needs the reason, as the server asks. Only what changed is sent.
struct CodeReviewFindingEdit: Equatable, Sendable, Identifiable {
    let reviewID: Int
    let findingID: Int
    var id: Int { findingID }
    /// The finding's title, for the editor's heading.
    let title: String
    /// Nil clears the verdict, leaving the finding unverified.
    var verdict: CodeReviewVerdict?
    /// Why the verdict is what it is; empty clears it.
    var reason: String
    private let savedVerdict: CodeReviewVerdict?
    private let savedReason: String

    init(_ finding: CodeReviewFinding, review reviewID: Int) {
        self.reviewID = reviewID
        findingID = finding.id
        title = finding.title
        verdict = finding.verdict
        reason = finding.comments ?? ""
        savedVerdict = finding.verdict
        savedReason = (finding.comments ?? "").cTrimmed
    }

    var isDirty: Bool { verdict != savedVerdict || reason.cTrimmed != savedReason }
    /// Not fixing a finding has to say why.
    var needsReason: Bool { verdict == .optional || verdict == .dismiss }
    /// A reason is given, and one of its own once the verdict changed: the saved one argued for the old verdict (the
    /// verify step's evidence for fixing it, say), so it cannot stand for the new one.
    var hasReason: Bool {
        let said = reason.cTrimmed
        return !said.isEmpty && (verdict == savedVerdict || said != savedReason)
    }
    var canSave: Bool { isDirty && (!needsReason || hasReason) }
    /// What the reason box asks for: why it will not be fixed, once that is the verdict.
    var reasonPrompt: String { needsReason ? "Why it will not be fixed" : "Why the verdict is what it is" }
    /// The line under the reason box while the verdict needs a reason; nil when it does not.
    var reasonHint: String? { needsReason ? "A finding left unfixed says why." : nil }
    /// The SF Symbol of Change verdict, the button that opens the editor.
    static let symbol = "pencil"

    /// The verdict and reason that changed, with the review and finding they belong to; null clears either.
    func arguments(repo: String, number: Int) -> JSON {
        var a: JSON = ["repo": .string(repo), "pr": JSON(number), "reviewId": JSON(reviewID), "findingId": JSON(findingID)]
        if verdict != savedVerdict { a["shouldFix"] = verdict.map { JSON.string($0.rawValue) } ?? .null }
        let said = reason.cTrimmed
        if said != savedReason { a["comments"] = said.isEmpty ? .null : .string(said) }
        return a
    }
}

/// Counts a screen's writes as each starts and as it ends, so a read can tell whether a write began or finished since it
/// started: such a read may predate the write and would put back what it changed.
struct WriteMarks: Equatable, Sendable {
    /// The mark a read starts at.
    private(set) var mark = 0

    mutating func begin() { mark += 1 }
    mutating func end() { mark += 1 }
    /// Whether a read that began at `start` may be taken: no write began or ended since. A read without a start (restored
    /// from the last visit, or a write's own answer) always holds.
    func holds(_ start: Int?) -> Bool { start == nil || start == mark }
}

/// A review's findings by verdict: the tab's header line and the badges a review row shows.
struct CodeReviewCounts: Equatable, Sendable {
    var fix = 0, optional = 0, dismissed = 0, pending = 0

    init(_ findings: [CodeReviewFinding]) {
        for f in findings {
            switch f.verdict {
            case .fix: fix += 1
            case .optional: optional += 1
            case .dismiss: dismissed += 1
            case nil: pending += 1
            }
        }
    }
    var total: Int { fix + optional + dismissed + pending }
    /// "3 findings · 1 fix · 1 optional · 1 dismissed", or "No findings".
    var line: String {
        guard total > 0 else { return "No findings" }
        var parts = ["\(total) finding\(total == 1 ? "" : "s")"]
        if fix > 0 { parts.append("\(fix) fix") }
        if optional > 0 { parts.append("\(optional) optional") }
        if dismissed > 0 { parts.append("\(dismissed) dismissed") }
        if pending > 0 { parts.append("\(pending) unverified") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

extension Array where Element == CodeReview {
    /// Whether `edit` can be saved: it can (`canSave`), and its review is here and has stopped running, since a rerun
    /// rewrites the findings.
    func allowsSaving(_ edit: CodeReviewFindingEdit) -> Bool {
        edit.canSave && (first { $0.id == edit.reviewID }?.canEditFindings ?? false)
    }
    /// The findings of the newest completed review, what a pull request still carries: a clean one carries none. While
    /// none has completed, the newest review's findings so far.
    var latestFindings: [CodeReviewFinding] { (first { $0.status == .completed } ?? first)?.findings ?? [] }
}
