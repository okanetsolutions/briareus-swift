// Mail synced from Gmail and Outlook (core #120; the Windows client's core/mail.c): the connected mailboxes and the
// providers the server can connect, the sign-in a connection starts, and the settings a mailbox keeps. The server reads
// the mail with the provider's own sign-in and keeps it; the apps only read its copy.
import Foundation

/// One connected mailbox. Its tokens are never sent to the app.
struct MailAccount: Equatable, Sendable {
    var id: Int
    var provider: String
    var email: String
    var label: String
    var enabled: Bool
    var syncDays: Int
    /// `connected`, or `reauth` once the provider stopped honouring its sign-in.
    var status: String
    var syncing: Bool
    var lastSyncAt: Date?
    var lastSyncError: String?
    var messages: Int
    var unread: Int

    /// Needs a positive id, a provider and an address.
    init?(_ j: JSON) {
        guard j.isObject, let id = j["id"].truncatedInt, id > 0, let provider = j["provider"].nonEmpty, let email = j["email"].nonEmpty else { return nil }
        self.id = id; self.provider = provider; self.email = email
        label = j["label"].string ?? ""
        enabled = j["enabled"].is(true)
        syncDays = j["syncDays"].truncatedInt ?? 30
        status = j["status"].string ?? ""
        syncing = j["syncing"].is(true)
        lastSyncAt = mailTime(j["lastSyncAt"])
        lastSyncError = j["lastSyncError"].nonEmpty
        messages = j["messages"].truncatedInt ?? 0
        unread = j["unread"].truncatedInt ?? 0
    }

    var needsSignIn: Bool { status == "reauth" }
    /// "Work (me@example.com)", or the address alone.
    var title: String { label.cTrimmed.isEmpty ? email : "\(label) (\(email))" }
    var providerName: String { mailProviderName(provider) }
}

func mailProviderName(_ provider: String) -> String { provider == "gmail" ? "Gmail" : provider == "outlook" ? "Outlook" : provider }

/// An epoch-milliseconds time, nil when absent or not positive.
func mailTime(_ j: JSON) -> Date? {
    guard let ms = j.number, ms.isFinite, ms > 0 else { return nil }
    return Date(timeIntervalSince1970: ms / 1000)
}

/// `GET /settings/mail/accounts`: the mailboxes, which providers the server has an OAuth client for, and the values a new
/// one starts from.
struct MailAccounts: Equatable, Sendable {
    var accounts: [MailAccount]
    var gmail: Bool
    var outlook: Bool

    /// Nil unless both lists are there and every account reads.
    init?(_ j: JSON) {
        guard j["accounts"].isArray, j["providers"].isArray else { return nil }
        var rows: [MailAccount] = []
        for item in j["accounts"].items {
            guard let a = MailAccount(item) else { return nil }
            rows.append(a)
        }
        accounts = rows
        let providers = j["providers"].items.compactMap(\.string)
        gmail = providers.contains("gmail"); outlook = providers.contains("outlook")
    }
    init(accounts: [MailAccount] = [], gmail: Bool = false, outlook: Bool = false) {
        self.accounts = accounts; self.gmail = gmail; self.outlook = outlook
    }

    func find(_ id: Int) -> MailAccount? { accounts.first { $0.id == id } }
    func available(_ provider: String) -> Bool { (provider == "gmail" && gmail) || (provider == "outlook" && outlook) }
    var syncing: Bool { accounts.contains(where: \.syncing) }
}

/// The sync window typed for a mailbox: a whole number of days from 1 to 365, else nil.
func mailSyncDays(_ typed: String) -> Int? {
    let t = typed.cTrimmed
    guard !t.isEmpty, t.count <= 3, t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(t), (1...365).contains(n) else { return nil }
    return n
}

// MARK: - Signing in

/// A connection under way (`POST …/connect`): where the provider sends the browser back, until when, and whether the server
/// finishes it itself (its own callback) or the app sends it the address the sign-in ended on.
struct MailSignIn: Equatable, Sendable {
    var url: String
    var state: String
    var redirectURI: String
    var provider: String
    var accountID: Int?
    var finishesOnServer: Bool
    var expiresAt: Date
    /// The accounts and their status when it started, which tell a sign-in that finished from one still waiting.
    var before: [Int: String]

