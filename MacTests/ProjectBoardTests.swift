// Ported from the Windows client's tests/core_board_tests.c (Projects board): columns, cards and sums, GitHub's refusal,
// the pull requests closing a card, the assignee filter, the project's own cards, moving a card, option colours, totals
// and the setting read from a board's address.
import XCTest
@testable import BriareusMacCore

final class ProjectBoardTests: XCTestCase {
    private func board(_ text: String) -> ProjectBoard { ProjectBoard(j(text))! }

    func testProjectBoardsReadColumnsCardsAndSums() {
        let b = board(#"{"project":{"title":"HQ","url":"https://github.com/orgs/o/projects/1"},"#
            + #""view":{"name":"This Iteration","number":42,"filter":"is:issue","url":"https://github.com/orgs/o/projects/1/views/42"},"#
            + #""groupBy":"Status","truncated":true,"unsupportedFilters":[],"projectsError":null,"columns":["#
            + #"{"id":null,"name":"No Status","color":null,"count":0,"sums":{"Story Points":0},"items":[]},"#
            + #"{"id":"a","name":"In Progress","color":"YELLOW","count":2,"sums":{"Story Points":5.5,"Bad":"x"},"items":["#
            + #"{"id":"i1","type":"issue","repo":"o/r","number":7,"title":"Fix it","url":"https://github.com/o/r/issues/7","state":"open","#
            + #""createdAt":"2026-10-01T10:00:00Z","author":"ana","assignees":[{"login":"ana","avatarUrl":"u"},{"avatarUrl":"v"}],"#
            + #""labels":[{"name":"bug","color":"d73a4a"}],"parent":{"repo":"o/r","number":3,"title":"Epic","url":"https://github.com/o/r/issues/3"},"#
            + #""fields":[{"name":"Priority","value":"High","color":"RED"},{"name":"Story Points","value":3},{"name":"","value":"x"},{"name":"Bad","value":null}]},"#
            + #"{"id":"i2","type":"draft","repo":null,"number":null,"title":"Idea","assignees":[],"labels":[],"parent":null,"fields":[]},"#
            + #"7]},{"name":null}]}"#)
        XCTAssertEqual(b.title, "HQ"); XCTAssertEqual(b.viewName, "This Iteration"); XCTAssertEqual(b.groupBy, "Status"); XCTAssertEqual(b.filter, "is:issue")
        XCTAssertTrue(b.truncated); XCTAssertNil(b.error)
        XCTAssertEqual(b.webURL, "https://github.com/orgs/o/projects/1/views/42")
        XCTAssertEqual(b.columns.count, 2)
        XCTAssertEqual(b.columns[0].name, "No Status"); XCTAssertNil(b.columns[0].id); XCTAssertNil(b.columns[0].color); XCTAssertEqual(b.columns[0].cards.count, 0)
        let c = b.columns[1]
        XCTAssertEqual(c.id, "a"); XCTAssertEqual(c.cards[0].id, "i1"); XCTAssertEqual(c.cards[1].id, "i2")
        XCTAssertEqual(c.color, "YELLOW"); XCTAssertEqual(c.count, 2); XCTAssertEqual(c.cards.count, 2)
        XCTAssertEqual(c.sums.count, 1); XCTAssertEqual(c.sums[0].name, "Story Points"); XCTAssertEqual(c.sums[0].value, 5.5)
        let k = c.cards[0]
        XCTAssertEqual(k.type, "issue"); XCTAssertEqual(k.repo, "o/r"); XCTAssertEqual(k.number, 7); XCTAssertEqual(k.title, "Fix it"); XCTAssertNotNil(k.createdAt)
        XCTAssertEqual(k.assignees, ["ana"])
        XCTAssertEqual(k.labels.count, 1); XCTAssertEqual(k.parent?.number, 3)
        XCTAssertEqual(k.fields.count, 2); XCTAssertEqual(k.field("priority")?.color, "RED")
        XCTAssertEqual(k.field("Story Points")?.value, "3"); XCTAssertNil(k.field("Type"))
        XCTAssertEqual(c.cards[1].type, "draft"); XCTAssertNil(c.cards[1].repo); XCTAssertEqual(c.cards[1].number, 0); XCTAssertNil(c.cards[1].parent)
    }

    func testACardOpensItsIssueAsABoardRow() {
        let k = ProjectBoardCard(j(#"{"id":"i1","type":"issue","repo":"o/r","number":7,"title":"Fix it","url":"https://github.com/o/r/issues/7","#
            + #""createdAt":"2026-10-01T10:00:00Z","author":"ana","assignees":["ana"],"labels":[{"name":"bug","color":"d73a4a"}],"#
            + #""parent":{"repo":"o/r","number":3,"title":"Epic","url":"https://github.com/o/r/issues/3"},"fields":[]}"#))!
        let row = IssueSummary(k.issueJSON)
        XCTAssertEqual(row?.number, 7); XCTAssertEqual(row?.title, "Fix it"); XCTAssertEqual(row?.author, "ana")
        XCTAssertEqual(row?.assignees, ["ana"]); XCTAssertEqual(row?.labels.first?.name, "bug"); XCTAssertEqual(row?.parent?.number, 3)
        XCTAssertEqual(k.issueJSON["createdAt"].string, "2026-10-01T10:00:00Z")
    }

    func testProjectBoardsCarryWhyGitHubRefused() {
        var b = board(#"{"project":null,"view":null,"columns":[],"projectsError":"Resource not accessible"}"#)
        XCTAssertEqual(b.error, "Resource not accessible"); XCTAssertNil(b.title); XCTAssertNil(b.viewName); XCTAssertEqual(b.columns.count, 0); XCTAssertFalse(b.truncated)
        b = board(#"{"columns":[],"projectsError":""}"#); XCTAssertNil(b.error)
        XCTAssertNil(ProjectBoard(j("[]")))
    }

    func testProjectBoardCardsListTheirPullRequests() {
        let b = board(#"{"columns":[{"name":"Todo","count":4,"items":["#
            + #"{"type":"issue","repo":"O/R","number":7,"title":"a"},"#
            + #"{"type":"issue","repo":"o/other","number":7,"title":"b"},"#
            + #"{"type":"pull","repo":"o/r","number":7,"title":"c"},"#
            + #"{"type":"issue","repo":"o/r","number":9,"title":"d"}]}]}"#)
        let issues = IssueSummary.parseList(j(#"[{"number":7,"title":"a","pulls":["#
            + #"{"number":20,"title":"Fix a","url":"https://github.com/o/r/pull/20","state":"open"},"#
            + #"{"number":5,"title":"Elsewhere","repo":"o/other","state":"open"}]}]"#))
        let pulls = PullSummary.parseList(j(#"[{"number":20,"title":"Fix a","issues":[{"number":7,"title":"a"}]},"#
            + #"{"number":21,"title":"Also a","draft":true,"url":"https://github.com/o/r/pull/21","issues":[{"number":7,"title":"a"}]},"#
            + #"{"number":22,"title":"Other 7","issues":[{"number":7,"title":"b","repo":"o/other"}]}]"#))
        let cards = b.columns[0].cards
        // Those the issue row names first, then the open pull requests naming it that it does not.
        let l = projectCardPulls(cards[0], repo: "o/r", issues: issues, pulls: pulls)
        XCTAssertEqual(l.count, 3)
        XCTAssertEqual(l[0].number, 20); XCTAssertEqual(l[1].number, 5); XCTAssertEqual(l[1].repo, "o/other")
        XCTAssertEqual(l[2].number, 21); XCTAssertEqual(l[2].title, "Also a"); XCTAssertTrue(l[2].draft); XCTAssertEqual(l[2].state, "open"); XCTAssertNil(l[2].repo)
        // Another repository's issue, a pull request card, and an issue nothing closes have none.
        for k in 1...3 { XCTAssertEqual(projectCardPulls(cards[k], repo: "o/r", issues: issues, pulls: pulls).count, 0) }
        // Without the pulls read yet, nothing.
        XCTAssertEqual(projectCardPulls(cards[0], repo: "o/r", issues: [], pulls: []).count, 0)
    }

    func testProjectBoardsFilterByAssignee() {
        var b = board(#"{"columns":["#
            + #"{"name":"Todo","count":3,"sums":{"Story Points":9},"items":["#
            + #"{"title":"a","assignees":[{"login":"Ana"},{"login":"bo"}],"fields":[{"name":"Story Points","value":2}]},"#
            + #"{"title":"b","assignees":["ana"],"fields":[{"name":"Story Points","value":5.5}]},"#
            + #"{"title":"c","assignees":[],"fields":[{"name":"Story Points","value":1.5}]}]},"#
            + #"{"name":"Done","count":1,"sums":{"Story Points":0},"items":[{"title":"d","assignees":[{"login":"cy"},{"login":"CY"}]}]}]}"#)
        let a = b.columns[0].cards[0], c = b.columns[0].cards[2]
        XCTAssertTrue(a.assigned(nil)); XCTAssertTrue(a.assigned("")); XCTAssertTrue(a.assigned("ANA")); XCTAssertTrue(a.assigned("bo"))
        XCTAssertFalse(a.assigned("cy")); XCTAssertFalse(a.assigned(projectNoAssignee))
        XCTAssertTrue(c.assigned(projectNoAssignee)); XCTAssertFalse(c.assigned("ana"))
        // Everyone by name, counted once a card however their login is written, and the unassigned last.
        var o = b.assignees(pick: nil)
        XCTAssertEqual(o.count, 4)
        XCTAssertEqual(o[0].text, "Ana"); XCTAssertEqual(o[0].count, 2)
        XCTAssertEqual(o[1].text, "bo"); XCTAssertEqual(o[1].count, 1)
        XCTAssertEqual(o[2].text, "cy"); XCTAssertEqual(o[2].count, 1)
        XCTAssertEqual(o[3].value, projectNoAssignee); XCTAssertEqual(o[3].text, "No assignee"); XCTAssertEqual(o[3].count, 1)
        // A pick the board has lost stays listed, so it can be seen and cleared.
        o = b.assignees(pick: "dee"); XCTAssertEqual(o.count, 5); XCTAssertEqual(o[3].text, "dee"); XCTAssertEqual(o[3].count, 0)
        XCTAssertEqual(b.assignees(pick: "ANA").count, 4)
        // The columns count and total only what passes.
        var m = b.columns[0].matching("ana"); XCTAssertEqual(m.count, 2); XCTAssertEqual(m.sums, [7.5])
        m = b.columns[0].matching(projectNoAssignee); XCTAssertEqual(m.count, 1); XCTAssertEqual(m.sums, [1.5])
        m = b.columns[0].matching(""); XCTAssertEqual(m.count, 3); XCTAssertEqual(m.sums, [9])
        m = b.columns[1].matching("ana"); XCTAssertEqual(m.count, 0); XCTAssertEqual(m.sums, [0])
        XCTAssertEqual(b.columns[1].matching("cy").count, 1)
        XCTAssertEqual(b.items("ana"), 2); XCTAssertEqual(b.items(nil), 4)
        // A board with everyone assigned offers no "No assignee", unless it is the pick.
        b = board(#"{"columns":[{"name":"Todo","items":[{"assignees":["ana"]}]}]}"#)
        XCTAssertEqual(b.assignees(pick: "").count, 1)
        o = b.assignees(pick: projectNoAssignee); XCTAssertEqual(o.count, 2); XCTAssertEqual(o[1].count, 0)
    }

    func testProjectBoardsKeepOnlyTheProjectsCards() {
        var b = board(#"{"columns":["#
            + #"{"name":"Todo","count":4,"sums":{"Story Points":10},"items":["#
            + #"{"repo":"hq/core","number":1,"fields":[{"name":"Story Points","value":2}]},"#
            + #"{"repo":"hq/app","number":2,"fields":[{"name":"Story Points","value":5}]},"#
            + #"{"type":"draft","title":"idea"},"#
            + #"{"repo":"HQ/Core","number":3,"fields":[{"name":"Story Points","value":3}]}]},"#
            + #"{"name":"Done","count":9,"sums":{"Story Points":40},"items":[{"repo":"hq/core","number":4}]}]}"#)
        b.keepRepo("hq/core")
        XCTAssertEqual(b.columns.count, 2)
        XCTAssertEqual(b.columns[0].cards.count, 2); XCTAssertEqual(b.columns[0].count, 2)
        XCTAssertEqual(b.columns[0].cards.map(\.number), [1, 3])
        XCTAssertEqual(b.columns[0].sums[0].value, 5)
        // A column that lost nothing keeps the server's count and totals, which reach past the cards it was sent.
        XCTAssertEqual(b.columns[1].cards.count, 1); XCTAssertEqual(b.columns[1].count, 9); XCTAssertEqual(b.columns[1].sums[0].value, 40)
    }

    func testProjectBoardsMoveACardAndItsTotals() {
        var b = board(#"{"columns":["#
            + #"{"id":null,"name":"No Status","count":0,"sums":{"Story Points":0},"items":[]},"#
            + #"{"id":"t","name":"Todo","count":2,"sums":{"Story Points":7.5},"items":["#
            + #"{"id":"a","fields":[{"name":"Story Points","value":2}]},{"id":"b","fields":[{"name":"Story Points","value":5.5}]}]},"#
            + #"{"id":"d","name":"Done","count":1,"sums":{"Story Points":1},"items":[{"id":"c","fields":[]}]}]}"#)
        // The card leaves its column and lands at the end of the other, its points with it.
        XCTAssertTrue(b.move(from: 1, card: 0, to: 2))
        XCTAssertEqual(b.columns[1].cards.count, 1); XCTAssertEqual(b.columns[1].count, 1); XCTAssertEqual(b.columns[1].cards[0].id, "b"); XCTAssertEqual(b.columns[1].sums[0].value, 5.5)
        XCTAssertEqual(b.columns[2].cards.count, 2); XCTAssertEqual(b.columns[2].count, 2); XCTAssertEqual(b.columns[2].cards[1].id, "a"); XCTAssertEqual(b.columns[2].sums[0].value, 3)
        // Into the empty "No Status" column, and a card without points moves none.
        XCTAssertTrue(b.move(from: 2, card: 0, to: 0))
        XCTAssertEqual(b.columns[0].cards.count, 1); XCTAssertEqual(b.columns[0].cards[0].id, "c"); XCTAssertEqual(b.columns[0].sums[0].value, 0); XCTAssertEqual(b.columns[2].sums[0].value, 3)
        XCTAssertFalse(b.move(from: 1, card: 0, to: 1)); XCTAssertFalse(b.move(from: 1, card: 1, to: 2))
        XCTAssertFalse(b.move(from: 1, card: 0, to: 3)); XCTAssertFalse(b.move(from: 3, card: 0, to: 1))
        XCTAssertEqual(b.columns[1].cards.count, 1)
    }

    func testProjectOptionColoursAreGitHubsNames() {
        let g = projectColorRGB("GREEN")!
        XCTAssertTrue(g.green > g.red && g.green > g.blue)
        XCTAssertNotNil(projectColorRGB("purple"))
        XCTAssertNil(projectColorRGB("TEAL")); XCTAssertNil(projectColorRGB(nil))
    }

    func testColumnSumsDropNeedlessDecimals() {
        XCTAssertEqual(projectSumText(21), "21")
        XCTAssertEqual(projectSumText(5.5), "5.5")
        XCTAssertEqual(projectSumText(0.126), "0.13")
        XCTAssertEqual(projectSumText(-2), "-2")
    }

    func testBoardSettingsAreReadFromTheirGitHubAddress() {
        var s = projectBoardSetting(fromURL: " https://github.com/orgs/hq/projects/1/views/42?filterQuery=x ")!
        XCTAssertEqual(s["owner"].string, "hq"); XCTAssertEqual(s["ownerType"].string, "organization")
        XCTAssertEqual(s["number"].int, 1); XCTAssertEqual(s["view"].int, 42)
        XCTAssertEqual(projectBoardSettingURL(s), "https://github.com/orgs/hq/projects/1/views/42")
        s = projectBoardSetting(fromURL: "github.com/users/ana/projects/3/")!
        XCTAssertEqual(s["ownerType"].string, "user"); XCTAssertTrue(s["view"].isNull)
        XCTAssertEqual(projectBoardSettingURL(s), "https://github.com/users/ana/projects/3")
        let bad: [String?] = [nil, "", "hq/1", "https://github.com/hq/projects/1", "https://github.com/orgs/hq/projects/x", "https://github.com/orgs/hq/projects/0",
                              "https://github.com/orgs//projects/1", "https://github.com/orgs/hq/projects/1/views/", "https://github.com/orgs/hq/projects/1/settings",
                              "https://gitlab.com/orgs/hq/projects/1"]
        for b in bad { XCTAssertNil(projectBoardSetting(fromURL: b), b ?? "(nil)") }
        XCTAssertNil(projectBoardSettingURL(j(#"{"owner":"","number":1}"#)))
        XCTAssertNil(projectBoardSettingURL(.null))
    }

    // MARK: - The Mac app's own

    func testProjectsSayWhichNameABoard() {
        let projects = j(#"{"projects":[{"repo":"o/b","hasBoard":true},{"repo":"o/n"}]}"#)
        XCTAssertTrue(projectHasBoard(projects, repo: "o/b")); XCTAssertFalse(projectHasBoard(projects, repo: "o/n")); XCTAssertFalse(projectHasBoard(projects, repo: "o/x"))
        XCTAssertTrue(projectHasBoard(j(#"[{"repo":"o/b","hasBoard":true}]"#), repo: "o/b"))
    }

    func testAnIssuesStatusIsItsFirstBoardsThatHasOne() {
        XCTAssertEqual(issueProjectStatus(j(#"{"projects":[{"title":"A","status":null},{"title":"B","status":""},{"title":"C","status":"In Review"},{"status":"Done"}]}"#)), "In Review")
        XCTAssertNil(issueProjectStatus(j(#"{"projects":[]}"#))); XCTAssertNil(issueProjectStatus(.null))
        XCTAssertEqual(savedIssueKey("o/r", 4), "issue:o/r#4")
    }

    func testTheBoardsRoutes() {
        XCTAssertEqual(APIRoute.named("project_board")?.method, "GET"); XCTAssertEqual(APIRoute.named("project_board")?.path, "project-board")
        XCTAssertEqual(APIRoute.named("project_board_move")?.method, "POST"); XCTAssertEqual(APIRoute.named("project_board_move")?.path, "project-board/move")
    }
}
