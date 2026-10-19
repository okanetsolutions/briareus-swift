// Sleep mode: what both apps show once nobody has touched them for a while. Each working session gets a pane where the
// file it writes or reads is typed out as code, and the commands every session runs scroll beneath, read from the
// `events` stream's transcript lines (`transcripts=1`). With nothing working, the recent sessions' steps are replayed.
// No UI here: each app draws a `SleepWall` and feeds it what arrives.
import Foundation

// MARK: - When it sleeps

/// The minutes after which the app can sleep, as Settings offers them; 0 is never.
let sleepAfterChoices = [0, 1, 2, 5, 10, 15, 30]
let sleepAfterDefault = 5

func sleepAfterLabel(_ minutes: Int) -> String { minutes <= 0 ? "Never" : "\(minutes) min" }

/// Whether the app goes to sleep: `minutes` (0 never) have passed since the last input.
func sleepIsDue(lastInput: Date, now: Date, minutes: Int) -> Bool {
    minutes > 0 && now.timeIntervalSince(lastInput) >= Double(minutes) * 60
}

// MARK: - What a step is

/// One step of a session's work that sleep mode shows: a file it wrote or read, or a command it ran.
enum SleepStep: Equatable, Sendable {
    /// `path` is from the repository's root; `writes` for an edit or a write, false for a read.
    case file(path: String, writes: Bool)
    case command(String)
}

private let sleepWriteTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "edit", "write", "patch"]
private let sleepReadTools: Set<String> = ["Read", "read", "view"]
private let sleepCommandTools: Set<String> = ["Bash", "Shell", "bash", "shell"]

/// A `transcript` event of the `events` stream (sent with `transcripts=1`): the session and its line. Nil for any
/// other event.
func sleepTranscriptLine(_ event: String, _ data: JSON) -> (sessionId: String, line: Event)? {
    guard event == "transcript", let id = data["sessionId"].nonEmpty, let line = Event(data["event"]) else { return nil }
    return (id, line)
}

/// What a transcript line of a session on `repo` shows in sleep mode: a file tool's path (codex lists every file it
/// changed, comma separated: the first shows), a shell tool's command, or a workspace command. Nil for anything else.
func sleepStep(_ e: Event, repo: String?) -> SleepStep? {
    switch e.kind {
    case "tool":
        let name = e.name ?? "", summary = (e.summary ?? "").cTrimmed
        if sleepCommandTools.contains(name) { return summary.isEmpty ? nil : .command(firstLine(summary)) }
        let writes = sleepWriteTools.contains(name)
        guard writes || sleepReadTools.contains(name) else { return nil }
        let first = summary.split(separator: ",", maxSplits: 1).first.map { String($0) } ?? ""
        return sleepRepoPath(first, repo: repo).map { .file(path: $0, writes: writes) }
    case "cmd", "git":
        let text = firstLine(e.text)
        return text.isEmpty ? nil : .command(text)
    default:
        return nil
    }
}

/// A path a tool named, from the repository's root. An absolute one must be inside the server's clone of `repo`
/// (`<workspaces>/owner__name`, or `owner__name__2` for a second slot); a relative one is taken as it is. Nil
/// otherwise, and for a path that climbs out with "..".
func sleepRepoPath(_ path: String, repo: String?) -> String? {
    var p = path.cTrimmed
    while p.hasPrefix("./") { p.removeFirst(2) }
    let parts = p.split(separator: "/").map(String.init)
    guard !parts.isEmpty, !parts.contains("..") else { return nil }
    guard p.hasPrefix("/") else { return parts.joined(separator: "/") }
    guard let names = repo?.split(separator: "/"), names.count == 2 else { return nil }
    let base = "\(names[0])__\(names[1])"
    let slot = parts.lastIndex { $0 == base || ($0.hasPrefix(base + "__") && Int($0.dropFirst(base.count + 2)) != nil) }
    guard let slot, slot + 1 < parts.count else { return nil }
    return parts[(slot + 1)...].joined(separator: "/")
}

// MARK: - The wall

/// A file a pane reads from the server: `repo_file` at the session's branch, else at the default branch.
struct SleepFetch: Hashable, Sendable {
    var sessionId: String
    var repo: String
    var branch: String?
    var path: String
}

extension SleepFetch {
    /// `repo_file`'s arguments: at the session's branch, or the default branch when `atBranch` is false or there is no
    /// branch. The branch holds the session's work once pushed; before that the default branch has the file as it was.
    func arguments(atBranch: Bool) -> JSON {
        var args: JSON = ["repo": .string(repo), "path": .string(path)]
        if atBranch, let branch, !branch.isEmpty { args["ref"] = .string(branch) }
        return args
    }
    /// Whether reading at the branch failed for a reason the default branch might not: a branch not pushed yet, or a file
    /// new on it.
    var triesDefaultBranch: Bool { branch?.isEmpty == false }

