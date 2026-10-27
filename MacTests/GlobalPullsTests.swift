// The global pull list's repository identity, filtering, caches, and independent project failures.
import XCTest
@testable import BriareusMacCore

final class GlobalPullsTests: XCTestCase {
    private let projects = j(#"{"projects":[{"repo":"o/a","label":"Alpha"},{"repo":"o/b","label":"Beta"}]}"#)
    private let first = j(#"{"pulls":[{"number":7,"title":"Login","branch":"fix/login","author":"alice","draft":true,"labels":["bug"],"reviewers":[{"user":"bob"}],"updatedAt":"2026-10-25T12:00:00Z"}]}"#)
    private let second = j(#"{"pulls":[{"number":7,"title":"Database","updatedAt":"2026-10-26T12:00:00Z"}]}"#)

    private func state() -> GlobalPullsState {
        var state = GlobalPullsState()
        state.replaceProjects(Project.parseList(projects)!, saved: { $0 == "o/a" ? first : second })
        return state
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

    private func jBoard(_ numbers: [Int]) -> JSON {
        ["pulls": .array(numbers.map { ["number": JSON($0)] })]
    }
}
