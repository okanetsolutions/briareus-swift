import Foundation

/// One spoken conversation with ElevenLabs about one project: the ElevenLabs call, the captions, and the tools it calls,
/// each held to that project. It outlives the screen that started it, so it goes on from any tab and with the phone
/// locked, and ends when the user ends it or after a silence. What it cost and how long it ran are kept.
/// Opened from one of the project's conversations, it is held to that one: a hands-free line to its agent, which gets
/// what the user says word for word once they pause, and whose transcript it follows to tell its replies and questions.
@MainActor
final class VoiceSession: ObservableObject {
    static let shared = VoiceSession()

    enum Phase: Equatable { case off, connecting, live, closing }
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var user: Bool
        var text: String
    }
    /// A tool call, as the screen lists it.
    struct Step: Identifiable, Equatable {
        enum State: Equatable { case running, waiting, done, failed(String) }
        let id = UUID()
        var tool: VoiceTool?
        var name: String
        var args: JSON
        var state: State
    }

    @Published private(set) var phase = Phase.off
    /// The project the conversation is about; nil before the first one.
    @Published private(set) var repo: String?
    /// The one conversation of the project it is held to, hands-free; nil when it is about the whole project.
    @Published private(set) var conversation: VoiceConversation?
    /// The voice is saying something, as its transcript arrives.
    @Published private(set) var speaking = false
    @Published private(set) var muted = false
    @Published private(set) var lines: [Line] = []
    @Published private(set) var steps: [Step] = []
    @Published private(set) var started: Date?
    /// When the conversation ended; with `started`, how long it ran.
    @Published private(set) var finished: Date?
    /// What the conversation has cost so far, from elapsed ElevenAgents time; LLM charges are separate.
    @Published private(set) var cost = VoiceCost()
    /// Why the last conversation failed or ended by itself.
    @Published private(set) var notice: String?

    private var call: LiveCall?
    private var reader: Task<Void, Never>?
    private var pause: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastActivity = Date()
    /// How many pieces of the user's speech have been heard: a yes must come after the read-back it answers.
    private var heard = 0
    /// In-flight client tool calls, cancelled when the call ends.
    private var calls: [String: Task<Void, Never>] = [:]
    private var seenCalls: Set<String> = []
    /// The merges read back to the user, with how much had been heard at the time.
    private var readBacks: [String: Int] = [:]
    /// The merges read back, by the same key: the call pinned to the head the user heard about, and its base.
    private var merges: [String: (arguments: JSON, base: String)] = [:]
    /// A held conversation's transcript, followed: read through `cursor`, its news told through `told`, and the events
    /// not told yet. `held` is its record as last read.
    private var follower: Task<Void, Never>?
    private var cursor = 0, told = 0
    /// Whether what was said before the call is known; not until the first read when the call was opened unread.
    private var caughtUp = true
    private var untold: [Event] = []
    private var held: Session?
    /// A response is under way, or the user is speaking: news told now waits for the voice to be free.
    private var responding = false, userSpeaking = false
    /// News was told that no response has said yet.
    private var pendingNews: [String] = []
    private var owed = false
    /// What the user said to the held conversation's agent and was not sent yet: sent once they pause.
    private var dictation: [String] = []
    /// A response was asked for and has not started or failed yet; tool calls whose outputs are still to be sent.
    private var requested = false
    /// The voice is free to say news now: nothing it says or hears would be cut, and no tool output is still owed.
    private var free: Bool { !responding && !requested && !userSpeaking && calls.isEmpty }

    private init() {}

    var isOn: Bool { phase != .off }
    /// How long the conversation has run, or ran, at `now`.
    func elapsed(at now: Date = Date()) -> Double {
        guard let started else { return 0 }
        return (finished ?? now).timeIntervalSince(started)
    }

    /// What this conversation is about, as a screen names it.
    var about: String? { conversation?.title ?? repo }

    func start(_ project: Project, conversation held: VoiceConversation? = nil) {
        guard phase == .off else { return }
        notice = nil
        let settings = VoiceSettings.shared
        let key: String
        do {
            guard let saved = try settings.key() else { notice = "Add your ElevenLabs API key in Settings › Voice."; return }
            key = saved
        } catch { notice = error.localizedDescription; return }
        phase = .connecting
        repo = project.repo
        conversation = held
        lines = []; steps = []; heard = 0; calls = [:]; seenCalls = []; readBacks = [:]; merges = [:]; muted = false
        cursor = held?.cursor ?? 0; told = cursor; untold = []; self.held = nil; caughtUp = cursor > 0
        responding = false; userSpeaking = false; owed = false; pendingNews = []; requested = false; dictation = []
        started = nil; finished = nil
        cost = VoiceCost()
        let call = LiveCall()
        self.call = call
        let named = project.title == project.repo ? project.repo : "\(project.title) (\(project.repo))"
        let selectedVoice = settings.voice
        reader = Task { [weak self] in
            do {
                let events = try await call.open(key: key, voice: selectedVoice, project: named, held: held?.title)
                for try await event in events {
                    guard !Task.isCancelled, self?.call === call else { return }
                    self?.handle(event)
                }
                guard self?.call === call else { return }
                self?.ended(nil)
            } catch {
                guard self?.call === call else { return }
                self?.ended(errorText(error))
            }
        }
    }

    /// Hangs up: closing the ElevenLabs call ends the conversation.
    func stop(reason: String? = nil) {
        guard phase == .connecting || phase == .live else { return }
        if let reason { notice = reason }
        phase = .closing
        speaking = false
        ended(nil)
    }

    func toggleMute() {
        muted.toggle()
        guard let call else { return }
        let on = muted
        Task {
            do { try await call.mute(on) } catch { if self.call === call { self.stop(reason: errorText(error)) } }
        }
        // Muted mid-sentence, the speech may never be heard to stop: news waiting on it is said now.
        if muted && userSpeaking {
            userSpeaking = false
            dictate()
            if owed && free { respond() }
        }
    }

    private func ended(_ failure: String?) {
        guard phase != .off else { return }
        if let failure, phase != .closing { notice = failure }
        reader?.cancel(); reader = nil
        watchdog?.cancel(); watchdog = nil
        follower?.cancel(); follower = nil
        calls.values.forEach { $0.cancel() }; calls = [:]
        pause?.cancel(); pause = nil
        call?.close(); call = nil
        speaking = false
        if let started {
            cost.update(seconds: elapsed())
            let now = Date()
            finished = now
            VoiceHistory.shared.add(VoiceRecord(seconds: now.timeIntervalSince(started), dollars: cost.dollars, date: now))
        }
        phase = .off
    }

    private func touch() { lastActivity = Date() }

    // MARK: Events

    private func handle(_ event: LiveCall.Event) {
        switch event {
        case .ready:
            guard phase == .connecting else { return }
            phase = .live
            started = Date()
            touch()
            watch()
            if conversation != nil { follow() }
        case .heard(let text):
            heard += 1
            caption(user: true, lines.last?.user == true ? " " + text : text)
            touch()
            if conversation != nil { dictation.append(text); scheduleDictation() }
        case .said(let text):
            caption(user: false, lines.last?.user == false ? " " + text : text)
            requested = false
            touch()
        case .agent(let talking, let busy):
            speaking = talking; responding = busy
            if !busy { requested = false }
            if !busy && owed && free { respond() }
        case .activity(let on):
            guard userSpeaking != on else { return }
            userSpeaking = on
            if on { touch(); pause?.cancel() }
            else if conversation != nil && !dictation.isEmpty { scheduleDictation() }
            if !on && owed && free { respond() }
        case .tool(let id, let name, let args):
            called(id: id, name: name, args: args)
        }
    }

    private func scheduleDictation() {
        pause?.cancel()
        pause = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(Voice.heldPauseMilliseconds)) } catch { return }
            self?.dictate()
        }
    }

    /// Ends the conversation after the silence the settings allow, as ElevenLabs bills conversation time.
    private func watch() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.phase == .live else { continue }
                self.cost.update(seconds: self.elapsed())
                if self.speaking || !self.calls.isEmpty { self.touch(); continue }
                let minutes = VoiceSettings.shared.idleMinutes
                if minutes > 0, Date().timeIntervalSince(self.lastActivity) > Double(minutes * 60) {
                    self.stop(reason: "Ended after \(minutes) minute\(minutes == 1 ? "" : "s") of silence.")
                }
            }
        }
    }

    private func caption(user: Bool, _ delta: String?) {
        guard let delta, !delta.isEmpty else { return }
        if let last = lines.last, last.user == user {
            lines[lines.count - 1].text += delta
        } else {
            lines.append(Line(user: user, text: delta.trimmingCharacters(in: .whitespaces)))
            if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        }
    }

    // MARK: Tools

    /// Client tools keep the existing project ownership, permissions and merge read-back checks.
    private func called(id: String, name: String, args: JSON) {
        guard seenCalls.insert(id).inserted, let call else { return }
        let tool = VoiceTool(rawValue: name)
        let args = conversation.flatMap { held in tool.map { Voice.holding(args, $0, to: held.id, pull: self.held?.pullNumber) } } ?? args
        let step = Step(tool: tool, name: name, args: args, state: .running)
        steps.append(step)
        touch()
        calls[id] = Task {
            let output = await self.run(step)
            guard !Task.isCancelled, self.call === call else { return }
            do { try await call.answer(id: id, output: output) }
            catch { self.stop(reason: errorText(error)); return }
            guard self.call === call else { return }
            self.calls[id] = nil
            if self.owed && self.free { self.respond() }
        }
    }

    // MARK: The held conversation

    /// Reads the held conversation's transcript after what was read, as its screen does: often while the agent works,
    /// less once it waits. It goes on with the phone locked, as the call keeps the app running.
    private func follow() {
        follower = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let id = self.conversation?.id, self.phase == .live else { return }
                var delay = 5.0
                if let answer = try? await Store.shared.call("session", ["sessionId": .string(id), "since": JSON(self.cursor)]) {
                    guard !Task.isCancelled, self.phase == .live else { return }
                    self.followed(answer)
                    delay = self.held.map(conversationPollInterval) ?? delay
                }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func followed(_ answer: JSON) {
        if let session = Session(answer["session"]) {
            held = session
            // A user waiting on a working agent is not silent: the call stays up while it works.
            if session.isActive { touch() }
        }
        var events = answer["events"].items.compactMap(Event.init).filter { $0.seq > told }
        if let last = events.map(\.seq).max(), last > cursor { cursor = last }
        // Opened before its transcript was read, the turns the first read finished were said before the call; one still
        // going on is news when it ends.
        if !caughtUp {
            caughtUp = true
            told = events.filter { $0.kind == "result" || $0.kind == "ask" }.map(\.seq).max() ?? 0
        }
        events.removeAll { $0.seq <= told }
        untold += events
        if untold.count > 400 { untold.removeFirst(untold.count - 400) }
        guard let news = Voice.agentNews(untold, after: told) else { return }
        told = news.through
        untold.removeAll { $0.seq <= told }
        tell(news.said)
    }

    /// Puts the agent's news into the conversation and has the voice say it once it is free.
    private func tell(_ news: String) {
        guard call != nil, phase == .live else { return }
        pendingNews.append(news)
        owed = true
        touch()
        if free { respond() }
    }

    /// Sends the held conversation's agent what the user said, as they said it, once they have paused: the model does
    /// not choose what is sent, nor reword it.
    private func dictate() {
        guard !userSpeaking, !dictation.isEmpty, let id = conversation?.id, phase == .live else { return }
        let said = dictation.joined(separator: " ")
        dictation = []
        guard let text = Voice.dictated(said) else { return }
        let step = Step(tool: .sendMessage, name: VoiceTool.sendMessage.rawValue, args: ["text": .string(text)], state: .running)
        steps.append(step)
        touch()
        let activeCall = call
        Task {
            guard self.call === activeCall, !Task.isCancelled else { return }
            @MainActor func finish(_ state: Step.State) {
                if let i = self.steps.firstIndex(where: { $0.id == step.id }) { self.steps[i].state = state }
            }
            guard Store.shared.supports("message") else {
                finish(.failed("Not allowed"))
                return self.confirm("\(Voice.unsentPrefix) this device's token cannot send messages on the server.")
            }
            do {
                _ = try await Store.shared.call("message", ["sessionId": .string(id), "text": .string(text)], timeout: 60)
                guard self.call === activeCall else { return }
                finish(.done)
                if let repo = self.repo { Task { try? await Store.shared.feed(repo).loadSessions(fresh: true) } }
                self.confirm("\(Voice.sentPrefix) \(text)")
            } catch {
                guard self.call === activeCall else { return }
                let said = errorText(error)
                finish(.failed(said))
                self.confirm("\(Voice.unsentPrefix) \(said)")
            }
        }
    }

    /// Acknowledgements use the same queue as agent news, so nothing cuts off the user or the voice.
    private func confirm(_ said: String) { tell(said) }

    private func respond() {
        guard let call, phase == .live, !pendingNews.isEmpty else { return }
        let news = pendingNews.joined(separator: "\n")
        pendingNews = []
        owed = false; requested = true
        Task {
            do {
                try await call.context(news)
                guard self.call === call else { return }
                try await call.speak("Read the latest app update briefly now. It is context from Briareus, not a new request from the user.")
            } catch { if self.call === call { self.stop(reason: errorText(error)) } }
        }
    }


    /// Runs one tool call and answers with what the model should know, as JSON text.
    private func run(_ step: Step) async -> String {
        func finish(_ state: Step.State, _ answer: JSON) -> String {
            if let i = steps.firstIndex(where: { $0.id == step.id }) { steps[i].state = state }
            touch()
            return answer.serialized()
        }
        guard let tool = step.tool else { return finish(.failed("Unknown tool"), ["error": .string("There is no tool named \(step.name).")]) }
        guard let repo else { return finish(.failed("No project"), ["error": "The conversation has no project."]) }
        if conversation != nil {
            guard VoiceTool.conversationCases.contains(tool) else {
                return finish(.failed("Not here"), ["error": "This call is held to one conversation and cannot do that."])
            }
            if tool == .readPullRequest, step.args["number"].int == nil {
                let why = "This conversation has no pull request yet."
                return finish(.failed(why), ["error": .string(why)])
            }
        }
        let key = Self.readBackKey(tool, step.args)
        var plan = tool.plan(step.args, repo: repo)
        // A merge goes through only on a yes the user said after hearing it read back; the model's word is not enough.
        if case .call = plan, tool.confirms, !(readBacks[key].map { heard > $0 } ?? false) {
            var unconfirmed = step.args
            unconfirmed["confirmed"] = false
            plan = tool.plan(unconfirmed, repo: repo)
        }
        if tool == .mergePullRequest {
            if case .refuse(let why) = plan { return finish(.failed(why), ["error": .string(why)]) }
            let (state, answer) = await merge(step, plan: plan, key: key, repo: repo)
            return finish(state, answer)
        }
        switch plan {
        case .refuse(let why):
            return finish(.failed(why), ["error": .string(why)])
        case .confirm(let readBack):
            readBacks[key] = heard
            return finish(.waiting, ["needs_confirmation": true, "read_back": .string(readBack),
                                     "next": "Read this back to the user. Call again with confirmed=true only if they say yes."])
        case .call(var arguments):
            // An errand's call is the board's own: `review` for a code review, `action` for the rest.
            let operation = tool == .runErrand ? (Voice.errand(step.args["errand"].string ?? "")?.operation ?? tool.operation) : tool.operation
            guard Store.shared.supports(operation) else {
                return finish(.failed("Not allowed"), ["error": "This device's token cannot do that on the server."])
            }
            do {
                // A conversation named by id is acted on only when it is the project's.
                if tool.namesConversation, let id = arguments["sessionId"].string,
                   !Voice.owns(try await Store.shared.call("sessions", ["repo": .string(repo)]), session: id) {
                    let why = "That conversation is not one of this project's."
                    return finish(.failed(why), ["error": .string(why)])
                }
                if tool == .runErrand, operation == "review", let number = arguments["prNumber"].int {
                    // A code review checks the pull request's branch out, read from the board.
                    let board = try await Store.shared.call("pulls", ["repo": .string(repo)])
                    guard let row = PullSummary.parseList(board["pulls"]).first(where: { $0.number == number }), !row.branch.isEmpty else {
                        let why = "Pull request #\(number) is not open on this project."
                        return finish(.failed(why), ["error": .string(why)])
                    }
                    arguments["branch"] = .string(row.branch)
                }
                if tool == .completeReviewRound, let id = arguments["sessionId"].string {
                    // The verdicts are made from the round as it is now, so a finding added meanwhile stays optional.
                    let sessions = Session.parseList(try await Store.shared.call("sessions", ["repo": .string(repo)])) ?? []
                    guard let held = sessions.first(where: { $0.id == id })?.heldTriage else {
                        let why = "That conversation holds no review round waiting for a decision."
                        return finish(.failed(why), ["error": .string(why)])
                    }
                    var completion: JSON = ["sessionId": .string(id)]
                    completion.merge(Voice.roundCompletion(held, fix: arguments["fix"].strings, dismiss: arguments["dismiss"].strings,
                                                           note: arguments["note"].string))
                    arguments = completion
                }
                if tool == .workOnIssue, let number = arguments["issue"].int {
                    let board = try await Store.shared.call("pulls", ["repo": .string(repo)])
                    guard let start = Voice.issueStart(board, number: number, repo: repo) else {
                        let why = "Issue #\(number) is not open on this project."
                        return finish(.failed(why), ["error": .string(why)])
                    }
                    arguments = start
                }
                var answer = try await Store.shared.call(operation, arguments, timeout: 60)
                // A pull request's description is read apart from its files.
                if tool == .readPullRequest, Store.shared.supports("pull_description"),
                   let body = (try? await Store.shared.call("pull_description", arguments))?["pr"]["body"].string {
                    answer["description"] = .string(body)
                }
                // An issue's comments are on its timeline, oldest first: its pages are read up to a few, for the latest.
                if tool == .readIssue, Store.shared.supports("issue_timeline") {
                    var rows: [JSON] = [], read = arguments
                    read["page"] = 1
                    var cut = false
                    for page in 0..<Voice.issueTimelinePages {
                        guard let timeline = try? await Store.shared.call("issue_timeline", read, timeout: 60) else { break }
                        rows += timeline["events"].items
                        guard let next = timeline["nextPage"].int else { break }
                        // Pages remain past the last one read: the comments read are not the latest.
                        if page == Voice.issueTimelinePages - 1 { cut = true }
                        read["page"] = JSON(next)
                    }
                    answer["timeline"] = .array(rows)
                    if cut { answer["timeline_cut"] = true }
                }
                let sessions = tool.readsConversations
                    ? (try? await Store.shared.call("sessions", ["repo": .string(repo)])).flatMap(Session.parseList) ?? []
                    : []
                readBacks[key] = nil
                if tool == .deleteConversation, let id = arguments["sessionId"].string {
                    Store.shared.cache.remove("transcript:\(id)")
                    Store.shared.feed(repo).drop(id)
                }
                if tool.changes || tool == .decideFinding { Task { try? await Store.shared.feed(repo).loadSessions(fresh: true) } }
                return finish(.done, tool.summary(answer, args: step.args, sessions: sessions))
            } catch {
                let said = errorText(error)
                return finish(.failed(said), ["error": .string(said)])
            }
        }
    }

    /// Merges a pull request: the first call reads it and reads back what stands in the way; the confirmed one merges
    /// the head the user heard about, so a push in between makes GitHub refuse it.
    private func merge(_ step: Step, plan: VoicePlan, key: String, repo: String) async -> (Step.State, JSON) {
        guard Store.shared.supports("merge_pull"), Store.shared.supports("pull") else {
            return (.failed("Not allowed"), ["error": "This device's token cannot merge pull requests on the server."])
        }
        guard let number = step.args["number"].int else { return (.failed("No number"), ["error": "number is missing."]) }
        do {
            if case .call = plan, let held = merges[key] {
                let answer = try await Store.shared.call("merge_pull", held.arguments, timeout: 60)
                readBacks[key] = nil; merges[key] = nil
                Task {
                    try? await Store.shared.feed(repo).loadBoard(fresh: true)
                    try? await Store.shared.feed(repo).loadSessions(fresh: true)
                }
                var args = step.args
                args["base"] = .string(held.base)
                return (.done, VoiceTool.mergePullRequest.summary(answer, args: args))
            }
            let place: JSON = ["repo": .string(repo), "pr": JSON(number)]
            let pull = try await Store.shared.call("pull", place)
            let files = Store.shared.supports("pull_files") ? try? await Store.shared.call("pull_files", place) : nil
            let board = Store.shared.supports("pulls") ? try? await Store.shared.call("pulls", ["repo": .string(repo)]) : nil
            let row = PullSummary.parseList(board?["pulls"] ?? .null).first { $0.number == number }
            let stack = row.flatMap { StackPosition($0.raw["stack"], stacks: board?["stacks"] ?? .null) }
            switch VoiceMerge.check(number: number, repo: repo, pull: pull, files: files, row: row, stack: stack) {
            case .refuse(let why):
                return (.failed(why), ["error": .string(why)])
            case .ready(let arguments, let base, let readBack):
                readBacks[key] = heard
                merges[key] = (arguments, base)
                return (.waiting, ["needs_confirmation": true, "read_back": .string(readBack),
                                   "next": "Read all of this to the user. Call again with confirmed=true only if they say yes."])
            }
        } catch {
            let said = errorText(error)
            return (.failed(said), ["error": .string(said)])
        }
    }

    /// The same change asked twice: the tool, what it acts on, its verdicts, and its words without case, spacing or punctuation.
    static func readBackKey(_ tool: VoiceTool, _ args: JSON) -> String {
        let words = { (s: String?) in
            (s ?? "").lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        // Built a part at a time: one expression of them all is too much for the type checker of older Xcodes.
        var parts: [String] = [tool.rawValue]
        parts.append(args["session_id"].string ?? "")
        parts.append(args["branch"].string ?? "")
        parts.append(args["issue"].int.map(String.init) ?? "")
        parts.append(args["number"].int.map(String.init) ?? "")
        parts.append(args["errand"].string ?? "")
        parts.append(args["key"].string ?? "")
        parts.append(args["decision"].string ?? "")
        parts.append(args["fix"].strings.sorted().joined(separator: ","))
        parts.append(args["dismiss"].strings.sorted().joined(separator: ","))
        parts.append(words(args["text"].string ?? args["prompt"].string))
        return parts.joined(separator: "|")
    }
}
