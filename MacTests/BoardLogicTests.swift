// The board screens' own logic: descriptions as GitHub shows them, the conversation timeline, the files tree and the counts.
import XCTest
@testable import BriareusMacCore

final class BoardLogicTests: XCTestCase {
    func testPullListFreshnessUsesGitHubSyncTime() {
        let board = j(#"{"syncedAt":"2026-10-27T12:00:00Z","pulls":[]}"#)
        let syncedAt = boardDateParse(board["syncedAt"].string)!
        XCTAssertFalse(pullsNeedRefresh(board, now: syncedAt))
        XCTAssertFalse(pullsNeedRefresh(board, now: syncedAt.addingTimeInterval(299)))
        XCTAssertTrue(pullsNeedRefresh(board, now: syncedAt.addingTimeInterval(300)))
        XCTAssertTrue(pullsNeedRefresh(board, now: syncedAt.addingTimeInterval(900)))
        XCTAssertFalse(pullsNeedRefresh(board, now: syncedAt.addingTimeInterval(-1)))
        XCTAssertFalse(pullsNeedRefresh(board, now: syncedAt.addingTimeInterval(-120)))
        XCTAssertFalse(pullsNeedRefresh(board, now: syncedAt.addingTimeInterval(-300)))
    }

    func testPullListWithoutAValidSyncTimeNeedsRefresh() {
        let now = boardDateParse("2026-10-27T12:00:00Z")!
        XCTAssertTrue(pullsNeedRefresh(.null, now: now))
        XCTAssertTrue(pullsNeedRefresh(j(#"{"pulls":[]}"#), now: now))
        XCTAssertTrue(pullsNeedRefresh(j(#"{"syncedAt":"invalid"}"#), now: now))
        XCTAssertTrue(pullsNeedRefresh(j(#"{"syncedAt":"2026-10-27T12:00:00Z"}"#), now: nil))
    }

    func testPullListUsesServerTimeAndElapsedTimeDespiteDeviceClockSkew() {
        let instant = ContinuousClock.now
        let reference = ServerTimeReference("Tue, 27 Oct 2026 12:00:00 GMT", at: instant)!
        let board = j(#"{"syncedAt":"2026-10-27T12:00:00Z"}"#)
        // The device's wall clock is never an input to the reference, whether minutes ahead or behind.
        XCTAssertFalse(pullsNeedRefresh(board, now: reference.now(at: instant)))
        XCTAssertFalse(pullsNeedRefresh(board, now: reference.now(at: instant.advanced(by: .seconds(299)))))
        XCTAssertTrue(pullsNeedRefresh(board, now: reference.now(at: instant.advanced(by: .seconds(300)))))
        XCTAssertTrue(pullsNeedRefresh(board, now: reference.now(at: instant.advanced(by: .seconds(900)))))
        // Receiving an old GitHub sync again does not reset its age.
        let later = ServerTimeReference("Tue, 27 Oct 2026 12:05:00 GMT", at: instant)!
        XCTAssertTrue(pullsNeedRefresh(board, now: later.now(at: instant)))
        XCTAssertNil(ServerTimeReference(nil))
        XCTAssertNil(ServerTimeReference("invalid"))
    }

    @MainActor
    func testAutomaticPullReadReusesWarmServerCache() async throws {
        var now: Date?
        var requests: [Bool] = []
        let cached = j(#"{"syncedAt":"2026-10-27T12:00:00Z","pulls":[]}"#)
        let answer = try await readPulls(fresh: false, now: { now }) { fresh in
            requests.append(fresh)
            // The first HTTP response establishes server time before freshness is checked.
            now = boardDateParse("2026-10-27T12:01:00Z")
            return cached
        }
        XCTAssertEqual(requests, [false])
        XCTAssertEqual(answer, cached)
    }

    @MainActor
    func testAutomaticPullReadRefreshesStaleServerCache() async throws {
        let now = boardDateParse("2026-10-27T12:05:00Z")!
        let stale = j(#"{"syncedAt":"2026-10-27T12:00:00Z"}"#)
        let updated = j(#"{"syncedAt":"2026-10-27T12:05:00Z"}"#)
        var requests: [Bool] = []
        let answer = try await readPulls(fresh: false, now: { now }) { fresh in
            requests.append(fresh)
            return fresh ? updated : stale
        }
        XCTAssertEqual(requests, [false, true])
        XCTAssertEqual(answer, updated)
    }

    @MainActor
    func testManualPullReadSkipsServerCache() async throws {
        var requests: [Bool] = []
        _ = try await readPulls(fresh: true, now: { nil }) { fresh in
            requests.append(fresh)
            return [:]
        }
        XCTAssertEqual(requests, [true])
    }

    @MainActor
    func testPullReadFallsBackForOldServer() async throws {
        var requests: [Bool] = []
        let answer = try await readPulls(fresh: false, now: { nil }) { fresh in
            requests.append(fresh)
            if fresh { throw APIError(.http, status: 400) }
            return [:]
        }
        XCTAssertEqual(requests, [false, true, false])
        XCTAssertEqual(answer, [:])
    }

    @MainActor
    func testPullReadPropagatesFailuresWithoutRetrying() async {
        for failureAt in [0, 1] {
            var requests: [Bool] = []
            let failure = APIError(.http, status: 429, retryAfter: 60)
            do {
                _ = try await readPulls(fresh: false, now: { nil }) { fresh in
                    requests.append(fresh)
                    if requests.count == failureAt + 1 { throw failure }
                    return [:]
                }
                XCTFail("The failed read must propagate")
            } catch { XCTAssertEqual(error as? APIError, failure) }
            XCTAssertEqual(requests, failureAt == 0 ? [false] : [false, true])
        }
    }

    @MainActor
    func testFreshPullsReadRetriesUnsupportedArgumentOnlyOnce() async throws {
        var requests: [Bool] = []
        let answer: JSON = ["pulls": []]
        let result = await readPulls(fresh: true) { fresh in
            requests.append(fresh)
            return fresh ? .failure(APIError(.http, status: 400)) : .success(answer)
        }
        XCTAssertEqual(requests, [true, false])
        XCTAssertEqual(try result.get(), answer)

        requests = []
        let failure = APIError(.http, status: 400)
        let failed = await readPulls(fresh: true) { fresh in
            requests.append(fresh)
            return .failure(failure)
        }
        XCTAssertEqual(requests, [true, false])
        XCTAssertThrowsError(try failed.get()) { XCTAssertEqual($0 as? APIError, failure) }
    }

    @MainActor
    func testPullsReadReturnsSuccessAndOtherFailuresWithoutRetry() async throws {
        let answer: JSON = ["pulls": []]
        for fresh in [false, true] {
            var requests: [Bool] = []
            let result = await readPulls(fresh: fresh) { flag in
                requests.append(flag)
                return .success(answer)
            }
            XCTAssertEqual(requests, [fresh])
            XCTAssertEqual(try result.get(), answer)
            for failure in [APIError(.http, status: 400), APIError(.http, status: 401),
                            APIError(.http, status: 429), APIError(.http, status: 502), APIError(.cancelled)] {
                if fresh && failure.status == 400 { continue }
                requests = []
                let result = await readPulls(fresh: fresh) { flag in
                    requests.append(flag)
                    return .failure(failure)
                }
                XCTAssertEqual(requests, [fresh])
                XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? APIError, failure) }
            }
        }
    }

    func testVisibleMarkdownDropsCommentsAndRawHTMLButKeepsCode() {
        XCTAssertEqual(visibleMarkdown("Hello <!-- hidden --> world"), "Hello  world")
        XCTAssertEqual(visibleMarkdown("Keep\n<!-- open forever\nlost"), "Keep")
        XCTAssertEqual(visibleMarkdown("<img src=x>\nText\n  <details>\nMore"), "Text\nMore")
        XCTAssertEqual(visibleMarkdown("```\n<div>\n```\n<p>"), "```\n<div>\n```")
        XCTAssertEqual(visibleMarkdown("  \n\n"), "")
        XCTAssertEqual(visibleMarkdown("a\r\n<b>\r\nc"), "a\r\nc")
    }

    func testTimelineSortsByTimeAndNestsThreadsUnderTheirReview() {
        let comments = j(#"[{"id":1,"body":"hi","createdAt":"2024-01-01T10:00:00Z"}]"#)
        let reviews = j(#"[{"id":10,"state":"APPROVED","body":"","submittedAt":"2024-01-01T09:00:00Z"},{"id":11,"state":"COMMENTED","body":"","submittedAt":"2024-01-01T11:00:00Z"},{"id":12,"state":"PENDING","body":"x"}]"#)
        let lines = j(#"[{"id":100,"reviewId":11,"createdAt":"2024-01-01T11:00:00Z"},{"id":101,"inReplyTo":100,"createdAt":"2024-01-01T12:00:00Z"},{"id":102,"createdAt":"2024-01-01T08:00:00Z"}]"#)
        let t = convTimeline(comments: comments, reviews: reviews, lines: lines)
        XCTAssertEqual(t.map(\.feed), [.reviewComments, .reviews, .comments, .reviews])
        XCTAssertEqual(t.map(\.index), [2, 0, 0, 1])
        XCTAssertEqual(convThreadRoot(lines, 1), 0)
        XCTAssertEqual(convReviewThreads(reviews: reviews, lines: lines, review: 1), [0])
        XCTAssertEqual(convThread(lines: lines, root: 0), [0, 1])
        // One comment, three line comments and the approval; the bare comment review and the pending one say nothing.
        XCTAssertEqual(convCount(comments: comments, reviews: reviews, lines: lines), 5)
        XCTAssertEqual(ReviewVerdict(j(#"{"state":"changes_requested"}"#)), .changesRequested)
        XCTAssertNil(ReviewVerdict(j(#"{"state":"COMMENTED"}"#)))
    }

    func testThreadRootStopsOnCycles() {
        let lines = j(#"[{"id":1,"inReplyTo":2},{"id":2,"inReplyTo":1}]"#)
        XCTAssertTrue([0, 1].contains(convThreadRoot(lines, 0)))
    }

    func testConvListKeepsWhatWasReadUntilTheLastPageIsIn() {
        var list = ConvList(items: j(#"[{"id":9}]"#), read: true)
        list.begin()
        XCTAssertTrue(list.loading)
        XCTAssertEqual(list.take(j(#"{"comments":[{"id":1}],"nextPage":2}"#), feed: .comments, page: 1), 2)
        XCTAssertEqual(list.items, j(#"[{"id":9}]"#))
        XCTAssertNil(list.take(j(#"{"comments":[{"id":2}],"nextPage":2}"#), feed: .comments, page: 2))
        XCTAssertEqual(list, ConvList(items: j(#"[{"id":1},{"id":2}]"#), read: true))

        var lines = ConvList()
        lines.begin()
        XCTAssertNil(lines.take(j(#"{"reviewComments":[{"id":5}]}"#), feed: .reviewComments, page: 1))
        XCTAssertEqual(lines.items.count, 1)
    }

    func testConvListFailureSaysWhyButACancelDoesNot() {
        var list = ConvList(items: j(#"[{"id":9}]"#), read: true)
        list.begin()
        _ = list.take(j(#"{"reviews":[{"id":1}],"nextPage":2}"#), feed: .reviews, page: 1)
        list.fail(nil)
        XCTAssertEqual(list, ConvList(items: j(#"[{"id":9}]"#), read: true))
        var fresh = ConvList()
        fresh.begin()
        fresh.fail("Offline")
        XCTAssertEqual(fresh, ConvList(read: true, error: "Offline"))
        XCTAssertTrue(convAllRead([fresh, ConvList(), ConvList()], supports: { $0 == "pull_comments" }))
        XCTAssertFalse(convAllRead([fresh, ConvList(), ConvList()], supports: { _ in true }))
    }

    func testFileTreeCompactsSortsAndFolds() {
        let files = ["src/b.swift", "src/App/Views/A.swift", "README.md", "src/a.swift", "docs/x/y/z.md"].map(PullFile.init(filename:))
        let tree = FileTree(files)
        let rows = tree.rows(collapsed: [])
        let names = rows.map { tree.nodes[$0.node].name }
        XCTAssertEqual(names, ["docs/x/y", "z.md", "src", "App/Views", "A.swift", "a.swift", "b.swift", "README.md"])
        XCTAssertEqual(rows.map(\.indent), [0, 1, 0, 1, 2, 1, 1, 0])
        let src = rows[2].node
        XCTAssertEqual(tree.nodes[src].path, "src")
        XCTAssertEqual(tree.nodes[rows[3].node].path, "src/App/Views")
        XCTAssertEqual(tree.rows(collapsed: ["src"]).map { tree.nodes[$0.node].name }, ["docs/x/y", "z.md", "src", "README.md"])
        XCTAssertEqual(tree.nodes[rows[4].node].file, 1)
    }

    func testFindingsCountsAndCatalog() {
        let f = j(#"[{"fixed":true,"decision":"fix"},{"decision":"fix"},{"decision":"optional"},{}]"#)
        XCTAssertEqual(findingsUnfixed(f), 3)
        XCTAssertEqual(findingsToFix(f), 1)
        XCTAssertTrue(catalogLists(.null, "implement-feedback"))
        XCTAssertFalse(catalogLists(j(#"[{"id":"review"}]"#), "implement-feedback"))
        XCTAssertTrue(diffstatBlocks(additions: 30, deletions: 10) == (3, 1))
        XCTAssertTrue(diffstatBlocks(additions: 0, deletions: 0) == (0, 0))
    }

    func testIssueRunsMatchTheIssueOrItsPullRequests() {
        let issue = IssueSummary(j(#"{"number":7,"title":"x","pulls":[{"number":9},{"number":3,"repo":"other/repo"}]}"#))!
        XCTAssertTrue(issueRunMatches(Session(raw: j(#"{"repo":"a/b","title":"Issue #7: x"}"#)), issue: issue, repo: "a/b"))
        XCTAssertTrue(issueRunMatches(Session(raw: j(#"{"repo":"a/b","startedOnPr":9}"#)), issue: issue, repo: "a/b"))
        XCTAssertFalse(issueRunMatches(Session(raw: j(#"{"repo":"a/b","startedOnPr":3}"#)), issue: issue, repo: "a/b"))
        XCTAssertFalse(issueRunMatches(Session(raw: j(#"{"repo":"c/d","title":"Issue #7: x"}"#)), issue: issue, repo: "a/b"))
        XCTAssertEqual(runsCost([Session(raw: j(#"{"usage":{"costUsd":1.5}}"#)), Session(raw: j(#"{"costUsd":0.5}"#)), Session(raw: j("{}"))]), 2)
        XCTAssertNil(runsCost([Session(raw: j("{}"))]))
    }
}
