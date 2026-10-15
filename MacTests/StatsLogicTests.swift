// The resource stats: the three routes' answers parsed, and the tiles, rows and charts both apps draw from them.
import XCTest
@testable import BriareusMacCore

final class StatsLogicTests: XCTestCase {
    private let host = #"{"cpus":4,"loadAverage":[1.5,1,0.5],"memoryBytes":8000,"freeMemoryBytes":2000,"intervalMs":5000}"#

    func testRoutesNameTheStatsPaths() throws {
        XCTAssertEqual(APIRoute.named("server_stats")?.path, "stats/server")
        XCTAssertEqual(APIRoute.named("sessions_stats")?.path, "stats/sessions")
        let r = try APIClient.resolve(APIRoute.named("session_stats")!, ["sessionId": "a b"])
        XCTAssertEqual(r.path, "sessions/a%20b/stats")
        XCTAssertEqual(APIRoute.named("session_stats")?.method, "GET")
    }

    func testSessionReadingParsesStatsRolesAndHistory() throws {
        let reading = try XCTUnwrap(SessionStatsReading(j(#"""
        {"host":\#(host),
         "stats":{"sessionId":"s1","at":1000,"cpuPercent":200,"memoryBytes":4000,"processes":5,
                  "roles":{"browser":{"cpuPercent":null,"memoryBytes":1000,"processes":2},"agent":{"cpuPercent":150,"memoryBytes":3000,"processes":3}},
                  "disk":{"bytes":2048,"measuredAt":900}},
         "history":[{"at":1000,"cpuPercent":null,"memoryBytes":10,"processes":1},{"at":2000,"cpuPercent":50,"memoryBytes":20,"processes":1},{"at":0}]}
        """#)))
        XCTAssertTrue(reading.isOpen)
        let s = try XCTUnwrap(reading.stats)
        // Roles in the screens' order, whatever the server's; a sample without a time is dropped.
        XCTAssertEqual(s.roles.map(\.role), [.agent, .browser])
        XCTAssertNil(s.roles[1].figures.cpuPercent)
        XCTAssertEqual(s.diskBytes, 2048)
        XCTAssertEqual(reading.history.count, 2)
        XCTAssertEqual(reading.host.usedMemoryBytes, 6000)

        let tiles = reading.tiles
        XCTAssertEqual(tiles.map(\.id), ["cpu", "memory", "processes", "disk"])
        // 200% of one core on four cores is half the machine; 4000 of 8000 bytes is half its memory.
        XCTAssertEqual(tiles[0].fraction, 0.5)
        XCTAssertEqual(tiles[1].fraction, 0.5)
        XCTAssertEqual(tiles[2].value, "5")
        XCTAssertEqual(tiles[3].value, "2.0 KB")
        XCTAssertEqual(reading.roleRows.map(\.id), ["agent", "browser"])
        XCTAssertEqual(reading.roleRows[0].cpuShare, 0.375)

        // A sample without CPU is left off the CPU line but kept on memory's.
        XCTAssertEqual(reading.charts.map { $0.series[0].points.count }, [1, 2])
        XCTAssertEqual(reading.charts.map(\.plots), [false, true])
    }

    func testClosedSessionHasNoStats() throws {
        let reading = try XCTUnwrap(SessionStatsReading(j(#"{"host":\#(host),"stats":null,"history":[]}"#)))
        XCTAssertFalse(reading.isOpen)
        XCTAssertTrue(reading.tiles.isEmpty)
        XCTAssertTrue(reading.roleRows.isEmpty)
        XCTAssertNil(SessionStatsReading(j(#"{"error":"x"}"#)))
    }

    func testOpenSessionRowsSortBusiestFirstAndNameByTitle() throws {
        let open = try XCTUnwrap(OpenSessionsStats(j(#"""
        {"host":\#(host),"sessions":[
          {"sessionId":"a","cpuPercent":10,"memoryBytes":100,"processes":1},
          {"sessionId":"b","cpuPercent":null,"memoryBytes":900,"processes":1},
          {"sessionId":"c","cpuPercent":10,"memoryBytes":300,"processes":2,"disk":{"bytes":1,"measuredAt":1}},
          {"cpuPercent":99}]}
        """#)))
        let rows = open.rows(titles: ["c": "Fix the build", "a": ""])
        XCTAssertEqual(rows.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(rows.map(\.title), ["Fix the build", "a", "b"])
        XCTAssertEqual(rows[0].cpuShare, 0.025)
        XCTAssertNil(rows[2].cpuShare)
    }

    func testServerStatsTilesDisksAndCharts() throws {
        let server = try XCTUnwrap(ServerStats(j(#"""
        {"host":{"cpus":4,"loadAverage":[3.8,2,1],"memoryBytes":1000,"freeMemoryBytes":50,"intervalMs":1000,"cpuPercent":80,"uptimeSeconds":90000},
         "process":{"cpuPercent":40,"memoryBytes":300,"heapUsedBytes":10,"heapTotalBytes":20,"uptimeSeconds":3700,"nodeVersion":"22.1.0"},
         "disks":[{"label":"workspaces","totalBytes":100,"freeBytes":20,"usedBytes":80},{"label":"files","totalBytes":100,"freeBytes":90}],
         "sessions":{"open":2,"cpuPercent":120,"memoryBytes":500,"processes":7,"diskBytes":4096},
         "history":[{"at":1000,"cpuPercent":40,"memoryBytes":300,"hostCpuPercent":null,"freeMemoryBytes":100,"loadAverage":1},
                    {"at":2000,"cpuPercent":80,"memoryBytes":310,"hostCpuPercent":60,"freeMemoryBytes":50,"loadAverage":2}]}
        """#)))
        XCTAssertEqual(server.tiles.map(\.id), ["host-cpu", "host-memory", "load", "uptime", "process", "sessions"])
        XCTAssertEqual(server.tiles.map(\.tone), [.warn, .danger, .danger, .muted, .ok, .ok])
        XCTAssertEqual(server.tiles[3].value, "1d 1h")
        XCTAssertEqual(server.tiles[5].value, "2")
        // A disk without usedBytes is its total less what is free.
        XCTAssertEqual(server.diskTiles.map(\.fraction), [0.8, 0.1])
        XCTAssertEqual(server.disks.map(\.label), ["workspaces", "files"])

        let cpu = server.charts[0].series, memory = server.charts[1].series
        XCTAssertEqual(cpu.map { $0.points.count }, [1, 2])
        // The process's percent of one core is scaled to the machine's axis (four cores).
        XCTAssertEqual(cpu[1].points.map(\.value), [10, 20])
        XCTAssertEqual(memory[0].points.map(\.value), [900, 950])
        XCTAssertEqual(memory[1].latest, "310 B")
    }

    func testFormats() {
        XCTAssertEqual(StatsFormat.bytes(0), "0 B")
        XCTAssertEqual(StatsFormat.bytes(1023), "1023 B")
        XCTAssertEqual(StatsFormat.bytes(1536), "1.5 KB")
        XCTAssertEqual(StatsFormat.bytes(10 * 1024 * 1024 - 1), "10 MB")
        XCTAssertEqual(StatsFormat.bytes(24 * 1024 * 1024 * 1024), "24 GB")
        XCTAssertEqual(StatsFormat.percent(nil), "\u{2014}")
        XCTAssertEqual(StatsFormat.percent(0), "0%")
        XCTAssertEqual(StatsFormat.percent(0.42), "0.4%")
        XCTAssertEqual(StatsFormat.percent(12.6), "13%")
        XCTAssertEqual(StatsFormat.uptime(40), "40s")
        XCTAssertEqual(StatsFormat.uptime(3720), "1h 2m")
        XCTAssertEqual(StatsFormat.load([]), "\u{2014}")
    }

    func testToneAndShare() {
        XCTAssertEqual([nil, 0.1, 0.75, 0.95].map(statsTone), [.muted, .ok, .warn, .danger])
        XCTAssertNil(statsShare(5, of: 0))
        XCTAssertNil(statsShare(nil, of: 10))
        XCTAssertEqual(statsShare(20, of: 10), 1)
    }

    func testPollFollowsTheSamplingInterval() {
        XCTAssertEqual(statsPollSeconds(nil), 5)
        XCTAssertEqual(statsPollSeconds(HostStats(j(#"{"intervalMs":500}"#))), 2)
        XCTAssertEqual(statsPollSeconds(HostStats(j(#"{"intervalMs":10000}"#))), 10)
    }
}
