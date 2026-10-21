// The saved prompts as every app lists them, and how a chosen one joins the box.
import XCTest
@testable import BriareusMacCore

final class PromptLogicTests: XCTestCase {
    func testListsBySortOrderThenTitleAndDropsIncompleteEntries() {
        let v = j(#"""
        {"prompts":[
          {"id":1,"title":"b","body":"B"},
          {"id":2,"title":"a","body":"A","repo":"o/r"},
          {"id":3,"title":"z","body":"Z","sortOrder":1},
          {"id":4,"title":"","body":"none"},
          {"id":5,"title":"no body"}
        ]}
        """#)
        let list = SavedPrompt.list(v)
        XCTAssertEqual(list.map(\.serverID), [3, 2, 1])
        XCTAssertEqual(list.map(\.everywhere), [true, false, true])
        XCTAssertEqual(list[1].repo, "o/r")
        XCTAssertEqual(list[0].body, "Z")
    }

    func testEmptyAnswerListsNothing() {
        XCTAssertEqual(SavedPrompt.list(.null), [])
    }

    func testInsertedReplacesAnEmptyBoxAndFollowsText() {
        let p = SavedPrompt(title: "t", body: "Fix it")
        XCTAssertEqual(p.inserted(into: "  \n"), "Fix it")
        XCTAssertEqual(p.inserted(into: "Also"), "Also\n\nFix it")
    }
}
