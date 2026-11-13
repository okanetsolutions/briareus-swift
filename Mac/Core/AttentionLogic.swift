// What waits on the operator (`GET /attention`), parsed for both apps' Status screens. No UI here.
import Foundation

// MARK: - Waiting on the operator

/// One thing the server says is waiting on the operator (`GET /attention`): a question, a session that failed or was
/// interrupted, a QA loop that stopped, a paused webhook, an SSH command or Slack message an agent asks approval for, or a
/// pull request whose code review waits on a person (`review-limit`, `review-status`, `review-approval`).
struct AttentionItem: Equatable, Sendable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var summary: String
    var repo: String?
    var sessionID: String?
    var sessionTitle: String?
    /// The pull request a review item is about; those have no session.
    var prNumber: Int?
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
        prNumber = j["prNumber"].truncatedInt
        at = j["at"].string.flatMap { attentionDate($0) }
        request = j["request"]
    }

    var isApproval: Bool { kind == "ssh" || kind == "slack" }
    /// The pull request to open for an item that has no session of its own, with its project; nil otherwise.
    var pull: (repo: String, number: Int)? {
        guard sessionID == nil, let repo, let prNumber else { return nil }
        return (repo, prNumber)
    }
    /// The pull request a `review-approval` item waits on a person's approval of, which both Status screens read and
    /// approve in place (its risk, security pass and Approve); nil for every other kind.
    var approvalPull: (repo: String, number: Int)? { kind == "review-approval" ? pull : nil }
    /// The approval's own id, which the decision names.
    var requestID: String? { request["id"].nonEmpty }
    /// The route that rules on an approval (`ssh_decision`, `slack_decision`); nil for an item that is not one.
    var decisionOperation: String? {
        switch kind {
        case "ssh": return "ssh_decision"
        case "slack": return "slack_decision"
        default: return nil
        }
    }
    /// The decision's body: the request it rules on and whether it is approved; nil without a request to name.
    func decisionArguments(approve: Bool) -> JSON? {
        guard decisionOperation != nil, let requestID else { return nil }
        return ["id": .string(requestID), "decision": .string(approve ? "approve" : "deny")]
    }
    /// Sending a Slack message as you is confirmed first; running a command or denying either is not.
    func confirmsFirst(approve: Bool) -> Bool { approve && kind == "slack" }
    /// The approve button's word for what approving does: the command runs, or the message goes out.
    var approveLabel: String { kind == "ssh" ? "Run it" : "Send it" }
    /// What the confirmation asks before a message goes out as you.
    static let sendConfirmTitle = "Send this Slack message as you?"
    /// What a decision came back with: the request's status (or the decision when it names none), with its error.
    static func decisionResult(_ answer: JSON, approve: Bool) -> String {
        let status = answer["request"]["status"].string ?? (approve ? "approved" : "denied")
        return answer["request"]["error"].nonEmpty.map { "\(status): \($0)" } ?? status
    }
    var expiresAt: Date? { request["expiresAt"].number.map { Date(timeIntervalSince1970: $0 / 1000) } }
    /// An SSH command run as root with the server's stored sudo password; the command shown is the sudo wrapper around it.
    var elevated: Bool { kind == "ssh" && request["sudo"].is(true) }

    /// What kind of wait it is, in a word or two.
    var label: String {
        switch kind {
        case "question": return "Question"
        case "recovery": return "Stopped"
        case "qa-failed": return "QA failed"
        case "qa-verdict": return "QA unread"
        case "webhook-paused": return "Webhook paused"
        case "ssh": return "SSH approval"
        case "slack": return "Slack approval"
        case "review-limit": return "Review rounds used"
        case "review-status": return "Review status unpublished"
        case "review-approval": return "Approval needed"
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
        if elevated { parts.append("as root") }
        if kind == "slack", let ws = request["workspaceLabel"].nonEmpty { parts.append("as \(request["sendsAs"].nonEmpty ?? "you") in \(ws)") }
        if request["unattended"].is(true) { parts.append("asked in a turn nobody started") }
        return parts.joined(separator: " · ")
    }

    /// The list, newest first as the server sends it.
    static func parse(_ answer: JSON) -> [AttentionItem] { answer["items"].items.compactMap(AttentionItem.init) }
    /// What the iPhone's Status rules on, in the server's order: the SSH and Slack approvals agents wait on, and the
    /// pull requests waiting on a person's approval.
    static func statusApprovals(_ items: [AttentionItem]) -> [AttentionItem] {
        items.filter { $0.isApproval || $0.approvalPull != nil }
    }
}

/// An ISO-8601 time, with or without fractions.
func attentionDate(_ s: String) -> Date? { isoFractional.date(from: s) ?? isoWhole.date(from: s) }
/// Made once: every item of a list parsed asks, and making a formatter costs far more than using one. Never changed
/// after this, so reading from several threads is safe.
private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoWhole: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
