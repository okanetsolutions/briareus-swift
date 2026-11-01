// What the apps make of the server's live event streams (EventStream.swift): every session on one connection
// (`events`), one conversation on its own (`session_events`), and when a dropped stream is tried again or left to polling.
// No UI here.
import Foundation

// MARK: - Every session

/// One event of the `events` stream: a session's record as it changed (and every record as it stands when the stream
/// opens), or a deleted session's id. Transcript lines, asked for only with `transcripts=1`, and anything newer are nil.
enum SessionsEvent: Equatable {
    case session(Session)
    case deleted(String)

    init?(_ event: String, _ data: JSON) {
        switch event {
        case "session":
            guard let s = Session(data), s.repo?.isEmpty == false else { return nil }
            self = .session(s)
        case "session.deleted":
            guard let id = data["id"].string, !id.isEmpty else { return nil }
            self = .deleted(id)
        default: return nil
        }
    }
}

extension Array where Element == Session {
    /// The list with a record that arrived live: in its row's place, or first when new. Nil when nothing changed.
    func upserting(_ s: Session) -> [Session]? {
        var list = self
        if let i = list.firstIndex(where: { $0.id == s.id }) {
            if list[i] == s { return nil }
            let previous = list[i]
            list[i] = s
            // Most events change only status or usage; keep their row in place without sorting the entire list.
            if previous.pinnedAt == s.pinnedAt && previous.raw["createdAt"] == s.raw["createdAt"] { return list }
        } else {
            list.insert(s, at: 0)
        }
        return list.orderedByPins()
    }
    /// Match the server's canonical ISO timestamps, including milliseconds; equal keys keep the list's order.
    func orderedByPins() -> [Session] {
        enumerated().sorted { a, b in
            let left = a.element.pinnedAt ?? "", right = b.element.pinnedAt ?? ""
            if left != right { return left > right }
            let createdA = a.element.raw["createdAt"].string ?? ""
            let createdB = b.element.raw["createdAt"].string ?? ""
            return createdA == createdB ? a.offset < b.offset : createdA > createdB
        }.map(\.element)
    }
    /// The list without a deleted session, or nil when it was not in it.
    func removing(_ id: String) -> [Session]? {
        guard contains(where: { $0.id == id }) else { return nil }
        return filter { $0.id != id }
    }
}

/// Each project's saved conversation list (`sessions:<repo>`), parsed once and kept beside the cache. The live stream
/// opens with every session and then changes one per event; parsing the saved list back for each one made its catch-up
/// cost the main thread the whole list per session. Every save goes through here so the two stay the same, and a cache
/// emptied meanwhile (a new device or repository list) leaves nothing behind.
final class SavedSessionLists {
    private let cache: DiskCache
    private var lists: [String: [Session]] = [:]
    private var clears: Int

    init(cache: DiskCache) {
        self.cache = cache
        clears = cache.clears
    }

    private func key(_ repo: String) -> String { "sessions:\(repo)" }
    private func current() {
        let now = cache.clears
        if now != clears { lists = [:]; clears = now }
    }

    /// The saved full list, or nil when none was read.
    func list(_ repo: String) -> [Session]? {
        current()
        if let list = lists[repo] { return list }
        guard let list = cache.value(key(repo)).flatMap(Session.parseList) else { return nil }
        lists[repo] = list
        return list
    }
    /// A full list as read from the server.
    func save(_ list: [Session], repo: String) {
        current()
        lists[repo] = list
        cache.store(Session.json(list), key(repo))
    }
    /// A live record updates a saved full list; it cannot establish that every session has been read. Nil when there is
    /// no saved list or nothing changed.
    func upsert(_ session: Session, repo: String) -> [Session]? {
        guard let list = list(repo)?.upserting(session) else { return nil }
        save(list, repo: repo)
        return list
    }
    /// A deletion updates a saved full list; live-only rows cannot establish a complete cache.
    func remove(_ id: String, repo: String) -> [Session]? {
        guard let list = list(repo)?.removing(id) else { return nil }
        save(list, repo: repo)
        return list
    }
    /// Signing out: what was read goes with the cache.
    func reset() { lists = [:]; clears = cache.clears }
}

// MARK: - One conversation

/// One event of a session's `session_events` stream: its record (named `session`) or a transcript line (unnamed, its
/// `seq` the event's id). Anything else is nil.
enum ConversationEvent: Equatable {
    case record(Session)
    case line(JSON)

    init?(_ event: String, _ data: JSON) {
        if event == "session" {
            guard let s = Session(data["session"].isObject ? data["session"] : data) else { return nil }
            self = .record(s)
            return
        }
        guard event.isEmpty || event == "message", data["seq"].truncatedInt != nil else { return nil }
        self = .line(data)
    }
}

// MARK: - Reconnecting

/// When a followed stream is opened again after it ends or fails: a second after a stream that ran and ended, else after
/// 2 s doubling to a minute (or the server's Retry-After), and not at all once the server refuses it (the route is gone or
/// the token may not read it) or it failed `limit` times in a row; polling, which never stops, carries on alone then.
struct StreamRetry: Equatable {
    /// Failures in a row since the stream last opened.
    private(set) var failures = 0
    /// The stream was given up on until `reset`.
    private(set) var stopped = false
    let limit: Int

    init(limit: Int = 6) { self.limit = limit }

    /// The server answered with the stream: the count starts again.
    mutating func opened() { failures = 0 }
    /// The app came back to the front, or the connection changed: the stream is tried afresh.
    mutating func reset() { failures = 0; stopped = false }

    /// The seconds to wait before opening the stream again after it ended (`error` nil) or failed, or nil to stop.
    mutating func next(after error: APIError?) -> TimeInterval? {
        guard !stopped else { return nil }
        // The server ended a stream that had opened: back in a second.
        guard let error else { return 1 }
        if error.kind == .cancelled { return nil }
        if error.kind == .http && [401, 403, 404, 405].contains(error.status) { return stop() }
        failures += 1
        if failures >= limit { return stop() }
        return delay(error.retryAfter)
    }

    private mutating func stop() -> TimeInterval? { stopped = true; return nil }
    private func delay(_ retryAfter: Double?) -> TimeInterval {
        let seconds = min(pow(2, Double(failures)), 60)
        if let retryAfter, retryAfter > seconds { return min(retryAfter, 600) }
        return seconds
    }
}
