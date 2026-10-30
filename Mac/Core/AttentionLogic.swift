// What waits on the operator (`GET /attention`), parsed for both apps' Status screens. No UI here.
import Foundation

// MARK: - Waiting on the operator

/// One thing the server says is waiting on the operator (`GET /attention`): a question, a session that failed or was
/// interrupted, a QA loop that stopped, a paused webhook, or an SSH command or Slack message an agent asks approval for.
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
}

/// An ISO-8601 time, with or without fractions.
func attentionDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
