// What the client API answers with, read into the shapes the screens use. Unknown fields ride along in `raw`.
import Foundation

// MARK: - Shared helpers

extension JSON {
    /// A number that is a whole number within C `int` range, as the Windows client's `json_int_or` reads one; nil otherwise.
    var int32: Int? {
        guard let n = number, n.isFinite, n == n.rounded(.down), n >= -2147483648.0, n <= 2147483647.0 else { return nil }
        return Int(n)
    }
    /// A number cut toward zero, as C's `(int)` cast reads one (7.9 is 7); nil for anything that is not a finite number.
    var truncatedInt: Int? {
        guard let n = number, n.isFinite else { return nil }
        return Int(max(-2147483648.0, min(2147483647.0, n.rounded(.towardZero))))
    }
    /// A string, or null when `value` is nil.
    static func string(orNull value: String?) -> JSON { value.map(JSON.string) ?? .null }
}

extension String {
    /// ASCII lower case only, as the C client's `str_fold`: logins and label names compare this way.
    var asciiFolded: String {
        String(String.UnicodeScalarView(unicodeScalars.map { s in
            (65...90).contains(s.value) ? Unicode.Scalar(s.value + 32)! : s
        }))
    }
    /// The first character upper-cased when it is ASCII, as `str_capitalized`.
    var asciiCapitalized: String {
        guard let first = unicodeScalars.first, (97...122).contains(first.value) else { return self }
        return String(Unicode.Scalar(first.value - 32)!) + String(unicodeScalars.dropFirst())
    }
    /// Without leading and trailing spaces, tabs, line breaks, form feeds and vertical tabs, as `str_trim`.
    var cTrimmed: String {
        let space: Set<UInt32> = [0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x0B]
        var scalars = Substring(self).unicodeScalars[...]
        while let f = scalars.first, space.contains(f.value) { scalars = scalars.dropFirst() }
        while let l = scalars.last, space.contains(l.value) { scalars = scalars.dropLast() }
        return String(String.UnicodeScalarView(scalars))
    }
    /// Byte order, as C's `strcmp`.
    func bytesPrecede(_ other: String) -> Bool { utf8.lexicographicallyPrecedes(other.utf8) }
}

/// Logins and label names are compared folded: GitHub hands the same person back in either case. Nil reads as "".
func foldEqual(_ a: String?, _ b: String?) -> Bool { (a ?? "").asciiFolded.utf8.elementsEqual((b ?? "").asciiFolded.utf8) }

/// The array a list answer holds under `key`, or the answer itself when it is the array.
func listOf(_ answer: JSON, _ key: String) -> JSON { answer.isArray ? answer : answer[key] }

// MARK: - Projects

struct Project: Equatable, Sendable {
    var repo: String
    var label: String?
    /// Settings name a local checkout of it, which a session can work in instead of a fresh worktree.
    var hasLocal = false

    init(repo: String, label: String? = nil, hasLocal: Bool = false) { self.repo = repo; self.label = label; self.hasLocal = hasLocal }
    init?(_ j: JSON) {
        guard let repo = j["repo"].string else { return nil }
        self.repo = repo; label = j["label"].string
        hasLocal = j["hasLocal"].is(true)
    }
    var json: JSON {
        var out: JSON = ["repo": .string(repo), "label": .string(orNull: label)]
        if hasLocal { out["hasLocal"] = true }
        return out
    }
    /// The label when it has one, else the repository name.
    var title: String { (label ?? "").isEmpty ? repo : label! }

    /// The `projects` answer (the object or its bare array); nil when it holds no list.
    static func parseList(_ value: JSON) -> [Project]? {
        let list = value.isArray ? value : value["projects"]
        guard let items = list.array else { return nil }
        return items.compactMap(Project.init)
    }
    static func json(_ projects: [Project]) -> JSON { .array(projects.map(\.json)) }
}

// MARK: - Sessions

/// A conversation as the server sent it. The object is kept whole, so saved lists round-trip.
struct Session: Equatable, Sendable {
    var raw: JSON

    /// Needs a string id and status.
    init?(_ j: JSON) {
        guard j["id"].string != nil, j["status"].string != nil else { return nil }
        raw = j
    }
    /// Wraps any object unchecked, as the ▶ Run helpers read rows of a `sessions` answer.
    init(raw: JSON) { self.raw = raw }

