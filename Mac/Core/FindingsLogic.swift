// The ⚑ Findings screen's pure parts, as the Windows client's screen_findings.c: rounds grouped by pull request, the
// verdicts a save or a completion sends, and the words its cards and confirmations use.
import Foundation

/// The rounds left on one pull request, in the queue's oldest-first order: indexes into the rounds list.
struct FindingsGroup: Equatable {
    var repo: String
    var pr: Int
    var rounds: [Int]
}

enum Findings {
    static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    /// Rounds by the pull request they were left on (the repository compared folded), in the order they first appear.
    static func groups(_ rounds: [HeldRound], sessions: [Session]) -> [FindingsGroup] {
        var out: [FindingsGroup] = []
        for (i, r) in rounds.enumerated() {
            let repo = sessions[r.index].repo ?? ""
            let pr = heldRoundPRNumber(r.held) ?? 0
            if let g = out.firstIndex(where: { $0.pr == pr && foldEqual($0.repo, repo) }) { out[g].rounds.append(i) }
            else { out.append(FindingsGroup(repo: repo, pr: pr, rounds: [i])) }
        }
        return out
    }

    /// The verdicts a save or a completion sends, one per finding with a key. Completing rules on every finding: an
    /// unmarked one goes as optional, which the loop never offers again; a save sends null for it, and every comment.
    static func verdicts(_ findings: JSON, decision: (String) -> String, reason: (String) -> String, completing: Bool) -> JSON {
        var out: [JSON] = []
        for f in findings.items {
            guard let key = f["key"].string else { continue }
            let d = decision(key), r = reason(key)
            var v: JSON = ["key": .string(key)]
            if !d.isEmpty { v["decision"] = .string(d) }
            else if completing { v["decision"] = "optional" }
            else { v["decision"] = .null }
            if !r.isEmpty || !completing { v["reason"] = .string(r) }
            out.append(v)
        }
        return .array(out)
    }

    /// The confirmation before Complete.
    static func completePrompt(mine: Bool, fixes: Int, pr: Int) -> (title: String, message: String) {
        guard mine else { return ("Take this review off the queue?", "What it found stays on PR #\(pr) for its author.") }
        if fixes > 0 {
            return ("Start a paid fix session for \(fixes) finding\(plural(fixes))?",
                    "Every verdict and comment is recorded on PR #\(pr); what is marked fix goes to the fix session.")
        }
        return ("Complete with nothing to fix?", "Every verdict is recorded on PR #\(pr), which is approved and its loop closed.")
    }
    /// The Complete button's words on the user's own pull request.
    static func completeLabel(fixes: Int, sending: Bool) -> String {
        if sending { return "Completing\u{2026}" }
        return fixes > 0 ? "Complete \u{00B7} send \(fixes) to be fixed" : "Complete \u{00B7} nothing to fix, approve and close"
    }
    /// How a card is worked, under its title.
    static func howText(mine: Bool, manage: Bool, count n: Int) -> String {
        let count = "\(n) finding\(plural(n))"
        if !mine {
            return n > 0 ? "\(count), already on the pull request. Read them there; Reply says something on a finding\u{2019}s own thread, Delete takes one out of the review itself, and Complete takes this card off the queue and leaves the rest to the pull request\u{2019}s author."
                         : "Every finding was deleted from the review. Complete takes this card off the queue."
        }
        if !manage { return "\(count). This device is read-only: the verdicts are given with a Manage token." }
        return "\(count). Give each one a verdict and a comment if you have one; Save comments keeps them here and on the pull request, and Complete appears once every finding is marked."
    }
    /// "round 3 · held since 10:42", or "code review" for a hand-started one.
    static func roundMeta(_ held: JSON, now: Date = Date()) -> String {
        var s = held["standalone"].isSet ? "code review" : "round \(held["round"].int32 ?? 0)"
        if let at = boardDateParse(held["heldAt"].string) { s += " \u{00B7} held since \(formatEventTime(at, now: now))" }
        return s
    }
    /// A group's heading count: "3 findings", or "5 findings across 2 reviews".
    static func groupCount(findings: Int, reviews: Int) -> String {
        reviews > 1 ? "\(findings) finding\(plural(findings)) across \(reviews) reviews" : "\(findings) finding\(plural(findings))"
    }
    static func unmarkedText(_ n: Int) -> String {
        "\(n) finding\(plural(n)) still unmarked; Complete appears once every finding has a verdict."
    }
    static func deleteMessage(title: String?, pr: Int) -> String {
        "\u{201C}\(title ?? "Finding")\u{201D} \u{2014} its comment on PR #\(pr) is deleted on GitHub and the review stops declaring it. This cannot be undone."
    }
    /// "src/a.swift:12 ↗", or nil without a file.
    static func location(_ finding: JSON) -> String? {
        guard let file = finding["file"].nonEmpty else { return nil }
        if let line = finding["line"].int32, line != 0 { return "\(file):\(line) \u{2197}" }
        return "\(file) \u{2197}"
    }
    /// The loop's own advice on a finding it would have parked; nil when it would not.
    static func parkedAdvice(_ finding: JSON) -> String? {
        guard finding["parked"].isSet else { return nil }
        return "The loop would have parked it: \(finding["parkedWhy"].nonEmpty ?? finding["parked"].nonEmpty ?? "")."
    }
    /// What a delete came back with: the line, and whether it is a warning.
    static func deleteOutcome(_ answer: JSON) -> (text: String, danger: Bool) {
        if let w = answer["warning"].nonEmpty { return ("Deleted, but the review still declares it: \(w)", true) }
        return (answer["commentDeleted"].isSet ? "Deleted from the review" : "The review no longer declares it; it had no comment of its own to delete", false)
    }
    /// Whether a completion's answer is worth a line once its card is gone: a dismissal of somebody else's review says nothing.
    static func completionSpeaks(_ answer: JSON) -> Bool { !answer["dismissed"].isSet || answer["approved"].isSet }

