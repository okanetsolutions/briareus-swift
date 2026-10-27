// The global pull list's repository identity, filtering, caches, and independent project failures.
import XCTest
@testable import BriareusMacCore

final class BoardGlobalPullsLogicTests: XCTestCase {
    private let projects = j(#"{"projects":[{"repo":"o/a","label":"Alpha"},{"repo":"o/b","label":"Beta"}]}"#)
    private let first = j(#"{"pulls":[{"number":7,"title":"Login","branch":"fix/login","author":"alice","draft":true,"labels":["bug"],"reviewers":[{"user":"bob"}],"updatedAt":"2026-10-25T12:00:00Z"}]}"#)
    private let second = j(#"{"pulls":[{"number":7,"title":"Database","updatedAt":"2026-10-26T12:00:00Z"}]}"#)

    private func state() -> GlobalPullsState {
        var state = GlobalPullsState()
        state.replaceProjects(Project.parseList(projects)!, saved: { $0 == "o/a" ? first : second })
        return state
    }

    func testBoardProgressKeepsBackgroundReadsOutOfLoadedLists() {
        XCTAssertTrue(boardShowsLoading(loaded: false, refreshing: false))
        XCTAssertTrue(boardShowsLoading(loaded: false, refreshing: true))
        XCTAssertFalse(boardShowsLoading(loaded: true, refreshing: false))
        XCTAssertTrue(boardShowsLoading(loaded: true, refreshing: true))
    }

    @MainActor
    func testProgressDistinguishesInitialLoadPollAndUserRefresh() async {
        for failure in [nil, APIError(.network), APIError(.cancelled)] {
            let reader = GlobalPullsReader(saved: { key in key == "projects" ? self.projects : self.first })
            var changes: [GlobalPullsState] = []
            await reader.load(projects: { self.projects }, saved: { _ in self.first },
                              read: { _ in self.first }, current: { true }, changed: { changes.append($0) })
            XCTAssertTrue(changes.first?.showsLoading == true)
            XCTAssertFalse(reader.state.showsLoading)
            changes.removeAll()
            await reader.load(projects: { self.projects }, saved: { _ in self.first },
                              read: { _ in self.first }, current: { true }, changed: { changes.append($0) })
            XCTAssertTrue(changes.allSatisfy { !$0.showsLoading && !$0.refreshing })
            changes.removeAll()
            await reader.load(fresh: true, projects: { self.projects }, saved: { _ in self.first }, read: { _ in
                if let failure { throw failure }
                return self.second
            }, current: { true }, changed: { changes.append($0) })
            XCTAssertTrue(changes.contains { $0.loading && $0.refreshing && $0.showsLoading })
            XCTAssertTrue(changes.filter(\.refreshing).allSatisfy(\.showsLoading))
            XCTAssertFalse(reader.state.refreshing)
            XCTAssertFalse(reader.state.showsLoading)
        }
    }

    func testRowsKeepRepositoryIdentityAndNewestFirst() {
        let rows = state().rows
        XCTAssertEqual(rows.map(\.id), ["o/b#7", "o/a#7"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows[1].project.label, "Alpha")
        XCTAssertTrue(rows[1].pull.draft)
        XCTAssertEqual(rows[1].pull.raw, first["pulls"][0])
    }

    func testMissingDatesAndTiesHaveStableRepositoryAndNumberOrder() {
        var state = GlobalPullsState()
        state.replaceProjects([Project(repo: "o/b"), Project(repo: "o/a")], saved: { _ in
            self.jBoard([3, 8])
        })
        XCTAssertEqual(state.rows.map(\.id), ["o/a#8", "o/a#3", "o/b#8", "o/b#3"])
    }

    func testSearchMatchesProjectPeopleLabelsBranchAndNumberWithAllWords() {
        for query in ["ALPHA", "o/a", "alice", "bob", "bug", "fix/login", "#7", "  Alpha\n bug  "] {
            let found = GlobalPullsFilter(query: query).rows(in: state())
            XCTAssertTrue(found.contains { $0.id == "o/a#7" }, query)
        }
        XCTAssertTrue(GlobalPullsFilter(query: "Alpha Database").rows(in: state()).isEmpty)
        XCTAssertEqual(GlobalPullsFilter(query: "\n ").rows(in: state()).count, 2)
        XCTAssertFalse(GlobalPullsFilter(query: "\n ").isOn)
    }

    func testProjectFilterCombinesWithSearchAndCanBeCleared() {
        var filter = GlobalPullsFilter(query: "#7", repo: "O/A")
        XCTAssertEqual(filter.rows(in: state()).map(\.id), ["o/a#7"])
        filter.query = "Database"
        XCTAssertTrue(filter.rows(in: state()).isEmpty)
        filter = GlobalPullsFilter()
        XCTAssertFalse(filter.isOn)
        XCTAssertEqual(filter.rows(in: state()).count, 2)
    }

    func testProjectsAndRowsAreDeduplicatedAndRemovedProjectsLeave() {
        var state = state()
        state.replaceProjects([Project(repo: "o/a", label: "Renamed"), Project(repo: "O/A")], saved: { _ in nil })
        XCTAssertEqual(state.projects.count, 1)
        XCTAssertEqual(state.rows.map(\.project.title), ["Renamed"])
        var entry = state.projects[0]
        try! entry.adopt(j(#"{"pulls":[{"number":4},{"number":4},{"number":0},{}]}"#))
        XCTAssertEqual(entry.rows.map(\.id), ["o/a#4"])
        state.replaceProjects([], saved: { _ in self.first })
        XCTAssertTrue(state.rows.isEmpty)
    }

    func testStackChainTravelsWithTheCorrectRepository() throws {
        var entry = GlobalPullProject(project: Project(repo: "o/a"))
        try entry.adopt(j(#"{"pulls":[{"number":4,"stack":{"id":2,"position":1,"total":2}}],"stacks":{"2":[{"number":4,"branch":"feature"},{"number":8}]}}"#))
        XCTAssertEqual(entry.rows.first?.stack?.chain.map(\.number), [4, 8])
        XCTAssertEqual(entry.rows.first?.stack?.json["chain"][0]["branch"].string, "feature")
    }

    @MainActor
    func testReaderRestoresOnlyProjectsInItsSavedList() {
        let reader = GlobalPullsReader(saved: { key in
            if key == "projects" { return self.projects }
            return key == "pulls:o/a" ? self.first : nil
        })
        XCTAssertEqual(reader.state.rows.map(\.id), ["o/a#7"])
        XCTAssertFalse(reader.state.loaded)
    }

    @MainActor
    func testPartialFailureKeepsCachedRowsAndPublishesSuccessfulProjects() async {
        let reader = GlobalPullsReader(saved: { _ in nil })
        var changes: [GlobalPullsState] = []
        var asked: [String] = []
        let error = await reader.load(projects: { self.projects }, saved: { _ in self.first }, read: { repo in
            asked.append(repo)
            if repo == "o/a" { throw APIError(.http, status: 503) }
            return self.second
        }, current: { true }, changed: { changes.append($0) })
        XCTAssertNil(error)
        XCTAssertEqual(asked, ["o/a", "o/b"])
        XCTAssertEqual(reader.state.rows.map(\.id), ["o/b#7", "o/a#7"])
        XCTAssertEqual(reader.state.projects[0].error?.status, 503)
        XCTAssertNil(reader.state.projects[1].error)
        XCTAssertTrue(changes.contains { $0.loading && $0.projects.first?.error?.status == 503 })
        XCTAssertTrue(reader.state.loaded)
        XCTAssertFalse(reader.state.loading)
        XCTAssertTrue(reader.state.hasErrors)
    }

    @MainActor
    func testMalformedBoardKeepsCacheAndDoesNotStopOtherProjects() async {
        let reader = GlobalPullsReader(saved: { _ in nil })
        await reader.load(projects: { self.projects }, saved: { _ in self.first }, read: { repo in
            repo == "o/a" ? .null : self.second
        }, current: { true }, changed: { _ in })
        XCTAssertEqual(reader.state.projects[0].error?.kind, .nonJSON)
        XCTAssertEqual(reader.state.rows.count, 2)
    }

    @MainActor
    func testCooldownRetainsRowsAndRecoveryClearsErrorAndRemovedProjects() async {
        let reader = GlobalPullsReader(saved: { _ in nil })
        await reader.load(projects: { self.projects }, saved: { _ in self.first }, read: { _ in nil },
                          current: { true }, changed: { _ in })
        XCTAssertEqual(reader.state.rows.count, 2)
        XCTAssertTrue(reader.state.projects.allSatisfy { $0.error?.status == 429 })
        await reader.load(projects: { Project.json([Project(repo: "o/b")]) }, saved: { _ in nil },
                          read: { _ in self.second }, current: { true }, changed: { _ in })
        XCTAssertEqual(reader.state.rows.map(\.id), ["o/b#7"])
        XCTAssertFalse(reader.state.hasErrors)
    }

    @MainActor
    func testProjectFailureKeepsCacheAndDoesNotReadRepositories() async {
        let reader = GlobalPullsReader(saved: { key in key == "projects" ? self.projects : self.first })
        var reads = 0
        let error = await reader.load(projects: { throw APIError(.http, status: 503) }, saved: { _ in nil }, read: { _ in
            reads += 1
            return self.second
        }, current: { true }, changed: { _ in })
        XCTAssertEqual(error?.status, 503)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(reader.state.rows.count, 2)
        XCTAssertTrue(reader.state.loaded)
        XCTAssertFalse(reader.state.loading)
    }

    @MainActor
    func testUnauthorizedReadClearsDataAndStopsReading() async {
        let reader = GlobalPullsReader(saved: { _ in nil })
        var reads = 0
        let error = await reader.load(projects: { self.projects }, saved: { _ in self.first }, read: { _ in
            reads += 1
            throw APIError(.http, status: 401)
        }, current: { true }, changed: { _ in })
        XCTAssertTrue(error?.unauthorized == true)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(reader.state.projects.isEmpty)
        XCTAssertFalse(reader.state.loading)
    }

    @MainActor
    func testCancellationIsNotShownAsAReadFailure() async {
        let reader = GlobalPullsReader(saved: { _ in nil })
        var reads = 0
        let error = await reader.load(projects: { self.projects }, saved: { _ in self.first }, read: { _ in
            reads += 1
            throw CancellationError()
        }, current: { true }, changed: { _ in })
        XCTAssertEqual(error?.kind, .cancelled)
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(reader.state.hasErrors)
        XCTAssertFalse(reader.state.loading)
    }

    @MainActor
    func testChangedConnectionDiscardsAnAnswerBeforeReadingRepositories() async {
        let reader = GlobalPullsReader(saved: { _ in nil })
        var connected = true
        var reads = 0
        _ = await reader.load(projects: {
            connected = false
            return self.projects
        }, saved: { _ in self.first }, read: { _ in
            reads += 1
            return self.first
        }, current: { connected }, changed: { _ in })
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(reader.state.projects.isEmpty)
        XCTAssertFalse(reader.state.loading)
    }

    @MainActor
    func testEmptyAccessibleProjectsCompleteWithoutReadingRepositories() async {
        let reader = GlobalPullsReader(saved: { _ in nil })
        var reads = 0
        await reader.load(projects: { Project.json([]) }, saved: { _ in self.first }, read: { _ in
            reads += 1
            return self.first
        }, current: { true }, changed: { _ in })
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(reader.state.loaded)
        XCTAssertTrue(reader.state.rows.isEmpty)
        XCTAssertFalse(reader.state.hasErrors)
    }

    func testRemovedProjectFilterResetsWithoutLosingSearchAndMatchesPickerCase() {
        var state = state()
        var filter = GlobalPullsFilter(query: "#7", repo: "O/A").reconciled(in: state)
        XCTAssertEqual(filter.repo, "o/a")
        state.replaceProjects([Project(repo: "o/b")], saved: { _ in nil })
        filter = filter.reconciled(in: state)
        XCTAssertEqual(filter.repo, "")
        XCTAssertEqual(filter.query, "#7")
        XCTAssertEqual(filter.rows(in: state).map(\.id), ["o/b#7"])
        XCTAssertEqual(GlobalPullsFilter(repo: "o/b").reconciled(in: GlobalPullsState()).repo, "")
    }

    func testPreparedRowsUpdateAfterBoardAndProjectChanges() throws {
        var state = state()
        let snapshot = state
        try state.projects[0].adopt(jBoard([9]))
        XCTAssertEqual(state.rows.map(\.id), ["o/b#7", "o/a#9"])
        XCTAssertTrue(GlobalPullsFilter(query: "Login").rows(in: state).isEmpty)
        XCTAssertEqual(GlobalPullsFilter(query: "#9").rows(in: state).map(\.id), ["o/a#9"])
        state.replaceProjects([Project(repo: "O/A", label: "Renamed")], saved: { _ in nil })
        XCTAssertEqual(GlobalPullsFilter(query: "RENAMED", repo: "o/a").rows(in: state).map(\.id), ["o/a#9"])
        XCTAssertTrue(GlobalPullsFilter(query: "Alpha").rows(in: state).isEmpty)
        XCTAssertEqual(snapshot.rows.map(\.id), ["o/b#7", "o/a#7"])
    }

    @MainActor
    func testCachedBoardsPreserveRealErrorsThroughCooldownUntilRecovery() async {
        for status in [404, 502] {
            let reader = GlobalPullsReader(saved: { _ in nil })
            let failure = APIError(.http, status: status)
            await reader.load(projects: { self.projects }, saved: { _ in self.first },
                              read: { _ in throw failure }, current: { true }, changed: { _ in })
            var changes: [GlobalPullsState] = []
            await reader.load(projects: { self.projects }, saved: { _ in self.first },
                              read: { _ in nil }, current: { true }, changed: { changes.append($0) })
            XCTAssertTrue(changes.allSatisfy { $0.projects.allSatisfy { $0.error == failure } })
            XCTAssertEqual(reader.state.rows.count, 2)
            await reader.load(projects: { self.projects }, saved: { _ in self.first },
                              read: { _ in self.second }, current: { true }, changed: { _ in })
            XCTAssertFalse(reader.state.hasErrors)
        }
    }

    @MainActor
    func testNewReadersReportCooldownFailuresFromOtherScreensAndRecover() async {
        let now = Date(timeIntervalSince1970: 1_000)
        for status in [404, 502] {
            var cooldown = PullsCooldown()
            let failure = APIError(.http, status: status, message: "Unavailable repository", retryAfter: 60)
            // The board screen failed before either global reader existed.
            cooldown.failed("o/a", error: failure, now: now)
            for _ in 0..<2 {
                let reader = GlobalPullsReader(saved: { _ in nil })
                var reads: [String] = []
                await reader.load(projects: { self.projects }, saved: { _ in self.first },
                                  cooldownError: { cooldown.error($0, now: now) }, read: { repo in
                    guard cooldown.mayRead(repo, now: now) else { return nil }
                    reads.append(repo)
                    return self.second
                }, current: { true }, changed: { _ in })
                XCTAssertEqual(reads, ["o/b"])
                XCTAssertEqual(reader.state.projects[0].error, failure)
                XCTAssertNil(reader.state.projects[1].error)
                XCTAssertEqual(reader.state.rows.count, 2)
                await reader.load(projects: { self.projects }, saved: { _ in self.first },
                                  cooldownError: { cooldown.error($0, now: now.addingTimeInterval(60)) },
                                  read: { _ in self.second }, current: { true }, changed: { _ in })
                XCTAssertFalse(reader.state.hasErrors)
            }
        }
    }

    @MainActor
    func testOnlyCurrentParseableProjectsAreKept() async {
        for answer in [projects, JSON.null] {
            for connectionChanges in [false, true] {
                let reader = GlobalPullsReader(saved: { _ in nil })
                var current = true
                var kept: [JSON] = []
                await reader.load(projects: {
                    current = !connectionChanges
                    return answer
                }, saved: { _ in nil }, keepProjects: { kept.append($0) },
                                  read: { _ in self.first }, current: { current }, changed: { _ in })
                XCTAssertEqual(kept, !connectionChanges && answer == projects ? [projects] : [])
            }
        }
    }

    @MainActor
    func testFreshRefreshWaitsForPollThenForItsOwnRead() async {
        let reader = GlobalPullsReader(saved: { _ in nil })
        let polling = expectation(description: "Poll is reading")
        let refreshing = expectation(description: "Fresh pass is reading")
        let queued = expectation(description: "Refresh requested during the poll")
        var finishPoll: CheckedContinuation<Void, Never>?
        var finishFresh: CheckedContinuation<Void, Never>?
        var events: [String] = []
        var returned = false
        let list = Project.json([Project(repo: "o/a")])
        let poll = Task {
            await reader.load(projects: { list }, saved: { _ in nil }, read: { _ in
                events.append("poll")
                await withCheckedContinuation { finishPoll = $0; polling.fulfill() }
                return self.first
            }, current: { true }, changed: { _ in })
        }
        await fulfillment(of: [polling], timeout: 5)
        XCTAssertFalse(reader.state.refreshing)
        let refresh = Task {
            queued.fulfill()
            let result = await reader.load(fresh: true, projects: { list }, saved: { _ in nil }, read: { _ in
                events.append("fresh")
                await withCheckedContinuation { finishFresh = $0; refreshing.fulfill() }
                return self.second
            }, current: { true }, changed: { _ in })
            returned = true
            return result
        }
        await fulfillment(of: [queued], timeout: 5)
        XCTAssertTrue(reader.state.refreshing)
        XCTAssertTrue(reader.state.showsLoading)
        XCTAssertFalse(returned)
        XCTAssertEqual(events, ["poll"])
        // A second poll does not queue another pass.
        await reader.load(projects: { XCTFail("Overlapping poll"); return list }, saved: { _ in nil },
                          read: { _ in nil }, current: { true }, changed: { _ in })
        finishPoll?.resume()
        await fulfillment(of: [refreshing], timeout: 5)
        XCTAssertFalse(returned)
        XCTAssertEqual(events, ["poll", "fresh"])
        XCTAssertTrue(reader.state.loading)
        finishFresh?.resume()
        let pollError = await poll.value
        let freshError = await refresh.value
        XCTAssertNil(pollError)
        XCTAssertNil(freshError)
        XCTAssertEqual(reader.state.rows.first?.pull.title, "Database")
        XCTAssertFalse(reader.state.loading)
        XCTAssertFalse(reader.state.refreshing)
        XCTAssertFalse(reader.state.showsLoading)
    }

    @MainActor
    func testQueuedFreshRefreshesShareOnePassAndWaitForItsResult() async {
        for initiallyFresh in [false, true] {
            for failure in [nil, APIError(.http, status: 503)] {
                let reader = GlobalPullsReader(saved: { _ in nil })
                let loading = expectation(description: "Initial pass is reading")
                let queued = expectation(description: "Four refreshes queued during the initial pass")
                queued.expectedFulfillmentCount = 4
                let refreshing = expectation(description: "Shared fresh pass is reading")
                var finishInitial: CheckedContinuation<Void, Never>?
                var finishFresh: CheckedContinuation<Void, Never>?
                var projectReads = 0, boardReads = 0, returned = 0
                let list = Project.json([Project(repo: "o/a")])
                let initial = Task {
                    await reader.load(fresh: initiallyFresh, projects: {
                        projectReads += 1
                        return list
                    }, saved: { _ in nil }, read: { _ in
                        boardReads += 1
                        await withCheckedContinuation { finishInitial = $0; loading.fulfill() }
                        return self.first
                    }, current: { true }, changed: { _ in })
                }
                await fulfillment(of: [loading], timeout: 5)
                let refreshes = (0..<4).map { _ in Task {
                    queued.fulfill()
                    let result = await reader.load(fresh: true, projects: {
                        projectReads += 1
                        await withCheckedContinuation { finishFresh = $0; refreshing.fulfill() }
                        if let failure { throw failure }
                        return list
                    }, saved: { _ in nil }, read: { _ in
                        boardReads += 1
                        return self.second
                    }, current: { true }, changed: { _ in })
                    returned += 1
                    return result
                } }
                await fulfillment(of: [queued], timeout: 5)
                XCTAssertEqual(returned, 0)
                finishInitial?.resume()
                await fulfillment(of: [refreshing], timeout: 5)
                XCTAssertEqual(returned, 0)
                XCTAssertTrue(reader.state.loading)
                finishFresh?.resume()
                _ = await initial.value
                for refresh in refreshes {
                    let error = await refresh.value
                    XCTAssertEqual(error, failure)
                }
                XCTAssertEqual(projectReads, 2)
                XCTAssertEqual(boardReads, failure == nil ? 2 : 1)
                XCTAssertEqual(returned, 4)
                XCTAssertEqual(reader.state.rows.first?.pull.title, failure == nil ? "Database" : "Login")
                XCTAssertFalse(reader.state.loading)
                XCTAssertFalse(reader.state.refreshing)
                XCTAssertFalse(reader.state.showsLoading)
            }
        }
    }

    @MainActor
    func testCancelledQueuedRefreshDoesNotReadAgain() async {
        let reader = GlobalPullsReader(saved: { _ in nil })
        let polling = expectation(description: "Poll is reading")
        let queued = expectation(description: "Refresh requested")
        var finishPoll: CheckedContinuation<Void, Never>?
        let poll = Task {
            await reader.load(projects: { self.projects }, saved: { _ in nil }, read: { _ in
                await withCheckedContinuation { finishPoll = $0; polling.fulfill() }
                throw CancellationError()
            }, current: { true }, changed: { _ in })
        }
        await fulfillment(of: [polling], timeout: 5)
        let refresh = Task {
            queued.fulfill()
            return await reader.load(fresh: true, projects: { XCTFail("Cancelled refresh"); return self.projects },
                                     saved: { _ in nil }, read: { _ in nil }, current: { true }, changed: { _ in })
        }
        await fulfillment(of: [queued], timeout: 5)
        refresh.cancel()
        finishPoll?.resume()
        _ = await poll.value
        let error = await refresh.value
        XCTAssertEqual(error?.kind, .cancelled)
        XCTAssertFalse(reader.state.loading)
        XCTAssertFalse(reader.state.refreshing)
        XCTAssertFalse(reader.state.hasErrors)
    }

    private func jBoard(_ numbers: [Int]) -> JSON {
        ["pulls": .array(numbers.map { ["number": JSON($0)] })]
    }
}
