// A session's ✉ Mail wake form (core #159): the rules under which new inbox mail in a connected mailbox wakes the
// session, the two caps the turns it starts run under, what the server's record fills them with, whether the project lets
// mail wake it at all, and the body Save sends to PUT /sessions/{id}/mail-wake.
import Foundation

/// The most rules a session keeps.
let mailWakeRuleLimit = 20
/// The longest address or subject a rule takes, in UTF-16 units as the server counts.
let mailWakeTextLimit = 320

/// One rule: new inbox mail in `account` that matches every filter given wakes the session; an empty filter matches all.
struct MailWakeRule: Equatable, Sendable {
    /// The server's id, sent back so an unchanged rule keeps its activation time; nil for a rule not saved yet.
    var id: String?
    /// A connected mailbox's id; nil until one is chosen.
    var account: Int?
    var enabled = true
    var to = ""
    var from = ""
    var subject = ""

    init(id: String? = nil, account: Int? = nil, enabled: Bool = true, to: String = "", from: String = "", subject: String = "") {
        self.id = id; self.account = account; self.enabled = enabled; self.to = to; self.from = from; self.subject = subject
    }
    /// A rule as the server answers it; a rule without `enabled` is on, as the server takes it.
    init(_ j: JSON) {
        id = j["id"].nonEmpty
        account = j["account"].truncatedInt.flatMap { $0 > 0 ? $0 : nil }
        enabled = j["enabled"].bool ?? true
        for f in MailWakeFilter.allCases { self[f] = j[f.key].string ?? "" }
    }

    subscript(f: MailWakeFilter) -> String {
        get { f == .to ? to : f == .from ? from : subject }
        set { switch f { case .to: to = newValue; case .from: from = newValue; case .subject: subject = newValue } }
    }
}

/// A rule's three filters, by the key they are read and sent under.
enum MailWakeFilter: String, CaseIterable, Hashable, Sendable {
    case to, from, subject

    var key: String { rawValue }
    /// To and From take one exact address; Subject any text it contains.
    var isAddress: Bool { self != .subject }
    var label: String {
        switch self {
        case .to: return "To or Cc"
        case .from: return "From"
        case .subject: return "Subject contains"
        }
    }
    var hint: String {
        switch self {
        case .to: return "One exact address among the message's To and Cc. Empty matches any."
        case .from: return "The sender's exact address. Empty matches any sender except the mailbox itself."
        case .subject: return "Text the subject contains, in any case. Empty matches any subject."
        }
    }
    func def() -> SettingsField { SettingsField(key: key, kind: .text, label: label, hint: hint) }
}

/// The two caps, each a whole number in its range; unlike the webhook's, turns cannot be unlimited.
enum MailWakeCap: String, CaseIterable, Hashable, Sendable {
    case perHour, maxTurns

    var key: String { rawValue }
    var label: String { self == .perHour ? "Wakes an hour" : "Turns in a row" }
    var hint: String {
        self == .perHour ? "Mail past it waits for the next hour. From 1 to 600."
            : "Turns mail may start with no word from you; past it wakes wait until you say anything in the conversation. From 1 to 1000."
    }
    var range: ClosedRange<Int> { self == .perHour ? 1...600 : 1...1000 }
    /// The server's default, for a record that lacks the cap.
    var fallback: Int { self == .perHour ? 30 : 10 }
    /// Why a value outside `range` is refused.
    var invalid: String { "\(label) must be a whole number from \(range.lowerBound) to \(range.upperBound)." }

    func def() -> SettingsField { SettingsField(key: key, kind: .text, label: label, hint: hint) }
    /// The text the form opens with for a mail-wake record.
    func text(_ wake: JSON) -> String { String(wake[key].truncatedInt ?? fallback) }
}

/// The rules a mail-wake record (or a session record's `mailWake`) holds.
func mailWakeRules(_ wake: JSON) -> [MailWakeRule] { wake["rules"].items.filter(\.isObject).map(MailWakeRule.init) }

/// Whether a session record says mail can wake it: a rule is on. The conversation's header marks the button so.
func mailWakeOn(_ session: JSON) -> Bool { mailWakeRules(session["mailWake"]).contains(where: \.enabled) }

