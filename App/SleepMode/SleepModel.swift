// Sleep mode on a phone or iPad: after "Sleep after" minutes with no touch while the app is in front, the screen shows
// what every working session is doing (SleepModeLogic.swift decides what) in a window of its own (SleepWindows). It follows the `events` stream with its
// transcript lines only while asleep, reads the files sessions touch, and replays recent work when nothing runs. Any
// touch wakes it. The Mac's twin is Mac/App/SleepMode/SleepModel.swift.
import Foundation

@MainActor
final class SleepModel: ObservableObject {
    static let shared = SleepModel()

    private enum Key { static let after = "sleep.afterMinutes" }
    /// Panes at most; a phone's single column shows the newest of them.
    private static let capacity = 4
    /// Characters each pane types per beat, a beat every 80 ms: about 90 a second.
    private static let charsPerBeat = 7

    @Published private(set) var asleep = false
    @Published private(set) var wall = SleepWall(capacity: capacity)
    /// Minutes without a touch before the app sleeps; 0 never.
    @Published var sleepAfter: Int { didSet { UserDefaults.standard.set(sleepAfter, forKey: Key.after) } }

    private var lastInput = Date()
    /// Whether the app is in front. The store stays active while CarPlay shows it, but sleep is only for a screen in hand.
    private var inFront = false
    /// Whether a window already runs `watchIdle`: an iPad's windows each start it, and one is enough.
    private var watching = false
    private var work: [Task<Void, Never>] = []
    private var replay = SleepReplay([])
    private var replayLoading = false
    /// When a replay was last read, so one that came back empty is read again a little later rather than every beat.
    private var replayRead: Date?
    /// When the last replayed step was shown.
    private var replayed = Date.distantPast
    /// Files already read this sleep, by repository, branch and path, so a replay's next round reads none again.
    private var files: [String: [[CodeToken]]] = [:]

    private init() {
        sleepAfter = UserDefaults.standard.object(forKey: Key.after) as? Int ?? sleepAfterDefault
    }

    // MARK: Intents

    /// A touch anywhere in the app, or typing: the idle clock starts again, and a sleeping app wakes.
    func touched() {
        lastInput = Date()
        if asleep { wake() }
    }

    /// Puts the app to sleep once it has gone untouched long enough, for as long as the calling task runs.
    func watchIdle() async {
        TouchWatcher.install()
        guard !watching else { return }
        watching = true
        defer { watching = false }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let store = Store.shared
            guard !asleep, inFront, store.client != nil, store.supports("events") else { continue }
            if sleepIsDue(lastInput: lastInput, now: Date(), minutes: sleepAfter) { fallAsleep() }
        }
    }

    /// The app came to the front or left it: either way it is awake and the idle clock starts again, and a window that
    /// appeared meanwhile is watched too.
    func phaseChanged(active: Bool) {
        inFront = active
        wake()
        if active { TouchWatcher.install() }
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
        replayRead = nil
        asleep = true
        work = [Task { await follow() }, Task { await beat() }]
    }

    private func follow() async {
        await followLive("events", { ["transcripts": "1"] }, live: { _ in }) { event, data in
            SleepModel.shared.receive(event, data)
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
        guard Store.shared.supports("session"), let answer = try? await Store.shared.call("session", ["sessionId": .string(s.id), "since": 0]), asleep else { return }
        for step in sleepSteps(answer["events"], repo: s.repo, limit: SleepWall.seedSteps) {
            if let fetch = wall.apply(step, session: s.id, now: Date()) { read(fetch) }
        }
    }

    /// The typing clock, and a replayed step every few seconds while nothing works. The wall is only published when a
    /// beat changed it, so an idle wall redraws nothing.
    private func beat() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard asleep else { return }
            let now = Date()
            var next = wall
            let fetches = next.tick(chars: Self.charsPerBeat, now: now)
            if next != wall { wall = next }
            fetches.forEach(read)
            if now.timeIntervalSince(replayed) >= SleepWall.replayInterval { replayStep(now) }
        }
    }

    private func replayStep(_ now: Date) {
        guard wall.wantsReplay(now: now) else { return }
        replayed = now
        if replay.isEmpty {
            guard !replayLoading, replayRead.map({ now.timeIntervalSince($0) >= SleepWall.replayRetry }) ?? true else { return }
            replayLoading = true
            replayRead = now
            Task { await loadReplay() }
            return
        }
        guard let (id, step) = replay.next() else { return }
        if let fetch = wall.apply(step, session: id, now: now, replay: true) { read(fetch) }
    }

    private func loadReplay() async {
        var queues: [(sessionId: String, steps: [SleepStep])] = []
        guard Store.shared.supports("session") else { replayLoading = false; return }
        for s in sleepReplaySessions(Array(wall.sessions.values), limit: Self.capacity) {
            guard let answer = try? await Store.shared.call("session", ["sessionId": .string(s.id), "since": 0]) else { continue }
            queues.append((s.id, sleepSteps(answer["events"], repo: s.repo, limit: SleepWall.replaySteps)))
        }
        replayLoading = false
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
