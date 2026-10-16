// Sleep mode on the Mac: after "Sleep after" minutes with no key, click or scroll in the app (in front or not, so a
// window left beside other work turns into a view of the sessions), the window shows what every working session is
// doing (SleepModeLogic.swift decides what). It follows the `events` stream with its transcript lines only while
// asleep, reads the files sessions touch, and replays recent work when nothing runs. Any input wakes it. The iPhone's
// twin is App/SleepMode/SleepModel.swift.
import Foundation

@MainActor
final class SleepModel: ObservableObject {
    static let shared = SleepModel()

    private enum Key { static let after = "sleep.afterMinutes" }
    private static let capacity = 4
    /// Characters each pane types per beat, a beat every 80 ms: about 90 a second.
    private static let charsPerBeat = 7

    @Published private(set) var asleep = false
    @Published private(set) var wall = SleepWall(capacity: capacity)
    /// Minutes without a touch before the app sleeps; 0 never.
    @Published var sleepAfter: Int { didSet { UserDefaults.standard.set(sleepAfter, forKey: Key.after) } }

    private var lastInput = Date()
    /// Whether `watchIdle` already runs: the window's task starts it again when it reappears.
    private var watching = false
    private var work: [Task<Void, Never>] = []
    private var replay = SleepReplay([])
    private var replayLoading = false
    /// Files already read this sleep, by repository, branch and path, so a replay's next round reads none again.
    private var files: [String: [[CodeToken]]] = [:]

    private init() {
        sleepAfter = UserDefaults.standard.object(forKey: Key.after) as? Int ?? sleepAfterDefault
    }

    // MARK: Intents

    /// Input anywhere in the app: the idle clock starts again, and a sleeping app wakes.
    func touched() {
        lastInput = Date()
        if asleep { wake() }
    }

    /// Puts the app to sleep once it has gone untouched long enough, for as long as the calling task runs.
    func watchIdle() async {
        guard !watching else { return }
        watching = true
        defer { watching = false }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let store = Store.shared
            guard !asleep, store.connected, store.supports("events") else { continue }
            if sleepIsDue(lastInput: lastInput, now: Date(), minutes: sleepAfter) { fallAsleep() }
        }
    }

    func wake() {
        lastInput = Date()
        guard asleep else { return }
        asleep = false
        work.forEach { $0.cancel() }
        work = []
        files = [:]
    }

    // MARK: Asleep

    private func fallAsleep() {
        wall = SleepWall(capacity: Self.capacity)
        replay = SleepReplay([])
        replayLoading = false
        asleep = true
        work = [Task { await follow() }, Task { await beat() }]
    }

    /// The stream, opened again after a drop with StreamRetry's backoff, until the server refuses it.
    private func follow() async {
        var retry = StreamRetry()
        while !Task.isCancelled, let client = Store.shared.client {
            var failure: APIError?
            do {
                try await client.stream("events", ["transcripts": "1"]) { event, data in
                    guard let j = JSON.parse(data) else { return }
                    Task { @MainActor in SleepModel.shared.receive(event, j) }
                }
                retry.opened()
            } catch {
                failure = error as? APIError ?? APIError(Task.isCancelled ? .cancelled : .network)
            }
            guard let wait = retry.next(after: failure) else { return }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func receive(_ event: String, _ data: JSON) {
        guard asleep else { return }
        let now = Date()
        if let (id, line) = sleepTranscriptLine(event, data) {
            if let step = sleepStep(line, repo: wall.sessions[id]?.repo), let fetch = wall.apply(step, session: id, now: now) { read(fetch) }
            return
        }
        switch SessionsEvent(event, data) {
        case .session(let s)?:
            let started = wall.sessions[s.id] == nil && s.isActive
            wall.update(s, now: now)
            if started { Task { await seed(s) } }
        case .deleted(let id)?:
            wall.remove(id)
        case nil:
            return
        }
    }

    /// A working session's last few steps, so its pane shows something before its next one.
    private func seed(_ s: Session) async {
        guard let answer = try? await Store.shared.call("session", ["sessionId": .string(s.id), "since": 0]), asleep else { return }
        for step in sleepSteps(answer["events"], repo: s.repo, limit: 8) {
            if let fetch = wall.apply(step, session: s.id, now: Date()) { read(fetch) }
        }
    }

    /// The typing clock, and a replayed step every few seconds while nothing works.
    private func beat() async {
        var n = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard asleep else { return }
            let now = Date()
            for fetch in wall.tick(chars: Self.charsPerBeat, now: now) { read(fetch) }
            n += 1
            if n % 30 == 0 { replayStep(now) }
        }
    }

    private func replayStep(_ now: Date) {
        guard wall.wantsReplay(now: now) else { return }
        if replay.isEmpty {
            if !replayLoading { replayLoading = true; Task { await loadReplay() } }
            return
        }
        guard let (id, step) = replay.next() else { return }
        if let fetch = wall.apply(step, session: id, now: now, replay: true) { read(fetch) }
    }

    private func loadReplay() async {
        var queues: [(sessionId: String, steps: [SleepStep])] = []
        for s in sleepReplaySessions(Array(wall.sessions.values), limit: Self.capacity) {
            guard let answer = try? await Store.shared.call("session", ["sessionId": .string(s.id), "since": 0]) else { continue }
            queues.append((s.id, sleepSteps(answer["events"], repo: s.repo, limit: 40)))
        }
        // Read once a sleep: with nothing to replay, the wall waits for live work.
        if asleep { replay = SleepReplay(queues) }
    }

    private func read(_ fetch: SleepFetch) {
        let key = "\(fetch.repo)@\(fetch.branch ?? ""):\(fetch.path)"
        if let code = files[key] { wall.loaded(fetch, code: code); return }
        Task {
            var text: String?
            if Store.shared.supports("repo_file") {
                if let answer = try? await Store.shared.call("repo_file", fetch.arguments(atBranch: true), timeout: 30) {
                    text = SleepFetch.text(answer)
                } else if fetch.triesDefaultBranch,
                          let answer = try? await Store.shared.call("repo_file", fetch.arguments(atBranch: false), timeout: 30) {
                    text = SleepFetch.text(answer)
                }
            }
            let language = CodeLanguage.of(fetch.path)
            let code = await Task.detached(priority: .utility) { text.map { codeHighlight($0, language: language) } }.value
            guard asleep else { return }
            if let code {
                if files.count >= 40 { files.removeAll() }
                files[key] = code
            }
            wall.loaded(fetch, code: code)
        }
    }
}
