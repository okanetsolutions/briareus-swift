// The meeting assistant's tools (the Windows client's core/meet_tools.c): what the ElevenLabs agent may look up about the
// one project the meeting is about, as the voice mode does, read-only. Each tool is a few /api/v1 calls the app makes
// with its own token, the project's repo put in every one, and their answers cut down to a short JSON summary for the
// model to say. Nothing here changes anything on the server: in a meeting anyone can speak, so the assistant only reads.
import Foundation

enum MeetTool: String, CaseIterable, Sendable {
    case listConversations = "list_conversations"
    case readConversation = "read_conversation"
    case listPullRequests = "list_pull_requests"
    case readPullRequest = "read_pull_request"
    case listFindings = "list_findings"
    case listIssues = "list_issues"
    case readIssue = "read_issue"

    var name: String { rawValue }

    private var description: String {
        switch self {
        case .listConversations:
            return "The project's conversations (coding agents' sessions), newest first, with their status, whether the agent asks a "
                + "question, and their pull request with its state (open, merged or closed) and checks."
        case .readConversation:
            return "A conversation's status and its latest messages: what was asked, what the agent said, and an open question."
        case .listPullRequests:
            return "The project's open pull requests with their checks, conflicts, labels and review state, whether each is ready to "
                + "merge, and the conversations working on it."
        case .readPullRequest:
            return "What one of the project's pull requests changes: how many files, lines added and removed, its description, and "
                + "each changed file's name with its diff, to summarize what it touches."
        case .listFindings:
            return "The review findings left on one of the project's pull requests: each one's severity, place, what it says, the "
                + "verdict given it (fix, dismissed or optional) and whether it is fixed."
        case .listIssues:
            return "The project's open issues with their labels, epic progress, the pull requests that close them and the "
                + "conversations started on them."
        case .readIssue:
            return "One of the project's issues in full: its state, labels, description and latest comments, its epic or sub-issues, "
                + "the pull requests that close it and the conversations started on it."
        }
    }
    private var parameters: [(name: String, type: String, about: String)] {
        switch self {
        case .listConversations: return [("active_only", "boolean", "Only the conversations still open.")]
        case .readConversation: return [("session_id", "string", "The conversation's id, from list_conversations.")]
        case .readPullRequest, .listFindings: return [("number", "integer", "The pull request's number.")]
        case .readIssue: return [("issue", "integer", "The issue's number.")]
        case .listPullRequests, .listIssues: return []
        }
    }

    /// The body that creates the tool in the ElevenLabs workspace (POST /v1/convai/tools) or brings it up to date (PATCH
    /// /v1/convai/tools/{id}): a client tool, which the app runs and answers.
    var body: JSON {
        var properties: JSON = [:]
        var required: [String] = []
        for p in parameters {
            properties[p.name] = ["type": .string(p.type), "description": .string(p.about)]
            // Every parameter but a filter is needed.
            if p.type != "boolean" { required.append(p.name) }
        }
        // The agent waits for the answer, which takes a few calls to the Briareus server: as long as it allows, since a large
        // project's board takes GitHub a while to read.
        return ["tool_config": ["type": "client", "name": .string(name), "description": .string(description),
                                "parameters": ["type": "object", "properties": properties, "required": JSON(required)],
                                "expects_response": true, "response_timeout_secs": 120]]
    }

