// CI/CD history the server observed from GitHub (`GET /stats/ci` and `GET /ci/runs`): totals and trends across the token's
// projects, per repository and per check, and the individual runs one page at a time. Parsed here, with the query both
// apps' CI screens send, the words and tones their tiles and rows show, and the daily chart's stacked bars. No UI here.
import Foundation

// MARK: - Query

/// The window and filters a CI screen reads with. Windows are whole days back from now; the server caps them at 366.
struct CIFilter: Equatable, Sendable {
    /// One repository as `owner/name`; nil for every project the token reads.
    var repo: String?
    var days: Int = 30
    /// Legacy commit statuses instead of GitHub Checks.
    var statuses = false
    /// An exact branch; nil or empty for every branch.
    var branch: String?

    /// The windows the screens offer.
    static let windows = [7, 30, 90]

    /// The shared query: `since` and `until` pinned to `now`, so paging keeps one window.
    func query(now: Date = Date()) -> JSON {
        let until = Int64(now.timeIntervalSince1970 * 1000)
        var out: JSON = ["since": .number(Double(until - Int64(days) * 86_400_000)), "until": .number(Double(until)),
                         "kind": .string(statuses ? "status" : "check_run")]
        if let repo, !repo.isEmpty { out["repo"] = .string(repo) }
        if let branch = branch?.cTrimmed, !branch.isEmpty { out["branch"] = .string(branch) }
        return out
    }
    /// `ci_runs`' query: the same window as `stats`, a page of `limit` from `offset`.
    func runsQuery(window: JSON, offset: Int = 0, limit: Int = 50) -> JSON {
        var out = window
        out["limit"] = .number(Double(limit))
        if offset > 0 { out["offset"] = .number(Double(offset)) }
        return out
    }
}

// MARK: - Figures

/// Counts and timings of one group of observed checks.
struct CIMetrics: Equatable, Sendable {
    var total, pending, succeeded, failed, cancelled, skipped, other: Int
    /// succeeded / (succeeded + failed), 0–1; nil without a decided result.
    var successRate: Double?
    var avgDurationMs: Double?
    var maxDurationMs: Double?
    var totalDurationMs: Double
    var lastObservedAt: Date?

    init(_ j: JSON) {
        total = j["total"].int ?? 0
        pending = j["pending"].int ?? 0
        succeeded = j["succeeded"].int ?? 0
        failed = j["failed"].int ?? 0
        cancelled = j["cancelled"].int ?? 0
        skipped = j["skipped"].int ?? 0
        other = j["other"].int ?? 0
        successRate = j["successRate"].number
        avgDurationMs = j["avgDurationMs"].number
        maxDurationMs = j["maxDurationMs"].number
        totalDurationMs = j["totalDurationMs"].number ?? 0
        lastObservedAt = epochMs(j["lastObservedAt"])
    }

    /// "92%", or "–" without a decided result.
    var successText: String { successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "\u{2013}" }
    /// Green from 90%, amber from 70%, red under it; faint without a decided result.
    var successTone: RowTone {
        guard let r = successRate else { return .faint }
        return r >= 0.9 ? .ok : r >= 0.7 ? .warn : .danger
    }
    var avgDurationText: String { avgDurationMs.map(formatDurationMs) ?? "\u{2013}" }
}

/// One UTC day, one repository or one named check, with its figures.
struct CIGroup: Equatable, Sendable, Identifiable {
    /// The day (`YYYY-MM-DD`), the repository (`owner/name`) or the check's name.
    var key: String
    /// A check's GitHub App, when known.
    var app: String?
    var metrics: CIMetrics
    var id: String { app.map { "\(key)|\($0)" } ?? key }
}

/// The `ci_stats` answer.
struct CIStats: Equatable, Sendable {
    var totals: CIMetrics
    /// Oldest first; empty days are left out.
    var daily: [CIGroup]
    var repositories: [CIGroup]
    var checks: [CIGroup]

    init(_ j: JSON) {
        totals = CIMetrics(j["totals"])
        daily = j["daily"].items.compactMap { d in d["day"].nonEmpty.map { CIGroup(key: $0, metrics: CIMetrics(d)) } }
        repositories = j["repositories"].items.compactMap { r in r["repo"].nonEmpty.map { CIGroup(key: $0, metrics: CIMetrics(r)) } }
        checks = j["checks"].items.compactMap { c in
            c["name"].nonEmpty.map { CIGroup(key: $0, app: c["app"].nonEmpty, metrics: CIMetrics(c)) }
        }
    }

    /// The checks failing most, most failures first (ties by name), at most `limit`; checks that never failed are left out.
    func mostFailing(limit: Int = 10) -> [CIGroup] {
        Array(checks.filter { $0.metrics.failed > 0 }.sorted { a, b in
            a.metrics.failed != b.metrics.failed ? a.metrics.failed > b.metrics.failed : a.key.localizedCompare(b.key) == .orderedAscending
        }.prefix(limit))
    }
}

