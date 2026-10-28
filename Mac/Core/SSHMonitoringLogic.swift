// Remote host telemetry: preserve missing readings, freshness and gaps in the rolling history.
import Foundation

enum SSHMonitoringAction: String, Sendable {
    case issue = "ssh_monitor_token", revoke = "revoke_ssh_monitor_token", toggle = "update_ssh_server"
    var clearsCredential: Bool { self != .toggle }
    func credential(from answer: JSON, current: String?) throws -> String? {
        if self == .issue { return try MonitorCredential(answer).configuration }
        return current
    }
}

enum SSHMonitoringPolicy {
    /// Polling cannot start during a write; only that write's reconciliation may read while it is busy.
    static func canLoad(loading: Bool, busy: Bool, afterWrite: Bool) -> Bool {
        !loading && (!busy || afterWrite)
    }
    static func canWrite(serverID: Double?, supported: Bool, loading: Bool, busy: Bool, uncertain: Bool) -> Bool {
        serverID != nil && !loading && SettingsWritePolicy.allows(supported: supported, busy: busy, uncertain: uncertain)
    }
}

struct MonitorCredential: Sendable {
    let configuration: String
    init(_ answer: JSON) throws {
        guard let endpoint = answer["endpoint"].nonEmpty, let token = answer["token"].nonEmpty,
              endpoint.hasPrefix("https://") else { throw APIError(.nonJSON) }
        var config = answer
        config["endpoint"] = .string(endpoint); config["token"] = .string(token)
        configuration = config.serialized(pretty: true)
    }
}

struct SSHResourceServer: Equatable, Sendable, Identifiable {
    let id: Double
    let title: String
    let repo: String
    let enabled: Bool
    let monitoring: Bool
    let stale: Bool
    let latest: JSON

    init?(_ raw: JSON) {
        guard let id = raw["id"].number, id > 0, id.isFinite else { return nil }
        self.id = id
        title = raw["label"].nonEmpty ?? "SSH server"
        repo = raw["repo"].string ?? ""
        enabled = raw["enabled"].is(true)
        monitoring = raw["monitoringEnabled"].is(true)
        stale = raw["stale"].bool != false
        latest = raw["latest"]
    }
    var state: String {
        if !enabled { return "Server disabled" }
        if !monitoring { return "Monitoring disabled" }
        return stale ? "No recent telemetry" : "Receiving telemetry"
    }
    var monitoringAction: String { monitoring ? "Pause monitoring" : "Enable monitoring" }
    var monitoringEdit: JSON { ["monitoringEnabled": .bool(!monitoring)] }
    var measuredAt: Date? { latest["at"].number.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var tiles: [StatTile] { SSHResourceHistory.tiles(latest["metrics"]) }
}

struct SSHResourceHistory: Equatable, Sendable {
    let samples: [JSON]
    let interval: Double
    init?(_ raw: JSON) {
        guard let samples = raw["samples"].array, raw["serverId"].number != nil else { return nil }
        self.samples = samples.sorted { ($0["at"].number ?? 0) < ($1["at"].number ?? 0) }
        interval = max(1, raw["intervalSeconds"].number ?? 60)
    }

    static func tiles(_ metrics: JSON) -> [StatTile] {
        guard metrics.isObject else { return [] }
        func bytes(_ reading: JSON) -> String { reading.number.map(StatsFormat.bytes) ?? "—" }
        var tiles = [
            StatTile(id: "cpu", label: "CPU", value: StatsFormat.percent(metrics["cpu"]["usagePercent"].number),
                     detail: metrics["cpu"]["cores"].int.map { "\($0) cores" } ?? "—", fraction: metrics["cpu"]["usagePercent"].number.map { $0 / 100 }),
            StatTile(id: "memory", label: "Memory", value: bytes(metrics["memory"]["usedBytes"]),
                     detail: "of \(bytes(metrics["memory"]["totalBytes"]))", fraction: metrics["memory"]["usedPercent"].number.map { $0 / 100 }),
            StatTile(id: "load", label: "Load average", value: StatsFormat.load(metrics["cpu"]["loadAverage"].items.compactMap(\.number)),
                     detail: "1, 5 and 15 minutes", fraction: nil),
            StatTile(id: "uptime", label: "Uptime", value: StatsFormat.uptime(metrics["uptimeSeconds"].number), detail: "since boot", fraction: nil),
            StatTile(id: "swap", label: "Swap", value: bytes(metrics["memory"]["swapUsedBytes"]),
                     detail: "of \(bytes(metrics["memory"]["swapTotalBytes"]))", fraction: nil),
        ]
        for disk in metrics["disks"].items {
            let mount = disk["mount"].string ?? "Disk"
            tiles.append(StatTile(id: "disk:\(mount)", label: mount, value: bytes(disk["usedBytes"]),
                                  detail: "of \(bytes(disk["totalBytes"]))", fraction: disk["usedPercent"].number.map { $0 / 100 }))
        }
        for network in metrics["network"].items {
            let name = network["name"].string ?? "Interface"
            func rate(_ key: String) -> String { network[key].number.map { StatsFormat.bytes($0) + "/s" } ?? "—" }
            tiles.append(StatTile(id: "network:\(name)", label: name, value: "↓ \(rate("rxBytesPerSecond"))",
                                  detail: "↑ \(rate("txBytesPerSecond"))", fraction: nil))
        }
        return tiles
    }

    /// A missing metric or minute starts a new line segment rather than joining across an outage.
    func series(id: String, label: String, unit: StatsSeries.Unit, slot: Int, value: (JSON) -> Double?) -> StatsSeries {
        var points: [StatsSeries.Point] = [], segment = 0
        var previous: Double?
        for sample in samples {
            guard let at = sample["at"].number, let v = value(sample["metrics"]), v.isFinite else {
                segment += 1; previous = nil; continue
            }
            if let previous, at - previous > interval * 1500 { segment += 1 }
            points.append(.init(at: Date(timeIntervalSince1970: at / 1000), value: v, segment: segment))
            previous = at
        }
        return StatsSeries(id: id, label: label, unit: unit, points: points, slot: slot, marksIsolatedReadings: true)
    }

    var charts: [StatsChart] {
        var charts = [StatsChart(id: "cpu", title: "CPU · last 24 hours", series: [series(id: "cpu", label: "CPU", unit: .percent, slot: 0) { $0["cpu"]["usagePercent"].number }]),
                      StatsChart(id: "memory", title: "Memory · last 24 hours", series: [series(id: "memory", label: "Memory", unit: .percent, slot: 1) { $0["memory"]["usedPercent"].number }])]
        let mounts = Set(samples.flatMap { $0["metrics"]["disks"].items.compactMap { $0["mount"].string } }).sorted()
        for mount in mounts {
            charts.append(StatsChart(id: "disk:\(mount)", title: "Disk · \(mount)", series: [series(id: mount, label: mount, unit: .percent, slot: 2) {
                $0["disks"].items.first { $0["mount"].string == mount }?["usedPercent"].number
            }]))
        }
        let names = Set(samples.flatMap { $0["metrics"]["network"].items.compactMap { $0["name"].string } }).sorted()
        for name in names {
            let lines = ["rxBytesPerSecond", "txBytesPerSecond"].enumerated().map { i, key in
                series(id: "\(name):\(key)", label: i == 0 ? "Received" : "Sent", unit: .bytesPerSecond, slot: i) {
                    $0["network"].items.first { $0["name"].string == name }?[key].number
                }
            }
            charts.append(StatsChart(id: "network:\(name)", title: "Network · \(name)", series: lines))
        }
        return charts
    }
}
