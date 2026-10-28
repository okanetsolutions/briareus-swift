// What Briareus costs the machine it runs on: an open session's CPU, memory, processes and workspace disk
// (`GET /sessions/{id}/stats`), every open session's (`GET /stats/sessions`) and the server's own figures, disks and last
// hour (`GET /stats/server`). Parsed here, and turned into the tiles, rows and chart series both apps' Resources screens
// draw, so the iPhone and the Mac say the same thing.
import Foundation

// MARK: - Figures

/// The machine the sessions share. `cpuPercent` (every core busy is 100) and `uptimeSeconds` come only with the server's
/// stats.
struct HostStats: Equatable, Sendable {
    var cpus: Int
    var loadAverage: [Double]
    var memoryBytes: Double
    var freeMemoryBytes: Double
    var intervalMs: Double
    var cpuPercent: Double?
    var uptimeSeconds: Double?

    init(_ j: JSON) {
        cpus = j["cpus"].int ?? 0
        loadAverage = j["loadAverage"].items.compactMap(\.number)
        memoryBytes = j["memoryBytes"].number ?? 0
        freeMemoryBytes = j["freeMemoryBytes"].number ?? 0
        intervalMs = j["intervalMs"].number ?? 0
        cpuPercent = j["cpuPercent"].number
        uptimeSeconds = j["uptimeSeconds"].number
    }
    var usedMemoryBytes: Double { max(0, memoryBytes - freeMemoryBytes) }
}

/// The kinds of process a session runs, in the order the screens list them.
enum ProcessRole: String, CaseIterable, Sendable {
    case agent, serve, browser
    var label: String {
        switch self {
        case .agent: return "Agent"
        case .serve: return "\u{25B6} Run"
        case .browser: return "Shared browser"
        }
    }
}

/// CPU (100 is one core busy; nil on the first sample after a restart), resident memory and a process count.
struct ProcessFigures: Equatable, Sendable {
    var cpuPercent: Double?
    var memoryBytes: Double
    var processes: Int

    init(_ j: JSON) {
        cpuPercent = j["cpuPercent"].number
        memoryBytes = j["memoryBytes"].number ?? 0
        processes = j["processes"].int ?? 0
    }
    init(cpuPercent: Double?, memoryBytes: Double, processes: Int) {
        self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes; self.processes = processes
    }
}

/// An open session right now: its processes together, each kind running, and its workspace's size once measured.
struct SessionStats: Equatable, Sendable {
    var sessionId: String
    var at: Date?
    var total: ProcessFigures
    /// The kinds running, in `ProcessRole` order; a kind with nothing running is absent.
    var roles: [RoleFigures]
    var diskBytes: Double?
    var diskMeasuredAt: Date?

    init?(_ j: JSON) {
        guard j.isObject, let id = j["sessionId"].nonEmpty else { return nil }
        sessionId = id
        at = epochMs(j["at"])
        total = ProcessFigures(j)
        roles = ProcessRole.allCases.compactMap { r in
            j["roles"][r.rawValue].isObject ? RoleFigures(role: r, figures: ProcessFigures(j["roles"][r.rawValue])) : nil
        }
        diskBytes = j["disk"]["bytes"].number
        diskMeasuredAt = epochMs(j["disk"]["measuredAt"])
    }
}

/// One kind of process a session runs, and its figures.
struct RoleFigures: Equatable, Sendable {
    var role: ProcessRole
    var figures: ProcessFigures
}

/// One point of a session's last hour.
struct SessionStatsSample: Equatable, Sendable {
    var at: Date
    var figures: ProcessFigures
    init?(_ j: JSON) {
        guard let at = epochMs(j["at"]) else { return nil }
        self.at = at
        figures = ProcessFigures(j)
    }
}

/// `GET /sessions/{id}/stats`. `stats` is nil and `history` empty while the session is not open.
struct SessionStatsReading: Equatable, Sendable {
    var stats: SessionStats?
    var history: [SessionStatsSample]
    var host: HostStats

