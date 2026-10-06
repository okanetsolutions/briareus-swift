// The meeting assistant (the Windows client's app/meeting.c): one meeting at a time, joined from a project, held by an
// ElevenLabs agent speaking in the user's voice, which looks the project up with read-only tools (its conversations, pull
// requests, findings and issues). It runs on until left, whatever screen is shown. Its settings and the ElevenLabs API
// key are this Mac's, and every meeting is recorded here with its time and cost.
import AppKit
import Foundation

// MARK: - The API key

/// The ElevenLabs API key, in this Mac's keychain beside the device token.
@MainActor
enum MeetingKey {
    private static let account = "elevenlabs"
    static func read() throws -> String? { try Keychain.read(account, service: Keychain.meeting) }
    static func save(_ key: String) throws { try Keychain.save(key, origin: account, service: Keychain.meeting) }
    @discardableResult static func remove() -> Bool { Keychain.remove(account, service: Keychain.meeting) }
    /// Whether a key is saved, without keeping it.
    static var saved: Bool { ((try? read()) ?? nil).map { !$0.isEmpty } ?? false }
}

// MARK: - Settings

/// Who the assistant speaks for and how, kept in this Mac's defaults.
struct MeetingSettings: Equatable {
    /// Who the assistant speaks for.
    var name: String
    /// What makes an addressed assistant answer.
    var wakeWords: String
    /// The ElevenLabs voice ID it speaks with.
    var elevenVoice: String
    /// It says who it is as it joins.
    var introduce: Bool
    /// It takes part on its own.
    var independent: Bool
    /// The system prompt the user wrote, with placeholders; empty for the default.
    var prompt: String
    /// What it says as it joins, as the user wrote it; nil for the default.
    var firstMessage: String?
    /// The output device its voice plays into, by Core Audio UID; empty for the virtual cable found.
    var outputDevice: String

    private enum Key {
        static let name = "meeting.name", wake = "meeting.wakeWords", voice = "meeting.elevenVoice", introduce = "meeting.introduce"
        static let independent = "meeting.independent", prompt = "meeting.prompt", first = "meeting.firstMessage", output = "meeting.outputDevice"
    }

    /// This Mac's user's full name, the name's default.
    static var defaultName: String { NSFullUserName().isEmpty ? NSUserName() : NSFullUserName() }

    static func load() -> MeetingSettings {
        let d = UserDefaults.standard
        let name = d.string(forKey: Key.name).flatMap { $0.isEmpty ? nil : $0 } ?? defaultName
        return MeetingSettings(name: name, wakeWords: d.string(forKey: Key.wake) ?? "\(name), assistant, Briareus",
                               elevenVoice: d.string(forKey: Key.voice) ?? "",
                               introduce: d.object(forKey: Key.introduce) as? Bool ?? true,
                               independent: d.object(forKey: Key.independent) as? Bool ?? false,
                               prompt: d.string(forKey: Key.prompt) ?? "", firstMessage: d.string(forKey: Key.first),
                               outputDevice: d.string(forKey: Key.output) ?? "")
    }
    func save() {
        let d = UserDefaults.standard
        d.set(name, forKey: Key.name); d.set(wakeWords, forKey: Key.wake); d.set(elevenVoice, forKey: Key.voice)
        d.set(introduce, forKey: Key.introduce); d.set(independent, forKey: Key.independent); d.set(prompt, forKey: Key.prompt)
        if let firstMessage { d.set(firstMessage, forKey: Key.first) } else { d.removeObject(forKey: Key.first) }
        d.set(outputDevice, forKey: Key.output)
    }
}

// MARK: - History

