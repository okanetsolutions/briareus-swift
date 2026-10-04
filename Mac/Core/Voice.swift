// The voice mode's side of GPT-Realtime, OpenAI's realtime voice model: the session it opens, the tools it calls on the
// client API, and what each answer becomes for the model to say. No UI and no audio here.
//
// GPT-Realtime holds the spoken conversation and decides itself which tool to call. The phone runs each call on /api/v1
// with its own token and answers with a short JSON summary. A voice conversation belongs to one project: no tool names a
// repository, the phone puts that project's in every call.
import Foundation

enum Voice {
    /// Where a call starts: the phone posts its WebRTC offer with the session, and the SDP answer comes back.
    static let endpoint = URL(string: "https://api.openai.com/v1/realtime/calls")!
    /// The data channel GPT-Realtime sends and takes its JSON events on.
    static let channel = "oai-events"
    static let model = "gpt-realtime-2.1-mini"
    static let title = "GPT-Realtime 2.1 mini"
    /// What writes out the user's speech for the captions; the model hears the audio itself.
    static let transcriber = "gpt-4o-mini-transcribe"
    static let defaultVoice = "marin"
    /// Marin first, the default; then the Realtime API's other voices.
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]

    /// How the voice speaks: short, in the speaker's language, about one project, and never claiming what a tool
    /// has not confirmed; then the tools' rules.
    static func instructions(project: String) -> String { """
    You are the voice of Briareus, an app that runs coding agents on the user's projects. This conversation is about one \
    project only: \(project). The user talks to you hands-free, often with the phone locked. Answer in the language the \
    user speaks, in one or two short sentences. Speak only when the user has said something; do not volunteer updates. \
    Use the tools for anything about the project's conversations, agents, pull requests, issues or findings, and say only \
    what they confirm. If the user asks about another project, say this conversation can only work on \(project). Do what \
    the user asks right away, without asking them to confirm; the one exception is merging a pull request, which waits \
    for their yes.

    \(toolInstructions(project: project))
    """ }

    /// What the model knows of the project, the tools and their rules.
    static func toolInstructions(project: String) -> String { """
    ## Voice conversation context
    This is a live voice conversation about one project on the user's Briareus server: \(project). Coding agents work \
    on it in conversations (sessions). Every tool works on this project only; there is no way to reach another. \
    Transcripts can contain mistakes, unfinished phrases and later corrections; use the latest context. If a needed \
    detail is unclear, ask for it instead of guessing.

    ## Tools
    Find conversations with list_conversations before acting on one; never invent an id. Match what the user names \
    against titles loosely. Each conversation carries its pull_request with its state (open, merged or closed) and \
    checks, and each open pull request names the conversations working on it: use these links to answer whether a \
    conversation's pull request was merged or closed. list_pull_requests lists open pull requests only; one missing \
    from it was merged or closed, and the conversation's pull_request says which. read_conversation tells what an \
    agent did, said or asks. send_message also answers an agent's question. For what a pull request changes (how \
    many files, which ones, lines added and removed, and what its diffs do), use read_pull_request with its number; a \
    conversation's pull_request gives the number. Summarize its description and diffs in plain words: what it touches \
    and why, never the code itself.

    ## Closing and deleting
    close_conversation ends a conversation and frees its workspace; it can be reopened later. delete_conversation \
    removes it and its transcript for good. Say which one will happen; when the user says they are done with a \
    conversation without saying how, offer to close it.

    ## Issues
    list_issues lists the project's open issues with their labels, epic progress, the pull requests that close them \
    and the conversations started on them. read_issue reads one in full: its description, its latest comments, its \
    epic or sub-issues and the pull requests that close it; use it whenever the user asks what an issue says or wants. \
    To have an agent do an issue, use work_on_issue with its number: it starts a conversation that reads the issue in \
    full, implements it and opens a pull request that closes it. Before starting one, say if a conversation or a pull \
    request is already on that issue.

    ## Reviews and feedback
    run_errand starts what the board's buttons start on a pull request: review runs the code review, \
    implement-feedback fixes the findings marked fix, fix-checks fixes failing checks, solve-conflicts resolves \
    conflicts. A pull request's findings are read with list_findings; the user says yes (fix), no (dismissed) or \
    optional to each, recorded one by one with decide_finding, then implement-feedback fixes the yeses. A review \
    round a conversation holds (waiting_findings) is read with read_review_round and completed with \
    complete_review_round, with the keys the user said yes and no to. Read the findings briefly, one at a time when the \
    user is deciding, and never decide one the user did not.

    ## Ready to merge
    A pull request is ready to be merged only when list_pull_requests marks it ready_to_merge: it carries the \
    code-approved label, its checks passed, it has no conflicts, it is not a draft, and it is not stacked on another \
    pull request. Say clearly when a pull request is stacked and its position: in a stack only position 1, the bottom, \
    can be ready; any other position waits for the ones under it. Never call one ready on its checks or reviews \
    alone; say what it still lacks instead.

    ## Merging
    merge_pull_request merges one of the project's pull requests, squashed unless the repository refuses squashes. \
    Its first call answers a read_back with what stands in its way: failing or running checks, conflicts, a missing \
    code-approved label, requested changes. Read all of it to the user; they may still choose to merge.

    ## Confirmation
    Only merge_pull_request needs the user's approval. Call it with confirmed=false first: the answer says what to read \
    back. Call again with confirmed=true only after the user clearly agreed to that exact merge in their latest turn; \
    never pass confirmed=true on your own. Every other tool acts at once when the user asks for it: do not ask them to \
    confirm, and say what was done once the tool answers.

    ## Saying the result
    Say the relevant facts in a few plain sentences, without Markdown, ids or URLs. Report an action as done only when \
    the tool says it is.
    """ }

    /// What starts a call over WebRTC: the voice, the captions' transcriber and the tools, all on one project. `project`
    /// is how it is named aloud: its label and repository. WebRTC settles the audio format; the SDP offer goes beside
    /// this, as another field of the form.
    static func session(voice: String, project: String) -> JSON {
        ["type": "realtime",
         "model": .string(model),
         "instructions": .string(instructions(project: project)),
         "audio": ["input": ["transcription": ["model": .string(transcriber)]],
                   "output": ["voice": .string(voices.contains(voice) ? voice : defaultVoice)]],
         "tools": .array(VoiceTool.allCases.map(\.definition)),
         "tool_choice": "auto"]
    }
}