// MARK: - Runs

/// Where a run stands, from its status and conclusion.
enum CIRunState: Equatable, Sendable {
    case pending, succeeded, failed, cancelled, skipped, other

    init(status: String, conclusion: String?) {
        guard status == "completed" else { self = .pending; return }
        switch conclusion ?? "" {
        case "success": self = .succeeded
        case "failure", "error", "timed_out", "startup_failure", "action_required": self = .failed
        case "cancelled": self = .cancelled
        case "skipped", "neutral": self = .skipped
        default: self = .other
        }
    }
    var title: String {
        switch self {
        case .pending: return "Running"
        case .succeeded: return "Passed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        case .other: return "Other"
        }
    }
    var tone: RowTone {
        switch self {
        case .pending: return .running
        case .succeeded: return .ok
        case .failed: return .danger
        case .cancelled: return .muted
        case .skipped, .other: return .faint
        }
    }
}

/// One observed GitHub check or legacy status.
struct CIRun: Equatable, Sendable, Identifiable {
    var repo: String
    var kind: String
    var runID: String
    var name: String
    var app: String?
    var headSha: String
    var branch: String?
    var status: String
    var conclusion: String?
    var url: String?
    var durationMs: Double?
    var runAt: Date?

    init?(_ j: JSON) {
        guard let runID = j["id"].nonEmpty ?? j["id"].number.map({ String(Int64($0)) }), let name = j["name"].nonEmpty else { return nil }
        self.runID = runID; self.name = name
        repo = j["repo"].string ?? ""
        kind = j["kind"].string ?? "check_run"
        app = j["app"].nonEmpty
        headSha = j["headSha"].string ?? ""
        branch = j["branch"].nonEmpty
        status = j["status"].string ?? ""
        conclusion = j["conclusion"].nonEmpty
        url = j["url"].nonEmpty
        durationMs = j["durationMs"].number
        runAt = epochMs(j["runAt"])
    }

    var id: String { "\(repo)|\(kind)|\(runID)" }
    var state: CIRunState { CIRunState(status: status, conclusion: conclusion) }
    /// "acme/shop · main · abc1234 · 3m 12s": where it ran and how long it took.
    var meta: String {
        [repo.isEmpty ? nil : repo, branch, headSha.isEmpty ? nil : String(headSha.prefix(7)), durationMs.map(formatDurationMs)]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

/// One page of `ci_runs`: its runs newest first, and the offset of the next page (nil at the end, or past the server's
/// reach when `truncated`).
struct CIRunsPage: Equatable, Sendable {
    var runs: [CIRun]
    var nextOffset: Int?
    var truncated: Bool

    init(_ j: JSON) {
        runs = j["runs"].items.compactMap(CIRun.init)
        nextOffset = j["nextOffset"].int
        truncated = j["truncated"].is(true)
    }
}

// MARK: - Chart

/// One segment of a day's stacked bar.
struct CIDailyBar: Equatable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Sendable {
        case succeeded, failed, other

        var title: String {
            switch self {
            case .succeeded: return "Succeeded"
            case .failed: return "Failed"
            case .other: return "Other"
            }
        }
        var tone: RowTone {
            switch self {
            case .succeeded: return .ok
            case .failed: return .danger
            case .other: return .faint
            }
        }
    }

    var day: Date
    var kind: Kind
    var count: Int
    var id: String { "\(day.timeIntervalSince1970)|\(kind.rawValue)" }
}

/// A `YYYY-MM-DD` day key as midnight of that day in `calendar`, so a chart labels it with the day the server named (its
/// UTC day); nil for anything else.
func ciDayDate(_ key: String, calendar: Calendar = .current) -> Date? {
    let parts = key.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
    guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2], (1...12).contains(m), (1...31).contains(d) else { return nil }
    return calendar.date(from: DateComponents(year: y, month: m, day: d))
}

/// The daily groups as stacked segments, oldest first: succeeded, failed, and every other check of the day (pending,
/// cancelled, skipped, other). Days whose key is not a date and empty segments are left out.
func ciDailyBars(_ daily: [CIGroup], calendar: Calendar = .current) -> [CIDailyBar] {
    daily.flatMap { group -> [CIDailyBar] in
        guard let day = ciDayDate(group.key, calendar: calendar) else { return [] }
        let m = group.metrics
        let other = max(m.total - m.succeeded - m.failed, 0)
        return [CIDailyBar(day: day, kind: .succeeded, count: m.succeeded), CIDailyBar(day: day, kind: .failed, count: m.failed),
                CIDailyBar(day: day, kind: .other, count: other)].filter { $0.count > 0 }
    }
}

/// Epoch milliseconds as a date; nil when absent.
private func epochMs(_ j: JSON) -> Date? { j.number.map { Date(timeIntervalSince1970: $0 / 1000) } }
