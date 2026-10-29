// The iPhone's Usage tab, its pure parts: the usage of a token that may read only its own projects (`GET /usage` for each),
// folded into the shape `GET /usage/all` answers so one screen draws both.
import Foundation

enum PhoneUsage {
    /// A bucket's day ("2026-08-03") or month ("2026-08") as midnight on its first day in `calendar`, for a chart's axis.
    static func bucketDate(_ key: String?, calendar: Calendar = .current) -> Date? {
        guard let key else { return nil }
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1].prefix(2)), (1...12).contains(m) else { return nil }
        var c = DateComponents(); c.year = y; c.month = m; c.day = 1
        if parts.count >= 3 { guard let d = Int(parts[2].prefix(2)), (1...31).contains(d) else { return nil }; c.day = d }
        return calendar.date(from: c)
    }

    private static let sums = ["turns", "sessions", "inputTokens", "outputTokens", "totalTokens", "durationMs", "unpricedTurns", "estimatedTurns"]
    /// Rows added up as the server's aggregateUsage does: the counts summed, the cost over the rows that carry one (null when none did).
    static func add(_ rows: [JSON]) -> JSON {
        var out: JSON = [:]
        for k in sums { out[k] = .number(rows.reduce(0) { $0 + ($1[k].number ?? 0) }) }
        let priced = rows.compactMap { $0["costUsd"].number }
        out["costUsd"] = priced.isEmpty ? .null : .number(priced.reduce(0, +))
        return out
    }
    /// Rows of several answers merged by `key`, their identifying fields from the first, their figures added up.
    private static func merge(_ lists: [[JSON]], key: (JSON) -> String, fields: [String]) -> [JSON] {
        var order: [String] = [], groups: [String: [JSON]] = [:]
        for row in lists.joined() {
            let k = key(row)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(row)
        }
        return order.map { k in
            let rows = groups[k]!
            var out = add(rows)
            for f in fields { out[f] = rows[0][f] }
            return out
        }
    }
    private static func byTokens(_ rows: [JSON]) -> [JSON] {
        rows.enumerated().sorted { a, b in
            let x = Usage.num(a.element, "totalTokens"), y = Usage.num(b.element, "totalTokens")
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// Each project's `usage` answer (this month) as one `usage/all`-shaped payload: the totals, the days, a row per project
    /// (`key` is its repository) and the providers, models and activities across them, biggest first as the server sorts.
    static func combine(_ answers: [(project: Project, usage: JSON)]) -> JSON {
        let usages = answers.map(\.usage)
        var out = add(usages)
        let today = usages.compactMap { $0["today"].string }.max() ?? ""
        out["period"] = "month"
        out["unit"] = "day"
        out["today"] = today.isEmpty ? .null : .string(today)
        let month = usages.compactMap { $0["daily"].items.first?["date"].string }.first.map { String($0.prefix(7)) } ?? String(today.prefix(7))
        out["month"] = month.isEmpty ? .null : .string(month)
        let days = merge(usages.map { $0["daily"].items }, key: { $0["date"].string ?? "" }, fields: ["date"])
        out["buckets"] = .array(days.sorted { ($0["date"].string ?? "").bytesPrecede($1["date"].string ?? "") })
        let projects = answers.map { a -> JSON in
            var row = add([a.usage])
            row["key"] = .string(a.project.repo); row["repo"] = .string(a.project.repo); row["label"] = .string(a.project.title)
            return row
        }
        out["projects"] = .array(projects.sorted { a, b in
            let x = Usage.num(a, "totalTokens"), y = Usage.num(b, "totalTokens")
            if x != y { return x > y }
            return (a["label"].string ?? "").localizedCompare(b["label"].string ?? "") == .orderedAscending
        })
        out["providers"] = .array(byTokens(merge(usages.map { $0["providers"].items }, key: { $0["provider"].string ?? "" }, fields: ["provider"])))
        out["models"] = .array(byTokens(merge(usages.map { $0["models"].items },
                                              key: { "\($0["provider"].string ?? "")|\($0["model"].string ?? "")" },
                                              fields: ["key", "provider", "model"])))
        let activities = merge(usages.map { $0["activities"].items }, key: { $0["activity"].string ?? "" }, fields: ["activity"])
        out["activities"] = .array(activities.enumerated().sorted { a, b in
            let x = a.element["costUsd"].number ?? 0, y = b.element["costUsd"].number ?? 0
            if x != y { return x > y }
            let s = Usage.num(a.element, "totalTokens"), t = Usage.num(b.element, "totalTokens")
            return s != t ? s > t : a.offset < b.offset
        }.map(\.element))
        return out
    }
}