    /// The review rounds waiting across the projects, from the conversations saved for each one (`sessions:<repo>`).
    static func waiting(projects: [Project], saved: (String) -> JSON?) -> Int {
        var total = 0
        for p in projects {
            guard let list = saved("sessions:\(p.repo)"), let sessions = Session.parseList(list) else { continue }
            total += sessions.filter { $0.heldRound != nil }.count
        }
        return total
    }
}

// MARK: - Waiting on the operator

/// One thing the server says is waiting on the operator (`GET /attention`): a question, a session that failed or was
/// interrupted, a review or QA loop that stopped, a paused webhook, or an SSH command or Slack message an agent asks
/// approval for. Held review rounds are left to the findings below them.
struct AttentionItem: Equatable, Sendable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var summary: String
    var repo: String?
    var sessionID: String?
    var sessionTitle: String?
    var at: Date?
    /// An approval's request: its id, and for SSH the server, host and how long it may run; for Slack where it goes.
    var request: JSON

    init?(_ j: JSON) {
        guard let id = j["id"].nonEmpty, let kind = j["kind"].nonEmpty else { return nil }
        self.id = id; self.kind = kind
        title = j["title"].nonEmpty ?? j["sessionTitle"].nonEmpty ?? "Session"
        summary = j["summary"].string ?? ""
        repo = j["repo"].nonEmpty
        sessionID = j["sessionId"].nonEmpty
        sessionTitle = j["sessionTitle"].nonEmpty
        at = j["at"].string.flatMap { attentionDate($0) }
        request = j["request"]
    }

    var isApproval: Bool { kind == "ssh" || kind == "slack" }
    /// The approval's own id, which the decision names.
    var requestID: String? { request["id"].nonEmpty }
    var expiresAt: Date? { request["expiresAt"].number.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// What kind of wait it is, in a word or two.
    var label: String {
        switch kind {
        case "question": return "Question"
        case "recovery": return "Stopped"
        case "review-failed": return "Review failed"
        case "review-stalled": return "Review stalled"
        case "qa-failed": return "QA failed"
        case "qa-verdict": return "QA unread"
        case "webhook-paused": return "Webhook paused"
        case "ssh": return "SSH approval"
        case "slack": return "Slack approval"
        default: return kind
        }
    }
    /// For an approval, who asked and where it goes: "Heedly · Fix checks #2955 · deploy@web-1:22".
    var detail: String {
        var parts: [String] = []
        if let repo { parts.append(repo) }
        if let t = sessionTitle, t != title { parts.append(t) }
        if kind == "ssh", let user = request["username"].nonEmpty, let host = request["host"].nonEmpty {
            parts.append("\(user)@\(host)\(request["port"].int32.map { ":\($0)" } ?? "")")
        }
        if kind == "slack", let ws = request["workspaceLabel"].nonEmpty { parts.append("as \(request["sendsAs"].nonEmpty ?? "you") in \(ws)") }
        if request["unattended"].is(true) { parts.append("asked in a turn nobody started") }
        return parts.joined(separator: " · ")
    }

    /// The list, without held findings (shown as rounds below), newest first as the server sends it.
    static func parse(_ answer: JSON) -> [AttentionItem] {
        answer["items"].items.compactMap(AttentionItem.init).filter { $0.kind != "findings" }
    }
}

/// An ISO-8601 time, with or without fractions.
func attentionDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
