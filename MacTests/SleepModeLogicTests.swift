// Sleep mode: when it is due, what a transcript line shows, how the wall's panes take files and type them out, and
// how recent work is replayed.
import XCTest
@testable import BriareusMacCore

final class SleepModeLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(_ id: String, _ status: String = "running", repo: String = "okanet/app", branch: String? = "feat") -> Session {
        var j: JSON = ["id": .string(id), "status": .string(status), "repo": .string(repo), "title": .string("T \(id)")]
        if let branch { j["branch"] = .string(branch) }
        return Session(j)!
    }
    private func tool(_ name: String, _ summary: String, seq: Int = 1) -> Event {
        Event(["seq": JSON(seq), "kind": "tool", "name": .string(name), "summary": .string(summary)])!
    }
    private func code(_ lines: [String]) -> [[CodeToken]] { lines.map { [CodeToken(text: $0, kind: .plain)] } }

    // MARK: When it sleeps

    func testSleepIsDueAfterTheMinutesAndNeverAtZero() {
        XCTAssertFalse(sleepIsDue(lastInput: t0, now: t0.addingTimeInterval(299), minutes: 5))
        XCTAssertTrue(sleepIsDue(lastInput: t0, now: t0.addingTimeInterval(300), minutes: 5))
        XCTAssertFalse(sleepIsDue(lastInput: t0, now: t0.addingTimeInterval(100_000), minutes: 0))
        XCTAssertTrue(sleepAfterChoices.contains(sleepAfterDefault))
    }

    // MARK: Steps

    func testTranscriptLinesAreReadFromTheEventsStream() {
        let line = sleepTranscriptLine("transcript", ["sessionId": "s1", "event": ["seq": 3, "kind": "tool", "name": "Bash", "summary": "ls"]])
        XCTAssertEqual(line?.sessionId, "s1")
        XCTAssertEqual(line?.line.seq, 3)
        XCTAssertNil(sleepTranscriptLine("session", ["sessionId": "s1", "event": ["seq": 3, "kind": "tool"]]))
        XCTAssertNil(sleepTranscriptLine("transcript", ["event": ["seq": 3, "kind": "tool"]]))
    }

    func testStepsFromToolsAndCommands() {
        let repo = "okanet/app"
        XCTAssertEqual(sleepStep(tool("Edit", "/srv/ws/okanet__app/src/a.ts"), repo: repo), .file(path: "src/a.ts", writes: true))
        XCTAssertEqual(sleepStep(tool("Read", "/srv/ws/okanet__app__3/README.md"), repo: repo), .file(path: "README.md", writes: false))
        XCTAssertEqual(sleepStep(tool("Edit", "lib/a.js, lib/b.js"), repo: repo), .file(path: "lib/a.js", writes: true))
        XCTAssertEqual(sleepStep(tool("Bash", "npm test\nmore"), repo: repo), .command("npm test"))
        XCTAssertEqual(sleepStep(Event(["seq": 1, "kind": "git", "text": "git fetch origin"])!, repo: repo), .command("git fetch origin"))
        XCTAssertNil(sleepStep(tool("Grep", "TODO"), repo: repo))
        XCTAssertNil(sleepStep(tool("Bash", "  "), repo: repo))
        XCTAssertNil(sleepStep(Event(["seq": 1, "kind": "text", "text": "Hi"])!, repo: repo))
    }

    func testRepoPathsStayInsideTheClone() {
        XCTAssertEqual(sleepRepoPath("/w/okanet__app/a/b.swift", repo: "okanet/app"), "a/b.swift")
        XCTAssertEqual(sleepRepoPath("./a/b.swift", repo: nil), "a/b.swift")
        XCTAssertNil(sleepRepoPath("/tmp/scratch.txt", repo: "okanet/app"))
        XCTAssertNil(sleepRepoPath("/w/okanet__app", repo: "okanet/app"))
        XCTAssertNil(sleepRepoPath("/w/okanet__app__x/a.swift", repo: "okanet/app"))
        XCTAssertNil(sleepRepoPath("../secret", repo: "okanet/app"))
        XCTAssertNil(sleepRepoPath("", repo: "okanet/app"))
    }

    func testFilesAreReadAtTheBranchThenTheDefaultBranch() {
        let fetch = SleepFetch(sessionId: "s1", repo: "o/r", branch: "feat", path: "a.ts")
        XCTAssertEqual(fetch.arguments(atBranch: true), ["repo": "o/r", "path": "a.ts", "ref": "feat"])
        XCTAssertEqual(fetch.arguments(atBranch: false), ["repo": "o/r", "path": "a.ts"])
        XCTAssertTrue(fetch.triesDefaultBranch)
        let bare = SleepFetch(sessionId: "s1", repo: "o/r", branch: nil, path: "a.ts")
        XCTAssertEqual(bare.arguments(atBranch: true), ["repo": "o/r", "path": "a.ts"])
        XCTAssertFalse(bare.triesDefaultBranch)
        let long = (1...(SleepWall.maxLines + 20)).map(String.init).joined(separator: "\n")
        XCTAssertEqual(SleepFetch.text(["path": "a.ts", "content": .string(long)])?.split(separator: "\n").count, SleepWall.maxLines)
        XCTAssertNil(SleepFetch.text(["path": "a.bin", "binary": true]))
    }

    // MARK: Typing

    func testVisibleLinesCutTheLineBeingTyped() {
        let lines = [[CodeToken(text: "let", kind: .keyword), CodeToken(text: " x", kind: .plain)], [CodeToken(text: "y", kind: .plain)]]
        XCTAssertEqual(sleepVisibleLines(lines, typed: 0, rows: 5).map(\.tokens), [[]])
        XCTAssertEqual(sleepVisibleLines(lines, typed: 4, rows: 5).map(\.tokens),
                       [[CodeToken(text: "let", kind: .keyword), CodeToken(text: " ", kind: .plain)]])
        XCTAssertEqual(sleepVisibleLines(lines, typed: 6, rows: 5).map(\.number), [1, 2])
        XCTAssertEqual(sleepVisibleLines(lines, typed: 7, rows: 1).map(\.number), [2])
    }

    // MARK: The wall

    func testAWorkingSessionGetsAPaneAndItsFileIsFetchedAtItsBranch() {
        var wall = SleepWall(capacity: 2)
        wall.update(session("s1"), now: t0)
        XCTAssertEqual(wall.panes.map(\.sessionId), ["s1"])
        wall.update(session("s2", "idle"), now: t0)
        XCTAssertEqual(wall.panes.count, 1)
        let fetch = wall.apply(.file(path: "a.ts", writes: true), session: "s1", now: t0)
        XCTAssertEqual(fetch, SleepFetch(sessionId: "s1", repo: "okanet/app", branch: "feat", path: "a.ts"))
        XCTAssertNil(wall.apply(.file(path: "a.ts", writes: true), session: "s1", now: t0))
        // A step from a session with no known record has nowhere to go.
        XCTAssertNil(wall.apply(.file(path: "b.ts", writes: true), session: "unknown", now: t0))
    }

    func testAFileIsHeldUntilTypedOutOrTheDwellPasses() {
        var wall = SleepWall(capacity: 1)
        wall.update(session("s1"), now: t0)
        let first = wall.apply(.file(path: "a.ts", writes: true), session: "s1", now: t0)!
        wall.loaded(first, code: code(["abc", "de"]))
        XCTAssertEqual(wall.panes[0].total, 6)
        XCTAssertNil(wall.apply(.file(path: "b.ts", writes: false), session: "s1", now: t0.addingTimeInterval(1)))
        XCTAssertNil(wall.apply(.file(path: "c.ts", writes: true), session: "s1", now: t0.addingTimeInterval(1)))
        // A read arriving after a waiting write does not take its place.
        XCTAssertNil(wall.apply(.file(path: "d.ts", writes: false), session: "s1", now: t0.addingTimeInterval(1)))
        XCTAssertEqual(wall.tick(chars: 3, now: t0.addingTimeInterval(2)), [])
        XCTAssertEqual(wall.panes[0].typed, 3)
        let next = wall.tick(chars: 10, now: t0.addingTimeInterval(3))
        XCTAssertEqual(next.map(\.path), ["c.ts"])
        XCTAssertNil(wall.panes[0].code)
        XCTAssertNil(wall.panes[0].pending)
        // A file still loading gives way once the dwell passes.
        XCTAssertNil(wall.apply(.file(path: "e.ts", writes: true), session: "s1", now: t0.addingTimeInterval(4)))
        XCTAssertEqual(wall.tick(chars: 1, now: t0.addingTimeInterval(3 + SleepWall.dwell)).map(\.path), ["e.ts"])
    }

    func testAWriteReplacesARead() {
        var wall = SleepWall(capacity: 1)
        wall.update(session("s1"), now: t0)
        _ = wall.apply(.file(path: "a.ts", writes: false), session: "s1", now: t0)
        XCTAssertEqual(wall.apply(.file(path: "b.ts", writes: true), session: "s1", now: t0)?.path, "b.ts")
    }

    func testALoadForAnOldFileIsIgnoredAndLongFilesAreCut() {
        var wall = SleepWall(capacity: 1)
        wall.update(session("s1"), now: t0)
        let old = wall.apply(.file(path: "a.ts", writes: false), session: "s1", now: t0)!
        _ = wall.apply(.file(path: "b.ts", writes: true), session: "s1", now: t0)
        wall.loaded(old, code: code(["x"]))
        XCTAssertNil(wall.panes[0].code)
        wall.loaded(SleepFetch(sessionId: "s1", repo: "okanet/app", path: "b.ts"), code: code(Array(repeating: "x", count: 500)))
        XCTAssertEqual(wall.panes[0].code?.count, SleepWall.maxLines)
        wall.loaded(SleepFetch(sessionId: "s1", repo: "okanet/app", path: "b.ts"), code: nil)
        XCTAssertEqual(wall.panes[0].code, [])
        XCTAssertTrue(wall.panes[0].done)
    }

    func testCommandsGoToTheTickerAndThePane() {
        var wall = SleepWall(capacity: 1)
        wall.update(session("s1"), now: t0)
        for i in 0..<(SleepWall.tickerLength + 5) { _ = wall.apply(.command("echo \(i)"), session: "s1", now: t0) }
        XCTAssertEqual(wall.ticker.count, SleepWall.tickerLength)
        XCTAssertEqual(wall.ticker.last?.text, "echo \(SleepWall.tickerLength + 4)")
        XCTAssertEqual(wall.ticker.last?.project, "app")
        XCTAssertEqual(Set(wall.ticker.map(\.id)).count, SleepWall.tickerLength)
        XCTAssertEqual(wall.panes[0].command, "echo \(SleepWall.tickerLength + 4)")
    }

    func testANewSessionTakesTheQuietestPane() {
        var wall = SleepWall(capacity: 2)
        for id in ["s1", "s2", "s3"] { wall.update(session(id, "idle"), now: t0) }
        _ = wall.apply(.command("a"), session: "s1", now: t0)
        _ = wall.apply(.command("b"), session: "s2", now: t0.addingTimeInterval(5))
        _ = wall.apply(.command("c"), session: "s3", now: t0.addingTimeInterval(10))
        XCTAssertEqual(wall.panes.map(\.sessionId), ["s3", "s2"])
        XCTAssertEqual(wall.shown(1).map(\.sessionId), ["s3"])
        XCTAssertEqual(wall.shown(5).map(\.sessionId), ["s3", "s2"])
        wall.update(session("s2", "closed"), now: t0)
        XCTAssertEqual(wall.panes[1].status, "closed")
        wall.remove("s3")
        XCTAssertEqual(wall.panes.map(\.sessionId), ["s2"])
    }

    // MARK: Replay

    func testReplayIsWantedOnlyWhileNothingWorks() {
        var wall = SleepWall(capacity: 2)
        XCTAssertTrue(wall.wantsReplay(now: t0))
        wall.update(session("s1", "idle"), now: t0)
        _ = wall.apply(.command("ls"), session: "s1", now: t0)
        XCTAssertFalse(wall.wantsReplay(now: t0.addingTimeInterval(30)))
        XCTAssertTrue(wall.wantsReplay(now: t0.addingTimeInterval(61)))
        wall.update(session("s2", "running"), now: t0)
        XCTAssertFalse(wall.wantsReplay(now: t0.addingTimeInterval(61)))
    }

    func testReplayedStepsGiveWayToLiveOnes() {
        var wall = SleepWall(capacity: 2)
        wall.update(session("old", "idle"), now: t0)
        wall.update(session("new", "idle"), now: t0)
        _ = wall.apply(.command("replayed"), session: "old", now: t0, replay: true)
        XCTAssertTrue(wall.replaying)
        XCTAssertNil(wall.lastLive)
        _ = wall.apply(.command("live"), session: "new", now: t0)
        XCTAssertFalse(wall.replaying)
        XCTAssertEqual(wall.panes.map(\.sessionId), ["new"])
        XCTAssertEqual(wall.ticker.map(\.text), ["live"])
        // While a live pane shows, replayed steps are dropped.
        _ = wall.apply(.command("replayed"), session: "old", now: t0, replay: true)
        XCTAssertEqual(wall.ticker.map(\.text), ["live"])
    }

    func testReplaySessionsAreTheMostRecentWithARepository() {
        let a = Session(["id": "a", "status": "idle", "repo": "o/r", "updatedAt": "2026-10-01T00:00:00Z"])!
        let b = Session(["id": "b", "status": "idle", "repo": "o/r", "createdAt": "2026-10-03T00:00:00Z"])!
        let c = Session(["id": "c", "status": "idle", "updatedAt": "2026-10-05T00:00:00Z"])!
        XCTAssertEqual(sleepReplaySessions([a, b, c], limit: 5).map(\.id), ["b", "a"])
        XCTAssertEqual(sleepReplaySessions([a, b, c], limit: 1).map(\.id), ["b"])
    }

    func testReplayTakesTurnsAndStartsOver() {
        let events: JSON = .array([
            ["seq": 2, "kind": "tool", "name": "Bash", "summary": "two"],
            ["seq": 1, "kind": "tool", "name": "Bash", "summary": "one"],
            ["seq": 3, "kind": "text", "text": "skip"],
        ])
        XCTAssertEqual(sleepSteps(events, repo: "o/r", limit: 10), [.command("one"), .command("two")])
        XCTAssertEqual(sleepSteps(events, repo: "o/r", limit: 1), [.command("two")])
        var replay = SleepReplay([("a", [.command("a1"), .command("a2")]), ("b", [.command("b1")]), ("c", [])])
        let order = (0..<5).compactMap { _ in replay.next() }.map { "\($0.sessionId):\($0.step)" }
        XCTAssertEqual(order, ["a:command(\"a1\")", "b:command(\"b1\")", "a:command(\"a2\")", "b:command(\"b1\")", "a:command(\"a1\")"])
        var empty = SleepReplay([])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.next())
    }
}
