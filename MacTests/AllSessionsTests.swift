// Cross-project rows keep their identity, search both session and project names, and sort consistently.
import XCTest
@testable import BriareusMacCore

final class AllSessionsTests: XCTestCase {
    private func session(_ id: String, repo: String, status: String = "idle", created: String? = nil) -> Session {
        Session(["id": .string(id), "repo": .string(repo), "status": .string(status),
                 "title": "Fix login", "createdAt": .string(orNull: created)])!
    }

    func testCachedReadinessIncludesEmptyResponsesButWaitsForProjects() {
        let list = AllSessions(sessions: [], projects: [Project(repo: "org/api")])
        XCTAssertFalse(list.cacheIsLoaded(projectsLoaded: false, cachedRepos: ["org/api"]))
        XCTAssertFalse(list.cacheIsLoaded(projectsLoaded: true, cachedRepos: []))
        XCTAssertTrue(list.cacheIsLoaded(projectsLoaded: true, cachedRepos: ["org/api"]))
        let noProjects = AllSessions(sessions: [], projects: [])
        XCTAssertTrue(noProjects.cacheIsLoaded(projectsLoaded: true, cachedRepos: []))
        XCTAssertFalse(noProjects.cacheIsLoaded(projectsLoaded: false, cachedRepos: []))
    }

    func testPartialCachesDoNotCountAsLoaded() {
        var list = AllSessions(sessions: [session("a", repo: "org/api")],
                               projects: [Project(repo: "org/api"), Project(repo: "org/web")])
        XCTAssertFalse(list.cacheIsLoaded(projectsLoaded: true, cachedRepos: ["org/api"]))
        XCTAssertFalse(list.cacheIsLoaded(projectsLoaded: true, cachedRepos: ["org/api", "org/other"]))
        XCTAssertTrue(list.cacheIsLoaded(projectsLoaded: true, cachedRepos: ["org/api", "org/web"]))
        list.projects.append(Project(repo: "org/new"))
        XCTAssertFalse(list.cacheIsLoaded(projectsLoaded: true, cachedRepos: ["org/api", "org/web"]))
    }

    func testFailedFirstProjectsReadDoesNotBecomeAnEmptySuccess() {
        let list = AllSessions(sessions: [], projects: [])
        let failedAnswer: JSON = .null
        XCTAssertFalse(list.cacheIsLoaded(projectsLoaded: Project.parseList(failedAnswer) != nil, cachedRepos: []))
        let emptyAnswer: JSON = ["projects": []]
        XCTAssertTrue(list.cacheIsLoaded(projectsLoaded: Project.parseList(emptyAnswer) != nil, cachedRepos: []))
    }

    func testEmptyStateDistinguishesNoSessionsFromFilteredResults() {
        XCTAssertEqual(AllSessions(sessions: [], projects: []).emptyState, .noSessions)
        let list = AllSessions(sessions: [session("a", repo: "org/api", status: "closed")], projects: [])
        XCTAssertTrue(list.shown(search: "", showClosed: false).isEmpty)
        XCTAssertEqual(list.emptyState, .noMatches)
    }

    func testSearchesAcrossProjectsAndCanHideClosedSessions() {
        let list = AllSessions(sessions: [session("a", repo: "org/api"), session("b", repo: "org/web", status: "closed")],
                               projects: [Project(repo: "org/api", label: "Backend")])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.shown(search: "", showClosed: true).map(\.id), ["a", "b"])
        XCTAssertEqual(list.shown(search: "", showClosed: false).map(\.id), ["a"])
        XCTAssertEqual(list.shown(search: " BACKEND ", showClosed: true).map(\.id), ["a"])
        XCTAssertEqual(list.shown(search: "ORG/WEB", showClosed: true).map(\.id), ["b"])
        XCTAssertEqual(list.shown(search: "login", showClosed: true).map(\.id), ["a", "b"])
        XCTAssertTrue(list.shown(search: "missing", showClosed: true).isEmpty)
        XCTAssertEqual(list.projectTitle(for: list.sessions[0]), "Backend")
        XCTAssertEqual(list.projectTitle(for: list.sessions[1]), "org/web")
    }

    func testWorkingFirstThenNewestWithStableTiesAndMissingDates() {
        let list = AllSessions(sessions: [session("old", repo: "a", created: "2026-01-01T00:00:00Z"),
                                          session("b", repo: "b"), session("a", repo: "a"),
                                          session("working", repo: "b", status: "running"),
                                          session("new", repo: "a", created: "2026-10-01T00:00:00Z")], projects: [])
        XCTAssertTrue(list.busy)
        XCTAssertEqual(list.shown(search: "", showClosed: true).map(\.id), ["working", "new", "old", "a", "b"])
        XCTAssertFalse(AllSessions(sessions: [], projects: []).busy)
        XCTAssertTrue(AllSessions(sessions: [], projects: []).shown(search: "", showClosed: true).isEmpty)
    }
}
