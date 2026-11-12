// An orchestrator's workers nested under it in a project's conversation list, and folding them away.
import XCTest
@testable import BriareusMacCore

final class SessionTreeTests: XCTestCase {
    private func sessions(_ text: String) -> [Session] { j(text).items.map { Session(raw: $0) } }
    private func shape(_ rows: [SessionNode], _ list: [Session]) -> [String] {
        rows.map { "\(list[$0.index].id):\($0.depth):\($0.workers)" }
    }

    func testWorkersFollowTheirOrchestratorInListOrder() {
        let list = sessions(#"""
        [{"id":"w2","parentId":"o1"},{"id":"a"},{"id":"o1","orchestrator":true},{"id":"w1","parentId":"o1"},
         {"id":"b","parentId":""},{"id":"w3","parentId":"o2"}]
        """#)
        // A worker whose orchestrator is not on the list, and an empty parent, stay at the top level.
        XCTAssertEqual(shape(sessionsNested(list), list), ["a:0:0", "o1:0:2", "w2:1:0", "w1:1:0", "b:0:0", "w3:0:0"])
    }

    func testNestedOrchestratorsAndCyclesKeepEveryRowOnce() {
        let list = sessions(#"""
        [{"id":"o1"},{"id":"o2","parentId":"o1"},{"id":"w","parentId":"o2"},
         {"id":"x","parentId":"y"},{"id":"y","parentId":"x"},{"id":"self","parentId":"self"}]
        """#)
        let rows = sessionsNested(list)
        XCTAssertEqual(shape(rows, list), ["o1:0:1", "o2:1:1", "w:2:0", "self:0:0", "x:0:1", "y:1:0"])
        XCTAssertEqual(Set(rows.map(\.index)).count, list.count)
    }

    func testFoldingHidesEverythingUnderAnOrchestrator() {
        let list = sessions(#"""
        [{"id":"o1"},{"id":"o2","parentId":"o1"},{"id":"w","parentId":"o2"},{"id":"a"},{"id":"o3"},{"id":"v","parentId":"o3"}]
        """#)
        let rows = sessionsNested(list)
        XCTAssertEqual(sessionsFolded(rows, list, folded: []), rows)
        XCTAssertEqual(shape(sessionsFolded(rows, list, folded: ["o1"]), list), ["o1:0:1", "a:0:0", "o3:0:1", "v:1:0"])
        XCTAssertEqual(shape(sessionsFolded(rows, list, folded: ["o2", "o3"]), list), ["o1:0:1", "o2:1:1", "a:0:0", "o3:0:1"])
        // Folding a conversation with no workers hides nothing.
        XCTAssertEqual(sessionsFolded(rows, list, folded: ["a"]), rows)
    }
}