// MARK: - Cost

/// What a conversation has cost so far, in dollars, from the token usage OpenAI reports: each response's on
/// `response.done`, and each transcription of the user's speech on its completed event. Prices per million tokens, as
/// OpenAI lists them for gpt-realtime-2.1-mini and gpt-4o-mini-transcribe.
/// An estimate: OpenAI's own bill is the reference.
struct VoiceCost: Equatable, Sendable {
    private(set) var dollars = 0.0
    private(set) var tokens = 0

    /// A response's usage: input split into text, audio and image, each with a cached part; output into text and audio.
    mutating func add(response usage: JSON) {
        tokens += (usage["input_tokens"].int ?? 0) + (usage["output_tokens"].int ?? 0)
        let input = usage["input_token_details"], cached = input["cached_tokens_details"], output = usage["output_token_details"]
        func n(_ j: JSON) -> Double { Double(j.int ?? 0) }
        let fresh = (text: n(input["text_tokens"]) - n(cached["text_tokens"]),
                     audio: n(input["audio_tokens"]) - n(cached["audio_tokens"]),
                     image: n(input["image_tokens"]) - n(cached["image_tokens"]))
        dollars += (max(fresh.text, 0) * 0.60 + n(cached["text_tokens"]) * 0.06
                    + max(fresh.audio, 0) * 10 + n(cached["audio_tokens"]) * 0.30
                    + max(fresh.image, 0) * 0.80 + n(cached["image_tokens"]) * 0.08
                    + n(output["text_tokens"]) * 2.40 + n(output["audio_tokens"]) * 20) / 1_000_000
    }

    /// A transcription's usage, when it is billed by tokens.
    mutating func add(transcription usage: JSON) {
        guard usage["type"].string == "tokens" else { return }
        tokens += (usage["input_tokens"].int ?? 0) + (usage["output_tokens"].int ?? 0)
        dollars += (Double(usage["input_tokens"].int ?? 0) * 1.25 + Double(usage["output_tokens"].int ?? 0) * 5) / 1_000_000
    }

    /// "$0.0123", with more places while it is under a cent.
    static func dollars(_ amount: Double) -> String {
        String(format: amount < 0.01 ? "$%.4f" : amount < 1 ? "$%.3f" : "$%.2f", amount)
    }
    /// "1:05", or "1:02:03" past an hour.
    static func time(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0).rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    /// What the screen shows under the controls after `elapsed` seconds.
    func line(elapsed: Double = 0) -> String {
        let tokenText = tokens >= 1000 ? String(format: "%.1fk tokens", Double(tokens) / 1000) : "\(tokens) tokens"
        return "≈ \(Self.dollars(dollars)) · \(Self.time(elapsed)) · \(tokenText)"
    }
}

// MARK: - Usage

/// One finished conversation, kept on the phone: how long it ran and what it cost.
struct VoiceRecord: Equatable, Sendable {
    var seconds: Double
    var dollars: Double
    var date: Date

    init(seconds: Double, dollars: Double, date: Date) {
        self.seconds = seconds; self.dollars = dollars; self.date = date
    }
    /// What `json` saved. One kept from another model (GPT-Live, which the app used to offer) is not this one's.
    init?(_ j: JSON) {
        guard (j["engine"].string ?? Voice.model) == Voice.model, let seconds = j["seconds"].number,
              let dollars = j["dollars"].number, let date = j["date"].number else { return nil }
        self.init(seconds: seconds, dollars: dollars, date: Date(timeIntervalSince1970: date))
    }
    var json: JSON {
        ["engine": .string(Voice.model), "seconds": .number(seconds), "dollars": .number(dollars),
         "date": .number(date.timeIntervalSince1970)]
    }
}

/// The conversations kept, added up: how many, how long they ran and what they cost.
struct VoiceTally: Equatable, Sendable {
    var conversations = 0
    var seconds = 0.0
    var dollars = 0.0