    init?(_ j: JSON) {
        guard j.isObject, j["host"].isObject else { return nil }
        stats = SessionStats(j["stats"])
        history = j["history"].items.compactMap(SessionStatsSample.init)
        host = HostStats(j["host"])
    }
    var isOpen: Bool { stats != nil }
}

/// `GET /stats/sessions`: the machine and every open session of the token's projects.
struct OpenSessionsStats: Equatable, Sendable {
    var host: HostStats
    var sessions: [SessionStats]
    init?(_ j: JSON) {
        guard j.isObject, j["host"].isObject else { return nil }
        host = HostStats(j["host"])
        sessions = j["sessions"].items.compactMap(SessionStats.init)
    }
}

/// A disk sessions write to: `workspaces` (the clones) or `files` (published files and recordings).
struct StatsDisk: Equatable, Sendable {
    var label: String
    var totalBytes: Double
    var freeBytes: Double
    var usedBytes: Double
    init(_ j: JSON) {
        label = j["label"].string ?? ""
        totalBytes = j["totalBytes"].number ?? 0
        freeBytes = j["freeBytes"].number ?? 0
        usedBytes = j["usedBytes"].number ?? max(0, totalBytes - freeBytes)
    }
    var title: String { label == "workspaces" ? "Workspaces" : label == "files" ? "Files and recordings" : label }
}

/// One point of the server's last hour: the Briareus process's CPU and memory, and the machine's.
struct ServerStatsSample: Equatable, Sendable {
    var at: Date
    var cpuPercent: Double?
    var memoryBytes: Double
    var hostCpuPercent: Double?
    var freeMemoryBytes: Double
    var loadAverage: Double?
    init?(_ j: JSON) {
        guard let at = epochMs(j["at"]) else { return nil }
        self.at = at
        cpuPercent = j["cpuPercent"].number
        memoryBytes = j["memoryBytes"].number ?? 0
        hostCpuPercent = j["hostCpuPercent"].number
        freeMemoryBytes = j["freeMemoryBytes"].number ?? 0
        loadAverage = j["loadAverage"].number
    }
}

/// `GET /stats/server`: the machine, the Briareus process, its disks, the open sessions together and the last hour.
struct ServerStats: Equatable, Sendable {
    var host: HostStats
    var process: ProcessFigures
    var heapUsedBytes: Double
    var heapTotalBytes: Double
    var processUptimeSeconds: Double?
    var nodeVersion: String?
    var disks: [StatsDisk]
    var openSessions: Int
    var sessions: ProcessFigures
    var sessionsDiskBytes: Double
    var history: [ServerStatsSample]

    init?(_ j: JSON) {
        guard j.isObject, j["host"].isObject else { return nil }
        host = HostStats(j["host"])
        let p = j["process"]
        process = ProcessFigures(cpuPercent: p["cpuPercent"].number, memoryBytes: p["memoryBytes"].number ?? 0, processes: 1)
        heapUsedBytes = p["heapUsedBytes"].number ?? 0
        heapTotalBytes = p["heapTotalBytes"].number ?? 0
        processUptimeSeconds = p["uptimeSeconds"].number
        nodeVersion = p["nodeVersion"].nonEmpty
        disks = j["disks"].items.map(StatsDisk.init)
        let s = j["sessions"]
        openSessions = s["open"].int ?? 0
        sessions = ProcessFigures(s)
        sessionsDiskBytes = s["diskBytes"].number ?? 0
        history = j["history"].items.compactMap(ServerStatsSample.init)
    }
}

private func epochMs(_ j: JSON) -> Date? {
    guard let ms = j.number, ms.isFinite, ms > 0 else { return nil }
    return Date(timeIntervalSince1970: ms / 1000)
}

// MARK: - Words and numbers

