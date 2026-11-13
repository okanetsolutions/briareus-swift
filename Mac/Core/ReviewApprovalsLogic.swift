// The human approvals a pull request's risk asks for, beyond the counts the review outcome shows (ReviewOutcomeLogic.swift):
// what produced the risk tier, every approval on record with whether it counts and why not, and the two writes a person
// makes, recording their approval of the reviewed head (`POST /pulls/{n}/approvals`) and withdrawing one of their own
// (`POST /pulls/{n}/approvals/{id}/withdraw`). Both apps' Code reviews tab draw it under the outcome. No UI here.
import Foundation

/// One approval the server has on record: recorded by a person here, or read from GitHub.
struct ReviewApproval: Equatable, Sendable, Identifiable {
    var id: Int
    /// Recorded through the API (`briareus`), or read from the pull request's reviews on GitHub.
    var fromGithub: Bool
    /// The Briareus user who recorded it; nil for one read from GitHub.
    var userId: Int?
    var name: String?
    var githubLogin: String?
    /// The head it approves, and counts for alone.
    var headSha: String
    var at: Date?
    var note: String?
    var withdrawn: Bool
    /// When its approver withdrew it, and what they wrote then.
    var withdrawnAt: Date?
    var withdrawNote: String?
    var counted: Bool
    /// Why it does not count (`withdrawn`, `head_moved`, `own_change`, …), in the server's words when it gave them.
    var reason: String?
    var message: String?

    init?(_ j: JSON) {
        guard let id = j["id"].truncatedInt else { return nil }
        self.id = id
        fromGithub = j["source"].string == "github"
        userId = j["by"]["userId"].truncatedInt
        name = j["by"]["name"].nonEmpty
        githubLogin = j["by"]["githubLogin"].nonEmpty
        headSha = j["headSha"].string ?? ""
        at = j["at"].string.flatMap(attentionDate)
        note = j["note"].nonEmpty
        withdrawn = j["withdrawnAt"].nonEmpty != nil
        withdrawnAt = j["withdrawnAt"].string.flatMap(attentionDate)
        withdrawNote = j["withdrawNote"].nonEmpty
        counted = j["counted"].is(true)
        reason = j["reason"].nonEmpty
        message = j["message"].nonEmpty
    }

    /// Who gave it: the person's name, else the GitHub account as `@login`.
    var who: String { name ?? githubLogin.map { "@\($0)" } ?? "Someone" }
    /// "Counts", "Withdrawn", or the reason it does not count.
    var state: String {
        if counted { return "Counts" }
        if withdrawn { return "Withdrawn" }
        return message ?? reason.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "Does not count"
    }
    var tone: RowTone { counted ? .ok : .muted }
    var symbol: String { counted ? "checkmark.circle" : withdrawn ? "arrow.uturn.backward.circle" : "minus.circle" }
    /// "on GitHub" for one read from there, and the head it approves in short.
    var detail: String {
        var parts: [String] = []
        if fromGithub { parts.append("on GitHub") }
        if !headSha.isEmpty { parts.append(String(headSha.prefix(7))) }
        return parts.joined(separator: " \u{00B7} ")
    }
    /// Why its approver withdrew it, in their words, for showing under its own note.
    var withdrawLine: String? { withdrawNote.map { "Withdrawn: \($0)" } }
    /// Only its approver withdraws one recorded here; one read from GitHub is dismissed there. Without the token's user
    /// (an older server) every approval recorded here is offered, and the server refuses another person's.
    func canWithdraw(me: Int?) -> Bool {
        guard !fromGithub, !withdrawn else { return false }
        guard let me, let userId else { return true }
        return me == userId
    }
}

/// One thing that set the change's risk tier: a sensitive path rule, a size threshold, an unreadable file list.
struct RiskReason: Equatable, Sendable, Identifiable {
    var code: String
    var tier: String?
    var message: String
    var id: String

    init?(_ j: JSON, index: Int) {
        guard let code = j["code"].nonEmpty else { return nil }
        self.code = code
        tier = j["tier"].nonEmpty
        message = j["message"].nonEmpty ?? code.replacingOccurrences(of: "_", with: " ")
        id = "\(index):\(code)"
    }
    static func list(_ j: JSON) -> [RiskReason] { j.items.enumerated().compactMap { RiskReason($1, index: $0) } }
}

/// The two writes on a pull request's approvals, and what an answer leaves of the kept outcome.
enum ReviewApprovalWrite {
    /// Approves exactly `headSha`, the head the requirement was computed for; the server refuses it once the pull
    /// request has moved on, so nothing approves commits nobody looked at.
    static func approveArguments(repo: String, number: Int, headSha: String, note: String) -> JSON {
        var args: JSON = ["repo": .string(repo), "pr": JSON(number), "headSha": .string(headSha)]
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { args["note"] = .string(note) }
        return args
    }
    static func withdrawArguments(repo: String, number: Int, approval: ReviewApproval, note: String) -> JSON {
        var args: JSON = ["repo": .string(repo), "pr": JSON(number), "approvalId": JSON(approval.id)]
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { args["note"] = .string(note) }
        return args
    }
    /// The notes are kept to the server's 2000 characters.
    static let noteLimit = 2000
}

extension ReviewApprovals {
    /// Approve is offered while the requirement asks for people, a review that has ended covers the head it names, and
    /// no approval of `me` already counts for it.
    func canApprove(me: Int?) -> Bool {
        guard enabled, result != "not_required", reviewCurrent, let headSha, !headSha.isEmpty else { return false }
        guard let me else { return true }
        return !approvals.contains { $0.counted && $0.userId == me && $0.headSha == headSha }
    }
    /// What the requirement says beyond its explanation: the pending reasons first, then the notes.
    var listedReasons: [ReviewReason] { reasons.filter { !$0.isNote } + reasons.filter(\.isNote) }
}
