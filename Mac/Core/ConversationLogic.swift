// What a conversation shows, worded as the Windows client's screen_conversation.c, screen_panel.c and attach_list.c word
// it: the header's status line, a turn's footer, the transcript folded into preparation and tool blocks, the composer's
// chips, an attachment's chip, and the panel's section labels. No UI here.
import Foundation

// MARK: - Header

/// `#chat-sub`: provider · model · effort · state · 🔁 loop round · branch · tokens · cost · session id · the pull request.
func conversationStatusLine(_ s: Session) -> String {
    var sub = ""
    for part in [s.provider, s.model, s.raw["effort"].nonEmpty] { if let part { sub += (sub.isEmpty ? "" : " \u{00B7} ") + part } }
    let state = s.status == "idle" && s.raw["awaitingAnswer"].is(true) ? "waiting" : s.status
    sub += (sub.isEmpty ? "" : " \u{00B7} ") + state
    let loop = s.raw["reviewLoop"]
    if loop.isObject {
        if let round = loop["rounds"].truncatedInt { sub += " \u{00B7} \u{1F501} loop round \(round)" } else { sub += " \u{00B7} \u{1F501} loop" }
    }
    if let branch = s.raw["branch"].nonEmpty { sub += " \u{00B7} \(branch)" }
    let browser = BrowserState.sessionOn(s.raw)
    if browser.on { sub += browser.running ? " \u{00B7} \u{1F310} browser" : " \u{00B7} \u{1F310} browser starts next turn" }
    let input = s.raw["inputTokens"].number, output = s.raw["outputTokens"].number
    if input != nil || output != nil { sub += " \u{00B7} \(formatTokens((input ?? 0) + (output ?? 0))) tok" }
    if let cost = s.raw["costUsd"].number { sub += " \u{00B7} \(formatCost(cost))" }
    sub += " \u{00B7} session \(s.id)"
    let pr = s.raw["prStatus"]
    if pr.isObject, let number = pr["number"].truncatedInt {
        let state = pr["state"].string
        let draft = pr["draft"].is(true)
        let light = state == "merged" ? "\u{1F7E3}" : state == "closed" ? "\u{1F534}" : draft ? "\u{26AA}" : "\u{1F7E2}"
        sub += " \u{00B7} \(light) PR #\(number) \(draft && state == "open" ? "draft" : state ?? "")"
        let checks = pr["checks"]
        let failed = checks["failed"].int32 ?? 0, pending = checks["pending"].int32 ?? 0, passed = checks["passed"].int32 ?? 0
        if failed != 0 { sub += " \u{00B7} \u{2717}\(failed)" }
        else if pending != 0 { sub += " \u{00B7} \u{2026}\(pending)" }
        else if passed != 0 { sub += " \u{00B7} \u{2713}\(passed)" }
    }
    return sub
}

// MARK: - Transcript

/// "— $2.9565 · 455s · 57 turns · 5.6M in / 36.4k out · 151.6k context", or "— turn done".
func turnFooterText(_ e: Event) -> String {
    var bits = ""
    func add(_ s: String) { bits += (bits.isEmpty ? "" : " \u{00B7} ") + s }
    if let cost = e.costUsd { add(String(format: "$%.4f", cost)) }
    if let ms = e.durationMs { add("\(Int((ms / 1000).rounded(.towardZero)))s") }
    if let turns = e.raw["numTurns"].truncatedInt { add("\(turns) turns") }
    let input = e.raw["inputTokens"].number, output = e.raw["outputTokens"].number
    if input != nil || output != nil { add("\(formatTokens(input ?? 0)) in / \(formatTokens(output ?? 0)) out") }
    if let tokens = e.raw["tokens"].number { add("\(formatTokens(tokens)) context") }
    return "\u{2014} " + (bits.isEmpty ? "turn done" : bits)
}

