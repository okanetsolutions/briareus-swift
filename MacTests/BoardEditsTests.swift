// Ported from the Windows client's tests/core_board_tests.c (MARK: - Edits) and core_api_tests.c: the labels and assignees
// an edit box holds, "Assign me", and the edit routes.
import XCTest
@testable import BriareusMacCore

final class BoardEditsTests: XCTestCase {
    private func names(_ text: String?, _ logins: Bool) -> [String] { boardNamesParse(text, logins: logins) }

    func testEditedNamesAreSplitTrimmedAndListedOnce() {
        XCTAssertEqual(names("bug, good first issue ,,\r\nBug\nui", false), ["bug", "good first issue", "ui"])
        XCTAssertEqual(names("", false), [])
        XCTAssertEqual(names(nil, false), [])
        XCTAssertEqual(names(" , \n ", false), [])
        // A login may be typed with its @; a label keeps one.
        XCTAssertEqual(names("@nadin, Nadin, @, octocat", true), ["nadin", "octocat"])
        XCTAssertEqual(names("@release", false), ["@release"])
        // A quoted name keeps its commas, and "" in it is a quote.
        XCTAssertEqual(names(#"bug, "needs: review, qa" ,"say ""hi""""#, false), ["bug", "needs: review, qa", #"say "hi""#])
        XCTAssertEqual(names(#""open, "#, false), ["open,"])
    }

    func testNamesJoinAsTheEditBoxShowsThem() {
        XCTAssertEqual(boardNamesJoin(["a", "b c"]), "a, b c")
        XCTAssertEqual(boardNamesJoin([]), "")
        XCTAssertEqual(boardLabelNamesJoin([PullLabel(name: "bug", color: "d73a4a"), PullLabel(name: "ui")]), "bug, ui")
        // A label with a comma is quoted, so saving the box unchanged sends it back as it was.
        let odd = boardLabelNamesJoin([PullLabel(name: "needs: review, qa"), PullLabel(name: #""x""#), PullLabel(name: "ui")])
        XCTAssertEqual(odd, #""needs: review, qa", """x""", ui"#)
        XCTAssertEqual(names(odd, false), ["needs: review, qa", #""x""#, "ui"])
    }

    func testAssignMeAddsOrTakesOffTheLogin() {
        var r = boardAssigneesToggle(["octocat", "Nadin"], login: "nadin")
        XCTAssertEqual(r.assignees, ["octocat"]); XCTAssertFalse(r.added)
        r = boardAssigneesToggle(["octocat"], login: "nadin")
        XCTAssertEqual(r.assignees, ["octocat", "nadin"]); XCTAssertTrue(r.added)
        XCTAssertEqual(boardAssigneesToggle([], login: "nadin").assignees, ["nadin"])
        XCTAssertEqual(assignMeLabel(["octocat", "Nadin"], me: "nadin"), "Unassign me")
        XCTAssertEqual(assignMeLabel(["octocat"], me: "nadin"), "Assign me")
        XCTAssertEqual(assignMeLabel(["octocat"], me: nil), "Assign me")
    }

    func testAnEditSendsOnlyWhatChanged() {
        XCTAssertNil(detailsEdited(title: "T", body: "a\r\nb", newTitle: "T", newBody: "a\nb"))
        let f = detailsEdited(title: "T", body: "a", newTitle: "New", newBody: "a")
        XCTAssertEqual(f?["title"].string, "New"); XCTAssertNil(f?["body"].string)
        // Emptying the description is a change, which clears it.
        XCTAssertEqual(detailsEdited(title: "T", body: "a", newTitle: "T", newBody: "")?["body"].string, "")
    }

    func testEditsGoOnTheirOwnRoutes() throws {
        XCTAssertEqual(APIRoute.named("update_pull")?.method, "PATCH")
        XCTAssertEqual(APIRoute.named("update_issue")?.method, "PATCH")
        XCTAssertEqual(APIRoute.named("update_pull_branch")?.method, "POST")
        // An edit sends its lists whole, an empty one included, since each replaces what GitHub has.
        var r = try APIClient.resolve(APIRoute.named("update_pull")!, ["pr": 7, "repo": "o/r", "labels": ["bug"], "assignees": []])
        XCTAssertEqual(r.path, "pulls/7"); XCTAssertEqual(r.rest["assignees"], JSON.array([])); XCTAssertNil(r.rest["pr"])
        r = try APIClient.resolve(APIRoute.named("update_issue")!, ["issue": 9, "repo": "o/r", "title": "T", "body": ""])
        XCTAssertEqual(r.path, "issues/9"); XCTAssertEqual(r.rest["body"]?.string, "")
        r = try APIClient.resolve(APIRoute.named("update_pull_branch")!, ["pr": 7, "repo": "o/r", "headSha": "abc", "baseRef": "main"])
        XCTAssertEqual(r.path, "pulls/7/update-branch"); XCTAssertEqual(r.rest.count, 3)
    }
}