    init(_ records: [VoiceRecord]) {
        for r in records { conversations += 1; seconds += r.seconds; dollars += r.dollars }
    }
    /// Dollars per minute of conversation; nil before any.
    var perMinute: Double? { seconds > 0 ? dollars / seconds * 60 : nil }
}

// MARK: - Tools

/// What the model may call. Each runs one call of the client API on the conversation's project; only a merge waits for
/// a yes.
enum VoiceTool: String, CaseIterable, Sendable {
    case listConversations = "list_conversations"
    case readConversation = "read_conversation"
    case listPullRequests = "list_pull_requests"
    case readPullRequest = "read_pull_request"
    case mergePullRequest = "merge_pull_request"
    case waitingFindings = "waiting_findings"
    case readReviewRound = "read_review_round"
    case completeReviewRound = "complete_review_round"
    case listFindings = "list_findings"
    case decideFinding = "decide_finding"
    case runErrand = "run_errand"
    case listIssues = "list_issues"
    case readIssue = "read_issue"
    case startConversation = "start_conversation"
    case workOnIssue = "work_on_issue"
    case sendMessage = "send_message"
    case stopConversation = "stop_conversation"
    case closeConversation = "close_conversation"
    case deleteConversation = "delete_conversation"

    /// The client API call each tool makes.
    var operation: String {
        switch self {
        case .listConversations, .waitingFindings, .readReviewRound: return "sessions"
        case .completeReviewRound: return "complete_findings"
        case .listFindings: return "findings"
        case .decideFinding: return "finding_decision"
        // The errand's own call, `review` or `action`, is chosen by the phone; this is the one most errands make.
        case .runErrand: return "action"
        case .readConversation: return "session"
        case .listPullRequests, .listIssues: return "pulls"
        case .readIssue: return "issue"
        case .readPullRequest: return "pull_files"
        case .mergePullRequest: return "merge_pull"
        case .startConversation, .workOnIssue: return "start_session"
        case .sendMessage: return "message"
        case .stopConversation: return "cancel"
        case .closeConversation: return "close"
        case .deleteConversation: return "delete"
        }
    }
    /// Waits for a yes the user said after hearing it read back: a merge only.
    var confirms: Bool { self == .mergePullRequest }
    /// Changes something on the server, so the project's conversations are read again after it.
    var changes: Bool {
        [.startConversation, .workOnIssue, .sendMessage, .stopConversation, .closeConversation, .deleteConversation,
         .mergePullRequest, .completeReviewRound, .runErrand, .decideFinding].contains(self)
    }
    /// Acts on a conversation named by id, which must be the project's: the phone checks before it answers.
    var namesConversation: Bool {
        [.readConversation, .sendMessage, .stopConversation, .closeConversation, .deleteConversation, .completeReviewRound]
            .contains(self)
    }

