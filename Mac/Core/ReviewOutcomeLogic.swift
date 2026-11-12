// What a pull request's code review amounts to, as the server computes it (`reviewOutcome` and `reviewRounds` in the
// `GET /pulls/{number}/code-reviews` answer, and `reviewOutcome` again in a verdict save's answer): the outcome and why,
// whether it is stale or ready, the rounds used against the project's limit, the security pass and the approvals the
// change's risk asks for. Both apps' Code reviews tab draw it above the reviews. No UI here.
import Foundation

/// The outcome itself: never read from a label or an approval, only from the server's own records.
enum ReviewOutcomeKind: String, Equatable, Sendable {
    case pending, incomplete, changesRequired = "changes_required", passed

    var title: String {
        switch self {
        case .pending: return "Pending"
        case .incomplete: return "Incomplete"
        case .changesRequired: return "Changes required"
        case .passed: return "Passed"
        }
    }
    var tone: RowTone {
        switch self {
        case .pending: return .running
        case .incomplete: return .warn
        case .changesRequired: return .danger
        case .passed: return .ok
        }
    }
    /// The SF Symbol before it, the same on both apps.
    var symbol: String {
        switch self {
        case .pending: return "clock"
        case .incomplete: return "exclamationmark.triangle"
        case .changesRequired: return "xmark.octagon"
        case .passed: return "checkmark.seal"
        }
    }
}

/// One reason the server gives for an outcome, a security result or an approval requirement: `{ code, effect, message }`.
struct ReviewReason: Equatable, Sendable, Identifiable {
    var code: String
    /// The outcome this reason alone leads to (`pending`, `incomplete`, `changes_required`, `failed`), or `note`.
    var effect: String
    var message: String
    /// Reasons are listed in the server's order; the index keeps two with the same code apart.
    var id: String

    init?(_ j: JSON, index: Int) {
        guard let code = j["code"].nonEmpty else { return nil }
        self.code = code
        effect = j["effect"].nonEmpty ?? "note"
        message = j["message"].nonEmpty ?? code.replacingOccurrences(of: "_", with: " ")
        id = "\(index):\(code)"
    }
    var isNote: Bool { effect == "note" }
    var tone: RowTone {
        switch effect {
        case "changes_required", "failed": return .danger
        case "incomplete": return .warn
        case "pending": return .running
        default: return .muted
        }
    }
    static func list(_ j: JSON) -> [ReviewReason] { j.items.enumerated().compactMap { ReviewReason($1, index: $0) } }
}

/// The pull request's security pass, under the project's `securityReview` policy.
struct ReviewSecurity: Equatable, Sendable {
    /// `off`, `advisory` or `required`.
    var policy: String
    /// `not_required`, `not_run`, `pending`, `incomplete`, `failed` or `passed`.
    var result: String
    /// Whether it keeps the outcome from passing: a required pass that has not passed.
    var blocking: Bool
    var reasons: [ReviewReason]

    init?(_ j: JSON) {
        guard j.isObject, let result = j["result"].nonEmpty else { return nil }
        policy = j["policy"].nonEmpty ?? "off"
        self.result = result
        blocking = j["blocking"].is(true)
        reasons = ReviewReason.list(j["reasons"])
    }
    /// Shown only when the project asks for a pass at all.
    var shown: Bool { result != "not_required" }
    /// "Passed", "Failed", "Not run", …, then "required" or "advisory".
    var line: String {
        let said: String
        switch result {
        case "passed": said = "Passed"
        case "failed": said = "Failed"
        case "not_run": said = "Not run"
        case "incomplete": said = "Incomplete"
        default: said = "Pending"
        }
        return policy == "required" || blocking ? "\(said) \u{00B7} required" : "\(said) \u{00B7} advisory"
    }
    var tone: RowTone {
        switch result {
        case "passed": return .ok
        case "failed": return .danger
        case "incomplete", "not_run": return .warn
        default: return .running
        }
    }
}

/// Whether the people the change's risk calls for approved the reviewed revision: a result of its own, apart from the outcome.
struct ReviewApprovals: Equatable, Sendable {
    var enabled: Bool
    /// `not_required`, `pending` or `satisfied`.
    var result: String
    /// `low`, `medium` or `high`; nil without a policy.
    var tier: String?
    var required: Int
    var valid: Int
    var missing: Int
    /// The server's own account of the requirement, shown as it is.
    var explanation: String?