/// A tool step's name: its own, else what kind of step it was.
func toolTitle(_ e: Event) -> String {
    if let name = e.name, !name.isEmpty { return name }
    switch e.kind {
    case "cmd": return "Command"
    case "git": return "Git"
    case "tool_error": return "Tool error"
    default: return "Tool"
    }
}
/// The first line of a text, trimmed.
func firstLine(_ text: String?) -> String {
    let trimmed = (text ?? "").cTrimmed
    let first = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    return first.cTrimmed
}
func isToolEvent(_ e: Event) -> Bool { e.kind == "tool" || e.kind == "tool_error" }
/// Workspace preparation output (`setup` is a setup command's own output; a failed step's last lines are there).
func isPrepLine(_ e: Event) -> Bool { ["info", "cmd", "git", "setup", "stdout"].contains(e.kind) && e.text != nil }
/// Info lines that belong to the conversation rather than to workspace preparation.
func prepClosed(_ e: Event) -> Bool {
    let t = e.text ?? ""
    if t.hasPrefix("Starting ") || t.hasPrefix("Started worker ") || t.hasPrefix("Worker ") { return true }
    return t.range(of: "session started", options: .caseInsensitive) != nil
}
/// A log line as the transcript shows it: a command with `$ ` before it.
func logLineText(_ e: Event) -> String { e.kind == "cmd" ? "$ \(e.text ?? "")" : (e.text ?? "") }

/// What the transcript lays out: workspace preparation folded into one block per turn, each run of tool calls into another,
/// and the visible events between them.
enum TranscriptBlock: Equatable, Sendable {
    case preparation([Event])
    case tools([Event])
    case event(Event)

    /// The sequence that names the block, which its open-or-closed state is kept by.
    var seq: Int {
        switch self {
        case .preparation(let e), .tools(let e): return e.first?.seq ?? 0
        case .event(let e): return e.seq
        }
    }
    /// "Preparing workspace… (3 steps)" or "2 steps · Bash".
    var summary: String? {
        switch self {
        case .preparation(let e): return "Preparing workspace\u{2026} (\(e.count) step\(e.count == 1 ? "" : "s"))"
        case .tools(let e): return "\(e.count) step\(e.count == 1 ? "" : "s") \u{00B7} \(e.last.map(toolTitle) ?? "Tool")"
        case .event: return nil
        }
    }
}

/// A row snapshot shares completed history and keeps its own tail, the only block a later append can change.
/// The builder and its snapshots stay with their owner; they are not sent between actors.
struct TranscriptRows: RandomAccessCollection, Equatable {
    fileprivate final class Storage { var blocks: [TranscriptBlock] = [] }
    fileprivate let storage: Storage
    fileprivate let tail: TranscriptBlock?
    fileprivate let revision: Int
    let endIndex: Int
    var startIndex: Int { 0 }

    fileprivate init(storage: Storage, revision: Int) {
        self.storage = storage; self.revision = revision
        endIndex = storage.blocks.count; tail = storage.blocks.last
    }
    func index(after i: Int) -> Int { i + 1 }
    func index(before i: Int) -> Int { i - 1 }
    subscript(position: Int) -> TranscriptBlock {
        precondition(position >= startIndex && position < endIndex)
        if position == endIndex - 1, let tail { return tail }
        return storage.blocks[position]
    }
    static func == (a: Self, b: Self) -> Bool {
        if a.storage === b.storage { return a.revision == b.revision }
        return a.elementsEqual(b)
    }
}

/// Folds rows only for conversation screens. Snapshots never retain the mutable history array's buffer.
final class TranscriptBlockBuilder {
    private var storage = TranscriptRows.Storage()
    private var revision = 0
    var blocks: TranscriptRows { TranscriptRows(storage: storage, revision: revision) }
    private var prepDone = false
    private enum Run: Equatable { case preparation, tools }
    private var run: Run?

    /// A poll can fill a gap behind the live cursor; its insertion may change existing folded runs.
    @discardableResult
    func update(_ events: [Event], changed: Range<Int>?) -> Bool {
        guard let changed else { return false }
        if changed.lowerBound == 0 {
            storage = TranscriptRows.Storage(); revision = 0; prepDone = false; run = nil
        }
        return append(events[changed])
    }

    /// Appends an ordered suffix; even an invisible event ends a contiguous preparation or tool run.
    @discardableResult
    func append(_ events: ArraySlice<Event>) -> Bool {
        var changed = false
        var i = events.startIndex
        while i < events.endIndex {
            let e = events[i]
            if e.kind == "user" || e.kind == "result" { prepDone = false }
            if !prepDone && isPrepLine(e) && !prepClosed(e) {
                var j = i + 1
                while j < events.endIndex && isPrepLine(events[j]) && !prepClosed(events[j]) { j += 1 }
                var group = Array(events[i..<j])
                if run == .preparation, case .preparation(let previous)? = storage.blocks.last {
                    group = previous + group
                    storage.blocks.removeLast()
                }
                storage.blocks.append(.preparation(group))
                run = .preparation
                changed = true; i = j
                continue
            }
            if isPrepLine(e) && prepClosed(e) { prepDone = true }
            if isToolEvent(e) {
                var j = i + 1
                while j < events.endIndex && isToolEvent(events[j]) { j += 1 }
                var group = Array(events[i..<j])
                if run == .tools, case .tools(let previous)? = storage.blocks.last {
                    group = previous + group
                    storage.blocks.removeLast()
                }
                storage.blocks.append(.tools(group))
                run = .tools
                changed = true; i = j
                continue
            }
            run = nil
            if e.isVisible { storage.blocks.append(.event(e)); changed = true }
            i += 1
        }
        if changed { revision += 1 }
        return changed
    }
}