    /// Nil unless the address to sign in at is https, the redirect is https or a loopback address, and the provider is one
    /// the server offers.
    init?(_ j: JSON, provider: String, accountID: Int?, accounts: MailAccounts) {
        guard let url = j["url"].string, mailOAuthURL(url), let state = j["state"].nonEmpty,
              let redirect = j["redirectUri"].nonEmpty, mailRedirectSafe(redirect), let expires = mailTime(j["expiresAt"]),
              j["finishesOnServer"].bool != nil, accounts.available(provider) else { return nil }
        self.url = url; self.state = state; redirectURI = redirect; self.provider = provider; self.accountID = accountID
        finishesOnServer = j["finishesOnServer"].is(true)
        expiresAt = expires
        before = Dictionary(accounts.accounts.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
    }

    /// The server finished it: an account of the provider that is new, or the one signed in again back from `reauth`, is
    /// connected. A mailbox already connected gives no sign of it, so the browser's own result says.
    func completed(by accounts: MailAccounts) -> Bool {
        guard finishesOnServer else { return false }
        return accounts.accounts.contains { a in
            if let accountID, a.id != accountID { return false }
            guard a.provider == provider, a.status == "connected" else { return false }
            guard let old = before[a.id] else { return true }
            return old == "reauth"
        }
    }

    /// The body for `…/connect/finish` from the whole address the sign-in ended on, pasted: nil unless it is the redirect
    /// exactly, carries this sign-in's state and one code, no error and no fragment, and the start has not expired.
    func finishBody(pasted: String, now: Date = Date()) -> JSON? {
        guard !finishesOnServer, now < expiresAt, !pasted.contains("#"), let q = pasted.firstIndex(of: "?") else { return nil }
        var destination = String(pasted[..<q])
        var expected = redirectURI
        // Browsers write an empty path as "/"; a path that is not empty must match exactly.
        let afterScheme = expected.hasPrefix("https://") ? expected.dropFirst(8) : expected.dropFirst(7)
        let path = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) }
        if path == nil || path == "/" {
            if path != nil { expected.removeLast() }
            if destination.hasSuffix("/") { destination.removeLast() }
        }
        guard destination == expected else { return nil }
        var state: String?, code: String?
        for pair in pasted[pasted.index(after: q)...].split(separator: "&", omittingEmptySubsequences: false) {
            guard let eq = pair.firstIndex(of: "="), let key = mailFormDecode(pair[..<eq]), let value = mailFormDecode(pair[pair.index(after: eq)...]) else { return nil }
            switch key {
            case "state": if state != nil { return nil }; state = value
            case "code": if code != nil { return nil }; code = value
            case "error": return nil
            default: break
            }
        }
        guard state == self.state, let code, !code.isEmpty else { return nil }
        return ["state": .string(self.state), "code": .string(code)]
    }
}

/// A query component decoded: `%XX` and `+`; nil when malformed or holding a control character.
private func mailFormDecode(_ s: Substring) -> String? {
    var bytes: [UInt8] = []
    var i = s.utf8.startIndex
    let u = s.utf8
    while i < u.endIndex {
        var c = u[i]
        if c == UInt8(ascii: "%") {
            let a = u.index(after: i)
            guard a < u.endIndex, u.index(after: a) < u.endIndex,
                  let h = Int(String(decoding: [u[a], u[u.index(after: a)]], as: UTF8.self), radix: 16) else { return nil }
            c = UInt8(h)
            i = u.index(after: u.index(after: a))
        } else {
            if c == UInt8(ascii: "+") { c = UInt8(ascii: " ") }
            i = u.index(after: i)
        }
        if c < 32 || c == 127 { return nil }
        bytes.append(c)
    }
    return String(bytes: bytes, encoding: .utf8)
}

/// An https address with nothing in it a browser would read otherwise: no spaces, controls or backslashes.
func mailOAuthURL(_ url: String) -> Bool {
    safeWebURL(url) && !url.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 || $0 == "\\" }
}