    var id: String { raw["id"].string ?? "" }
    var repo: String? { raw["repo"].string }
    var status: String { raw["status"].string ?? "" }
    var model: String? { raw["model"].nonEmpty }
    var provider: String? { raw["provider"].nonEmpty }
    var displayTitle: String { raw["title"].nonEmpty ?? "New conversation" }
    var isActive: Bool { ["queued", "preparing", "running", "starting"].contains(status) }
    /// Closed: it takes no messages until it is reopened, and its rows are drawn dimmed.
    var isClosed: Bool { status == "closed" }
    var pinnedAt: String? { raw["pinnedAt"].nonEmpty }
    var isPinned: Bool { pinnedAt != nil }
    var pinLabel: String { isPinned ? "Unpin session" : "Pin session" }
    var pinSymbol: String { isPinned ? "pin.slash" : "pin" }
    var pinBody: JSON { ["pinned": .bool(!isPinned)] }
    var liveInput: Bool { raw["liveInput"].is(true) }
    /// Background work the running turn still waits on: sub-agents, Monitors and background shell commands.
    var backgroundTasks: [BackgroundTask] { raw["backgroundTasks"].items.compactMap(BackgroundTask.init) }
    var queued: JSON { raw["queued"] }
    /// The pull request this conversation works on, once it has one; nil without (the C client's 0).
    var pullNumber: Int? {
        let n = raw["prStatus"]["number"].number ?? raw["startedOnPr"].number
        guard let n, n >= 1, n.isFinite else { return nil }
        return Int(min(n, 2147483647))
    }
    /// Whether it was started on issue `number`: such a session is named by its prompt's first line, `Issue #N: title`.
    func onIssue(_ number: Int) -> Bool {
        guard let t = raw["title"].string, number >= 1 else { return false }
        return t.utf8.starts(with: "Issue #\(number):".utf8)
    }

    /// The `sessions` answer (the object or its bare array); nil when it holds no list.
    static func parseList(_ value: JSON) -> [Session]? {
        let list = value.isArray ? value : value["sessions"]
        guard let items = list.array else { return nil }
        return items.compactMap(Session.init)
    }
    static func json(_ sessions: [Session]) -> JSON { .array(sessions.map(\.raw)) }
}

// MARK: - Transcript

struct Event: Equatable, Sendable {
    var raw: JSON
    var seq: Int
    var kind: String
    var t: String?
    var text: String?
    var name: String?
    var summary: String?
    var question: String?
    /// The arrays as sent; nil when the field is not an array.
    var options: JSON?
    var attachments: JSON?
    var costUsd: Double?
    var durationMs: Double?
    /// Nil when unset (the C client's -1).
    var isError: Bool?

    /// Needs a string kind and a numeric sequence.
    init?(_ j: JSON) {
        guard let kind = j["kind"].string, let seq = j["seq"].truncatedInt else { return nil }
        raw = j; self.seq = seq; self.kind = kind
        t = j["t"].string; text = j["text"].string; name = j["name"].string
        summary = j["summary"].string; question = j["question"].string
        options = j["options"].isArray ? .some(j["options"]) : .none
        attachments = j["attachments"].isArray ? .some(j["attachments"]) : .none
        costUsd = j["costUsd"].number; durationMs = j["durationMs"].number
        isError = j["isError"].bool
    }
    /// Tool events carry their detail in `summary`; other kinds use `text`.
    var detail: String? { text ?? summary }
    /// Status and workspace setup output are server plumbing, not part of the conversation.
    var isVisible: Bool {
        if kind == "status" { return false }
        return text != nil || question != nil || kind == "tool" || kind == "tool_error" || kind == "result"
    }
    /// When the server logged it; nil without a readable time.
    var time: Date? { boardDateParse(t) }
}

/// Cursor and transcript have one lifetime: saved events restore both, and an empty transcript starts at zero.
struct Transcript: Equatable, Sendable {
    private(set) var events: [Event] = []
    private(set) var cursor = 0
    private var seen: Set<Int> = []

    static func == (a: Transcript, b: Transcript) -> Bool { a.events == b.events && a.cursor == b.cursor }

    init() {}
    /// Appends every event of a JSON array not already held (the first copy of a sequence wins), sorted by sequence,
    /// and advances the cursor. Returns the new suffix, or the whole range after reordering; nil when nothing was added.
    @discardableResult
    mutating func append(_ value: JSON) -> Range<Int>? {
        let before = events.count
        var needsSort = false
        for item in value.items {
            guard let e = Event(item), seen.insert(e.seq).inserted else { continue }
            if let last = events.last, e.seq < last.seq { needsSort = true }
            events.append(e)
        }
        guard events.count != before else { return nil }
        if needsSort { events.sort { $0.seq < $1.seq } }
        let last = events.last?.seq ?? 0
        if last > cursor { cursor = last }
        return (needsSort ? 0 : before)..<events.count
    }
    var json: JSON { .array(events.map(\.raw)) }
}