    /// A file's text from `repo_file`'s answer, its first `SleepWall.maxLines` lines; nil for a binary, too large or
    /// unreadable one.
    static func text(_ answer: JSON) -> String? {
        guard let content = RepoFile(answer)?.content else { return nil }
        return content.split(separator: "\n", maxSplits: SleepWall.maxLines, omittingEmptySubsequences: false)
            .prefix(SleepWall.maxLines).joined(separator: "\n")
    }
}

/// One line of a pane's code as typed so far.
struct SleepLine: Equatable, Sendable, Identifiable {
    var number: Int
    var tokens: [CodeToken]
    var id: Int { number }
}

/// A command in the ticker beneath the panes.
struct SleepCommand: Equatable, Sendable, Identifiable {
    var id: Int
    var sessionId: String
    /// The repository's name without its owner.
    var project: String
    var text: String
    var replay: Bool
}

/// What a pane's code area shows.
enum SleepPaneContent: Equatable, Sendable {
    /// The session has touched no file yet.
    case waiting
    /// Its file is being read.
    case reading
    /// Nothing to show for its file: binary, too large, or not on the server.
    case empty
    case code
}

/// What the whole wall is showing, for its header.
enum SleepWallState: Equatable, Sendable {
    case working, replaying, idle

    /// The SF Symbol each app draws beside it.
    var symbol: String {
        switch self {
        case .working: return "hammer"
        case .replaying: return "clock.arrow.circlepath"
        case .idle: return "moon.zzz"
        }
    }
}

/// One session's pane: its header and the file being typed out.
struct SleepPane: Equatable, Sendable, Identifiable {
    var sessionId: String
    var title: String
    var repo: String
    var branch: String?
    var status: String
    /// The file on show; nil until the session touches one.
    var path: String?
    var writes = false
    /// The file's coloured lines once read; nil while it loads, empty when there is nothing to show (binary, too large,
    /// not on the server yet).
    var code: [[CodeToken]]?
    /// Characters typed so far, each line break counted as one.
    var typed = 0
    /// Characters in `code`, line breaks counted.
    var total = 0
    /// The command it ran last.
    var command: String?
    /// When it took its file, held at least `SleepWall.dwell` unless typed out or a write replaces a read.
    var since: Date
    /// Its last step, for the pane a new session takes over.
    var touched: Date
    /// A file that arrived while this one was held: the latest, a write winning over a read.
    var pending: (path: String, writes: Bool)?
    var replay: Bool

    var id: String { sessionId }
    var done: Bool { code != nil && typed >= total }

    var content: SleepPaneContent {
        guard path != nil else { return .waiting }
        guard let code else { return .reading }
        return code.isEmpty ? .empty : .code
    }
    /// The SF Symbol beside the file's path: a pencil for one being written, a page for one being read.
    var fileSymbol: String { writes ? "pencil" : "doc.text" }
    /// The line under the title: the repository and the branch.
    var place: String { [repo, branch].compactMap { $0 }.joined(separator: " \u{00B7} ") }

    static func == (a: SleepPane, b: SleepPane) -> Bool {
        a.sessionId == b.sessionId && a.title == b.title && a.repo == b.repo && a.branch == b.branch && a.status == b.status
            && a.path == b.path && a.writes == b.writes && a.code == b.code && a.typed == b.typed && a.total == b.total
            && a.command == b.command && a.since == b.since && a.touched == b.touched && a.pending?.path == b.pending?.path
            && a.pending?.writes == b.pending?.writes && a.replay == b.replay
    }

    /// The last `rows` lines typed so far, the one being typed cut where the typing has got to.
    func visibleLines(rows: Int) -> [SleepLine] { sleepVisibleLines(code ?? [], typed: typed, rows: rows) }
}

/// The lines of `code` typed after `typed` characters (each line break counts as one), the last `rows` of them.
func sleepVisibleLines(_ code: [[CodeToken]], typed: Int, rows: Int) -> [SleepLine] {
    var out: [SleepLine] = []
    var left = typed
    for (i, line) in code.enumerated() {
        if i > 0 {
            guard left > 0 else { break }
            left -= 1
        }
        var tokens: [CodeToken] = []
        for token in line {
            guard left > 0 else { break }
            let n = token.text.count
            if n <= left { tokens.append(token); left -= n } else {
                tokens.append(CodeToken(text: String(token.text.prefix(left)), kind: token.kind)); left = 0
            }
        }
        out.append(SleepLine(number: i + 1, tokens: tokens))
    }
    return Array(out.suffix(max(rows, 0)))
}