enum StatsFormat {
    /// "0 B", "512 KB", "1.5 GB", "24 GB": binary units, one decimal under ten.
    static func bytes(_ n: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = n.isFinite ? max(0, n) : 0, unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        if unit == 0 { return "\(Int(value)) B" }
        // One decimal under ten, unless it rounds up to ten.
        if value < 9.95 { return String(format: "%.1f %@", value, units[unit]) }
        return String(format: "%.0f %@", value, units[unit])
    }
    /// "12%", "0.4%" under one, or a dash when the figure is not known yet.
    static func percent(_ p: Double?) -> String {
        guard let p, p.isFinite else { return "\u{2014}" }
        if p > 0 && p < 0.95 { return String(format: "%.1f%%", p) }
        return String(format: "%.0f%%", p)
    }
    /// "3d 4h", "5h 12m", "12m", "40s".
    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "\u{2014}" }
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }
    /// "1.24 · 0.98 · 0.75": the load over 1, 5 and 15 minutes.
    static func load(_ values: [Double]) -> String {
        values.isEmpty ? "\u{2014}" : values.map { String(format: "%.2f", $0) }.joined(separator: " \u{00B7} ")
    }
    static func processes(_ n: Int) -> String { "\(n) process\(n == 1 ? "" : "es")" }
}

/// How full a gauge reads: past three quarters it warns, past nine tenths it is a danger.
func statsTone(_ fraction: Double?) -> RowTone {
    guard let fraction else { return .muted }
    if fraction >= 0.9 { return .danger }
    if fraction >= 0.75 { return .warn }
    return .ok
}

/// A share in 0...1, or nil when the whole is unknown.
func statsShare(_ part: Double?, of whole: Double) -> Double? {
    guard let part, whole > 0, part.isFinite else { return nil }
    return min(1, max(0, part / whole))
}

// MARK: - What the screens show

/// A figure on a tile: its label, the value, a line under it and, for a gauge, how full it is.
struct StatTile: Equatable, Sendable, Identifiable {
    var id: String
    var label: String
    var value: String
    var detail: String
    /// 0...1 for a bar under the value; nil draws none.
    var fraction: Double?
    var tone: RowTone { statsTone(fraction) }
}

/// A row of figures: a session or one kind of its processes.
struct StatsRow: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var cpu: String
    var memory: String
    var detail: String
    /// The session's CPU as a share of the whole machine, for its bar.
    var cpuShare: Double?
}

/// A line over the last hour. `unit` says how its axis reads.
struct StatsSeries: Equatable, Sendable, Identifiable {
    enum Unit: Equatable, Sendable { case percent, bytes, bytesPerSecond }
    struct Point: Equatable, Sendable { var at: Date; var value: Double; var segment = 0 }
    var id: String
    var label: String
    var unit: Unit
    var points: [Point]
    /// The colour slot of BriareusChart the line is drawn in.
    var slot: Int

    /// Remote telemetry keeps isolated readings visible across outages.
    var marksIsolatedReadings = false

    /// A segment with no neighbour needs a point mark to make its reading visible.
    var isolatedPoints: [Point] {
        guard marksIsolatedReadings else { return [] }
        let counts = Dictionary(grouping: points, by: \.segment).mapValues(\.count)
        return points.filter { counts[$0.segment] == 1 }
    }
    /// The axis label of a value of this series.
    func axis(_ value: Double) -> String { unit == .percent ? StatsFormat.percent(value) : StatsFormat.bytes(value) + (unit == .bytesPerSecond ? "/s" : "") }
    /// The last value, as the legend names it.
    var latest: String { points.last.map { axis($0.value) } ?? "\u{2014}" }
}

/// A chart: the series sharing one axis.
struct StatsChart: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var series: [StatsSeries]
    /// Remote telemetry can draw a point before a line can form.
    var plots: Bool { series.contains { $0.points.count > 1 || !$0.isolatedPoints.isEmpty } }
}

