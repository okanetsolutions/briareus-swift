// A pull request's code reviews as Briareus stored them (`GET /pulls/{number}/code-reviews`): each review session's run,
// its cost and summary, and every finding it registered with the verification step's verdict. Read-only: verdicts are
// given by the review's own verify step, not by the user. Both apps' Code reviews tab, the voice and the meeting read
// these. No UI here.
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
    /// How many findings carry each verdict, and how many wait for one.
    var counts: CodeReviewCounts { CodeReviewCounts(findings) }
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
    /// The findings of the newest completed review, what a pull request still carries: a clean one carries none. While
    /// none has completed, the newest review's findings so far.
    var latestFindings: [CodeReviewFinding] { (first { $0.status == .completed } ?? first)?.findings ?? [] }
}