/// Whether the project lets its sessions use mail, from `GET /settings/projects`; nil when the list does not say.
func mailToolsEnabled(_ settingsProjects: JSON, repo: String) -> Bool? {
    listOf(settingsProjects, "projects").items.first { $0["repo"].string == repo }?["mailToolsEnabled"].bool
}

/// The mailboxes a rule can wake on: connected and turned on, as the server requires of an enabled rule.
func mailWakeMailboxes(_ accounts: MailAccounts) -> [MailAccount] {
    accounts.accounts.filter { $0.enabled && $0.status == "connected" }
}

/// One address as the server takes it: something, an @, and a domain with a dot inside it, no spaces.
func mailWakeAddress(_ text: String) -> Bool {
    let parts = text.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !text.contains(where: \.isWhitespace), !parts[0].isEmpty else { return false }
    let domain = Array(parts[1])
    return domain.indices.contains { domain[$0] == "." && $0 > 0 && $0 < domain.count - 1 }
}

/// Why the form cannot be sent; `rule` counts from 0.
enum MailWakeProblem: Equatable, Sendable {
    case tooMany
    case noMailbox(rule: Int)
    /// The rule is on but its mailbox is not connected and turned on.
    case mailboxUnusable(rule: Int)
    case notAddress(rule: Int, MailWakeFilter)
    case tooLong(rule: Int, MailWakeFilter)
    /// A rule is on in a project whose mail tools are off.
    case mailToolsOff
    case cap(MailWakeCap)

    var message: String {
        switch self {
        case .tooMany: return "A session keeps at most \(mailWakeRuleLimit) rules."
        case .noMailbox(let r): return "Rule \(r + 1) needs a mailbox."
        case .mailboxUnusable(let r): return "Rule \(r + 1)'s mailbox is not connected and turned on. Choose another, or turn the rule off."
        case .notAddress(let r, let f): return "Rule \(r + 1): \(f.label) must be one email address."
        case .tooLong(let r, let f): return "Rule \(r + 1): \(f.label) must be at most \(mailWakeTextLimit) characters."
        case .mailToolsOff: return "This project's mail tools are off, so its sessions cannot be woken by mail. Turn the rules off, or turn mail tools on in the project's settings."
        case .cap(let c): return c.invalid
        }
    }
    /// The rule at fault, when it is one rule's.
    var rule: Int? {
        switch self {
        case .noMailbox(let r), .mailboxUnusable(let r), .notAddress(let r, _), .tooLong(let r, _): return r
        default: return nil
        }
    }
}

/// What Save sends, or the first thing that cannot be sent.
enum MailWakeSave: Equatable, Sendable {
    case body(JSON)
    case invalid(MailWakeProblem)
}

/// The PUT body from the rules and the caps as typed. `usable` is the mailboxes an enabled rule may name and `mailTools`
/// whether the project allows mail; nil when unknown, which leaves the server to judge.
func mailWakeSave(rules: [MailWakeRule], caps: [MailWakeCap: String], usable: Set<Int>? = nil, mailTools: Bool? = nil) -> MailWakeSave {
    guard rules.count <= mailWakeRuleLimit else { return .invalid(.tooMany) }
    if mailTools == false && rules.contains(where: \.enabled) { return .invalid(.mailToolsOff) }
    var out: [JSON] = []
    for (i, rule) in rules.enumerated() {
        guard let account = rule.account else { return .invalid(.noMailbox(rule: i)) }
        if rule.enabled, let usable, !usable.contains(account) { return .invalid(.mailboxUnusable(rule: i)) }
        var r: JSON = ["account": JSON(account), "enabled": .bool(rule.enabled)]
        if let id = rule.id { r["id"] = .string(id) }
        for f in MailWakeFilter.allCases {
            let text = rule[f].cTrimmed
            if text.utf16.count > mailWakeTextLimit { return .invalid(.tooLong(rule: i, f)) }
            if f.isAddress && !text.isEmpty && !mailWakeAddress(text) { return .invalid(.notAddress(rule: i, f)) }
            r[f.key] = .string(text)
        }
        out.append(r)
    }
    var body: JSON = ["rules": .array(out)]
    for c in MailWakeCap.allCases {
        guard let n = Int((caps[c] ?? "").cTrimmed), c.range.contains(n) else { return .invalid(.cap(c)) }
        body[c.key] = JSON(n)
    }
    return .body(body)
}