// MARK: - Dates

/// GitHub's timestamps come with and without fractional seconds; seconds since 1970, UTC. Nil when unreadable.
func boardDateEpoch(_ value: String?) -> Int? {
    guard let value else { return nil }
    let p = Array(value.utf8)
    var i = 0
    func at(_ k: Int) -> UInt8 { k < p.count ? p[k] : 0 }
    func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    func digits(_ count: Int) -> Int? {
        var v = 0
        for k in 0..<count {
            let c = at(i + k)
            guard isDigit(c) else { return nil }
            v = v * 10 + Int(c - 48)
        }
        i += count
        return v
    }
    func take(_ c: Character) -> Bool { let ok = at(i) == c.asciiValue!; i += 1; return ok }

    guard let y = digits(4), take("-"), let mo = digits(2), take("-"), let d = digits(2) else { return nil }
    guard at(i) == UInt8(ascii: "T") || at(i) == UInt8(ascii: "t") || at(i) == UInt8(ascii: " ") else { return nil }
    i += 1
    guard let h = digits(2), take(":"), let mi = digits(2) else { return nil }
    var s = 0
    if at(i) == UInt8(ascii: ":") { i += 1; guard let v = digits(2) else { return nil }; s = v }
    if at(i) == UInt8(ascii: ".") || at(i) == UInt8(ascii: ",") {
        i += 1
        guard isDigit(at(i)) else { return nil }
        while isDigit(at(i)) { i += 1 }
    }
    var offset = 0
    if at(i) == UInt8(ascii: "Z") || at(i) == UInt8(ascii: "z") { i += 1 }
    else if at(i) == UInt8(ascii: "+") || at(i) == UInt8(ascii: "-") {
        let sign = at(i) == UInt8(ascii: "-") ? -1 : 1
        i += 1
        guard let oh = digits(2) else { return nil }
        var om = 0
        if at(i) == UInt8(ascii: ":") { i += 1 }
        if isDigit(at(i)) { guard let v = digits(2) else { return nil }; om = v }
        offset = sign * (oh * 3600 + om * 60)
    } else { return nil }
    guard i == p.count else { return nil }
    guard (1...12).contains(mo), (1...31).contains(d), h <= 23, mi <= 59, s <= 60 else { return nil }
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset
}
/// GitHub's timestamps come with and without fractional seconds. UTC; the fraction is dropped. Nil when unreadable.
func boardDateParse(_ value: String?) -> Date? { boardDateEpoch(value).map { Date(timeIntervalSince1970: TimeInterval($0)) } }

private func daysFromCivil(_ year: Int, _ m: Int, _ d: Int) -> Int {
    let y = year - (m <= 2 ? 1 : 0)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

// MARK: - New sessions

/// Where a new session works (the Windows client's workspace chip): a fresh worktree with its own database, the project's
/// own local checkout, or an orchestrator that plans and coordinates worker sessions and takes no branch.
enum WorkspaceMode: Equatable, Sendable, CaseIterable {
    case worktree, local, orchestrator

    var chip: String {
        switch self {
        case .worktree: return "\u{2317} Worktree"
        case .local: return "\u{2302} Local"
        case .orchestrator: return "\u{1F9ED} Orchestrator"
        }
    }
    /// The workspace menu's line; Local says why it cannot be picked when the project has no local checkout.
    func menuTitle(hasLocal: Bool) -> String {
        switch self {
        case .worktree: return "\u{2317} Worktree: a fresh clone and database"
        case .local: return hasLocal ? "\u{2302} Local: the project's own checkout" : "\u{2302} Local: no local checkout set in Settings"
        case .orchestrator: return "\u{1F9ED} Orchestrator: plan and coordinate workers"
        }
    }
    /// The welcome line around the project's name.
    var welcome: (before: String, after: String) {
        switch self {
        case .worktree: return ("Start a session in a fresh ", " checkout with its own database.")
        case .local: return ("Start a session in ", "'s own local checkout and database.")
        case .orchestrator: return ("Start an orchestrator for ", " to plan and coordinate worker sessions.")
        }
    }
    /// The branch chip with none picked: something else in each mode.
    func noBranchLabel(defaultBranch: String?) -> String { self == .local ? "Current branch" : "New branch off \(defaultBranch ?? "main")" }
    /// `start_session`'s workspace arguments: an orchestrator takes no branch.
    func arguments(branch: String?) -> JSON {
        var out: JSON = [:]
        if self == .orchestrator { out["orchestrator"] = true; return out }
        if let branch { out["branch"] = .string(branch) }
        if self == .local { out["local"] = true }
        return out
    }
}