    /// A Realtime function tool.
    var definition: JSON {
        var properties: [String: JSON] = [:]
        var required: [String] = []
        func add(_ name: String, _ type: String, _ about: String, required isRequired: Bool = true) {
            properties[name] = ["type": .string(type), "description": .string(about)]
            if isRequired { required.append(name) }
        }
        let description: String
        switch self {
        case .listConversations:
            description = "The project's conversations, newest first, with their status, whether the agent asks a question, and their pull request with its state (open, merged or closed) and checks."
            add("active_only", "boolean", "Only the conversations an agent is working on or that wait for the user.", required: false)
        case .readConversation:
            description = "A conversation's status and its latest messages: what the user asked, what the agent said, and an open question."
            add("session_id", "string", "The conversation's id, from list_conversations.")
        case .listPullRequests:
            description = "The project's open pull requests with their checks, conflicts, labels and review state, whether each is ready to merge, and the conversations working on it."
        case .mergePullRequest:
            description = "Merges one of the project's open pull requests into its base branch. The first call reads it and answers what to read back, with what stands in the way."
            add("number", "integer", "The pull request's number.")
            add("confirmed", "boolean", "True only after the user agreed to this exact action.")
        case .readPullRequest:
            description = "What one of the project's pull requests changes: how many files, lines added and removed, its description, and each changed file's name with its diff, to summarize what it touches."
            add("number", "integer", "The pull request's number.")
        case .waitingFindings:
            description = "The project's review rounds waiting for the user's decision."
        case .readReviewRound:
            description = "The findings of the review round a conversation holds for the user's decision: each one's key, severity, place, what it says and the verdict drafted for it."
            add("session_id", "string", "The conversation's id, from waiting_findings or list_conversations.")
        case .completeReviewRound:
            description = "Completes a conversation's review round with the user's verdicts: the findings to fix are sent to be fixed, the dismissed ones are dropped, the rest stay optional. With nothing to fix, the pull request is approved."
            add("session_id", "string", "The conversation's id.")
            properties["fix"] = ["type": "array", "items": ["type": "string"], "description": "Keys of the findings the user said yes to: they are fixed."]
            required.append("fix")
            properties["dismiss"] = ["type": "array", "items": ["type": "string"], "description": "Keys of the findings the user said no to."]
            required.append("dismiss")
            add("note", "string", "What the user wants the fix session told, if anything.", required: false)
        case .listFindings:
            description = "The review findings left on one of the project's pull requests: each one's key, severity, place, what it says, the user's verdict (yes to fix, no, or optional) and whether it is fixed."
            add("number", "integer", "The pull request's number.")
        case .decideFinding:
            description = "Records the user's yes or no on one finding of a pull request: fix (yes, implement it), dismissed (no) or optional. Only on the user's own word; run_errand implement-feedback then fixes the ones marked fix."
            add("number", "integer", "The pull request's number.")
            add("key", "string", "The finding's key, from list_findings.")
            properties["decision"] = ["type": "string", "enum": ["fix", "dismissed", "optional"], "description": "fix for yes, dismissed for no, optional to leave it to the implementer."]
            required.append("decision")
        case .runErrand:
            description = "Starts an errand on one of the project's pull requests, as the board's buttons do: review (run the code review and publish it), implement-feedback (fix the findings marked fix and have the fixes reviewed), fix-checks (fix failing CI checks) or solve-conflicts (merge the base in and resolve the conflicts)."
            add("number", "integer", "The pull request's number.")
            properties["errand"] = ["type": "string", "enum": .array(Voice.errands.map { .string($0) }), "description": "Which errand."]
            required.append("errand")
        case .listIssues:
            description = "The project's open issues with their labels, epic progress, the pull requests that close them and the conversations started on them."
        case .readIssue:
            description = "One of the project's issues in full: its state, type, labels, description and latest comments, its epic or sub-issues, the pull requests that close it and the conversations started on it."
            add("issue", "integer", "The issue's number, from list_issues or as the user said it.")
        case .workOnIssue:
            description = "Starts an agent on one of the project's open issues: it reads the issue in full, implements it and opens a pull request that closes it."
            add("issue", "integer", "The issue's number, from list_issues.")
        case .startConversation:
            description = "Starts an agent on the project with a first prompt."
            add("prompt", "string", "What the agent should do, as the user said it.")
            add("branch", "string", "The branch to start from. Omit for the project's default.", required: false)
        case .sendMessage:
            description = "Sends a message to a conversation's agent, or answers its question. A busy agent gets it in its running turn or the next."
            add("session_id", "string", "The conversation's id, from list_conversations.")
            add("text", "string", "The message, as the user said it.")
        case .stopConversation:
            description = "Stops the agent's running turn. The conversation stays open."
            add("session_id", "string", "The conversation's id, from list_conversations.")
        case .closeConversation:
            description = "Closes a conversation: its agent stops and its workspace is freed. It can be reopened later."
            add("session_id", "string", "The conversation's id, from list_conversations.")
        case .deleteConversation:
            description = "Deletes a conversation and its transcript for good. It cannot be undone."
            add("session_id", "string", "The conversation's id, from list_conversations.")
        }
        return ["type": "function", "name": .string(rawValue), "description": .string(description),
                "parameters": ["type": "object", "properties": .object(properties), "required": JSON(required),
                               "additionalProperties": false]]
    }

    /// What a call with these arguments does on `repo`: the client API call to make, a read-back that waits for a yes,
    /// or why it cannot be made.
    func plan(_ args: JSON, repo: String) -> VoicePlan {
        func text(_ key: String) -> String? {
            args[key].string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
        }
        let confirmed = args["confirmed"].is(true)
        switch self {
        case .listConversations, .waitingFindings, .listPullRequests, .listIssues:
            return .call(["repo": .string(repo)])
        case .readIssue:
            guard let number = args["issue"].int, number >= 1 else { return .refuse("issue is missing.") }
            return .call(["repo": .string(repo), "issue": JSON(number)])
        case .workOnIssue:
            guard let number = args["issue"].int, number >= 1 else { return .refuse("issue is missing.") }
            // The board is read first: the conversation's prompt is made from the issue's row there.
            return .call(["repo": .string(repo), "issue": JSON(number)])
        case .readPullRequest, .listFindings:
            guard let number = args["number"].int, number >= 1 else { return .refuse("number is missing.") }
            return .call(["repo": .string(repo), "pr": JSON(number)])
        case .readReviewRound:
            guard text("session_id") != nil else { return .refuse("session_id is missing.") }
            return .call(["repo": .string(repo)])
        case .completeReviewRound:
            guard let id = text("session_id") else { return .refuse("session_id is missing.") }
            let fix = args["fix"].strings, dismiss = args["dismiss"].strings
            // The phone reads the round and makes the verdicts from these keys before the call.
            var call: JSON = ["sessionId": .string(id), "fix": JSON(fix), "dismiss": JSON(dismiss)]
            if let note = text("note") { call["note"] = .string(note) }
            return .call(call)
        case .decideFinding:
            guard let number = args["number"].int, number >= 1, let key = text("key") else { return .refuse("number and key are needed.") }
            guard let decision = text("decision"), findingDecisionIds.contains(decision) else { return .refuse("decision must be fix, dismissed or optional.") }
            let call: JSON = ["repo": .string(repo), "pr": JSON(number), "key": .string(key), "decision": .string(decision)]
            return .call(call)
        case .runErrand:
            guard let number = args["number"].int, number >= 1 else { return .refuse("number is missing.") }
            guard let errand = text("errand"), let action = Voice.errand(errand) else {
                return .refuse("errand must be one of \(Voice.errands.joined(separator: ", ")).")
            }
            // Code review checks the branch out itself: the phone adds it from the board before the call.
            return .call(action.arguments(repo: repo, number: number))
        case .mergePullRequest:
            // The phone reads the pull request before either answer: the read-back says what stands in the way, and the
            // merge is pinned to the head the user heard about.
            guard let number = args["number"].int, number >= 1 else { return .refuse("number is missing.") }
            return confirmed ? .call(["repo": .string(repo), "pr": JSON(number)]) : .confirm("Merge pull request #\(number).")
        case .readConversation:
            guard let id = text("session_id") else { return .refuse("session_id is missing.") }
            return .call(["sessionId": .string(id), "since": 0])
        case .startConversation:
            guard let prompt = text("prompt") else { return .refuse("prompt is missing.") }
            var call: JSON = ["repo": .string(repo), "prompt": .string(prompt)]
            if let branch = text("branch") { call["branch"] = .string(branch) }
            return .call(call)
        case .sendMessage:
            guard let id = text("session_id"), let message = text("text") else { return .refuse("session_id and text are needed.") }
            return .call(["sessionId": .string(id), "text": .string(message)])
        case .stopConversation:
            guard let id = text("session_id") else { return .refuse("session_id is missing.") }
            return .call(["sessionId": .string(id)])
        case .closeConversation:
            guard let id = text("session_id") else { return .refuse("session_id is missing.") }
            return .call(["sessionId": .string(id)])
        case .deleteConversation:
            guard let id = text("session_id") else { return .refuse("session_id is missing.") }
            return .call(["sessionId": .string(id)])
        }
    }

