// The link to the server as one app sees it: the system's network path, how the app's requests end, and the waits
// that end early when the link comes back. Each app's Store holds one; the rules are Connectivity's.
import Foundation
import Network

/// Wakes every task waiting on it at once, for polls and streams sleeping out a backoff when the link comes back.
final class WakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    init() {}

    /// How many tasks are waiting, for the tests.
    var waiting: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }

    /// Wakes everyone waiting now.
    func fire() {
        lock.lock()
        let woken = waiters
        let ended = timers
        waiters = [:]; timers = [:]
        lock.unlock()
        for t in ended.values { t.cancel() }
        for c in woken.values { c.resume() }
    }

    /// Returns after `seconds`, when the signal fires, or when the task is cancelled, whichever comes first.
    func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let id = UUID()
        let nanoseconds = UInt64(min(seconds, 86400) * 1_000_000_000)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); c.resume(); return }
                waiters[id] = c
                timers[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    self?.wake(id)
                }
                lock.unlock()
            }
        } onCancel: {
            wake(id)
        }
    }

    private func wake(_ id: UUID) {
        lock.lock()
        let c = waiters.removeValue(forKey: id)
        let t = timers.removeValue(forKey: id)
        lock.unlock()
        t?.cancel()
        c?.resume()
    }
}

/// One app's link: the path from the system once `start` is called, each request's outcome from its Store, the notice
/// to show, and waits that a returning link cuts short.
final class LinkWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var link = Connectivity()
    private var monitor: NWPathMonitor?
    /// Wakes the polls and streams waiting out a backoff or a lost link.
    let wake = WakeSignal()
    /// Told the notice each time it changes, on the queue the change happened on.
    var noticeChanged: (@Sendable (ConnectivityNotice?) -> Void)?

    init() {}

    /// The link as it stands.
    var current: Connectivity { lock.lock(); defer { lock.unlock() }; return link }

    /// Starts following the system's network path. A phone's monitor is cheap: the system tells it of changes only.
    func start() {
        lock.lock()
        guard monitor == nil else { lock.unlock(); return }
        let m = NWPathMonitor()
        monitor = m
        lock.unlock()
        m.pathUpdateHandler = { [weak self] p in
            self?.pathChanged(NetworkPath(reachable: p.status == .satisfied, constrained: p.isConstrained, expensive: p.isExpensive))
        }
        m.start(queue: DispatchQueue(label: "LinkWatch.path", qos: .utility))
    }

    /// The system reported a path.
    func pathChanged(_ path: NetworkPath) {
        update { $0.pathChanged(path) }
    }

    /// A request ended: nil when the server answered, else why it did not.
    func record(_ error: APIError?) {
        update { $0.record(error) }
    }

    private func update(_ change: (inout Connectivity) -> Bool) {
        lock.lock()
        let before = link.notice
        let back = change(&link)
        let after = link.notice
        let tell = noticeChanged
        lock.unlock()
        if before != after { tell?(after) }
        if back { wake.fire() }
    }

    /// An event stream ended. One that opened shows the server answered, however it ended (an idle timeout or a restart
    /// on a working link says nothing against it); one that never opened counts as its failure would.
    func streamEnded(opened: Bool, failure: APIError?) {
        if opened { record(nil) } else if let failure { record(failure) }
    }

    /// The interval a screen polls at for a `base` on a good link.
    func pollInterval(_ base: TimeInterval) -> TimeInterval { current.pollInterval(base) }

    /// Waits `seconds`, or less once the link comes back, but never less than `atLeast` (a server's Retry-After, which a
    /// returning link does not cut short). True when the link was lost as the wait began and works now: the caller's
    /// backoff then starts again, and a stream given up on meanwhile is tried afresh.
    @discardableResult
    func pause(_ seconds: TimeInterval, atLeast floor: TimeInterval = 0) async -> Bool {
        let lost = current.state.isLost
        let fixed = min(max(floor, 0), seconds)
        if fixed > 0 { try? await Task.sleep(nanoseconds: UInt64(fixed * 1_000_000_000)) }
        if !Task.isCancelled { await wake.sleep(seconds - fixed) }
        return lost && !current.state.isLost
    }

    /// Returns once there is a way out (at once while there is one), or the task is cancelled.
    func untilReachable() async {
        while current.pausesReads && !Task.isCancelled { await wake.sleep(60) }
    }
}