/// A redirect the sign-in may end on: https without a query or fragment, or http on this computer's loopback address with
/// an optional port and nothing that could hide another host.
func mailRedirectSafe(_ uri: String) -> Bool {
    if mailOAuthURL(uri) { return !uri.contains("#") && !uri.contains("?") }
    guard uri.hasPrefix("http://") else { return false }
    let rest = uri.dropFirst(7)
    var after: Substring
    if rest.hasPrefix("127.0.0.1") { after = rest.dropFirst(9) }
    else if rest.hasPrefix("localhost") { after = rest.dropFirst(9) }
    else if rest.hasPrefix("[::1]") { after = rest.dropFirst(5) }
    else { return false }
    if after.hasPrefix(":") {
        after = after.dropFirst()
        let digits = after.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let port = Int(digits), port > 0, port <= 65535 else { return false }
        after = after.dropFirst(digits.count)
    }
    if !after.isEmpty && !after.hasPrefix("/") { return false }
    return !uri.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 || "@?#\\".unicodeScalars.contains($0) }
}

/// What a refused mail request means, in words (`finishing`: the sign-in's exchange).
func mailErrorMessage(status: Int, finishing: Bool, detail: String?) -> String {
    if status == 400 && !finishing && detail == "Label too long" { return "Mailbox labels must be at most 200 characters after trimming whitespace." }
    switch status {
    case 400: return finishing ? "Sign-in expired, was already used, or was refused. Start sign-in again."
                               : "The server refused these settings; check its OAuth and encryption configuration."
    case 401: return "This token expired or was revoked. Reconnect to the server."
    case 403: return "Mail account settings require an Admin token."
    case 404: return "This mail route or account is no longer available. Refresh or reconnect to the server."
    case 409: return finishing ? "A different mailbox was selected (HTTP 409). The original account is unchanged; start again with its mailbox, or connect the other mailbox separately."
                               : "This account needs sign-in again (HTTP 409)."
    case 429: return "The server is rate limiting mail requests. Wait before trying again."
    case 503: return "This mail provider is unavailable on the server (HTTP 503). Check the server configuration."
    default: return "The request did not complete. Refresh account status before trying a write again."
    }
}

/// How long the account list waits after `failures` failed reads in a row: 10 s doubling to a minute, or the server's
/// Retry-After when longer.
func mailRetryDelay(failures: Int, retryAfter: Double?) -> TimeInterval {
    var delay: TimeInterval = 10
    var i = 1
    while i < failures && delay < 60 { delay = delay > 30 ? 60 : delay * 2; i += 1 }
    if let retryAfter, retryAfter.isFinite, retryAfter > delay { delay = retryAfter.rounded(.up) }
    return delay
}

// MARK: - The inbox

/// A sender or a recipient as "Name <address>", or the address alone.
func mailAddressText(_ j: JSON) -> String {
    let address = j["address"].string ?? ""
    if let name = j["name"].nonEmpty { return address.isEmpty ? name : "\(name) <\(address)>" }
    return address
}
func mailAddressesText(_ j: JSON) -> String { j.items.map(mailAddressText).filter { !$0.isEmpty }.joined(separator: ", ") }

struct MailAttachment: Equatable, Sendable {
    var name: String
    var mimeType: String
    var size: Int
}

/// A synced message: as a list shows it, and with its body once read on its own. Nothing here changes the mailbox.
struct MailMessage: Equatable, Sendable {
    var accountID: Int
    var id: String
    var threadID: String
    var receivedAt: Date?
    var from: String
    var to: String
    var cc: String
    var replyTo: String
    var subject: String
    var snippet: String
    var labels: [String]
    var inInbox: Bool
    var isRead: Bool
    var isStarred: Bool
    var attachments: [MailAttachment]
    var webURL: String?
    /// The plain text (the HTML rendered as text by the server when it had no text part); the HTML itself is never shown.
    var text: String?
    var truncated: Bool