    /// Reads the project's conversations too, to link each pull request or issue to the conversations working on it.
    var readsConversations: Bool { [.listPullRequests, .listIssues, .readIssue].contains(self) }

    /// The answer of the call, cut to what the model needs to say it. `args` are the tool's own arguments, and
    /// `sessions` the project's conversations when `readsConversations`. A `read_issue` answer carries the timeline
    /// rows the phone read after it as `timeline`.
    func summary(_ answer: JSON, args: JSON, sessions: [Session] = []) -> JSON {
        switch self {
        case .listConversations:
            var sessions = Session.parseList(answer) ?? []
            if args["active_only"].is(true) { sessions = sessions.filter { !["closed", "failed", "error"].contains($0.status) } }
            return ["conversations": .array(sessions.prefix(15).map(Voice.conversation)),
                    "total": JSON(sessions.count)]
        case .readConversation:
            guard let session = Session(answer["session"]) else { return ["error": "The server did not return the conversation."] }
            let events = answer["events"].items.compactMap(Event.init)
            var out = Voice.conversation(session, events: events)
            out["latest"] = .array(Voice.latest(events))
            return out
        case .listPullRequests:
            let pulls = PullSummary.parseList(answer["pulls"])
            return ["pull_requests": .array(pulls.prefix(15).map { pr in
                let stack = StackPosition(pr.raw["stack"], stacks: answer["stacks"])
                var out: JSON = ["number": JSON(pr.number), "title": .string(CarText.inline(pr.title)), "state": .string(CarText.pullLine(pr)),
                                 "labels": JSON(pr.labels.map(\.name)), "ready_to_merge": .bool(Voice.readyToMerge(pr, stack: stack)),
                                 "conversations": .array(sessions.filter { $0.pullNumber == pr.number }.map { s in
                                     ["session_id": .string(s.id), "title": .string(s.displayTitle)]
                                 })]
                if let stacked = Voice.stacked(stack, number: pr.number) {
                    out["stack"] = .string(stacked.said)
                    if let under = stacked.under { out["stacked_on"] = JSON(under) }
                }
                return out
            }), "total": JSON(pulls.count)]
        case .mergePullRequest:
            return ["done": true, "result": .string(CarText.merged(answer, base: args["base"].string ?? "its base"))]
        case .readPullRequest:
            guard let page = PullFilesPage(answer) else { return ["error": "The server did not return the pull request's files."] }
            return Voice.changes(page, description: answer["description"].string)
        case .readReviewRound:
            guard let id = args["session_id"].string, let s = (Session.parseList(answer) ?? []).first(where: { $0.id == id }) else {
                return ["error": "That conversation is not one of this project's."]
            }
            guard let held = s.heldTriage else { return ["error": "That conversation holds no review round waiting for a decision."] }
            var out: JSON = ["title": .string(s.displayTitle), "mine": .bool(triageTakesVerdicts(held)),
                             "findings": .array(held["findings"].items.map { Voice.finding($0, verdict: triageDecision(held, $0, picked: [:])) })]
            if let pr = s.pullNumber { out["pull_request"] = JSON(pr) }
            if !triageTakesVerdicts(held) { out["note"] = "This round is on someone else's pull request: completing it only takes it off the queue." }
            return out
        case .completeReviewRound:
            return ["done": true, "result": .string(triageOutcomeText(answer).text)]
        case .listFindings, .decideFinding:
            let findings = answer["findings"].items
            return ["findings": .array(findings.map { Voice.finding($0, verdict: $0["decision"].string ?? "") }),
                    "to_fix": JSON(findingsToFix(answer["findings"])), "not_fixed": JSON(findingsUnfixed(answer["findings"]))]
        case .runErrand:
            guard let session = Session(answer["session"]) else { return ["done": true] }
            return ["done": true, "session_id": .string(session.id), "title": .string(session.displayTitle)]
        case .waitingFindings:
            let held = CarText.holdingFindings(Session.parseList(answer) ?? [])
            return ["waiting": .array(held.map { s in
                ["session_id": .string(s.id), "title": .string(s.displayTitle),
                 "findings": JSON(s.heldTriage?["findings"].count ?? 0)]
            })]
        case .listIssues:
            let issues = IssueSummary.parseList(answer["issues"])
            return ["issues": .array(issues.prefix(20).map { issue in
                var out: JSON = ["number": JSON(issue.number), "title": .string(CarText.inline(issue.title)),
                                 "labels": JSON(issue.labels.map(\.name)),
                                 "pull_requests": .array(issue.pulls.map { JSON($0.number) }),
                                 "conversations": .array(sessions.filter { $0.onIssue(issue.number) }.map { s in
                                     ["session_id": .string(s.id), "title": .string(s.displayTitle), "status": .string(CarText.status(s))]
                                 })]
                if issue.isEpic { out["sub_issues"] = .string("\(issue.subIssuesDone) of \(issue.subIssues) done") }
                if let parent = issue.parent { out["epic"] = JSON(parent.number) }
                return out
            }), "total": JSON(issues.count)]
        case .readIssue:
            let raw = answer["issue"]
            guard let issue = IssueSummary(raw) else { return ["error": "The server did not return the issue."] }
            let pulls: [JSON] = issue.pulls.map { pr in
                var link: JSON = ["number": JSON(pr.number), "title": .string(CarText.inline(pr.title))]
                if let state = pr.state { link["state"] = .string(state) }
                if pr.draft { link["draft"] = true }
                return link
            }
            let working: [JSON] = sessions.filter { $0.onIssue(issue.number) }.map { s in
                ["session_id": .string(s.id), "title": .string(s.displayTitle), "status": .string(CarText.status(s))]
            }
            var out: JSON = ["number": JSON(issue.number), "title": .string(CarText.inline(issue.title)),
                             "state": .string(Voice.issueState(raw)), "labels": JSON(issue.labels.map(\.name)),
                             "description": .string(Voice.cut(CarText.inline(raw["body"].string ?? ""), 4000)),
                             "pull_requests": .array(pulls), "conversations": .array(working)]
            if let type = raw["type"].nonEmpty { out["type"] = .string(type) }
            if let author = issue.author { out["author"] = .string(author) }
            if !issue.assignees.isEmpty { out["assignees"] = JSON(issue.assignees) }
            if let parent = issue.parent { out["epic"] = ["number": JSON(parent.number), "title": .string(CarText.inline(parent.title))] }
            if issue.isEpic {
                out["sub_issues"] = .string("\(issue.subIssuesDone) of \(issue.subIssues) done")
                let open = raw["subIssues"]["items"].items.compactMap(BoardLink.init).filter { $0.state == "open" }
                out["open_sub_issues"] = .array(open.prefix(10).map { ["number": JSON($0.number), "title": .string(CarText.inline($0.title))] })
            }
            let comments = answer["timeline"].items.filter { $0["kind"].string == "commented" && $0["body"].nonEmpty != nil }
            out["comments"] = .array(comments.suffix(5).map { c in
                ["from": .string(c["actor"].string ?? "a deleted account"), "text": .string(Voice.cut(CarText.inline(c["body"].string ?? ""), 800))]
            })
            out["comments_total"] = JSON(issue.comments)
            if answer["timeline_cut"].is(true) {
                out["comments_note"] = "Only the start of a long timeline was read: these may not be the latest comments. Say so."
            }
            return out
        case .startConversation, .workOnIssue:
            guard let session = Session(answer["session"]) else { return ["done": true] }
            return ["done": true, "session_id": .string(session.id), "title": .string(session.displayTitle)]
        case .sendMessage:
            return ["done": true, "delivery": .string(CarText.sent(Session(answer["session"])))]
        case .stopConversation, .closeConversation, .deleteConversation:
            return ["done": true]
        }
    }
}