extension SessionStatsReading {
    /// CPU (as a share of every core), memory (of the machine's), processes and the workspace's disk.
    var tiles: [StatTile] {
        guard let s = stats else { return [] }
        let cores = Double(max(host.cpus, 1)) * 100
        return [
            StatTile(id: "cpu", label: "CPU", value: StatsFormat.percent(s.total.cpuPercent),
                     detail: "of one core \u{00B7} \(host.cpus) on the machine", fraction: statsShare(s.total.cpuPercent, of: cores)),
            StatTile(id: "memory", label: "Memory", value: StatsFormat.bytes(s.total.memoryBytes),
                     detail: "of \(StatsFormat.bytes(host.memoryBytes))", fraction: statsShare(s.total.memoryBytes, of: host.memoryBytes)),
            StatTile(id: "processes", label: "Processes", value: "\(s.total.processes)",
                     detail: s.roles.map(\.role.label).joined(separator: ", "), fraction: nil),
            StatTile(id: "disk", label: "Workspace", value: s.diskBytes.map(StatsFormat.bytes) ?? "\u{2014}",
                     detail: s.diskBytes == nil ? "not measured yet" : "on disk", fraction: nil),
        ]
    }
    /// One row per kind of process running.
    var roleRows: [StatsRow] {
        guard let s = stats else { return [] }
        let cores = Double(max(host.cpus, 1)) * 100
        return s.roles.map { r in
            StatsRow(id: r.role.rawValue, title: r.role.label, cpu: StatsFormat.percent(r.figures.cpuPercent),
                     memory: StatsFormat.bytes(r.figures.memoryBytes), detail: StatsFormat.processes(r.figures.processes),
                     cpuShare: statsShare(r.figures.cpuPercent, of: cores))
        }
    }
    var charts: [StatsChart] {
        [
            StatsChart(id: "cpu", title: "CPU", series: [
                StatsSeries(id: "cpu", label: "Session", unit: .percent,
                            points: history.compactMap { s in s.figures.cpuPercent.map { .init(at: s.at, value: $0) } }, slot: 0),
            ]),
            StatsChart(id: "memory", title: "Memory", series: [
                StatsSeries(id: "memory", label: "Session", unit: .bytes,
                            points: history.map { .init(at: $0.at, value: $0.figures.memoryBytes) }, slot: 1),
            ]),
        ]
    }
}

/// The conversations this device has read, every project's saved list together: what names an open session's row and
/// which record the row opens its Resources with.
struct KnownSessions: Sendable {
    var sessions: [Session]

    init(_ sessions: [Session]) { self.sessions = sessions }
    /// Each of `repos`' saved conversation lists (`sessions:<repo>`).
    init(repos: [String], cache: DiskCache) {
        sessions = repos.flatMap { cache.value("sessions:\($0)").flatMap(Session.parseList) ?? [] }
    }

    /// Each conversation's title by its id; the first of a repeated id wins.
    var titles: [String: String] { Dictionary(sessions.map { ($0.id, $0.displayTitle) }) { a, _ in a } }
    /// The conversation's record as it was read, else its id and the row's name.
    func record(_ row: StatsRow) -> JSON {
        sessions.first { $0.id == row.id }?.raw ?? ["id": .string(row.id), "title": .string(row.title)]
    }
}

extension OpenSessionsStats {
    /// The open sessions, the busiest first, named by the conversations read.
    func rows(known: KnownSessions) -> [StatsRow] { rows(titles: known.titles) }

    /// The open sessions, the busiest first (CPU, then memory); `titles` names each by its id, else the id stands.
    func rows(titles: [String: String]) -> [StatsRow] {
        let cores = Double(max(host.cpus, 1)) * 100
        return sessions
            .sorted { a, b in
                let ca = a.total.cpuPercent ?? -1, cb = b.total.cpuPercent ?? -1
                return ca != cb ? ca > cb : a.total.memoryBytes > b.total.memoryBytes
            }
            .map { s in
                var detail = [StatsFormat.processes(s.total.processes)]
                if let disk = s.diskBytes { detail.append("\(StatsFormat.bytes(disk)) on disk") }
                return StatsRow(id: s.sessionId, title: titles[s.sessionId].flatMap { $0.isEmpty ? nil : $0 } ?? s.sessionId,
                                cpu: StatsFormat.percent(s.total.cpuPercent), memory: StatsFormat.bytes(s.total.memoryBytes),
                                detail: detail.joined(separator: " \u{00B7} "), cpuShare: statsShare(s.total.cpuPercent, of: cores))
            }
    }
}

