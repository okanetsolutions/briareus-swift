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
            list[i] = s
        } else {
            list.insert(s, at: 0)
        }
        return list
    }
    /// The list without a deleted session, or nil when it was not in it.
    func removing(_ id: String) -> [Session]? {
        guard contains(where: { $0.id == id }) else { return nil }
        return filter { $0.id != id }
    }
}

extension DiskCache {
    /// A live record updates a saved full list; it cannot establish that every session has been read.
    func upsertSession(_ session: Session, repo: String) -> [Session]? {
        let key = "sessions:\(repo)"
        guard let saved = value(key).flatMap(Session.parseList), let list = saved.upserting(session) else { return nil }
        store(Session.json(list), key)
        return list
    }

    /// A deletion updates a saved full list; live-only rows cannot establish a complete cache.
    func removeSession(_ id: String, repo: String) -> [Session]? {
        let key = "sessions:\(repo)"
        guard let saved = value(key).flatMap(Session.parseList), let list = saved.removing(id) else { return nil }
        store(Session.json(list), key)
        return list
    }
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