/// Everything sleep mode shows: a pane per session working (at most `capacity`, the longest quiet one giving way to a
/// new session), and the commands they ran. Steps from a replay give way to the first live one.
struct SleepWall: Equatable, Sendable {
    /// Seconds a pane holds a file before the next one takes over, unless it is typed out first.
    static let dwell: TimeInterval = 6
    /// Lines of a file a pane types out.
    static let maxLines = 160
    static let tickerLength = 30
    /// A working session's last steps shown when it first appears, so its pane has something before its next one.
    static let seedSteps = 8
    /// Steps of each recent session a replay goes through.
    static let replaySteps = 40
    /// Seconds between replayed steps, and before a replay with nothing to show is read again.
    static let replayInterval: TimeInterval = 2.4
    static let replayRetry: TimeInterval = 30

    let capacity: Int
    private(set) var panes: [SleepPane] = []
    private(set) var ticker: [SleepCommand] = []
    private(set) var sessions: [String: Session] = [:]
    /// When the last live step landed; nil before any.
    private(set) var lastLive: Date?
    private var serial = 0

    init(capacity: Int) { self.capacity = max(capacity, 1) }

    /// The panes a screen with room for `limit` shows: the most recently active, kept in their places so none jumps.
    func shown(_ limit: Int) -> [SleepPane] {
        let newest = panes.indices.sorted { panes[$0].touched > panes[$1].touched }.prefix(max(limit, 0))
        return newest.sorted().map { panes[$0] }
    }

    /// Showing only replayed steps.
    var replaying: Bool { !panes.isEmpty && panes.allSatisfy(\.replay) }
    var working: Bool { sessions.values.contains { $0.isActive } }
    var state: SleepWallState { replaying ? .replaying : working ? .working : .idle }

    /// No session works and none has shown a live step for a minute: time to replay recent work (its panes taking over
    /// from the live ones that went quiet).
    func wantsReplay(now: Date) -> Bool {
        !working && (lastLive.map { now.timeIntervalSince($0) > 60 } ?? true)
    }

    /// A session's record as it changed: its pane's header follows, and a session that starts working gets a pane
    /// before its first step.
    mutating func update(_ s: Session, now: Date) {
        guard let repo = s.repo, !repo.isEmpty else { return }
        sessions[s.id] = s
        if let i = panes.firstIndex(where: { $0.sessionId == s.id }) {
            panes[i].title = s.displayTitle; panes[i].branch = s.raw["branch"].nonEmpty; panes[i].status = s.status
        } else if s.isActive {
            if panes.contains(where: \.replay) { dropReplay() }
            _ = pane(for: s.id, now: now, replay: false)
        }
    }

    mutating func remove(_ id: String) {
        sessions[id] = nil
        panes.removeAll { $0.sessionId == id }
    }

    /// A session's step, live or replayed. Returns the file to read when a pane takes a new one.
    mutating func apply(_ step: SleepStep, session id: String, now: Date, replay: Bool = false) -> SleepFetch? {
        if replay && panes.contains(where: { !$0.replay }) {
            // Live work holds the wall until it has been quiet long enough for a replay.
            guard wantsReplay(now: now) else { return nil }
            panes.removeAll { !$0.replay }
        }
        if !replay {
            lastLive = now
            if panes.contains(where: \.replay) { dropReplay() }
        }
        guard let i = pane(for: id, now: now, replay: replay) else { return nil }
        panes[i].touched = now
        switch step {
        case .command(let text):
            panes[i].command = text
            serial += 1
            let project = panes[i].repo.split(separator: "/").last.map(String.init) ?? panes[i].repo
            ticker.append(SleepCommand(id: serial, sessionId: id, project: project, text: text, replay: replay))
            if ticker.count > Self.tickerLength { ticker.removeFirst(ticker.count - Self.tickerLength) }
            return nil
        case .file(let path, let writes):
            if panes[i].path == path {
                panes[i].writes = panes[i].writes || writes
                return nil
            }
            if canSwitch(panes[i], writes: writes, now: now) { return take(i, path: path, writes: writes, now: now) }
            if !(panes[i].pending?.writes == true && !writes) { panes[i].pending = (path, writes) }
            return nil
        }
    }