    /// What the model is told about the project and the tools.
    static func instructions(project: String) -> String {
        "## The project\n"
            + "Coding agents work on \(project) in conversations (sessions). Every tool reads this project only; there is no way to "
            + "reach another, and no tool changes anything: you can look things up, never start, message, merge or close. If "
            + "asked to do something, say it has to be done in Briareus. Transcripts can contain mistakes and unfinished "
            + "phrases; use the latest context, and ask when a needed detail is unclear instead of guessing.\n\n"
            + "## Tools\n"
            + "Find conversations with list_conversations before reading one; never invent an id, and match what people name "
            + "against titles loosely. Each conversation carries its pull_request with its state (open, merged or closed) and "
            + "checks, and each open pull request names the conversations working on it. list_pull_requests lists open pull "
            + "requests only; one missing from it was merged or closed. read_conversation tells what an agent did, said or "
            + "asks. For what a pull request changes, use read_pull_request with its number and summarize its description and "
            + "diffs in plain words: what it touches and why, never the code itself. list_findings reads a pull request's "
            + "review findings. list_issues and read_issue read the project's issues.\n\n"
            + "## Ready to merge\n"
            + "A pull request is ready to merge only when list_pull_requests marks it ready_to_merge: the code-approved label, "
            + "checks passed, no conflicts, not a draft, and not stacked on another pull request. Otherwise say what it lacks.\n\n"
            + "## Saying the result\n"
            + "Say the relevant facts in a few plain sentences, without Markdown, ids or URLs, and only what the tools say."
    }

    // MARK: Calls

    /// The calls a tool makes with the model's `args` on `repo`, in order; none with `refusal` (a JSON output for the
    /// model) when the arguments are wrong.
    func calls(_ args: JSON, repo: String) -> (calls: [MeetCall], refusal: String?) {
        let r: JSON = ["repo": .string(repo)]
        func positive(_ key: String) -> Int? {
            guard let n = args[key].number, n >= 1, n < 1e9 else { return nil }
            return Int(n)
        }
        switch self {
        case .listConversations:
            return ([MeetCall(op: "sessions", args: r)], nil)
        case .readConversation:
            guard let id = args["session_id"].nonEmpty else {
                return ([], MeetTool.error("Say which conversation: its session_id, from list_conversations."))
            }
            // The list first, so a conversation of another project is not read.
            return ([MeetCall(op: "sessions", args: r), MeetCall(op: "session", args: ["sessionId": .string(id), "since": 0])], nil)
        case .listPullRequests, .listIssues:
            return ([MeetCall(op: "pulls", args: r), MeetCall(op: "sessions", args: r)], nil)
        case .readPullRequest, .listFindings:
            guard let number = positive("number") else { return ([], MeetTool.error("Say which pull request: its number.")) }
            var a = r; a["pr"] = JSON(number)
            if self == .listFindings { return ([MeetCall(op: "findings", args: a)], nil) }
            return ([MeetCall(op: "pull_files", args: a), MeetCall(op: "pull_description", args: a)], nil)
        case .readIssue:
            guard let number = positive("issue") else { return ([], MeetTool.error("Say which issue: its number.")) }
            var a = r; a["issue"] = JSON(number)
            var timeline = a; timeline["page"] = 1
            return ([MeetCall(op: "issue", args: a), MeetCall(op: "issue_timeline", args: timeline), MeetCall(op: "sessions", args: r)], nil)
        }
    }

    // MARK: Summaries

    /// The output when the calls failed: `why` in an error object.
    static func error(_ why: String) -> String { (["error": .string(why)] as JSON).serialized() }

    /// The output for the model, as JSON text, from the calls' answers in order (nil for one that failed: only the first
    /// is needed). `repo` keeps out conversations of other projects.
    func summary(_ args: JSON, repo: String, answers: [JSON?]) -> String {
        func at(_ i: Int) -> JSON? { i < answers.count ? answers[i] : nil }
        guard let a0 = at(0) else { return MeetTool.error("The server could not be read.") }
        let out: JSON
        switch self {
        case .listConversations: out = Self.listConversations(args, repo: repo, a0)
        case .readConversation: out = Self.readConversation(args, repo: repo, list: a0, at(1))
        case .listPullRequests: out = Self.listPullRequests(repo: repo, board: a0, sessions: at(1))
        case .readPullRequest: out = Self.readPullRequest(files: a0, description: at(1))
        case .listFindings: out = Self.listFindings(a0)
        case .listIssues: out = Self.listIssues(repo: repo, board: a0, sessions: at(1))
        case .readIssue: out = Self.readIssue(repo: repo, a0, timeline: at(1), sessions: at(2))
        }
        return out.serialized()
    }