func transcriptBlocks(_ events: [Event]) -> [TranscriptBlock] {
    let builder = TranscriptBlockBuilder()
    builder.append(events[...])
    return Array(builder.blocks)
}

/// Whether a transcript holds only events without a time: saved before messages showed theirs, it is read again once.
func transcriptNeedsRetime(_ events: [Event]) -> Bool { !events.isEmpty && events.allSatisfy { $0.t == nil } }

/// A voice note's text appended to what the composer holds, a space between unless it already ends in one.
func appendDictation(_ current: String, _ text: String) -> String {
    guard !text.isEmpty else { return current }
    let gap = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") || current.hasSuffix("\t") ? "" : " "
    return current + gap + text
}

// MARK: - Review findings held in the conversation

/// The round's title: "Round 2 findings · PR #70", or "Review findings".
func triageTitle(_ triage: JSON) -> String {
    if triage["externalFeedback"].is(true) { return "Feedback assessment · PR #\(heldRoundPRNumber(triage) ?? 0)" }
    var title = triage["round"].truncatedInt.map { "Round \($0) findings" } ?? "Review findings"
    if let pr = triage["prNumber"].truncatedInt { title += " \u{00B7} PR #\(pr)" }
    return title
}
/// A stale feedback assessment must be rerun; ordinary loop rounds can review the moved branch.
enum TriageStaleResolution: Equatable, Sendable { case reviewMovedHead, discardAssessment }
func triageStaleResolution(_ triage: JSON) -> TriageStaleResolution {
    triage["externalFeedback"].is(true) ? .discardAssessment : .reviewMovedHead
}
func triageStaleMessage(_ triage: JSON) -> String {
    triageStaleResolution(triage) == .discardAssessment
        ? "The pull request or source feedback changed. Run Implement feedback again before selecting fixes; completing with nothing to fix discards this assessment."
        : "The branch moved after this round was reviewed: some findings may already be fixed. Sending with nothing to fix reviews the new commits instead of closing the loop."
}
/// A round takes verdicts unless the server says it is not this user's (`mine: false`).
func triageTakesVerdicts(_ triage: JSON) -> Bool { triage["externalFeedback"].is(true) || triage["mine"].bool != false }
/// "file.ts:12", or nil without a file.
func findingLocation(_ finding: JSON) -> String? {
    guard let file = finding["file"].string else { return nil }
    if let line = finding["line"].truncatedInt { return "\(file):\(line)" }
    return file
}
/// The Complete button's title.
func triageCompleteTitle(takesVerdicts: Bool, fixes: Int, externalFeedback: Bool = false) -> String {
    guard takesVerdicts else { return "Complete" }
    if externalFeedback && fixes == 0 { return "Complete assessment · nothing to fix" }
    return fixes > 0 ? "Complete \u{00B7} send \(fixes) to be fixed" : "Complete \u{00B7} nothing to fix, approve and close"
}
/// The confirmation before completing.
func triageConfirmTitle(takesVerdicts: Bool, fixes: Int) -> String {
    if !takesVerdicts { return "Take this review off the queue?" }
    if fixes == 0 { return "Complete with nothing to fix?" }
    return "Start a paid fix session for \(fixes) finding\(fixes == 1 ? "" : "s")?"
}
/// A finding's verdict: the one picked here, else the round's saved draft, else "".
func triageDecision(_ triage: JSON, _ finding: JSON, picked: [String: String]) -> String {
    guard let key = finding["key"].string else { return "" }
    if let d = picked[key] { return d }
    return triage["drafts"]["verdicts"][key]["decision"].string ?? ""
}
/// What `complete_findings` is sent: every keyed finding's verdict (optional when none was picked) with its draft reason,
/// and the trimmed note.
func triageCompletion(_ triage: JSON, picked: [String: String], note: String) -> JSON {
    var extra: JSON = [:]
    guard triageTakesVerdicts(triage) else { return extra }
    var verdicts: [JSON] = []
    for f in triage["findings"].items {
        guard let key = f["key"].string else { continue }
        let chosen = triageDecision(triage, f, picked: picked)
        var v: JSON = ["key": .string(key), "decision": .string(chosen.isEmpty ? "optional" : chosen)]
        if let reason = triage["drafts"]["verdicts"][key]["reason"].nonEmpty { v["reason"] = .string(reason) }
        verdicts.append(v)
    }
    if !verdicts.isEmpty { extra["verdicts"] = .array(verdicts) }
    let trimmed = note.cTrimmed
    if !trimmed.isEmpty { extra["note"] = .string(trimmed) }
    return extra
}