extension ServerStats {
    /// The machine first (CPU, memory, load, uptime), then the Briareus process and the open sessions together.
    var tiles: [StatTile] {
        let cores = Double(max(host.cpus, 1)) * 100
        return [
            StatTile(id: "host-cpu", label: "Machine CPU", value: StatsFormat.percent(host.cpuPercent),
                     detail: "\(host.cpus) core\(host.cpus == 1 ? "" : "s")", fraction: statsShare(host.cpuPercent, of: 100)),
            StatTile(id: "host-memory", label: "Machine memory", value: StatsFormat.bytes(host.usedMemoryBytes),
                     detail: "of \(StatsFormat.bytes(host.memoryBytes)) \u{00B7} \(StatsFormat.bytes(host.freeMemoryBytes)) free",
                     fraction: statsShare(host.usedMemoryBytes, of: host.memoryBytes)),
            StatTile(id: "load", label: "Load", value: host.loadAverage.first.map { String(format: "%.2f", $0) } ?? "\u{2014}",
                     detail: StatsFormat.load(host.loadAverage), fraction: statsShare(host.loadAverage.first, of: Double(max(host.cpus, 1)))),
            StatTile(id: "uptime", label: "Machine up", value: StatsFormat.uptime(host.uptimeSeconds), detail: "since its last start", fraction: nil),
            StatTile(id: "process", label: "Briareus server", value: StatsFormat.percent(process.cpuPercent),
                     detail: "\(StatsFormat.bytes(process.memoryBytes)) \u{00B7} up \(StatsFormat.uptime(processUptimeSeconds))"
                        + (nodeVersion.map { " \u{00B7} Node \($0)" } ?? ""),
                     fraction: statsShare(process.cpuPercent, of: cores)),
            StatTile(id: "sessions", label: "Open sessions", value: "\(openSessions)",
                     detail: "\(StatsFormat.percent(sessions.cpuPercent)) \u{00B7} \(StatsFormat.bytes(sessions.memoryBytes)) \u{00B7} "
                        + "\(StatsFormat.bytes(sessionsDiskBytes)) on disk",
                     fraction: statsShare(sessions.cpuPercent, of: cores)),
        ]
    }
    /// One gauge per disk: what is used of it.
    var diskTiles: [StatTile] {
        disks.map { d in
            StatTile(id: "disk-\(d.label)", label: d.title, value: StatsFormat.bytes(d.usedBytes),
                     detail: "of \(StatsFormat.bytes(d.totalBytes)) \u{00B7} \(StatsFormat.bytes(d.freeBytes)) free",
                     fraction: statsShare(d.usedBytes, of: d.totalBytes))
        }
    }
    /// The last hour: CPU of the machine and of Briareus, then the machine's used memory and Briareus's.
    var charts: [StatsChart] {
        let cores = Double(max(host.cpus, 1))
        return [
            StatsChart(id: "cpu", title: "CPU", series: [
                StatsSeries(id: "host-cpu", label: "Machine", unit: .percent,
                            points: history.compactMap { s in s.hostCpuPercent.map { .init(at: s.at, value: $0) } }, slot: 0),
                // The process's 100 is one core; on the machine's axis it is a share of every core.
                StatsSeries(id: "process-cpu", label: "Briareus", unit: .percent,
                            points: history.compactMap { s in s.cpuPercent.map { .init(at: s.at, value: $0 / cores) } }, slot: 1),
            ]),
            StatsChart(id: "memory", title: "Memory", series: [
                StatsSeries(id: "host-memory", label: "Machine in use", unit: .bytes,
                            points: history.map { .init(at: $0.at, value: max(0, host.memoryBytes - $0.freeMemoryBytes)) }, slot: 0),
                StatsSeries(id: "process-memory", label: "Briareus", unit: .bytes,
                            points: history.map { .init(at: $0.at, value: $0.memoryBytes) }, slot: 1),
            ]),
        ]
    }
}

/// How often a stats screen reads again: the server's sampling interval, no faster than every two seconds, and every five
/// before the first answer says.
func statsPollSeconds(_ host: HostStats?) -> Double {
    guard let ms = host?.intervalMs, ms > 0 else { return 5 }
    return max(2, ms / 1000)
}