    /// Needs its account and the provider's id.
    init?(_ j: JSON) {
        guard j.isObject, let account = j["accountId"].truncatedInt, account > 0, let id = j["id"].nonEmpty else { return nil }
        accountID = account; self.id = id
        threadID = j["threadId"].string ?? ""
        receivedAt = mailTime(j["receivedAt"])
        from = mailAddressText(j["from"]); to = mailAddressesText(j["to"]); cc = mailAddressesText(j["cc"]); replyTo = mailAddressesText(j["replyTo"])
        subject = j["subject"].string ?? ""
        snippet = j["snippet"].string ?? ""
        labels = j["labels"].items.compactMap(\.string)
        inInbox = j["inInbox"].is(true); isRead = j["isRead"].is(true); isStarred = j["isStarred"].is(true)
        attachments = j["attachments"].items.map { a in
            MailAttachment(name: a["name"].nonEmpty ?? "Unnamed", mimeType: a["mimeType"].nonEmpty ?? "unknown type", size: a["size"].truncatedInt ?? 0)
        }
        webURL = j["webUrl"].string.flatMap { mailWebURLSafe($0) ? $0 : nil }
        text = j["body"]["text"].string
        truncated = j["body"]["truncated"].is(true)
    }

    /// Who it is from, the sender's name alone when it has one.
    var sender: String { from.isEmpty ? "Unknown sender" : from }
    var shownSubject: String { subject.cTrimmed.isEmpty ? "(No subject)" : subject }
    /// The same message is the same account's id.
    var key: String { "\(accountID):\(id)" }
}

/// A page of `GET /mail/messages`, and the cursor of the next older one (nil on the last).
struct MailPage: Equatable, Sendable {
    var messages: [MailMessage]
    var nextCursor: String?

    init?(_ j: JSON) {
        guard j["messages"].isArray else { return nil }
        messages = j["messages"].items.compactMap(MailMessage.init)
        nextCursor = j["nextCursor"].nonEmpty
    }
}

/// The inbox's filters: one mailbox or all, a search, an exact label or folder, a thread, and read, inbox and star state
/// each as any (nil), no or yes.
struct MailFilter: Equatable, Sendable {
    var account: Int?
    var query = ""
    var label = ""
    var thread = ""
    var unread: Bool?
    var inbox: Bool?
    var starred: Bool?

    var isDefault: Bool { query.isEmpty && label.isEmpty && thread.isEmpty && unread == nil && inbox == nil && starred == nil }

    /// `GET /mail/messages`'s arguments for a page: the newest without a cursor.
    func arguments(cursor: String?) -> JSON {
        var out: JSON = [:]
        if let account { out["account"] = JSON(account) }
        let q = query.cTrimmed
        if !q.isEmpty { out["q"] = .string(String(q.prefix(200))) }
        if !label.cTrimmed.isEmpty { out["label"] = .string(label.cTrimmed) }
        if !thread.cTrimmed.isEmpty { out["thread"] = .string(thread.cTrimmed) }
        if let unread { out["unread"] = unread ? "1" : "0" }
        if let inbox { out["inbox"] = inbox ? "1" : "0" }
        if let starred { out["starred"] = starred ? "1" : "0" }
        if let cursor { out["cursor"] = .string(cursor) }
        return out
    }
}

/// The messages so far and a page after them: a message already listed (pages overlap as mail arrives) is not listed
/// twice, and one of a mailbox that cannot be read now (gone, or waiting for a sign-in) is left out.
func mailMerge(_ shown: [MailMessage], _ page: [MailMessage], readable: Set<Int>) -> [MailMessage] {
    var seen = Set(shown.map(\.key))
    var out = shown
    for m in page where readable.contains(m.accountID) && seen.insert(m.key).inserted { out.append(m) }
    return out
}

extension MailAccounts {
    /// The mailboxes whose mail can be read: connected ones.
    var readable: Set<Int> { Set(accounts.filter { !$0.needsSignIn }.map(\.id)) }
}

/// An https address whose host holds nothing a link could hide another in, for Open at the provider.
func mailWebURLSafe(_ url: String) -> Bool {
    guard safeWebURL(url) else { return false }
    let host = url.dropFirst(8).prefix { !"/?#".contains($0) }
    guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]".contains($0)) }) else { return false }
    return !url.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 || $0 == "\\" }
}