// MARK: - Composer

/// The composer's chips, in their order.
enum ComposerChip: CaseIterable { case workspace, project, branch, provider, model, effort, loop }

/// A conversation's chip text; empty hides it (the loop chip is shown by the caller's rule).
func conversationChipText(_ s: Session, _ chip: ComposerChip) -> String {
    switch chip {
    case .workspace:
        return s.raw["local"].is(true) ? "\u{2302} Local" : s.raw["orchestrator"].is(true) ? "\u{1F9ED} Orchestrator" : "\u{2317} Worktree"
    case .project:
        guard let repo = s.repo else { return "" }
        return repo.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? repo
    case .branch: return s.raw["branch"].nonEmpty ?? ""
    case .provider: return s.provider ?? ""
    case .model: return s.model ?? ""
    case .effort: return s.raw["effort"].nonEmpty ?? ""
    case .loop: return reviewLoopChipText(s.reviewLoopOn)
    }
}
func reviewLoopChipText(_ on: Bool) -> String { on ? "\u{1F501} Review loop: on" : "\u{1F501} Review loop" }

/// One piece of background work a running turn waits on, from a session record's `backgroundTasks`.
struct BackgroundTask: Equatable, Sendable {
    /// What it is: `Bash`, `Monitor`, or a sub-agent's type (`general-purpose`, `Explore`, …, `agent` when unnamed).
    var name: String
    /// What it runs, when the server says.
    var summary: String?

    init(name: String, summary: String? = nil) { self.name = name; self.summary = summary }
    /// Needs a name.
    init?(_ j: JSON) {
        guard let name = j["name"].nonEmpty else { return nil }
        self.init(name: name, summary: j["summary"].nonEmpty)
    }
}

/// Whether the agent has answered and said nothing since: past the server's own lines (a pull request's state, a quiet
/// timer, stderr), the transcript ends on the turn's result. A running turn that has answered and still lists background
/// work is waiting on it; one still speaking is not, whatever it backgrounded.
func transcriptAnswered<Blocks: BidirectionalCollection>(_ blocks: Blocks) -> Bool where Blocks.Element == TranscriptBlock {
    for block in blocks.reversed() {
        switch block {
        case .preparation: continue
        case .tools: return false
        case .event(let e):
            if ["text", "user", "ask", "result"].contains(e.kind) { return e.kind == "result" }
        }
    }
    return false
}

/// What the working line says after its glyph: the queue or the start-up in those states, the background work a running
/// turn that has answered has left to wait on (it is waiting then, not thinking), else the spinning verb.
func workingLineText(status: String, background: [BackgroundTask], answered: Bool, tick: Int) -> String {
    if status == "queued" { return "Queued\u{2026}" }
    if status == "preparing" || status == "starting" { return "Starting up\u{2026}" }
    if status == "running", answered, let first = background.first {
        if background.count > 1 { return "Waiting on \(background.count) background tasks\u{2026}" }
        return "Waiting on \(first.name)\(first.summary.map { ": \($0)" } ?? "")\u{2026}"
    }
    return "\(workingVerb(tick))\u{2026}"
}

/// What a message sent now does, under the conversation's composer.
func conversationComposerNote(active: Bool, liveInput: Bool, uploading: Bool, files: Int, empty: Bool) -> String {
    if active { return liveInput ? "Sent into the running turn" : "Queued for the next turn" }
    if uploading { return "Uploading\u{2026}" }
    if files > 0 && empty { return "Add a few words to send the files" }
    return ""
}

