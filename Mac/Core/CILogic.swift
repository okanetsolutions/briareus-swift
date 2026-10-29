// Durable GitHub CI totals and execution history, shared by both dashboards.
import Foundation

enum CIKind: String, CaseIterable, Sendable {
    case checks = "check_run", statuses = "status"
    var title: String { self == .checks ? "Checks" : "Legacy statuses" }
}

struct CIQuery: Hashable, Sendable {
    var days = 30
    var repo = ""
    var kind: CIKind = .checks

    /// Freeze one window for totals and every history page; until is exclusive.
    func arguments(now: Date) -> JSON {
        let until = floor(now.timeIntervalSince1970 * 1000)
        var out: JSON = ["since": JSON(max(0, until - Double(days) * 86_400_000)),
                         "until": JSON(until), "kind": .string(kind.rawValue)]
        if !repo.isEmpty { out["repo"] = .string(repo) }
        return out
    }
}

struct CIMetrics: Equatable, Sendable {
    var total: Int
    var succeeded: Int
    var failed: Int
    var pending: Int
    var cancelled: Int
    var skipped: Int
    var other: Int
    var successRate: Double?
    var averageMs: Double?

    init(_ j: JSON) {
        total = j["total"].int ?? 0
        succeeded = j["succeeded"].int ?? 0
        failed = j["failed"].int ?? 0
        pending = j["pending"].int ?? 0
        cancelled = j["cancelled"].int ?? 0
        skipped = j["skipped"].int ?? 0
        other = j["other"].int ?? 0
        successRate = j["successRate"].number
        averageMs = j["avgDurationMs"].number
    }
    var summary: String { "\(succeeded) passed · \(failed) failed · \(pending) pending · \(cancelled) cancelled · \(skipped) skipped · \(other) other" }
    var tiles: [StatTile] {
        [StatTile(id: "executions", label: "Executions", value: "\(total)", detail: summary, fraction: nil),
         StatTile(id: "success", label: "Success rate", value: successRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                  detail: "Passed / (passed + failed)", fraction: nil),
         StatTile(id: "duration", label: "Average duration", value: Self.duration(averageMs),
                  detail: "Executions with valid start and end times", fraction: nil)]
    }
    static func duration(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
        return String(format: "%.1f s", milliseconds / 1000)
    }
}

struct CIGroup: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var metrics: CIMetrics
    init?(_ j: JSON, key: String) {
        guard let title = j[key].nonEmpty else { return nil }
        let app = j["app"].nonEmpty
        id = "\(title.utf8.count):\(title)\(app ?? "")"
        self.title = app.map { "\(title) · \($0)" } ?? title
        metrics = CIMetrics(j)
    }
}

struct CIReading: Equatable, Sendable {
    var totals: CIMetrics
    var daily: [CIGroup]
    var repositories: [CIGroup]
    var checks: [CIGroup]
    init?(_ j: JSON) {
        guard j["totals"].isObject else { return nil }
        totals = CIMetrics(j["totals"])
        daily = j["daily"].items.compactMap { CIGroup($0, key: "day") }
        repositories = j["repositories"].items.compactMap { CIGroup($0, key: "repo") }
        checks = j["checks"].items.compactMap { CIGroup($0, key: "name") }
    }
}

struct CIRun: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var detail: String
    var result: String
    var duration: String
    var at: Date?
    var url: URL?
    var tone: RowTone
    init?(_ j: JSON) {
        guard let repo = j["repo"].nonEmpty, let kind = j["kind"].nonEmpty,
              let runID = j["id"].nonEmpty, let name = j["name"].nonEmpty else { return nil }
        id = "\(repo):\(kind):\(runID)"
        self.name = name
        detail = [repo, j["branch"].nonEmpty, j["headSha"].nonEmpty.map { String($0.prefix(7)) }].compactMap { $0 }.joined(separator: " · ")
        result = j["conclusion"].nonEmpty ?? j["status"].nonEmpty ?? "unknown"
        duration = CIMetrics.duration(j["durationMs"].number)
        at = j["runAt"].number.map { Date(timeIntervalSince1970: $0 / 1000) }
        url = j["url"].nonEmpty.flatMap { value in
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        switch result {
        case "success": tone = .ok
        case "failure", "error", "timed_out", "startup_failure", "action_required": tone = .danger
        default: tone = .muted
        }
    }
}

struct CIHistory: Equatable, Sendable {
    var runs: [CIRun] = []
    var nextOffset: Int?
    var truncated = false
    /// History pages retain the aggregate's exact window and filters.
    static func arguments(window: JSON, offset: Int) -> JSON {
        var args = window
        args["offset"] = JSON(offset); args["limit"] = 50
        return args
    }
    /// Replace on a new window; append without duplicating executions seen on adjacent pages.
    mutating func receive(_ j: JSON, offset: Int) throws {
        guard j["runs"].isArray else { throw APIError(.nonJSON) }
        if offset == 0 { runs = [] }
        var seen = Set(runs.map(\.id))
        runs += j["runs"].items.compactMap(CIRun.init).filter { seen.insert($0.id).inserted }
        let next = j["nextOffset"].int
        nextOffset = next.flatMap { $0 > offset && $0 <= 100_000 ? $0 : nil }
        truncated = j["truncated"].is(true)
    }
}
