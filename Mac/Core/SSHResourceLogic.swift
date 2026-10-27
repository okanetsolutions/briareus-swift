// SSH telemetry shared by the Mac and phone: selection, status, tiles and 24-hour charts.
// Failed samples stay gaps; virtual and physical network interfaces are never summed.
import Foundation

struct SSHResourceServer: Equatable, Sendable, Identifiable {
    var raw: JSON
    var id: String { raw["id"].number.map { String(format: "%.0f", $0) } ?? "" }
    var label: String { raw["label"].nonEmpty ?? id }
    var repo: String { raw["repo"].string ?? "" }
    var title: String { "\(label) · \(repo)" }
    var status: String {
        if raw["enabled"].is(false) { return "Server disabled" }
        if !raw["monitoringEnabled"].is(true) { return "Monitoring off · enable it in SSH settings" }
        if let error = raw["latest"]["error"].nonEmpty { return error }
        if raw["latest"].isNull { return "Waiting for the first sample" }
        return raw["stale"].is(true) ? "No recent sample · figures may be outdated" : "Sampling every minute · last 24 hours"
    }
    static func list(_ answer: JSON) -> [Self]? {
        guard let rows = answer["servers"].array else { return nil }
        return rows.filter { $0["id"].number != nil }.map { Self(raw: $0) }
    }
    static func selection(_ id: String, in servers: [Self]) -> String {
        servers.contains { $0.id == id } ? id : servers.first?.id ?? ""
    }
}

struct SSHResourceReading: Equatable, Sendable {
    var samples: [JSON]
    var from: Date
    var to: Date
    init?(_ answer: JSON) {
        guard let rows = answer["samples"].array,
              let start = answer["from"].number, let end = answer["to"].number else { return nil }
        from = Date(timeIntervalSince1970: start / 1000)
        to = Date(timeIntervalSince1970: end / 1000)
        samples = rows.filter { row in
            guard let at = row["at"].number else { return false }
            return at >= start && at <= end
        }.sorted { ($0["at"].number ?? 0) < ($1["at"].number ?? 0) }
    }
    var latest: JSON { samples.last ?? .null }
    var metrics: JSON { latest["metrics"] }
    var error: String? { latest["error"].nonEmpty }
    var updated: Date? { latest["at"].number.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var tiles: [StatTile] {
        guard metrics.isObject else { return [] }
        let memory = metrics["memory"], cpu = metrics["cpu"]
        return [
            StatTile(id: "cpu", label: "CPU", value: StatsFormat.percent(cpu["usagePercent"].number),
                     detail: "\(cpu["cores"].int ?? 0) cores", fraction: cpu["usagePercent"].number.map { $0 / 100 }),
            StatTile(id: "memory", label: "Memory", value: bytes(memory["usedBytes"]),
                     detail: "of \(bytes(memory["totalBytes"])) · \(bytes(memory["availableBytes"])) available",
                     fraction: memory["usedPercent"].number.map { $0 / 100 }),
            StatTile(id: "swap", label: "Swap", value: bytes(memory["swapUsedBytes"]),
                     detail: "of \(bytes(memory["swapTotalBytes"]))", fraction: nil),
            StatTile(id: "uptime", label: "Uptime", value: StatsFormat.uptime(metrics["uptimeSeconds"].number),
                     detail: "since last boot", fraction: nil),
        ]
    }
    var diskTiles: [StatTile] {
        metrics["disks"].items.map { disk in
            StatTile(id: disk["mount"].string ?? "", label: disk["mount"].string ?? "Disk", value: bytes(disk["usedBytes"]),
                     detail: "of \(bytes(disk["totalBytes"])) · \(bytes(disk["availableBytes"])) available",
                     fraction: disk["usedPercent"].number.map { $0 / 100 })
        }
    }
    var networkTiles: [StatTile] {
        metrics["network"].items.map { net in
            StatTile(id: net["name"].string ?? "", label: net["name"].string ?? "Network",
                     value: "↓ \(rate(net["rxBytesPerSecond"])) · ↑ \(rate(net["txBytesPerSecond"]))",
                     detail: "↓ \(bytes(net["rxBytes"])) · ↑ \(bytes(net["txBytes"])) since interface reset", fraction: nil)
        }
    }
    var charts: [StatsChart] {
        var result = [
            StatsChart(id: "cpu", title: "CPU", series: [series("cpu", label: "Usage", unit: .percent, slot: 0) { $0["cpu"]["usagePercent"].number }]),
            StatsChart(id: "memory", title: "Memory", series: [series("memory", label: "Used", unit: .bytes, slot: 1) { $0["memory"]["usedBytes"].number }]),
        ]
        let disks = Set(samples.flatMap { $0["metrics"]["disks"].items.compactMap { $0["mount"].string } }).sorted()
        for mount in disks {
            result.append(StatsChart(id: "disk:\(mount)", title: "Disk · \(mount)", series: [
                series("disk:\(mount)", label: "Used", unit: .percent, slot: 0) { metrics in
                    metrics["disks"].items.first { $0["mount"].string == mount }?["usedPercent"].number
                },
            ]))
        }
        let names = Set(samples.flatMap { $0["metrics"]["network"].items.compactMap { $0["name"].string } }).sorted()
        for name in names {
            result.append(StatsChart(id: "network:\(name)", title: "Network · \(name)", series: [
                series("rx:\(name)", label: "Receive", unit: .bytesPerSecond, slot: 0) { metrics in
                    metrics["network"].items.first { $0["name"].string == name }?["rxBytesPerSecond"].number
                },
                series("tx:\(name)", label: "Send", unit: .bytesPerSecond, slot: 1) { metrics in
                    metrics["network"].items.first { $0["name"].string == name }?["txBytesPerSecond"].number
                },
            ]))
        }
        return result
    }
    /// A missing sample/value starts a new line, rather than connecting across an outage.
    private func series(_ id: String, label: String, unit: StatsSeries.Unit, slot: Int,
                        value: (JSON) -> Double?) -> StatsSeries {
        var points: [StatsSeries.Point] = [], segment = 0
        var previous: Double?
        for sample in samples {
            guard let at = sample["at"].number, let number = value(sample["metrics"]), number.isFinite else {
                segment += 1; previous = nil; continue
            }
            if let previous, at - previous > 90_000 { segment += 1 }
            points.append(.init(at: Date(timeIntervalSince1970: at / 1000), value: number, segment: segment))
            previous = at
        }
        return StatsSeries(id: id, label: label, unit: unit, points: points, slot: slot)
    }
    private func bytes(_ value: JSON) -> String { value.number.map(StatsFormat.bytes) ?? "—" }
    private func rate(_ value: JSON) -> String { value.number.map { StatsFormat.bytes($0) + "/s" } ?? "—" }
}