/// What a tool call becomes on the phone.
enum VoicePlan: Equatable, Sendable {
    /// Make the tool's client API call with these arguments.
    case call(JSON)
    /// Answer the model with this read-back; nothing is done until the call comes back confirmed.
    case confirm(String)
    /// Answer the model with what is wrong with the call.
    case refuse(String)
}

extension Voice {
    /// What `start_session` is sent for an agent on issue `number`, from the board the project's `pulls` answered; nil
    /// when the issue is not open on it.
    static func issueStart(_ board: JSON, number: Int, repo: String) -> JSON? {
        guard let issue = issuesFind(IssueSummary.parseList(board["issues"]), number) else { return nil }
        return ["repo": .string(repo), "prompt": .string(issuePrompt(issue, repo: repo)), "activity": "issue"]
    }
    /// How many timeline pages `read_issue` reads at most: 100 rows each, oldest first, so its latest comments are on the last.
    static let issueTimelinePages = 5
    /// An issue's state in words: open, closed, or closed with its reason.
    static func issueState(_ issue: JSON) -> String {
        guard issue["state"].string == "closed" else { return issue["state"].string ?? "open" }
        switch issue["stateReason"].string {
        case "not_planned": return "closed as not planned"
        case "duplicate": return "closed as a duplicate"
        case "completed": return "closed as completed"
        default: return "closed"
        }
    }
    /// `text` cut to `length` characters, with an ellipsis when it was longer.
    static func cut(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
    /// What a pull request changes, from the first page of its files: the totals, its description, and each file by its
    /// name with its diff, so the model can say what the change touches. Diffs are cut to `perFile` characters each
    /// and `budget` in all; the files past the budget keep their names.
    static func changes(_ page: PullFilesPage, description: String? = nil, perFile: Int = 4000, budget: Int = 60000) -> JSON {
        let pr = page.pr
        var out: JSON = ["changed_files": JSON(pr["changedFiles"].int ?? page.files.count)]
        if let added = pr["additions"].int { out["lines_added"] = JSON(added) }
        if let removed = pr["deletions"].int { out["lines_removed"] = JSON(removed) }
        if let commits = pr["commits"].int { out["commits"] = JSON(commits) }
        if let title = pr["title"].nonEmpty { out["title"] = .string(CarText.inline(title)) }
        if let body = (description ?? pr["body"].string)?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            out["description"] = .string(cut(visibleMarkdown(body), 6000))
        }
        var left = budget
        out["files"] = .array(page.files.map { file in
            var f: JSON = ["file": .string(file.filename)]
            guard let patch = file.patch, !patch.isEmpty else { f["diff"] = "No diff: a binary file, or one too large for GitHub to show."; return f }
            guard left > 0 else { return f }
            let shown = cut(patch, min(perFile, left))
            left -= shown.count
            f["diff"] = .string(shown)
            return f
        })
        if left <= 0 { out["diffs"] = "Cut short: the later files are listed by name only." }
        if page.nextPage != nil || page.truncated { out["files_listed"] = .string("the first \(page.files.count) only") }
        return out
    }
    /// The errands the voice can start on a pull request, by the board's ids.
    static let errands = ["review", "implement-feedback", "fix-checks", "solve-conflicts"]
    static func errand(_ id: String) -> BoardAction? {
        errands.contains(id) ? BoardAction.known.first { $0.id == id } : nil
    }
    /// What `complete_findings` is sent for a held round from the keys the user said yes and no to; the rest stay
    /// optional. A round on someone else's pull request takes no verdicts.
    static func roundCompletion(_ held: JSON, fix: [String], dismiss: [String], note: String?) -> JSON {
        var picked: [String: String] = [:]
        for key in dismiss { picked[key] = "dismissed" }
        for key in fix { picked[key] = "fix" }
        return triageCompletion(held, picked: picked, note: note ?? "")
    }
    /// A finding as the model reads it: its key, severity, place and words, and the verdict given it in plain terms.
    static func finding(_ f: JSON, verdict: String) -> JSON {
        var out: JSON = ["key": .string(f["key"].string ?? ""), "title": .string(CarText.inline(f["title"].string ?? ""))]
        if let severity = f["severity"].nonEmpty { out["severity"] = .string(severity) }
        if let place = findingLocation(f) { out["place"] = .string(place) }
        if let body = (f["body"].nonEmpty ?? f["detail"].nonEmpty ?? f["description"].nonEmpty) {
            out["says"] = .string(cut(CarText.inline(body), 500))
        }
        out["verdict"] = .string(["fix": "yes, fix it", "dismissed": "no", "optional": "optional"][verdict] ?? "not decided")
        if f["fixed"].is(true) { out["fixed"] = true }
        return out
    }
    /// The label a reviewer sets once the code is approved.
    static let approvedLabel = "code-approved"
    /// Ready to merge: approved by its label, checks passed, no conflicts, not a draft, and not stacked on another pull
    /// request: in a stack only the bottom one, position 1, merges next.
    static func readyToMerge(_ pr: PullSummary, stack: StackPosition? = nil) -> Bool {
        // Its depth in the chain, as the board shows it; the header's position only when the chain does not name it.
        let depth: Int = stack.map { s in s.chain.first { $0.number == pr.number }?.depth ?? s.position } ?? 1
        let approved = pr.labels.contains { foldEqual($0.name, approvedLabel) }
        return approved && pr.checks == "success" && !pr.hasConflicts && !pr.draft && depth == 1
    }
    /// Where a pull request sits in its stack, in words, and the pull request under it; nil when it is not stacked.
    static func stacked(_ stack: StackPosition?, number: Int) -> (said: String, under: Int?)? {
        guard let stack, stack.total > 1 else { return nil }
        let depth = stack.chain.first { $0.number == number }?.depth ?? stack.position
        let under = stack.chain.first { $0.depth == depth - 1 }?.number
        let size = "\(stack.total)\(stack.partial ? " or more" : "")"
        guard depth > 1 else { return ("Bottom of a stack of \(size): it merges first.", nil) }
        let on = under.map { ", on top of #\($0)" } ?? ""
        return ("Position \(depth) of a stack of \(size)\(on): the pull requests under it merge first.", under)
    }
    /// Whether a conversation is one of the project's, by what `sessions` answered for it.
    static func owns(_ sessions: JSON, session id: String) -> Bool {
        (Session.parseList(sessions) ?? []).contains { $0.id == id }
    }
    /// A conversation as the model reads it.
    static func conversation(_ s: Session) -> JSON { conversation(s, events: []) }
    static func conversation(_ s: Session, events: [Event]) -> JSON {
        let asking = CarText.openQuestion(events)
        var out: JSON = ["session_id": .string(s.id), "title": .string(s.displayTitle),
                         "status": .string(CarText.status(s, asking: asking != nil))]
        if let pr = pullRequest(s) { out["pull_request"] = pr }
        if let asking {
            out["question"] = .string(CarText.question(asking))
            let options = CarText.options(asking)
            if !options.isEmpty { out["options"] = JSON(options) }
        }
        return out
    }
    /// A conversation's pull request as the server last synced it: its number, state and checks. A conversation started
    /// on a pull request the server has not synced yet has its number alone.
    static func pullRequest(_ s: Session) -> JSON? {
        guard let number = s.pullNumber else { return nil }
        let pr = s.raw["prStatus"]
        guard pr["number"].truncatedInt == number else { return ["number": JSON(number)] }
        var out: JSON = ["number": JSON(number), "state": .string(s.pullState)]
        if let title = pr["title"].nonEmpty { out["title"] = .string(CarText.inline(title)) }
        if pr["draft"].is(true) { out["draft"] = true }
        let checks = pr["checks"]
        if checks.isObject { out["checks"] = .string(CarText.checks(checks)) }
        return out
    }
    /// The last few things said in a conversation, oldest first, each cut short.
    static func latest(_ events: [Event], count: Int = 6, length: Int = 600) -> [JSON] {
        let said = events.filter { ["user", "text", "result", "ask"].contains($0.kind) && ($0.question ?? $0.text)?.isEmpty == false }
        return said.suffix(count).map { e in
            let who = e.kind == "user" ? "user" : "agent"
            return ["from": .string(who), "text": .string(cut(CarText.inline(e.question ?? e.text ?? ""), length))]
        }
    }
}

