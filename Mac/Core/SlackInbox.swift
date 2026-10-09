// The operator's Slack inbox (core #121; the Windows client's core/slack.c): the workspaces, their conversations and
// directory, a conversation's history and threads, and the messages sent to them as the operator. The server answers with
// Slack's own objects; this reads them: Slack timestamps compared as the decimal strings they are, mrkdwn turned into the
// Markdown the transcript draws, names for people and conversations, drafts per destination and read marks.
import Foundation

enum SlackTS {
    /// `1791403200.000100`: 1-12 digits, a point, 1-9 digits.
    static func valid(_ ts: String?) -> Bool {
        guard let ts, let dot = ts.firstIndex(of: ".") else { return false }
        let a = ts[..<dot], b = ts[ts.index(after: dot)...]
        return (1...12).contains(a.count) && (1...9).contains(b.count) && a.allSatisfy(\.isASCIIDigit) && b.allSatisfy(\.isASCIIDigit)
    }
    /// Orders two valid timestamps without floating point: the integer part by its significant length, then the fraction
    /// padded with zeroes.
    static func compare(_ a: String, _ b: String) -> Int {
        func split(_ s: String) -> (Substring, Substring) {
            let dot = s.firstIndex(of: ".") ?? s.endIndex
            var whole = s[..<dot]
            while whole.count > 1 && whole.first == "0" { whole = whole.dropFirst() }
            return (whole, dot < s.endIndex ? s[s.index(after: dot)...] : "")
        }
        let (aw, af) = split(a), (bw, bf) = split(b)
        if aw.count != bw.count { return aw.count < bw.count ? -1 : 1 }
        if aw != bw { return aw < bw ? -1 : 1 }
        let n = max(af.count, bf.count)
        let ap = af + String(repeating: "0", count: n - af.count), bp = bf + String(repeating: "0", count: n - bf.count)
        return ap == bp ? 0 : ap < bp ? -1 : 1
    }
    static func date(_ ts: String) -> Date? {
        guard valid(ts), let seconds = Double(ts) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

private extension Character { var isASCIIDigit: Bool { isASCII && isNumber } }

/// A message as Slack sent it, with what the inbox reads from it.
struct SlackMessage: Equatable, Sendable {
    var raw: JSON
    var ts: String { raw["ts"].string ?? "" }
    var user: String? { raw["user"].nonEmpty ?? raw["bot_id"].nonEmpty }
    var threadTS: String? { raw["thread_ts"].nonEmpty }
    var replyCount: Int { raw["reply_count"].truncatedInt ?? 0 }
    var isThreadParent: Bool { threadTS == nil || threadTS == ts }
    /// Shown in the conversation: a top-level message, or a reply also sent to the channel.
    var inChannel: Bool { isThreadParent || raw["subtype"].string == "thread_broadcast" }
}

/// The messages of one conversation, oldest first, each once by its ts; a later copy of one merges into it.
struct SlackMessages: Equatable, Sendable {
    private(set) var list: [SlackMessage] = []

    @discardableResult
    mutating func merge(_ j: JSON) -> Bool {
        guard let ts = j["ts"].string, SlackTS.valid(ts) else { return false }
        if let i = list.firstIndex(where: { $0.ts == ts }) {
            var raw = list[i].raw
            raw.merge(j)
            list[i].raw = raw
            return true
        }
        let m = SlackMessage(raw: j)
        let at = list.firstIndex { SlackTS.compare($0.ts, ts) > 0 } ?? list.count
        list.insert(m, at: at)
        return true
    }
    mutating func remove(_ ts: String) { list.removeAll { $0.ts == ts } }
    var newest: SlackMessage? { list.last }
}

/// Where the next page of history (older) or replies (newer) starts: the server's cursor, else the edge read so far. A
/// cursor seen twice, or a page that moves nothing, stops it rather than asking again forever.
struct SlackPage: Equatable, Sendable {
    var cursor = ""
    var oldest: String?
    var latest: String?
    var more = true
    var stalled = false

    /// Merges a page into `messages`; nil when the answer is not a page.
    mutating func merge(_ answer: JSON, into messages: inout SlackMessages, thread: Bool) -> Bool {
        guard answer["messages"].isArray, let cursor = answer["nextCursor"].string else { return false }
        var edge: String?
        for m in answer["messages"].items {
            guard let ts = m["ts"].string, between(ts) else { continue }
            messages.merge(m)
            if edge == nil || (thread ? SlackTS.compare(ts, edge!) > 0 : SlackTS.compare(ts, edge!) < 0) { edge = ts }
        }
        more = !cursor.isEmpty || answer["hasMore"].is(true)
        stalled = (!cursor.isEmpty && cursor == self.cursor) || (more && cursor.isEmpty && edge == nil)
        self.cursor = cursor
        if cursor.isEmpty, let edge, more { if thread { oldest = edge } else { latest = edge } }
        if stalled { more = false }
        return true
    }
    private func between(_ ts: String) -> Bool {
        SlackTS.valid(ts) && (oldest.map { SlackTS.compare(ts, $0) > 0 } ?? true) && (latest.map { SlackTS.compare(ts, $0) < 0 } ?? true)
    }
    /// The query for the next page.
    var arguments: JSON {
        var out: JSON = [:]
        if !cursor.isEmpty { out["cursor"] = .string(cursor) }
        else {
            if let oldest { out["oldest"] = .string(oldest) }
            if let latest { out["latest"] = .string(latest) }
        }
        return out
    }
}

enum SlackNames {
    /// A person's display name, else their real name, else their handle, else the id.
    static func person(_ id: String?, people: [String: JSON]) -> String {
        guard let id, !id.isEmpty else { return "Unknown author" }
        let p = people[id] ?? .null
        return p["profile"]["display_name"].nonEmpty ?? p["real_name"].nonEmpty ?? p["profile"]["real_name"].nonEmpty ?? p["name"].nonEmpty ?? id
    }
    /// A direct message by the person's name, a group or channel by its own.
    static func conversation(_ row: JSON, people: [String: JSON]) -> String {
        if row["is_im"].is(true) { return person(row["user"].string, people: people) }
        if row["is_mpim"].is(true), let purpose = row["purpose"]["value"].nonEmpty { return purpose }
        return row["name"].nonEmpty ?? row["id"].string ?? "Conversation"
    }
    /// What a conversation is: "#", "🔒", "@" or "👥".
    static func glyph(_ row: JSON) -> String {
        if row["is_im"].is(true) { return "@" }
        if row["is_mpim"].is(true) { return "👥" }
        if row["is_private"].is(true) { return "🔒" }
        return "#"
    }
}

enum SlackText {
    static let limit = 8000

    /// 1-8000 UTF-16 units (the server's JavaScript length), not only spaces.
    static func valid(_ text: String) -> Bool {
        text.utf16.count <= limit && text.contains { !$0.isWhitespace }
    }

    private static func literal(_ s: String) -> String {
        var out = ""
        for c in s { if "\\[]*_~`".contains(c) { out.append("\\") }; out.append(c) }
        return out
    }
    private static func safeLink(_ s: String) -> Bool { s.hasPrefix("https://") && !s.contains(where: { " ()\\\r\n\t".contains($0) }) }

    /// Where a `*` or `~` opened at `i` closes on its line, ignoring code and links; nil when it does not.
    private static func emphasisClose(_ c: [Character], _ i: Int) -> Int? {
        guard i + 1 < c.count, !c[i + 1].isWhitespace else { return nil }
        var code = false
        var p = i + 1
        while p < c.count {
            if p + 2 < c.count && c[p] == "`" && c[p + 1] == "`" && c[p + 2] == "`" { return nil }
            if c[p] == "\n" && p + 1 < c.count && c[p + 1] == "\n" { return nil }
            if c[p] == "`" { code.toggle() }
            else if !code && c[p] == "<", let end = c[p...].firstIndex(of: ">") { p = end }
            else if !code && c[p] == c[i] && p > i + 1 && !c[p - 1].isWhitespace { return p }
            p += 1
        }
        return nil
    }
    /// A line Markdown would read as a block (a heading, a list, a rule, a table's delimiter), which in Slack is plain text:
    /// the index of the character to escape.
    private static func blockLiteral(_ c: [Character], _ start: Int) -> Int? {
        var p = start
        while p < c.count && c[p] != "\n" && c[p].isWhitespace { p += 1 }
        guard p < c.count else { return nil }
        if c[p] == "#" || c[p] == "-" || c[p] == "+" { return p }
        let number = p
        while p < c.count && c[p].isASCIIDigit { p += 1 }
        if p > number && p - number <= 3 && p + 1 < c.count && (c[p] == "." || c[p] == ")") && c[p + 1] == " " { return p }
        p = number
        if c[p] == "_" || c[p] == "*" || c[p] == "~" {
            let mark = c[p]
            var q = p
            while q < c.count && c[q] != "\n" { if c[q] != mark && !c[q].isWhitespace { return nil }; q += 1 }
            return p
        }
        var dash: Int?
        while p < c.count && c[p] != "\n" {
            if c[p] == "-" && dash == nil { dash = p }
            else if !"-:|".contains(c[p]) && !c[p].isWhitespace { return nil }
            p += 1
        }
        return dash
    }

    /// Slack mrkdwn as Markdown: mentions by name, `<https://…|label>` links, `*bold*` and `~strike~`, entities, code
    /// spans and fences as they are, and what Markdown would take for markup left literal.
    static func markdown(_ source: String, people: [String: JSON]) -> String {
        let c = Array(source)
        var s = ""
        var code = false, fence = false
        var boldClose: Int?, strikeClose: Int?
        var blockEscape: Int?
        var p = 0
        func has(_ text: String, at i: Int) -> Bool {
            let t = Array(text)
            return i + t.count <= c.count && Array(c[i..<i + t.count]) == t
        }
        while p < c.count {
            if p == 0 || c[p - 1] == "\n" { blockEscape = blockLiteral(c, p) }
            let ch = c[p]
            if !code && !fence && p == blockEscape && "_*~".contains(ch) {
                while p < c.count && c[p] != "\n" { if "_*~".contains(c[p]) { s.append("\\") }; s.append(c[p]); p += 1 }
                continue
            } else if ch == "`" {
                if has("```", at: p) {
                    if !s.isEmpty && s.last != "\n" { s.append("\n") }
                    fence.toggle(); s += "```"
                    let after = p + 3
                    if (fence || after < c.count) && after < c.count && c[after] != "\n" && !(c[after] == "\r" && after + 1 < c.count && c[after + 1] == "\n") { s.append("\n") }
                    if !fence { blockEscape = blockLiteral(c, after) }
                    p += 3
                    continue
                }
                code.toggle(); s.append("`")
            } else if code || fence {
                s.append(ch)
            } else if has("&amp;", at: p) { s.append("&"); p += 5; continue }
            else if has("&lt;", at: p) { s.append("<"); p += 4; continue }
            else if has("&gt;", at: p) { s.append(">"); p += 4; continue }
            else if ch == "<", let end = c[p...].firstIndex(of: ">") {
                let token = String(c[(p + 1)..<end])
                let parts = token.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let target = String(parts[0]), label = parts.count > 1 ? String(parts[1]) : nil
                if target.hasPrefix("@") { s += "@" + literal(SlackNames.person(String(target.dropFirst()), people: people)) }
                else if target.hasPrefix("#") { s += "#" + literal(label ?? String(target.dropFirst())) }
                else if target.hasPrefix("!") { s += literal(label ?? String(target.dropFirst())) }
                else if safeLink(target) { s += "[\(literal(label ?? target))](\(target))" }
                else { s += literal(label ?? target) }
                p = end + 1
                continue
            } else if ch == "*" || ch == "~" {
                var close = ch == "*" ? boldClose : strikeClose
                var paired = p == close
                if paired { close = nil }
                else if close == nil { close = emphasisClose(c, p); paired = close != nil }
                if ch == "*" { boldClose = close } else { strikeClose = close }
                s.append(paired ? ch : "\\"); s.append(ch)
            } else if p == blockEscape || ch == "[" || ch == "]" {
                s.append("\\"); s.append(ch)
            } else {
                s.append(ch)
            }
            p += 1
        }
        return s
    }

    private static func blockText(_ value: JSON, people: [String: JSON], into out: inout String) {
        if value.isArray { for v in value.items { blockText(v, people: people, into: &out) }; return }
        guard value.isObject else { return }
        if let text = value["text"].nonEmpty {
            out += (value["type"].string == "plain_text" ? text : markdown(text, people: people)) + "\n"
        } else {
            blockText(value["text"], people: people, into: &out)
        }
        blockText(value["elements"], people: people, into: &out)
        blockText(value["fields"], people: people, into: &out)
    }

    /// What a message says, as Markdown: its text, else its blocks and attachments' text; then its files, described, with
    /// their Slack link (which may ask for a Slack sign-in). Their bytes are never fetched.
    static func message(_ m: JSON, people: [String: JSON]) -> String {
        var s = ""
        if let text = m["text"].nonEmpty { s = markdown(text, people: people) }
        else {
            blockText(m["blocks"], people: people, into: &s)
            for a in m["attachments"].items {
                if let fallback = a["fallback"].nonEmpty ?? a["text"].nonEmpty { s += "\n" + markdown(fallback, people: people) }
            }
            if s.isEmpty && m["blocks"].count > 0 { s = "[Slack block content]" }
        }
        for f in m["files"].items {
            let name = f["title"].nonEmpty ?? f["name"].nonEmpty ?? "File"
            let size = ByteCountFormatter.string(fromByteCount: Int64(f["size"].truncatedInt ?? 0), countStyle: .file)
            s += "\n\n📎 \(literal(name)) (\(f["mimetype"].nonEmpty ?? "unknown type"), \(size))"
            if let link = f["permalink"].string, safeLink(link) { s += " · [Open in browser](\(link))" }
            else { s += " · open Slack to get it" }
        }
        return s.isEmpty ? "[Message without text]" : s
    }
}

/// A message being written to one destination (a conversation, or a thread in it), and where its last send stands: a send
/// the server may or may not have taken is uncertain, and is not sent again until the history has been checked.
struct SlackDraft: Equatable, Sendable {
    var text = ""
    var sending = false
    var uncertain = false
    var sentText: String?

    enum Result: Equatable { case confirmed, workspaceChanged, refused, ambiguous }

    mutating func begin() -> Bool {
        guard !sending, !uncertain, SlackText.valid(text) else { return false }
        sentText = text; sending = true
        return true
    }
    /// The receipt names the channel and a ts: sent, and the draft cleared unless it was typed in since.
    mutating func finish(ok: Bool, refusal: Bool, receipt: JSON, channel: String) -> Result {
        sending = false
        if ok, receipt["channel"].string == channel, SlackTS.valid(receipt["ts"].string) {
            if text == sentText { text = "" }
            sentText = nil; uncertain = false
            return receipt["workspaceChanged"].is(true) ? .workspaceChanged : .confirmed
        }
        uncertain = !refusal || ok
        return uncertain ? .ambiguous : .refused
    }
    /// Its history has been checked: it may be sent again.
    mutating func recover() { uncertain = false; sentText = nil }
}
