// CI windows, missing measurements, identity and pagination without live GitHub requests.
import XCTest
@testable import BriareusMacCore

final class CILogicTests: XCTestCase {
    func testHistoryArgumentsPreserveTheFrozenWindowAndFilters() {
        let window = CIQuery(days: 7, repo: "o/r", kind: .statuses).arguments(now: Date(timeIntervalSince1970: 2_000_000_000))
        for offset in [0, 50, 100] {
            let args = CIHistory.arguments(window: window, offset: offset)
            for key in window.keys { XCTAssertEqual(args[key], window[key]) }
            XCTAssertEqual(args["offset"], JSON(offset))
            XCTAssertEqual(args["limit"], 50)
        }
        XCTAssertNil(window.object?["offset"])
        XCTAssertNil(window.object?["limit"])
    }
    func testQueryUsesOneMillisecondWindowAndKeepsSourcesSeparate() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let all = CIQuery().arguments(now: now)
        XCTAssertEqual(all["until"].number, 2_000_000_000_000)
        XCTAssertEqual(all["until"].number! - all["since"].number!, 30 * 86_400_000)
        XCTAssertEqual(all["kind"], "check_run")
        XCTAssertNil(all.object?["repo"])
        let selected = CIQuery(days: 7, repo: "o/r", kind: .statuses).arguments(now: now)
        XCTAssertEqual(selected["repo"], "o/r")
        XCTAssertEqual(selected["kind"], "status")
        XCTAssertEqual(selected["until"].number! - selected["since"].number!, 7 * 86_400_000)
        XCTAssertEqual(APIRoute.named("ci_stats")?.path, "stats/ci")
        XCTAssertEqual(APIRoute.named("ci_runs")?.path, "ci/runs")
    }
    func testAbsentDurationsAndSuccessRatesRemainUnknown() throws {
        let empty = CIMetrics(["total": 3, "pending": 3, "successRate": nil, "avgDurationMs": nil])
        XCTAssertNil(empty.successRate)
        XCTAssertNil(empty.averageMs)
        XCTAssertEqual(empty.pending, 3)
        XCTAssertEqual(empty.tiles.count, 3)
        let measured = CIMetrics(["total": 4, "succeeded": 2, "failed": 1, "skipped": 1, "successRate": 0.666, "avgDurationMs": 2500])
        XCTAssertEqual(measured.total, 4)
        XCTAssertEqual(measured.successRate, 0.666)
        XCTAssertEqual(measured.averageMs, 2500)
        XCTAssertNotEqual(CIMetrics.duration(nil), CIMetrics.duration(0))
        XCTAssertNil(CIReading([:]))
        let reading = try XCTUnwrap(CIReading(["totals": ["total": 1], "daily": [["day": "2026-10-29", "total": 1]],
                                              "checks": [["name": "build", "app": "a"], ["name": "build", "app": "b"]]]))
        XCTAssertEqual(reading.daily.first?.metrics.total, 1)
        XCTAssertEqual(Set(reading.checks.map(\.id)).count, 2)
    }
    private func run(_ id: String, repo: String = "o/r") -> JSON {
        ["id": .string(id), "repo": .string(repo), "kind": "check_run", "name": "build", "headSha": "abcdef12345",
         "status": "completed", "conclusion": "success", "runAt": 1000, "durationMs": nil, "url": "https://github.com/o/r/actions/runs/1"]
    }
    func testHistoryKeepsRepositoryIdentityAndDeduplicatesAdjacentPages() throws {
        var history = CIHistory()
        try history.receive(["runs": .array([run("1"), run("2")]), "nextOffset": 50], offset: 0)
        XCTAssertEqual(history.runs.count, 2)
        XCTAssertEqual(history.nextOffset, 50)
        let record = try XCTUnwrap(history.runs.first)
        XCTAssertEqual(record.at, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(record.tone, .ok)
        XCTAssertNotNil(record.url)
        try history.receive(["runs": .array([run("2"), run("3"), run("1", repo: "other/repo")]), "nextOffset": nil], offset: 50)
        XCTAssertEqual(history.runs.count, 4)
        XCTAssertNil(history.nextOffset)
        try history.receive(["runs": [], "nextOffset": nil, "truncated": true], offset: 0)
        XCTAssertTrue(history.runs.isEmpty)
        XCTAssertTrue(history.truncated)
        XCTAssertThrowsError(try history.receive([:], offset: 0))
    }
    func testHistoryRejectsUnsafeLinksAndNonadvancingOffsets() throws {
        var payload = run("1")
        payload["url"] = "javascript:alert(1)"
        payload["conclusion"] = "timed_out"
        XCTAssertNil(CIRun(payload)?.url)
        XCTAssertEqual(CIRun(payload)?.tone, .danger)
        XCTAssertNil(CIRun(["id": "incomplete"]))
        var history = CIHistory()
        for next in [0, 50, 100_001] {
            try history.receive(["runs": [], "nextOffset": JSON(next)], offset: 50)
            XCTAssertNil(history.nextOffset)
        }
    }
    func testDashboardExposesCIOnlyWhenOneOfItsReadsIsSupported() {
        for operation in ["ci_stats", "ci_runs"] {
            let tabs = UsageDashboardTab.available { $0 == operation }
            XCTAssertEqual(tabs, [.usage, .ci])
            XCTAssertEqual(UsageDashboardTab.ci.resolved(in: tabs), .ci)
        }
        XCTAssertEqual(UsageDashboardTab.ci.resolved(in: [.usage]), .usage)
        XCTAssertNil(UsageDashboardTab.ci.serverTab)
    }
}