    /// `text` on one line, Markdown dropped, cut to about `max` bytes at a sentence or a word.
    private static func cut(_ text: String?, _ max: Int) -> String {
        let all = Meet.spoken(text ?? "", Int.max / 2)
        if all.utf8.count <= max { return all }
        return Meet.spoken(text, max) + "…"
    }

    /// The project's conversations, newest first as the server lists them.
    private static func projectSessions(_ answer: JSON?, repo: String) -> [Session] {
        guard let answer else { return [] }
        return (Session.parseList(answer) ?? []).filter { $0.repo == nil || $0.repo == repo }
    }

    private static func checksText(_ checks: JSON) -> String {
        let total = checks["total"].number ?? 0, passed = checks["passed"].number ?? 0
        let failed = checks["failed"].number ?? 0, pending = checks["pending"].number ?? 0
        if total <= 0 { return "no checks" }
        if failed > 0 { return "\(Int(failed)) of \(Int(total)) failed" }
        if pending > 0 { return "\(Int(pending)) of \(Int(total)) still running" }
        return "all \(Int(passed)) passed"
    }

    /// The open question an agent asks: its last event, when that is a question no one answered yet.
    private static func openQuestion(_ events: [Event]) -> Event? {
        for e in events.reversed() {
            if e.kind == "ask" { return e.question != nil ? e : nil }
            if ["user", "text", "result"].contains(e.kind) { return nil }
        }
        return nil
    }

    private static func conversation(_ s: Session, events: [Event] = []) -> JSON {
        let asking = openQuestion(events)
        var o: JSON = ["session_id": .string(s.id), "title": .string(cut(s.displayTitle, 200)),
                       "status": .string(asking != nil ? "waiting for an answer" : s.status.isEmpty ? "unknown" : s.status)]
        if let number = s.pullNumber {
            var pr: JSON = ["number": JSON(number)]
            let st = s.raw["prStatus"]
            if st["number"].truncatedInt == number {
                if let state = st["state"].nonEmpty { pr["state"] = .string(state) }
                if let title = st["title"].nonEmpty { pr["title"] = .string(cut(title, 200)) }
                if st["draft"].is(true) { pr["draft"] = true }
                if st["checks"].isObject { pr["checks"] = .string(checksText(st["checks"])) }
            }
            o["pull_request"] = pr
        }
        if let asking {
            o["question"] = .string(cut(asking.question, 600))
            let options = (asking.options ?? .null).items.compactMap { $0["label"].nonEmpty }
            if !options.isEmpty { o["options"] = JSON(options) }
        }
        return o
    }

    private static func conversations(_ sessions: [Session], pull: Int = 0, issue: Int = 0) -> JSON {
        .array(sessions.filter { pull != 0 ? $0.pullNumber == pull : $0.onIssue(issue) }.map { s in
            var c: JSON = ["session_id": .string(s.id), "title": .string(cut(s.displayTitle, 200))]
            if !s.status.isEmpty { c["status"] = .string(s.status) }
            return c
        })
    }

    private static func labelNames(_ labels: [PullLabel]) -> JSON { JSON(labels.map(\.name)) }

    private static func listConversations(_ args: JSON, repo: String, _ answer: JSON) -> JSON {
        var sessions = projectSessions(answer, repo: repo)
        if args["active_only"].is(true) { sessions = sessions.filter { !["closed", "failed", "error"].contains($0.status) } }
        return ["conversations": .array(sessions.prefix(15).map { conversation($0) }), "total": JSON(sessions.count)]
    }

    private static func readConversation(_ args: JSON, repo: String, list: JSON, _ answer: JSON?) -> JSON {
        let id = args["session_id"].string
        guard projectSessions(list, repo: repo).contains(where: { $0.id == id }) else {
            return ["error": "That conversation is not one of this project's."]
        }
        guard let answer, let s = Session(answer["session"]) else { return ["error": "The server did not return the conversation."] }
        var t = Transcript()
        t.append(answer["events"])
        var out = conversation(s, events: t.events)
        // The last few things said, oldest first.
        let said = t.events.filter { ["user", "text", "result", "ask"].contains($0.kind) && ($0.question != nil || $0.text?.isEmpty == false) }
        out["latest"] = .array(said.suffix(6).compactMap { e in
            guard let text = e.question ?? e.text, !text.isEmpty else { return nil }
            return ["from": .string(e.kind == "user" ? "user" : "agent"), "text": .string(cut(text, 600))]
        })
        return out
    }