private extension String {
    var nonEmptyString: String? { isEmpty ? nil : self }
}

// MARK: - Merging

/// What merging a pull request takes, as the phone read it before the read-back.
enum VoiceMerge: Equatable, Sendable {
    case refuse(String)
    /// The `merge_pull` arguments, pinned to the head read now; the base it goes into; and what to read back.
    case ready(arguments: JSON, base: String, readBack: String)

    /// Reads `pull`'s answer, the first page of `pull_files` when there is one, and the board row when it is on the
    /// board: an open, non-draft pull request merges, with what stands in its way said first.
    static func check(number: Int, repo: String, pull: JSON, files: JSON?, row: PullSummary?, stack: StackPosition? = nil) -> VoiceMerge {
        let pr = pull["pr"], live = files?["pr"] ?? .null
        let state = pr["state"].string ?? "open"
        guard state == "open" else { return .refuse("Pull request #\(number) is already \(state).") }
        if pr["draft"].is(true) || row?.draft == true { return .refuse("Pull request #\(number) is a draft; it cannot merge until it is marked ready.") }
        guard let head = live["headSha"].string ?? pr["headSha"].string, let base = pr["baseRef"].string else {
            return .refuse("Pull request #\(number) could not be read.")
        }
        var notes = live.isObject ? mergeWarnings(mergeable: live["mergeable"], state: live["mergeableState"].string) : []
        let failed = pr["checks"]["failed"].truncatedInt ?? 0, pending = pr["checks"]["pending"].truncatedInt ?? 0
        if failed > 0 { notes.append("\(failed) check\(failed == 1 ? " is" : "s are") failing.") }
        if pending > 0 { notes.append("\(pending) check\(pending == 1 ? " is" : "s are") still running.") }
        if let row, !row.labels.contains(where: { foldEqual($0.name, Voice.approvedLabel) }) {
            notes.append("It does not carry the \(Voice.approvedLabel) label.")
        }
        if case .changesRequested = ReviewStatus(decision: row?.reviewDecision, reviews: pr["reviews"]) {
            notes.append("A reviewer has requested changes.")
        }
        if let stacked = Voice.stacked(stack, number: number), stacked.said.hasPrefix("Position") {
            notes.append("It is not ready: \(stacked.said)")
        }
        let method = CarText.mergeMethod(allowed: live["mergeMethods"].strings)
        let title = pr["title"].nonEmpty.map { ", \(CarText.inline($0))," } ?? ""
        let how = ["merge": "with a merge commit", "rebase": "rebased"][method] ?? "squashed"
        let readBack = (["Merge pull request #\(number)\(title) into \(base), \(how)."] + notes).joined(separator: " ")
        return .ready(arguments: ["repo": .string(repo), "pr": JSON(number), "headSha": .string(head), "baseRef": .string(base),
                                  "method": .string(method)], base: base, readBack: readBack)
    }
}
