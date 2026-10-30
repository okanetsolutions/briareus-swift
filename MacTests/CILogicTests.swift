// CI/CD history (Mac/Core/CILogic.swift): the query both CI screens send, `GET /stats/ci`'s figures and `GET /ci/runs`'
// pages, read into metrics, groups and runs.
import XCTest
@testable import BriareusMacCore

final class CILogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let nowMs = 1_790_000_000_000.0

    // MARK: - Query

    func testQueryPinsItsWindowToNow() {
        let q = CIFilter().query(now: now)
        XCTAssertEqual(q["until"].number, nowMs)
        XCTAssertEqual(q["since"].number, nowMs - 30 * 86_400_000)
        XCTAssertEqual(q["kind"], "check_run")
        XCTAssertNil(q.object?["repo"]); XCTAssertNil(q.object?["branch"])
        XCTAssertEqual(q.count, 3)
        XCTAssertEqual(CIFilter.windows, [7, 30, 90])
    }

    func testQueryCarriesItsFilters() {
        var f = CIFilter(repo: "o/r", days: 7, statuses: true, branch: "  main ")
        var q = f.query(now: now)
        XCTAssertEqual(q["since"].number, nowMs - 7 * 86_400_000)
        XCTAssertEqual(q["kind"], "status")
        XCTAssertEqual(q["repo"], "o/r")
        XCTAssertEqual(q["branch"], "main")
        // Empty filters are no filters.
        f.repo = ""; f.branch = "   "
        q = f.query(now: now)
        XCTAssertNil(q.object?["repo"]); XCTAssertNil(q.object?["branch"])
        f.branch = nil
        XCTAssertNil(f.query(now: now).object?["branch"])
    }

    func testRunsQueryPagesWithinTheSameWindow() {
        let window = CIFilter(repo: "o/r").query(now: now)
        var q = CIFilter().runsQuery(window: window)
        XCTAssertEqual(q["limit"], 50)
        XCTAssertNil(q.object?["offset"])
        XCTAssertEqual(q["since"], window["since"]); XCTAssertEqual(q["until"], window["until"]); XCTAssertEqual(q["repo"], "o/r")
        q = CIFilter().runsQuery(window: window, offset: 100, limit: 25)
        XCTAssertEqual(q["offset"], 100); XCTAssertEqual(q["limit"], 25)
        XCTAssertEqual(q["since"], window["since"])
        XCTAssertNil(CIFilter().runsQuery(window: window, offset: 0).object?["offset"])
    }

    // MARK: - Metrics

    func testMetricsReadEveryFigure() {
        let m = CIMetrics(j(#"""
        {"total":20,"pending":1,"succeeded":15,"failed":3,"cancelled":1,"skipped":0,"other":0,"successRate":0.8333,
         "timed":18,"avgDurationMs":192000,"maxDurationMs":600000,"totalDurationMs":3456000,"lastObservedAt":1790000000000}
        """#))
        XCTAssertEqual(m.total, 20); XCTAssertEqual(m.pending, 1); XCTAssertEqual(m.succeeded, 15); XCTAssertEqual(m.failed, 3)
        XCTAssertEqual(m.cancelled, 1); XCTAssertEqual(m.skipped, 0); XCTAssertEqual(m.other, 0)
        XCTAssertEqual(m.successRate, 0.8333)
        XCTAssertEqual(m.avgDurationMs, 192_000); XCTAssertEqual(m.maxDurationMs, 600_000); XCTAssertEqual(m.totalDurationMs, 3_456_000)
        XCTAssertEqual(m.lastObservedAt, now)
        XCTAssertEqual(m.successText, "83%")
        XCTAssertEqual(m.avgDurationText, formatDurationMs(192_000))
    }

    func testSummaryTilesCarryTheFiguresAndTheirTones() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let m = CIMetrics(["total": 12, "succeeded": 9, "failed": 2, "cancelled": 1, "pending": 3, "skipped": 4,
                           "successRate": 0.8, "avgDurationMs": 65_000, "lastObservedAt": 1_799_999_940_000])
        let tiles = m.tiles(now: now)
        XCTAssertEqual(tiles.map(\.id), ["total", "success", "failed", "duration", "pending"])
        XCTAssertEqual(tiles.map(\.value), ["12", m.successText, "2", m.avgDurationText, "3"])
        XCTAssertTrue(tiles.allSatisfy { $0.fraction == nil })
        XCTAssertNotEqual(tiles[0].detail, CIMetrics([:]).tiles(now: now)[0].detail)
        XCTAssertEqual(m.failedTone, .danger)
        XCTAssertEqual(CIMetrics(["failed": 0]).failedTone, .muted)
        XCTAssertEqual(m.tileTones, ["success": m.successTone, "failed": .danger])
    }

    func testMetricsWithNullsAndNothingDecided() {
        let m = CIMetrics(j(#"{"total":2,"pending":2,"successRate":null,"avgDurationMs":null,"maxDurationMs":null,"totalDurationMs":0,"lastObservedAt":null}"#))
        XCTAssertEqual(m.total, 2); XCTAssertEqual(m.pending, 2); XCTAssertEqual(m.failed, 0)
        XCTAssertNil(m.successRate); XCTAssertNil(m.avgDurationMs); XCTAssertNil(m.maxDurationMs); XCTAssertNil(m.lastObservedAt)
        XCTAssertEqual(m.totalDurationMs, 0)
        XCTAssertEqual(m.successTone, .faint)
        XCTAssertEqual(m.successText, m.avgDurationText)
        let empty = CIMetrics(.null)
        XCTAssertEqual(empty.total, 0); XCTAssertEqual(empty.totalDurationMs, 0); XCTAssertNil(empty.successRate)
    }

    func testSuccessToneThresholds() {
        let cases: [(Double, RowTone)] = [(1, .ok), (0.9, .ok), (0.8999, .warn), (0.7, .warn), (0.6999, .danger), (0, .danger)]
        for (rate, tone) in cases {
            XCTAssertEqual(CIMetrics(["successRate": .number(rate)]).successTone, tone, "\(rate)")
        }
        XCTAssertEqual(CIMetrics(["successRate": 1]).successText, "100%")
        XCTAssertEqual(CIMetrics(["successRate": 0.005]).successText, "1%")
    }

    // MARK: - Stats

    private let stats = #"""
    {"since":1,"until":2,"kind":"check_run","totals":{"total":10,"succeeded":7,"failed":3,"successRate":0.7,"totalDurationMs":0},
     "daily":[{"day":"2026-10-01","total":4,"failed":1},{"day":"","total":1},{"total":9},{"day":"2026-10-02","total":6,"failed":2}],
     "repositories":[{"repo":"o/a","total":8,"failed":3},{"total":2}],
     "checks":[{"name":"lint","app":"github-actions","total":3,"failed":1},{"name":"build","total":4,"failed":5},
               {"name":"Alpha","total":2,"failed":1},{"name":"test","app":"","total":5,"failed":0},{"app":"x","failed":9},
               {"name":"beta","failed":1}]}
    """#

    func testStatsReadTotalsAndGroups() {
        let s = CIStats(j(stats))
        XCTAssertEqual(s.totals.total, 10); XCTAssertEqual(s.totals.successTone, .warn)
        // Groups without their key are left out.
        XCTAssertEqual(s.daily.map(\.key), ["2026-10-01", "2026-10-02"])
        XCTAssertEqual(s.daily[1].metrics.failed, 2)
        XCTAssertEqual(s.repositories.map(\.key), ["o/a"])
        XCTAssertEqual(s.checks.map(\.key), ["lint", "build", "Alpha", "test", "beta"])
        XCTAssertEqual(s.checks[0].app, "github-actions")
        XCTAssertNil(s.checks[3].app)
        XCTAssertNil(s.daily[0].app)
        // A check's id tells apart two apps' checks of one name.
        XCTAssertEqual(s.checks[0].id, "lint|github-actions")
        XCTAssertEqual(s.checks[1].id, "build")
        XCTAssertEqual(CIStats(.null).checks, [])
    }

    func testMostFailingOrdersByFailuresThenNameAndLimits() {
        let s = CIStats(j(stats))
        XCTAssertEqual(s.mostFailing().map(\.key), ["build", "Alpha", "beta", "lint"])
        XCTAssertEqual(s.mostFailing(limit: 2).map(\.key), ["build", "Alpha"])
        XCTAssertEqual(s.mostFailing(limit: 0), [])
        // A check that never failed is not among them.
        XCTAssertFalse(s.mostFailing(limit: 100).contains { $0.key == "test" })
    }

    // MARK: - Runs

    func testRunStateForEveryStatusAndConclusion() {
        let cases: [(String, String?, CIRunState)] = [
            ("queued", nil, .pending), ("in_progress", "success", .pending), ("", nil, .pending),
            ("completed", "success", .succeeded),
            ("completed", "failure", .failed), ("completed", "error", .failed), ("completed", "timed_out", .failed),
            ("completed", "startup_failure", .failed), ("completed", "action_required", .failed),
            ("completed", "cancelled", .cancelled),
            ("completed", "skipped", .skipped), ("completed", "neutral", .skipped),
            ("completed", "stale", .other), ("completed", nil, .other), ("completed", "", .other),
        ]
        for (status, conclusion, state) in cases {
            XCTAssertEqual(CIRunState(status: status, conclusion: conclusion), state, "\(status) \(conclusion ?? "nil")")
        }
        let tones: [(CIRunState, RowTone)] = [(.pending, .running), (.succeeded, .ok), (.failed, .danger), (.cancelled, .muted),
                                              (.skipped, .faint), (.other, .faint)]
        for (state, tone) in tones { XCTAssertEqual(state.tone, tone, "\(state)") }
        XCTAssertEqual(Set([CIRunState.pending, .succeeded, .failed, .cancelled, .skipped, .other].map(\.title)).count, 6)
    }

    func testARunReadsEveryField() {
        let r = CIRun(j(#"""
        {"repo":"o/r","kind":"check_run","id":"98765","name":"test","app":"github-actions","headSha":"abcdef1234","branch":"main",
         "status":"completed","conclusion":"failure","url":"https://github.com/o/r/runs/98765","startedAt":1,"completedAt":2,
         "durationMs":192000,"runAt":1790000000000,"observedAt":1790000001000}
        """#))!
        XCTAssertEqual(r.repo, "o/r"); XCTAssertEqual(r.kind, "check_run"); XCTAssertEqual(r.runID, "98765"); XCTAssertEqual(r.name, "test")
        XCTAssertEqual(r.app, "github-actions"); XCTAssertEqual(r.headSha, "abcdef1234"); XCTAssertEqual(r.branch, "main")
        XCTAssertEqual(r.status, "completed"); XCTAssertEqual(r.conclusion, "failure")
        XCTAssertEqual(r.url, "https://github.com/o/r/runs/98765")
        XCTAssertEqual(r.durationMs, 192_000); XCTAssertEqual(r.runAt, now)
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(r.id, "o/r|check_run|98765")
        XCTAssertEqual(r.meta, ["o/r", "main", "abcdef1", formatDurationMs(192_000)].joined(separator: " \u{00B7} "))
    }

    func testARunNeedsAnIDAndANameAndDefaultsTheRest() {
        let numeric = CIRun(j(#"{"id":12345678901,"name":"lint","status":"queued"}"#))!
        XCTAssertEqual(numeric.runID, "12345678901")
        XCTAssertEqual(numeric.repo, ""); XCTAssertEqual(numeric.kind, "check_run"); XCTAssertEqual(numeric.headSha, "")
        XCTAssertNil(numeric.app); XCTAssertNil(numeric.branch); XCTAssertNil(numeric.conclusion); XCTAssertNil(numeric.url)
        XCTAssertNil(numeric.durationMs); XCTAssertNil(numeric.runAt)
        XCTAssertEqual(numeric.state, .pending)
        XCTAssertEqual(numeric.meta, "")
        XCTAssertEqual(CIRun(j(#"{"id":"s1","name":"ci/build","kind":"status","conclusion":"","app":""}"#))?.kind, "status")
        XCTAssertNil(CIRun(j(#"{"id":"s1","name":"x","conclusion":""}"#))?.conclusion)
        XCTAssertNil(CIRun(j(#"{"id":"1"}"#)))
        XCTAssertNil(CIRun(j(#"{"id":"1","name":""}"#)))
        XCTAssertNil(CIRun(j(#"{"name":"lint"}"#)))
        XCTAssertNil(CIRun(j(#"{"id":"","name":"lint"}"#)))
    }

    func testARunsPageKeepsValidRunsAndSaysWhereTheNextStarts() {
        var page = CIRunsPage(j(#"""
        {"since":1,"until":2,"kind":"check_run","runs":[{"id":"1","name":"a"},{"id":"2"},{"id":3,"name":"c"}],"nextOffset":50,"truncated":false}
        """#))
        XCTAssertEqual(page.runs.map(\.runID), ["1", "3"])
        XCTAssertEqual(page.nextOffset, 50)
        XCTAssertFalse(page.truncated)
        page = CIRunsPage(j(#"{"runs":[],"nextOffset":null,"truncated":true}"#))
        XCTAssertEqual(page.runs, []); XCTAssertNil(page.nextOffset); XCTAssertTrue(page.truncated)
        page = CIRunsPage(.null)
        XCTAssertEqual(page.runs, []); XCTAssertNil(page.nextOffset); XCTAssertFalse(page.truncated)
    }

    func testARunsFeedReplacesOnTheFirstPageAndExtendsOnLaterOnes() {
        var feed = CIRunsFeed()
        feed.receive(CIRunsPage(j(#"{"runs":[{"id":"1","name":"a"}],"nextOffset":50}"#)), offset: 0)
        feed.receive(CIRunsPage(j(#"{"runs":[{"id":"2","name":"b"}],"nextOffset":null,"truncated":true}"#)), offset: 50)
        XCTAssertEqual(feed.runs.map(\.runID), ["1", "2"])
        XCTAssertNil(feed.nextOffset); XCTAssertTrue(feed.truncated); XCTAssertNil(feed.failedOffset)
        feed.receive(CIRunsPage(j(#"{"runs":[{"id":"3","name":"c"}],"nextOffset":50}"#)), offset: 0)
        XCTAssertEqual(feed.runs.map(\.runID), ["3"])
        XCTAssertEqual(feed.nextOffset, 50); XCTAssertFalse(feed.truncated)
    }

    func testAFailedLaterPageKeepsTheRunsAndIsTheOneToRetry() {
        var feed = CIRunsFeed()
        feed.receive(CIRunsPage(j(#"{"runs":[{"id":"1","name":"a"}],"nextOffset":50}"#)), offset: 0)
        feed.fail(offset: 50)
        XCTAssertEqual(feed.runs.map(\.runID), ["1"])
        XCTAssertEqual(feed.nextOffset, 50)
        XCTAssertEqual(feed.failedOffset, 50)
        feed.receive(CIRunsPage(j(#"{"runs":[{"id":"2","name":"b"}]}"#)), offset: 50)
        XCTAssertEqual(feed.runs.map(\.runID), ["1", "2"])
        XCTAssertNil(feed.failedOffset)
    }

    func testAFailedFirstPageDropsTheRunsOfTheWindowReadBefore() {
        var feed = CIRunsFeed()
        feed.receive(CIRunsPage(j(#"{"runs":[{"id":"1","name":"a"}],"nextOffset":50,"truncated":true}"#)), offset: 0)
        feed.fail(offset: 0)
        XCTAssertEqual(feed.runs, [])
        XCTAssertNil(feed.nextOffset); XCTAssertFalse(feed.truncated)
        XCTAssertEqual(feed.failedOffset, 0)
    }

    func testOnlyTheDefaultFilterIsUnfiltered() {
        XCTAssertFalse(CIFilter().isFiltered)
        XCTAssertTrue(CIFilter(repo: "o/r").isFiltered)
        XCTAssertTrue(CIFilter(days: CIFilter.windows[0]).isFiltered)
        XCTAssertTrue(CIFilter(statuses: true).isFiltered)
        XCTAssertTrue(CIFilter(branch: "main").isFiltered)
    }

    func testTheCIRoutesExist() {
        XCTAssertEqual(APIRoute.named("ci_stats")?.method, "GET")
        XCTAssertEqual(APIRoute.named("ci_stats")?.path, "stats/ci")
        XCTAssertEqual(APIRoute.named("ci_runs")?.method, "GET")
        XCTAssertEqual(APIRoute.named("ci_runs")?.path, "ci/runs")
    }
}

final class CIDailyBarsTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    func testADayKeyIsMidnightOfThatDayInTheCalendarGiven() {
        let d = ciDayDate("2026-10-28", calendar: utc)
        XCTAssertEqual(d.map { utc.dateComponents([.year, .month, .day, .hour], from: $0) },
                       DateComponents(year: 2026, month: 10, day: 28, hour: 0))
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(ciDayDate("2026-10-28", calendar: tokyo).map { tokyo.component(.day, from: $0) }, 28)
        for bad in ["", "2026-10", "2026-13-01", "2026-10-32", "2026-10-x", "2026--10-01"] { XCTAssertNil(ciDayDate(bad, calendar: utc), bad) }
    }

    func testEachDayStacksSucceededFailedAndTheRestLeavingOutEmptySegmentsAndBadDays() {
        let stats = CIStats(["daily": [
            ["day": "2026-10-27", "total": 10, "succeeded": 7, "failed": 2],
            ["day": "2026-10-28", "total": 3, "succeeded": 3, "failed": 0],
            ["day": "nope", "total": 5, "succeeded": 5],
            ["day": "2026-10-29", "total": 1, "succeeded": 1, "failed": 2],
        ]])
        let bars = ciDailyBars(stats.daily, calendar: utc)
        XCTAssertEqual(bars.map(\.kind), [.succeeded, .failed, .other, .succeeded, .succeeded, .failed])
        XCTAssertEqual(bars.map(\.count), [7, 2, 1, 3, 1, 2])
        XCTAssertEqual(Set(bars.map(\.id)).count, bars.count)
        XCTAssertEqual(CIDailyBar.Kind.failed.tone, .danger)
        XCTAssertEqual(CIDailyBar.Kind.succeeded.tone, .ok)
    }
}