    private static func listPullRequests(repo: String, board: JSON, sessions answer: JSON?) -> JSON {
        let sessions = projectSessions(answer, repo: repo)
        let pulls = PullSummary.parseList(board["pulls"])
        return ["pull_requests": .array(pulls.prefix(15).map { pr in
            var o: JSON = ["number": JSON(pr.number), "title": .string(cut(pr.title, 200))]
            var state = pr.draft ? "draft" : "open"
            if pr.hasConflicts { state += ", has conflicts" }
            if let checks = pr.checks { state += ", checks \(checks)" }
            if let review = pr.reviewDecision { state += ", review \(review)" }
            o["state"] = .string(state)
            o["labels"] = labelNames(pr.labels)
            let stack = StackPosition(pr.raw["stack"], stacks: board["stacks"])
            let position = stack.map { $0.total > 1 ? $0.position : 1 } ?? 1
            let approved = pr.labels.contains { foldEqual($0.name, "code-approved") }
            o["ready_to_merge"] = .bool(approved && pr.checks == "success" && !pr.hasConflicts && !pr.draft && position == 1)
            if let stack, stack.total > 1 {
                let more = stack.partial ? " or more" : ""
                o["stack"] = .string(position > 1 ? "Position \(position) of a stack of \(stack.total)\(more): the pull requests under it merge first."
                                                  : "Bottom of a stack of \(stack.total)\(more): it merges first.")
            }
            o["conversations"] = conversations(sessions, pull: pr.number)
            return o
        }), "total": JSON(pulls.count)]
    }

    private static func readPullRequest(files: JSON, description: JSON?) -> JSON {
        guard let page = PullFilesPage(files) else { return ["error": "The server did not return the pull request's files."] }
        let pr = page.pr
        var out: JSON = ["changed_files": .number(pr["changedFiles"].number ?? Double(page.files.count))]
        if let v = pr["additions"].number { out["lines_added"] = .number(v) }
        if let v = pr["deletions"].number { out["lines_removed"] = .number(v) }
        if let v = pr["commits"].number { out["commits"] = .number(v) }
        if let title = pr["title"].nonEmpty { out["title"] = .string(cut(title, 200)) }
        if let body = description?["pr"]["body"].nonEmpty ?? pr["body"].nonEmpty { out["description"] = .string(cut(body, 6000)) }
        // Each file's diff, cut to 4,000 bytes and 60,000 in all; past that only the names.
        var left = 60000
        out["files"] = .array(page.files.map { f in
            var o: JSON = ["file": .string(f.filename)]
            guard let patch = f.patch, !patch.isEmpty else { o["diff"] = "No diff: a binary file, or one too large for GitHub to show."; return o }
            guard left > 0 else { return o }
            let bytes = Array(patch.utf8)
            var max = min(left, 4000)
            if bytes.count > max {
                while max > 0 && bytes[max] & 0xC0 == 0x80 { max -= 1 }
                o["diff"] = .string(String(decoding: bytes[..<max], as: UTF8.self) + "…")
                left -= max
            } else {
                o["diff"] = .string(patch)
                left -= bytes.count
            }
            return o
        })
        if left <= 0 { out["diffs"] = "Cut short: the later files are listed by name only." }
        if page.nextPage != nil || page.truncated { out["files_listed"] = .string("the first \(page.files.count) only") }
        return out
    }