/// An attachment's chip: 📎 (… while uploading), its name and its size.
func attachmentChipLabel(name: String, size: Int?, uploaded: Bool) -> String {
    "\(uploaded ? "\u{1F4CE}" : "\u{2026}") \(name)" + (size.map { " \u{00B7} \(formatFileSize($0))" } ?? "")
}
/// The most files one message takes, as the Windows client's "At most 10 files per message".
let attachmentsMax = 10
/// Why a file could not be attached: "name why." lines.
func attachmentRefusal(_ name: String, _ why: String) -> String { "\(name) \(why)." }

/// A composer's files are read and uploaded one at a time, keeping only the current file's bytes in memory.
@MainActor
final class AttachmentUploadQueue {
    private var tail: Task<Void, Never>?

    func enqueue(releaseOnCancel: Bool = true, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let (finished, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            await previous?.value
            defer { continuation.finish() }
            guard !Task.isCancelled else { return }
            await withTaskCancellationHandler {
                await operation()
            } onCancel: {
                // Photos retain their turn until a conversion already in progress has stopped.
                if releaseOnCancel { continuation.finish() }
            }
        }
        tail = Task { for await _ in finished {} }
        return task
    }
}

// MARK: - Panel

/// "Findings (3 · all fixed)", "Findings (3 · 1 fixed)", "Findings (3)" or "Findings".
func panelFindingsLabel(count: Int, fixed: Int) -> String {
    guard count > 0 else { return "Findings" }
    if fixed == count { return "Findings (\(count) \u{00B7} all fixed)" }
    if fixed > 0 { return "Findings (\(count) \u{00B7} \(fixed) fixed)" }
    return "Findings (\(count))"
}
/// A pull request's state tag in the panel: draft for an open draft, else its state (open when unknown).
func panelStateText(_ pr: JSON) -> String {
    let state = pr["state"].string
    if pr["draft"].is(true) && state == "open" { return "draft" }
    return state ?? "open"
}
/// "Context" in the usage section: "12.0k / 200.0k (6%)", or "12.0k tokens" without a window.
func contextHeadline(used: Double, window: Double) -> String {
    if window > 0 { return "\(formatTokens(used)) / \(formatTokens(window)) (\(Int((used / window * 100 + 0.5).rounded(.down)))%)" }
    return "\(formatTokens(used)) tokens"
}
/// What the session spent with everything it ordered, or its own figures from a server without `usage`.
func sessionUsage(_ raw: JSON) -> JSON { raw["usage"].isObject ? raw["usage"] : raw }
/// The context in use and the model's window (0 when unknown); nil without a figure for what is used.
func sessionContextSize(_ raw: JSON) -> (used: Double, window: Double)? {
    let cu = raw["contextUsage"]
    let window = cu["window"].number ?? raw["contextWindow"].number ?? 0
    guard let used = cu["tokens"].number ?? raw["contextTokens"].number else { return nil }
    return (used, window)
}
func sessionUsageRowsPresent(_ raw: JSON) -> Bool {
    let u = sessionUsage(raw)
    return ["inputTokens", "outputTokens", "durationMs", "costUsd"].contains { u[$0].number != nil }
}

// MARK: - Recovery

/// What an interrupted or failed session left in its workspace (`GET /sessions/{id}/recovery`): the branch it is on and
/// the one it should be, its last commit, the files changed, whether it can be resumed and why (not), and the report's
/// fingerprint, which a resume names so it resumes from what was read.
struct RecoveryReport: Equatable, Sendable {
    var status: String
    var expectedBranch: String?
    var branch: String?
    var head: String?
    var changes: String
    var available: Bool
    var canResume: Bool
    var reason: String
    var phase: String
    var fingerprint: String

    init?(_ j: JSON) {
        guard j.isObject, let fingerprint = j["fingerprint"].string else { return nil }
        status = j["status"].string ?? ""
        expectedBranch = j["expectedBranch"].nonEmpty
        branch = j["branch"].nonEmpty
        head = j["head"].nonEmpty
        changes = j["changes"].string ?? ""
        available = j["available"].is(true)
        canResume = j["canResume"].is(true) && !fingerprint.isEmpty
        reason = j["reason"].string ?? ""
        phase = j["phase"].string ?? "conversation"
        self.fingerprint = fingerprint
    }