    /// A file read for a pane: its first `maxLines` lines, or nothing to show when nil. A pane on another file by now
    /// ignores it.
    mutating func loaded(_ fetch: SleepFetch, code: [[CodeToken]]?) {
        guard let i = panes.firstIndex(where: { $0.sessionId == fetch.sessionId && $0.path == fetch.path }) else { return }
        let lines = Array((code ?? []).prefix(Self.maxLines))
        panes[i].code = lines
        panes[i].total = max(lines.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.count } } + lines.count - 1, 0)
        panes[i].typed = 0
    }

    /// Time passing: each pane types `chars` more characters, and one whose file is held long enough takes the file
    /// that waited. Returns the files to read.
    mutating func tick(chars: Int, now: Date) -> [SleepFetch] {
        var fetches: [SleepFetch] = []
        for i in panes.indices {
            if panes[i].code != nil { panes[i].typed = min(panes[i].typed + chars, panes[i].total) }
            if let next = panes[i].pending, canSwitch(panes[i], writes: next.writes, now: now),
               let fetch = take(i, path: next.path, writes: next.writes, now: now) {
                fetches.append(fetch)
            }
        }
        return fetches
    }

    // MARK: Private

    private func canSwitch(_ p: SleepPane, writes: Bool, now: Date) -> Bool {
        p.path == nil || p.done || now.timeIntervalSince(p.since) >= Self.dwell || (writes && !p.writes)
    }

    private mutating func take(_ i: Int, path: String, writes: Bool, now: Date) -> SleepFetch? {
        panes[i].path = path; panes[i].writes = writes; panes[i].code = nil
        panes[i].typed = 0; panes[i].total = 0; panes[i].since = now; panes[i].pending = nil
        return SleepFetch(sessionId: panes[i].sessionId, repo: panes[i].repo, branch: panes[i].branch, path: path)
    }

    /// The pane of session `id`: its own, a new one while there is room, else the quietest one's place (a replayed
    /// one first). Nil for a session with no known repository.
    private mutating func pane(for id: String, now: Date, replay: Bool) -> Int? {
        if let i = panes.firstIndex(where: { $0.sessionId == id }) { return i }
        guard let s = sessions[id], let repo = s.repo, !repo.isEmpty else { return nil }
        let fresh = SleepPane(sessionId: id, title: s.displayTitle, repo: repo, branch: s.raw["branch"].nonEmpty,
                              status: s.status, since: now, touched: now, replay: replay)
        if panes.count < capacity { panes.append(fresh); return panes.count - 1 }
        let quietest = panes.indices.min { (panes[$0].replay ? 0 : 1, panes[$0].touched) < (panes[$1].replay ? 0 : 1, panes[$1].touched) }!
        panes[quietest] = fresh
        return quietest
    }

    private mutating func dropReplay() {
        panes.removeAll(where: \.replay)
        ticker.removeAll(where: \.replay)
    }
}

// MARK: - Replay

/// The sessions replayed when none is working: the `limit` most recently changed with a repository, newest first.
func sleepReplaySessions(_ sessions: [Session], limit: Int) -> [Session] {
    func when(_ s: Session) -> Int {
        boardDateEpoch(s.raw["updatedAt"].string) ?? boardDateEpoch(s.raw["endedAt"].string) ?? boardDateEpoch(s.raw["createdAt"].string) ?? 0
    }
    let listed = sessions.filter { $0.repo?.isEmpty == false }.map { (s: $0, at: when($0)) }
    return Array(listed.sorted { $0.at > $1.at }.prefix(max(limit, 0)).map(\.s))
}

/// A transcript's last `limit` steps sleep mode shows, oldest first.
func sleepSteps(_ events: JSON, repo: String?, limit: Int) -> [SleepStep] {
    let steps = events.items.compactMap(Event.init).sorted { $0.seq < $1.seq }.compactMap { sleepStep($0, repo: repo) }
    return Array(steps.suffix(max(limit, 0)))
}

/// Replayed steps, one session after another in turn, starting over once every session's run out.
struct SleepReplay: Equatable, Sendable {
    private(set) var queues: [(sessionId: String, steps: [SleepStep])]
    private var turn = 0
    private var position: [Int]

    init(_ queues: [(sessionId: String, steps: [SleepStep])]) {
        self.queues = queues.filter { !$0.steps.isEmpty }
        position = Array(repeating: 0, count: self.queues.count)
    }

    static func == (a: SleepReplay, b: SleepReplay) -> Bool {
        a.turn == b.turn && a.position == b.position && a.queues.map(\.sessionId) == b.queues.map(\.sessionId)
            && a.queues.map(\.steps) == b.queues.map(\.steps)
    }

    var isEmpty: Bool { queues.isEmpty }

    /// The next step to replay and its session; nil when there is nothing to replay.
    mutating func next() -> (sessionId: String, step: SleepStep)? {
        guard !queues.isEmpty else { return nil }
        if zip(position, queues).allSatisfy({ $0 >= $1.steps.count }) { position = position.map { _ in 0 } }
        for _ in queues.indices {
            let q = turn % queues.count
            turn += 1
            if position[q] < queues[q].steps.count {
                position[q] += 1
                return (queues[q].sessionId, queues[q].steps[position[q] - 1])
            }
        }
        return nil
    }
}