    private static func listFindings(_ answer: JSON) -> JSON {
        var toFix = 0, notFixed = 0
        let list: [JSON] = answer["findings"].items.map { f in
            var o: JSON = ["title": .string(cut(f["title"].string, 200))]
            if let severity = f["severity"].nonEmpty { o["severity"] = .string(severity) }
            if let file = f["file"].nonEmpty {
                let line = f["line"].int32 ?? 0
                o["place"] = .string(line > 0 ? "\(file) line \(line)" : file)
            }
            if let says = f["body"].nonEmpty ?? f["detail"].nonEmpty ?? f["description"].nonEmpty { o["says"] = .string(cut(says, 500)) }
            let decision = f["decision"].string
            o["verdict"] = .string(["fix": "fix it", "dismissed": "dismissed", "optional": "optional"][decision ?? ""] ?? "not decided")
            let fixed = f["fixed"].is(true)
            if fixed { o["fixed"] = true }
            if decision == "fix" { toFix += 1; if !fixed { notFixed += 1 } }
            return o
        }
        return ["findings": .array(list), "to_fix": JSON(toFix), "to_fix_not_fixed": JSON(notFixed)]
    }

    private static func listIssues(repo: String, board: JSON, sessions answer: JSON?) -> JSON {
        let sessions = projectSessions(answer, repo: repo)
        let issues = IssueSummary.parseList(board["issues"])
        return ["issues": .array(issues.prefix(20).map { issue in
            var o: JSON = ["number": JSON(issue.number), "title": .string(cut(issue.title, 200)), "labels": labelNames(issue.labels),
                           "pull_requests": .array(issue.pulls.map { JSON($0.number) }),
                           "conversations": conversations(sessions, issue: issue.number)]
            if issue.isEpic { o["sub_issues"] = .string("\(issue.subIssuesDone) of \(issue.subIssues) done") }
            if let parent = issue.parent { o["epic"] = JSON(parent.number) }
            return o
        }), "total": JSON(issues.count)]
    }

    private static func issueState(_ raw: JSON) -> String {
        let state = raw["state"].string
        guard state == "closed" else { return state ?? "open" }
        switch raw["stateReason"].string {
        case "not_planned": return "closed as not planned"
        case "duplicate": return "closed as a duplicate"
        case "completed": return "closed as completed"
        default: return "closed"
        }
    }

    private static func readIssue(repo: String, _ answer: JSON, timeline: JSON?, sessions answer2: JSON?) -> JSON {
        let raw = answer["issue"]
        guard let issue = IssueSummary(raw) else { return ["error": "The server did not return the issue."] }
        let sessions = projectSessions(answer2, repo: repo)
        var out: JSON = ["number": JSON(issue.number), "title": .string(cut(issue.title, 200)), "state": .string(issueState(raw)),
                         "labels": labelNames(issue.labels), "description": .string(cut(raw["body"].string, 4000)),
                         "pull_requests": .array(issue.pulls.map { l in
                             var o: JSON = ["number": JSON(l.number), "title": .string(cut(l.title, 200))]
                             if let state = l.state { o["state"] = .string(state) }
                             if l.draft { o["draft"] = true }
                             return o
                         }),
                         "conversations": conversations(sessions, issue: issue.number)]
        if let type = raw["type"].nonEmpty { out["type"] = .string(type) }
        if let author = issue.author { out["author"] = .string(author) }
        if let parent = issue.parent { out["epic"] = ["number": JSON(parent.number), "title": .string(cut(parent.title, 200))] }
        if issue.isEpic {
            out["sub_issues"] = .string("\(issue.subIssuesDone) of \(issue.subIssues) done")
            let open = raw["subIssues"]["items"].items.compactMap(BoardLink.init).filter { $0.state == "open" }
            out["open_sub_issues"] = .array(open.prefix(10).map { ["number": JSON($0.number), "title": .string(cut($0.title, 200))] })
        }
        // The last five comments of the first page of the timeline.
        let comments = (timeline?["events"] ?? .null).items.filter { $0["kind"].string == "commented" && $0["body"].nonEmpty != nil }
        out["comments"] = .array(comments.suffix(5).map { c in
            ["from": .string(c["actor"].string ?? "a deleted account"), "text": .string(cut(c["body"].string, 800))]
        })
        out["comments_total"] = JSON(issue.comments)
        return out
    }
}

/// One API call a tool makes: the client operation and its arguments.
struct MeetCall: Equatable, Sendable {
    var op: String
    var args: JSON
}
