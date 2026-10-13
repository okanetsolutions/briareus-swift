// The server's live event streams on a phone, as the Mac follows them (Mac/App/Shared/ProjectsModel.swift): every
// session on one connection for the lists, and an open conversation's own stream for its transcript. iOS keeps no
// connection open for an app in the background, so a stream closes when the app leaves the front and opens again,
// catching up, when it returns; polling carries on beside it, slowly while a stream flows.
import Foundation

/// Whether a stream's server answered, set from the stream's own queue and read once it ends.
private final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var yes: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Follows a GET call's event stream for as long as the calling task runs and the app is in front (a window or the
/// car's screen), with `arguments()` as they stand each time it opens, once `ready()`. A dropped stream comes back
/// after StreamRetry's backoff; one refused, or failing time after time, is left to polling until the app comes back
/// to the front. `live` says whether the stream flows; `emit` gets each event on the main actor.
@MainActor
func followLive(_ name: String, _ arguments: () -> JSON = { [:] }, ready: () -> Bool = { true },
                live: @escaping @MainActor @Sendable (Bool) -> Void,
                emit: @escaping @MainActor @Sendable (String, JSON) -> Void) async {
    var retry = StreamRetry()
    while !Task.isCancelled {
        // Out of sight (or not ready to say where to start): no stream. Back in front, one given up on is tried again.
        var away = false
        while (!Store.shared.active || !ready() || retry.stopped && !away) && !Task.isCancelled {
            if !Store.shared.active { away = true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if Task.isCancelled { return }
        if away { retry.reset() }
        guard let client = Store.shared.client else { return }
        let args = arguments()
        let opened = Opened()
        let stream = Task {
            try await client.stream(name, args, opened: { opened.set(); Task { @MainActor in live(true) } }) { event, data in
                guard let j = JSON.parse(data) else { return }
                Task { @MainActor in emit(event, j) }
            }
        }
        // The app leaving the front closes the stream.
        let watch = Task { @MainActor in
            while Store.shared.active && !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            stream.cancel()
        }
        var failure: APIError?
        do { try await withTaskCancellationHandler { try await stream.value } onCancel: { stream.cancel() } }
        catch { failure = error as? APIError ?? APIError(.network, message: error.localizedDescription) }
        watch.cancel()
        live(false)
        if Task.isCancelled { return }
        if !Store.shared.active { continue }
        if opened.yes { retry.opened() }
        let wait = retry.next(after: failure) ?? 1
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
}

/// Every session the token can see, followed on one connection (`GET /events`): a record lands in its project's list
/// as it changes and a deleted one goes, so the lists, their counts and the car's screen keep up without their 7-second
/// poll. The stream opens with every session as it stands, which is the catch-up after a drop or a spell in the
/// background; a deletion missed meanwhile waits for the minute's safety read.
@MainActor
final class SessionFeed: ObservableObject {
    static let shared = SessionFeed()
    @Published private(set) var live = false

    /// Follows the stream while the calling task runs, on a server that has it.
    func follow() async {
        guard Store.shared.supports("events") else { return }
        await followLive("events", live: { SessionFeed.shared.set(live: $0) }) { event, data in
            SessionFeed.shared.apply(event, data)
        }
        set(live: false)
    }

    private func set(live: Bool) { if live != self.live { self.live = live } }

    private func apply(_ event: String, _ data: JSON) {
        switch SessionsEvent(event, data) {
        case .session(let s)?:
            guard let repo = s.repo else { return }
            Store.shared.feed(repo).upsert(s)
        case .deleted(let id)?:
            for p in ProjectsModel.shared.projects { Store.shared.feed(p.repo).remove(id) }
        case nil: return
        }
    }
}