    init?(_ j: JSON) {
        guard j.isObject, let result = j["result"].nonEmpty else { return nil }
        enabled = j["enabled"].is(true)
        self.result = result
        tier = j["tier"].nonEmpty
        required = j["required"].truncatedInt ?? 0
        valid = j["valid"].truncatedInt ?? 0
        missing = j["missing"].truncatedInt ?? 0
        explanation = j["explanation"].nonEmpty
    }
    /// Shown only when a policy is on and the change's tier asks for approvals.
    var shown: Bool { enabled && result != "not_required" }
    /// "1 of 2 approvals · high risk".
    var line: String {
        var parts = ["\(valid) of \(required) approval\(required == 1 ? "" : "s")"]
        if let tier { parts.append("\(tier) risk") }
        return parts.joined(separator: " \u{00B7} ")
    }
    var tone: RowTone { result == "satisfied" ? .ok : .warn }
}

/// The pull request's review rounds against its project's `reviewRoundLimit`.
struct ReviewRounds: Equatable, Sendable {
    /// 0 for no limit.
    var limit: Int
    var used: Int
    var limitReached: Bool
    /// How many rounds a person granted past the limit.
    var continuations: Int

    init?(_ j: JSON) {
        guard j.isObject, let used = j["used"].truncatedInt else { return nil }
        limit = j["limit"].truncatedInt ?? 0
        self.used = used
        limitReached = j["limitReached"].is(true)
        continuations = j["continuations"].truncatedInt ?? 0
    }
    /// "2 of 3 rounds", "4 rounds" without a limit, "3 of 3 rounds · 1 granted past the limit".
    var line: String {
        var said = limit > 0 ? "\(used) of \(limit) round\(limit == 1 ? "" : "s")" : "\(used) round\(used == 1 ? "" : "s")"
        if continuations > 0 { said += " \u{00B7} \(continuations) granted past the limit" }
        return said
    }
    var tone: RowTone { limitReached ? .warn : .muted }
}

/// A pull request's review outcome, with its rounds, security pass and approvals.
struct ReviewOutcome: Equatable, Sendable {
    var outcome: ReviewOutcomeKind
    var reasons: [ReviewReason]
    /// The pull request moved on from the reviewed revision; a stale outcome is never passed.
    var stale: Bool
    /// The outcome passed and the approvals are not pending.
    var ready: Bool
    /// The project publishes the outcome as a commit status (`enforceReviewOutcome`), and whether GitHub carries it yet.
    var enforced: Bool
    var published: Bool
    var security: ReviewSecurity?
    var approvals: ReviewApprovals?
    var rounds: ReviewRounds?

    /// What `state(_:over:)` keeps; nil while the server has sent no outcome (an older server, or nothing read yet).
    init?(_ state: JSON) {
        let o = state["reviewOutcome"]
        guard o.isObject, let outcome = o["outcome"].string.flatMap(ReviewOutcomeKind.init) else { return nil }
        self.outcome = outcome
        reasons = ReviewReason.list(o["reasons"])
        stale = o["stale"].is(true)
        ready = o["ready"].is(true)
        enforced = o["enforced"].is(true)
        published = o["status"]["published"].is(true)
        security = ReviewSecurity(o["security"])
        approvals = ReviewApprovals(o["approvals"])
        rounds = ReviewRounds(state["reviewRounds"])
    }

    /// The outcome and rounds to keep from an answer: each that `answer` carries, else the one `previous` kept. A verdict
    /// save answers a fresh outcome without the rounds, and a handling save neither.
    static func state(_ answer: JSON, over previous: JSON = .null) -> JSON {
        var kept: JSON = [:]
        for key in ["reviewOutcome", "reviewRounds"] {
            let fresh = answer[key]
            kept[key] = fresh.isObject ? fresh : previous[key]
        }
        return kept["reviewOutcome"].isObject || kept["reviewRounds"].isObject ? kept : .null
    }

    /// What blocks or explains the outcome, the blocking ones first; the notes, which only inform, after them.
    var listedReasons: [ReviewReason] { reasons.filter { !$0.isNote } + reasons.filter(\.isNote) }
    /// Why the outcome is out of date, when it is.
    var staleNote: String? { stale ? "The pull request moved on from the reviewed revision; its next review is still to come." : nil }
    /// A project that enforces the outcome on GitHub, whose commit status GitHub does not carry yet.
    var statusNote: String? { enforced && !published ? "Not yet published to GitHub as the briareus/code-review status." : nil }
    /// Said once the review passed and the approvals it needs are in; CI and GitHub's own rules still apply to the merge.
    var readyNote: String? { ready ? "Review passed and the approvals it needs are in." : nil }
}
