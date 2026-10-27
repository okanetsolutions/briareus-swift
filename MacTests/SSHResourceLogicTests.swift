// Telemetry parsing, missing data, 24-hour chart gaps and SSH monitoring saves.
import XCTest
@testable import BriareusMacCore

final class SSHResourceLogicTests: XCTestCase {
    private func sample(_ at: Double, cpu: JSON = 25) -> JSON {
        ["at": .number(at), "error": .null, "metrics": [
            "cpu": ["cores": 4, "usagePercent": cpu],
            "memory": ["usedBytes": 400, "totalBytes": 1000, "availableBytes": 600, "usedPercent": 40],
            "network": [["name": "eth0", "rxBytesPerSecond": 100, "txBytesPerSecond": 50]],
            "disks": [["mount": "/", "usedBytes": 500, "totalBytes": 1000, "availableBytes": 450, "usedPercent": 52.63]],
        ]]
    }
    private func reading(_ samples: [JSON]) throws -> SSHResourceReading {
        try XCTUnwrap(SSHResourceReading(["from": 0, "to": 86_400_000, "samples": .array(samples)]))
    }
    func testRoutesAndSelection() throws {
        XCTAssertEqual(APIRoute.named("ssh_resource_servers")?.method, "GET")
        let route = try XCTUnwrap(APIRoute.named("ssh_resources"))
        let request = try APIClient.resolve(route, ["id": "1712345678901"])
        XCTAssertEqual(request.path, "ssh/servers/1712345678901/resources")
        XCTAssertNil(SSHResourceServer.list([:]))
        let servers = try XCTUnwrap(SSHResourceServer.list(["servers": [["id": 1712345678901, "label": "Host", "repo": "o/r"]]]))
        XCTAssertEqual(servers.first?.id, "1712345678901")
        XCTAssertEqual(SSHResourceServer.selection("removed", in: servers), "1712345678901")
        XCTAssertEqual(SSHResourceServer.selection("1712345678901", in: servers), "1712345678901")
        XCTAssertEqual(SSHResourceServer.selection("1712345678901", in: []), "")
    }
    func testNullRatesAndFailedSamplesDoNotBecomeZeros() throws {
        let first = try reading([sample(0, cpu: .null)])
        XCTAssertNil(first.tiles.first?.fraction)
        XCTAssertEqual(first.charts.first?.series.first?.points, [])
        let failed = try reading([sample(0), ["at": 60_000, "metrics": .null, "error": "unreachable"]])
        XCTAssertEqual(failed.error, "unreachable")
        XCTAssertTrue(failed.tiles.isEmpty)
        XCTAssertTrue(failed.networkTiles.isEmpty)
        XCTAssertTrue(failed.diskTiles.isEmpty)
    }
    func testChartsUseSeparateSegmentsAcrossMissingAttemptsAndLongGaps() throws {
        let r = try reading([sample(240_000), sample(0), ["at": 60_000, "metrics": .null], sample(120_000)])
        let points = try XCTUnwrap(r.charts.first?.series.first?.points)
        XCTAssertEqual(points.map(\.value), [25, 25, 25])
        XCTAssertNotEqual(points[0].segment, points[1].segment)
        XCTAssertNotEqual(points[1].segment, points[2].segment)
        XCTAssertEqual(r.tiles[0].fraction, 0.25)
        XCTAssertEqual(r.tiles[1].fraction, 0.4)
        XCTAssertEqual(r.diskTiles[0].fraction, 0.5263)
        XCTAssertEqual(r.charts.last?.series.map(\.unit), [.bytesPerSecond, .bytesPerSecond])
    }
    func testHistoryStaysInsideTheReturnedWindowAndKeepsInterfacesSeparate() throws {
        let r = try reading([sample(-60_000), sample(0), sample(86_460_000)])
        XCTAssertEqual(r.samples.count, 1)
        XCTAssertEqual(r.networkTiles.count, 1)
        XCTAssertEqual(r.charts.filter { $0.id.hasPrefix("network:") }.count, 1)
        XCTAssertNil(SSHResourceReading([:]))
    }
    func testMonitoringSaveIsExplicitAndCompatibleWithOlderServers() throws {
        let base: JSON = ["id": 1712345678901, "repo": "o/r", "host": "host", "port": 22, "username": "u"]
        let old = SSHServerFormState(row: base)
        XCTAssertFalse(old.offersMonitoring)
        XCTAssertNil(try old.body().get().object?["monitoringEnabled"])
        var row = base
        row["monitoringEnabled"] = false
        var state = SSHServerFormState(row: row)
        XCTAssertFalse(state.changed)
        state.monitoringEnabled = true
        XCTAssertTrue(state.tabChanged(.server))
        XCTAssertTrue(try state.body().get()["monitoringEnabled"].is(true))
        row["monitoringEnabled"] = true
        state.saved(row, sent: try state.body().get())
        XCTAssertFalse(state.changed)
        state.monitoringEnabled = false
        XCTAssertTrue(try state.body().get()["monitoringEnabled"].is(false))
    }
}