/// Every meeting recorded on this Mac, one MeetRecord.json a line.
enum MeetingHistory {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Okanet/Briareus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meetings.jsonl")
    }
    /// Oldest first.
    static func all() -> [JSON] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSON.parse(String($0)) }.filter(\.isObject)
    }
    static func append(_ record: MeetRecord) {
        let line = Data((record.json.serialized() + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

// MARK: - The meeting

@MainActor
final class Meeting: ObservableObject {
    static let shared = Meeting()

    enum State { case off, connecting, live, leaving }

    @Published private(set) var state = State.off
    @Published private(set) var muted = false
    /// The project the meeting is about, and the app it listens to.
    @Published private(set) var repo: String?
    @Published private(set) var source = ""
    /// An error after the conversation started, or a note: shown on the status line.
    @Published private(set) var note: String?
    /// The meeting so far, and the project it is about, kept after the meeting for its transcript.
    @Published private(set) var log = MeetLog()
    @Published private(set) var logRepo: String?
    /// Whether an ElevenLabs API key is saved, for the settings sidebar's row.
    @Published private(set) var hasKey = false
    /// Ticks every second of a meeting, so its time and cost on the header move.
    @Published private(set) var tick = 0

    /// How long a board read may take, within the 120 s the agent waits for a tool.
    private static let boardTimeout: TimeInterval = 110

    private var gen = 0
    private var ready = false
    private var settings = MeetingSettings.load()
    private var title = ""
    private var audio: MeetAudio?
    private var socket: URLSessionWebSocketTask?
    private var sender: DispatchSourceTimer?
    private var timer: Timer?
    private var connecting: Task<Void, Never>?
    private var record = MeetRecord(model: .agent)
    private var joined = Date()
    /// The tool calls under way, by their call id.
    @Published private var lookups: [String: Task<Void, Never>] = [:]
    private let session = URLSession(configuration: .default)

    private init() {
        hasKey = MeetingKey.saved
        // The app quits: the meeting is left at once.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Meeting.shared.leave() }
        }
    }

    func keyChanged() { hasKey = MeetingKey.saved }

    /// Whether the meeting is about this project.
    func isFor(_ repo: String) -> Bool { state != .off && self.repo == repo }

    // MARK: Joining

    /// Joins a meeting about `repo` (called `title` aloud) with the ElevenLabs agent, listening to `app` (nil: every app
    /// but Briareus). Says why in an alert when it cannot start.
    func join(repo: String, title: String, app: MeetApp?) {
        guard state == .off else { Dialogs.alert("Meeting assistant", "A meeting is already running. Leave it first."); return }
        let settings = MeetingSettings.load()
        guard !settings.elevenVoice.isEmpty else {
            Dialogs.alert("Meeting assistant", "Add your ElevenLabs voice ID first: ⚙ Settings → Meeting assistant."); return
        }
        let key: String
        do {
            guard let saved = try MeetingKey.read(), !saved.isEmpty else {
                Dialogs.alert("Meeting assistant", "Add your ElevenLabs API key first: ⚙ Settings → Meeting assistant."); return
            }
            key = saved
        } catch {
            Dialogs.alert("Meeting assistant", "The ElevenLabs API key could not be read from the keychain."); return
        }
        guard let device = MeetDevices.chosen(settings.outputDevice) else {
            Dialogs.alert("Meeting assistant", settings.outputDevice.isEmpty
                ? "The virtual microphone was not found. Install BlackHole 2ch (free, from existential.audio), then pick “BlackHole 2ch” as the microphone in your meeting app."
                : "The output device chosen in ⚙ Settings → Meeting assistant is not connected.")
            return
        }
        self.settings = settings
        self.repo = repo
        self.title = title == repo ? title : "\(title) (\(repo))"
        source = app?.label ?? "every app"
        record = MeetRecord(model: .agent, started: Date().timeIntervalSince1970)
        muted = false; ready = false; note = nil
        log = MeetLog(); logRepo = repo
        state = .connecting
        MeetingDebug.open()
        let persona = MeetPersona(name: settings.name, wakeWords: settings.wakeWords, project: self.title, voice: settings.elevenVoice,
                                  introduce: settings.introduce, independent: settings.independent, prompt: settings.prompt,
                                  firstMessage: settings.firstMessage)
        let gen = self.gen
        connecting = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await MeetAudio.start(app: app, device: device)
                guard gen == self.gen, self.state == .connecting else { audio.stop(); return }
                self.audio = audio
                audio.onStopped = { [weak self] why in Task { @MainActor in self?.ended(gen, error: why) } }
                let agent = try await self.agentReady(key: key, persona: persona)
                guard gen == self.gen, self.state == .connecting else { return }
                try await self.connect(agent: agent, key: key, gen: gen)
            } catch {
                guard gen == self.gen else { return }
                self.finish((error as? MeetFailure)?.text ?? (error as? MeetAudioError)?.text ?? error.localizedDescription)
            }
        }
    }

    func leave() { if state != .off { finish(nil) } }

    /// Readies the agent, then opens its conversation and reads it. A private agent's conversation opens on a signed URL;
    /// should that fail, on the key in a header.
    private func connect(agent: String, key: String, gen: Int) async throws {
        var path: String?
        if let answer = try? await eleven("GET", "/v1/convai/conversation/get-signed-url?agent_id=\(agent)", nil, key: key).answer {
            path = Meet.signedWSPath(answer)
        }
        let signed = path != nil
        var request = URLRequest(url: URL(string: "wss://\(Meet.host)\(path ?? Meet.agentWSPath(agent))")!)
        if !signed { request.setValue(key, forHTTPHeaderField: "xi-api-key") }
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 16 << 20
        socket.resume()
        guard gen == self.gen, state == .connecting else { socket.cancel(with: .normalClosure, reason: nil); return }
        self.socket = socket
        MeetingDebug.write("connect", signed ? "signed url" : "key header")
        send(Meet.startEvent)
        guard let audio else { return }
        Task.detached { [self] in await Self.read(socket, audio: audio, gen: gen, to: self) }
    }

    /// The socket's reader: speech goes straight to the virtual microphone and pings are answered here, everything else
    /// goes to the main actor.
    private nonisolated static func read(_ socket: URLSessionWebSocketTask, audio: MeetAudio, gen: Int, to meeting: Meeting) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() } catch {
                await meeting.ended(gen, error: "ElevenLabs: \(error.localizedDescription)")
                return
            }
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            guard let event = MeetEvent(text) else { continue }
            switch event {
            case .audio(let pcm): audio.play(pcm); continue
            case .ping(let id): socket.send(.string(Meet.pongEvent(id))) { _ in }; continue
            case .interrupted: audio.flush()
            default: break
            }
            MeetingDebug.write("recv", text)
            await meeting.received(event, gen: gen)
        }
    }

    private func send(_ event: String) {
        guard let socket else { return }
        if !event.contains("user_audio_chunk") { MeetingDebug.write("send", event) }
        socket.send(.string(event)) { _ in }
    }

    // MARK: Events

    private func received(_ event: MeetEvent, gen: Int) {
        guard gen == self.gen, state != .off else { return }
        switch event {
        case .ready: onReady()
        case .heardTurn(let text): log.line(.meeting, text)
        case .said(let text): log.line(.assistant, text)
        case .tool(let id, let name, let parameters): onTool(id: id, name: name, parameters: parameters)
        case .error(let text):
            // Before the conversation started an error ends it; later ones only show.
            if !ready { finish(text) } else { note = text }
        default: break
        }
    }

    private func onReady() {
        guard !ready, state == .connecting, let socket, let audio else { return }
        ready = true
        state = .live
        joined = Date()
        sender = Self.sending(audio, on: socket) { [weak self, gen] in Task { @MainActor in self?.ended(gen, error: "ElevenLabs: the audio could not be sent.") } }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick += 1 } }
    }

    /// The meeting's sender: what the assistant hears, at the pace it was heard, every 100 ms.
    private nonisolated static func sending(_ audio: MeetAudio, on socket: URLSessionWebSocketTask, failed: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.okanetsolutions.briareus.meeting.sender"))
        let pace = SenderPace()
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler {
            let n = pace.due()
            guard n > 0 else { return }
            socket.send(.string(Meet.audioEvent(audio.takeInput(n)))) { error in
                if error != nil && pace.stop() { failed() }
            }
        }
        timer.resume()
        return timer
    }

    /// The socket or the capture ended: the meeting ends, saying why unless it was being left.
    private func ended(_ gen: Int, error: String) {
        guard gen == self.gen, state != .off else { return }
        finish(state == .leaving ? nil : error)
    }

    /// Ends the meeting: the sender stopped, the socket closed, the devices closed, the record saved when it got going,
    /// and `error` shown.
    private func finish(_ error: String?) {
        guard state != .off else { return }
        let wasLive = ready
        state = .off
        gen += 1
        connecting?.cancel(); connecting = nil
        sender?.cancel(); sender = nil
        timer?.invalidate(); timer = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        audio?.onStopped = nil
        audio?.stop(); audio = nil
        for task in lookups.values { task.cancel() }
        lookups = [:]
        if wasLive {
            record.seconds = Date().timeIntervalSince(joined)
            record.usage.seconds = record.seconds
            MeetingHistory.append(record)
        }
        repo = nil; source = ""; note = nil; ready = false
        if let error { Dialogs.alert("Meeting assistant", wasLive ? "The meeting ended: \(error)" : error) }
    }

    // MARK: Controls

    func setMuted(_ on: Bool) { muted = on; audio?.muted = on }
    /// Asks the assistant to answer what was just said.
    func answerNow() { if state == .live { send(Meet.answerNowEvent) } }

    /// "🎙 ElevenLabs agent · Zoom · 3:12 · $0.256 · listening", for the project's header.
    var status: String {
        guard state != .off else { return "" }
        _ = tick
        var s = "🎙 \(MeetModel.agent.label) · \(source)"
        if state == .connecting { s += " · connecting…" } else {
            let secs = Int(Date().timeIntervalSince(joined))
            s += String(format: " · %d:%02d · $%.3f", secs / 60, secs % 60, MeetUsage(seconds: Double(secs)).cost(.agent))
            s += muted ? " · muted" : !lookups.isEmpty ? " · looking it up…" : audio?.speaking == true ? " · speaking" : " · listening"
        }
        if let note { s += " · \(note)" }
        return s
    }
    /// The transcript of the meeting about `repo`, running or the last one left; nil when there is none.
    func transcript(for repo: String) -> String? {
        guard logRepo == repo else { return nil }
        let t = log.tail(1 << 20)
        return t.isEmpty && !isFor(repo) ? nil : t
    }

    // MARK: The project's tools

    private func onTool(id: String, name: String, parameters: JSON) {
        record.requests += 1
        log.line(.lookup, name)
        let asked = Date()
        guard let repo, let tool = MeetTool(rawValue: name) else {
            answer(id, MeetTool.error("No such tool: only the project's read-only tools are offered."), asked: asked); return
        }
        let plan = tool.calls(parameters, repo: repo)
        if plan.calls.isEmpty { answer(id, plan.refusal ?? MeetTool.error("Nothing to read."), asked: asked); return }
        let store = Store.shared
        guard store.supports(plan.calls[0].op) else {
            answer(id, MeetTool.error("This device's token cannot read that on the server."), asked: asked); return
        }
        let gen = self.gen
        lookups[id] = Task { [weak self] in
            // The calls are made together; only the first one's answer is needed.
            let results = await withTaskGroup(of: (Int, Result<JSON, Error>?).self) { group in
                for (i, call) in plan.calls.enumerated() {
                    group.addTask { @MainActor in
                        guard store.supports(call.op) else { return (i, nil) }
                        // A large project's board takes GitHub a while to read: the one the project screen last synced
                        // answers at once.
                        let board = call.op == "pulls"
                        if board, let saved = store.cache.value("pulls:\(repo)") { return (i, .success(saved)) }
                        do {
                            let value = try await store.call(call.op, call.args, timeout: board ? Self.boardTimeout : nil)
                            // The board read for a meeting is the project screen's too.
                            if board { store.cache.store(value, "pulls:\(repo)") }
                            return (i, .success(value))
                        } catch { return (i, .failure(error)) }
                    }
                }
                var out = [Result<JSON, Error>?](repeating: nil, count: plan.calls.count)
                for await (i, r) in group { out[i] = r }
                return out
            }
            guard let self, gen == self.gen, !Task.isCancelled else { return }
            let output: String
            if case .failure(let e)? = results.first ?? nil {
                output = MeetTool.error(errorText(e))
            } else {
                // A later call that failed is left out.
                output = tool.summary(parameters, repo: repo, answers: results.map { r -> JSON? in
                    if case .success(let v)? = r { return v }
                    return nil
                })
            }
            self.answer(id, output, asked: asked)
        }
    }

    private func answer(_ id: String, _ output: String, asked: Date) {
        send(Meet.toolResultEvent(callID: id, result: output, isError: output.hasPrefix(#"{"error""#)))
        record.answers += 1
        record.answerSeconds += Date().timeIntervalSince(asked)
        lookups[id] = nil
    }

    // MARK: The agent in ElevenLabs

    /// One call to ElevenLabs' REST API: the answer's JSON and its status, or why it failed.
    private func eleven(_ method: String, _ path: String, _ body: JSON?, key: String) async throws -> (answer: JSON?, status: Int) {
        var request = URLRequest(url: URL(string: "https://\(Meet.host)\(path)")!, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body.data }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw MeetFailure(text: "ElevenLabs could not be reached: \(error.localizedDescription)", status: 0)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        MeetingDebug.write("rest", "\(method) \(path) -> \(status)")
        let answer = JSON.parse(data)
        guard (200..<300).contains(status) else {
            // ElevenLabs says why in detail.message or detail.
            let detail = answer?["detail"] ?? .null
            let message = detail["message"].nonEmpty ?? detail.nonEmpty ?? detail[0]["msg"].nonEmpty
            throw MeetFailure(text: status == 401 ? "ElevenLabs refused the API key."
                                                  : "ElevenLabs answered HTTP \(status)\(message.map { ": \($0)" } ?? ".")", status: status)
        }
        return (answer, status)
    }

    /// FNV-1a over the tools' bodies: a change of tools updates them in ElevenLabs once.
    private static func toolsVersion(_ bodies: [String]) -> String {
        var h: UInt64 = 1469598103934665603
        for body in bodies { for c in body.utf8 { h ^= UInt64(c); h = h &* 1099511628211 } }
        return String(format: "%016llx", h)
    }

    /// Creates or brings up to date the project's tools and the agent in the user's workspace; the agent's id. The ids
    /// are kept in the defaults, so a meeting usually updates only the agent.
    private func agentReady(key: String, persona: MeetPersona) async throws -> String {
        let d = UserDefaults.standard
        let bodies = MeetTool.allCases.map { $0.body.serialized() }
        let version = Self.toolsVersion(bodies)
        let current = d.string(forKey: "meeting.elevenToolsVersion") == version
        let savedIDs = d.string(forKey: "meeting.elevenTools").flatMap(JSON.parse) ?? [:]
        var ids: [String] = []
        for (tool, body) in zip(MeetTool.allCases, bodies) {
            let saved = savedIDs[tool.name].nonEmpty
            if let saved, current { ids.append(saved); continue }
            var id: String?
            if let saved {
                do { _ = try await eleven("PATCH", "/v1/convai/tools/\(saved)", JSON.parse(body), key: key); id = saved }
                // A tool deleted in ElevenLabs is made again.
                catch let e as MeetFailure where e.status == 404 {}
            }
            if id == nil {
                let made = try await eleven("POST", "/v1/convai/tools", JSON.parse(body), key: key)
                guard let made = made.answer.flatMap(Meet.createdID) else { throw MeetFailure(text: "ElevenLabs did not say the new tool's id.") }
                id = made
            }
            ids.append(id!)
        }
        var map: JSON = [:]
        for (tool, id) in zip(MeetTool.allCases, ids) { map[tool.name] = .string(id) }
        d.set(map.serialized(), forKey: "meeting.elevenTools")
        d.set(version, forKey: "meeting.elevenToolsVersion")
        let body = Meet.agentBody(persona, toolIDs: ids)
        if let saved = d.string(forKey: "meeting.elevenAgent"), !saved.isEmpty {
            do { _ = try await eleven("PATCH", "/v1/convai/agents/\(saved)", body, key: key); return saved }
            catch let e as MeetFailure where e.status == 404 {}
        }
        let made = try await eleven("POST", "/v1/convai/agents/create", body, key: key)
        guard let agent = made.answer.flatMap(Meet.createdID) else { throw MeetFailure(text: "ElevenLabs did not say the new agent's id.") }
        d.set(agent, forKey: "meeting.elevenAgent")
        return agent
    }
}

/// The sender's count of what it sent since the meeting started, so it sends what was heard at the pace it was heard.
private final class SenderPace: @unchecked Sendable {
    private let lock = NSLock()
    private let start = DispatchTime.now().uptimeNanoseconds
    private var sent: UInt64 = 0
    private var stopped = false

    /// The samples due now, at most a second's; none once stopped.
    func due() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return 0 }
        let due = (DispatchTime.now().uptimeNanoseconds - start) * UInt64(Meet.sampleRate) / 1_000_000_000
        let n = min(due > sent ? due - sent : 0, UInt64(Meet.sampleRate))
        sent += n
        return Int(n)
    }
    /// Stops it; true the first time.
    func stop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { stopped = true }
        return !stopped
    }
}

/// Why a meeting could not go on, said to the user, with the HTTP status that said so.
struct MeetFailure: Error {
    var text: String
    var status = 0
}

/// With BRIAREUS_MEET_LOG naming a file, every message to and from ElevenLabs is written there, cut short, to see what it
/// did. Off otherwise: the meeting's words stay out of files.
enum MeetingDebug {
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let lock = NSLock()

    static func open() {
        lock.lock(); defer { lock.unlock() }
        guard handle == nil, let path = ProcessInfo.processInfo.environment["BRIAREUS_MEET_LOG"], !path.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }
    static func write(_ who: String, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        let shown = text.count > 300 ? String(text.prefix(300)) + "…" : text
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        handle.write(Data("\(f.string(from: Date())) \(who) \(shown)\n".utf8))
    }
}