    /// Whether the conversation offers recovery: a session that stopped mid-work.
    static func offered(status: String) -> Bool { status == "interrupted" || status == "failed" }
    /// "Changed: 3 files" from `git status --short`, or nil without changes.
    var changeCount: Int { changes.split(separator: "\n").filter { !$0.hasPrefix("…") && !$0.hasPrefix("(") }.count }
    var shortHead: String? { head.map { String($0.prefix(8)) } }
}

// MARK: - Find in the conversation

/// The texts a transcript block shows that find searches (the Windows client's doc_search over the rendered document),
/// one per piece of selectable text in reading order: what is drawn, not its Markdown source, so markup is invisible and a
/// link's address is not searched. A folded block's steps count only while it is open.
func transcriptFindPieces(_ block: TranscriptBlock, open: Bool) -> [String] {
    switch block {
    case .preparation(let events): return open ? events.map(logLineText) : []
    case .tools: return []
    case .event(let e):
        switch e.kind {
        case "user": return [e.text ?? ""]
        case "text": return markdownFindPieces(e.text)
        case "ask": return ["Your input is needed"] + markdownFindPieces(e.question ?? e.text)
        case "result": return []
        default: return e.text != nil ? [logLineText(e)] : []
        }
    }
}

/// A reply's pieces as MarkdownView draws them: a paragraph, heading, list item or quote each, a code block whole, a
/// table cell by cell, row by row.
func markdownFindPieces(_ source: String?) -> [String] {
    var out: [String] = []
    for b in Markdown.parse(source) {
        switch b.kind {
        case .paragraph, .heading, .bullet, .quote: out.append(Markdown.plain(b.text))
        case .code: out.append(b.text)
        case .table: for row in b.cells { for cell in row { out.append(Markdown.plain(cell)) } }
        case .rule: break
        }
    }
    return out
}

/// Where each occurrence of `query` starts in `text`, in UTF-16 units, ignoring case; occurrences do not overlap.
func findOccurrences(of query: String, in text: String) -> [Int] {
    guard !query.isEmpty else { return [] }
    let s = text as NSString
    var out: [Int] = []
    var from = 0
    while from < s.length {
        let r = s.range(of: query, options: [.caseInsensitive], range: NSRange(location: from, length: s.length - from))
        if r.location == NSNotFound { break }
        out.append(r.location)
        from = r.location + max(r.length, 1)
    }
    return out
}

/// One hit: the block (by its seq), the piece of it and where in the piece.
struct TranscriptFindMatch: Equatable, Sendable {
    var block: Int
    var piece: Int
    var offset: Int
}

/// The find bar's search over a transcript: the query, every match in reading order, and the one shown as current, which
/// stays on the same place when the transcript is read again (the first match at or after it).
struct TranscriptFind: Equatable, Sendable {
    private(set) var query = ""
    private(set) var matches: [TranscriptFindMatch] = []
    private(set) var current = 0

    var currentMatch: TranscriptFindMatch? { matches.indices.contains(current) ? matches[current] : nil }
    /// Which occurrence within its block the current match is: how the drawn text finds it.
    var currentInBlock: Int? {
        guard let m = currentMatch else { return nil }
        return matches[..<current].filter { $0.block == m.block }.count
    }
    /// "Find", "No matches" or "3 / 12".
    var status: String {
        if query.isEmpty { return "Find" }
        if matches.isEmpty { return "No matches" }
        return "\(current + 1) / \(matches.count)"
    }

    /// Searches the blocks (seq and pieces, in reading order) for a new query, from the first match.
    mutating func search(_ query: String, in blocks: [(seq: Int, pieces: [String])]) {
        self.query = query
        matches = []; current = 0
        rebuild(blocks)
    }
    /// The transcript changed: the matches again, the current one kept on its place.
    mutating func rebuild(_ blocks: [(seq: Int, pieces: [String])]) {
        let old = currentMatch
        matches = []; current = 0
        var restored = false
        for b in blocks {
            for (p, text) in b.pieces.enumerated() {
                for o in findOccurrences(of: query, in: text) {
                    let m = TranscriptFindMatch(block: b.seq, piece: p, offset: o)
                    if !restored, let old, (m.block, m.piece, m.offset) >= (old.block, old.piece, old.offset) {
                        current = matches.count; restored = true
                    }
                    matches.append(m)
                }
            }
        }
    }
    /// The next match, or the previous one, wrapping around.
    mutating func step(backward: Bool) {
        guard !matches.isEmpty else { return }
        current = (current + (backward ? matches.count - 1 : 1)) % matches.count
    }
}
