// The GitHub account form (GithubAccountLogic.swift): what a save sends with and without a token, the token a new account
// cannot do without, the projects ticked, unsaved changes, and a fine-grained token's scopes told apart from none.
import XCTest
@testable import BriareusMacCore

final class GithubAccountFormStateTests: XCTestCase {
    private let saved: JSON = ["id": 1763000000001, "label": "Bot", "login": "acme-bot", "githubId": 4242, "scopes": ["repo", "workflow"],
                               "repos": ["a/b"], "hasToken": true]

    func testTheTokenNeverFillsItsBox() {
        let s = GithubAccountFormState(row: saved)
        XCTAssertEqual(s.text(.token), "")
        XCTAssertEqual(s.text(.label), "Bot")
        XCTAssertEqual(s.repos, ["a/b"])
        XCTAssertEqual(s.id, 1763000000001)
        XCTAssertFalse(s.changed)
    }

    func testAnUpdateWithAnEmptyTokenKeepsTheStoredOne() throws {
        let body = try GithubAccountFormState(row: saved).body().get()
        XCTAssertNil(body.object?["token"])
        XCTAssertEqual(body["repos"], ["a/b"])
        // Read-only fields are never sent back.
        for key in ["login", "githubId", "scopes", "hasToken", "id"] { XCTAssertNil(body.object?[key], key) }
    }

    func testAnUnchangedLabelIsLeftOutSoItKeepsFollowingTheLogin() throws {
        var s = GithubAccountFormState(row: saved)
        s.texts[.token] = "ghp_rotated"
        XCTAssertNil(try s.body().get().object?["label"])
        s.texts[.label] = "Renamed"
        XCTAssertEqual(try s.body().get()["label"], "Renamed")
        // Emptied, it is sent empty: the server names the account after its login again.
        s.texts[.label] = ""
        XCTAssertEqual(try s.body().get()["label"], "")
    }

    func testATokenTypedIsSentTrimmed() throws {
        var s = GithubAccountFormState(row: saved)
        s.texts[.token] = "  ghp_new  "
        XCTAssertTrue(s.changed)
        XCTAssertEqual(try s.body().get()["token"], "ghp_new")
    }

    func testANewAccountIsRefusedWithoutAToken() throws {
        var s = GithubAccountFormState(row: [:])
        XCTAssertTrue(s.isNew)
        XCTAssertNotNil(s.body().failureMessage)
        s.texts[.token] = "   "
        XCTAssertNotNil(s.body().failureMessage)
        s.texts[.token] = "github_pat_x"
        let body = try s.body().get()
        XCTAssertEqual(body["token"], "github_pat_x")
        XCTAssertEqual(body["label"], "")
        XCTAssertEqual(body["repos"], [])
        XCTAssertEqual(s.saveOperation, "create_github_account")
    }

    func testTheSaveRequestCarriesTheIDOnUpdate() throws {
        let s = GithubAccountFormState(row: saved)
        XCTAssertEqual(s.saveOperation, "update_github_account")
        XCTAssertEqual(try s.saveRequest().get()["id"], JSON(1763000000001.0))
    }

    func testReposToggleAndCompareInAnyOrder() throws {
        var s = GithubAccountFormState(row: saved)
        s.toggle("c/d")
        XCTAssertEqual(s.repos, ["a/b", "c/d"])
        XCTAssertTrue(s.changed)
        XCTAssertEqual(try s.body().get()["repos"], ["a/b", "c/d"])
        s.row["repos"] = ["c/d", "a/b"]
        XCTAssertFalse(s.changed)
        s.toggle("a/b")
        XCTAssertEqual(s.repos, ["c/d"])
        XCTAssertTrue(s.changed)
    }

    func testTheSavedAnswerRefillsTheFormAndEmptiesTheToken() {
        var s = GithubAccountFormState(row: [:])
        s.texts[.token] = "ghp_secret"
        s.dirty = true
        XCTAssertNotNil(s.saved(["account": saved]))
        XCTAssertEqual(s.text(.token), "")
        XCTAssertFalse(s.dirty)
        XCTAssertEqual(s.id, 1763000000001)
        XCTAssertNil(s.saved(["ok": true]))
    }

    func testNullScopesAreAFineGrainedTokenNotEmptyOnes() {
        var fineGrained = saved
        fineGrained["scopes"] = .null
        var none = saved
        none["scopes"] = []
        let a = GithubAccountFormState.scopesText(fineGrained["scopes"])
        let b = GithubAccountFormState.scopesText(none["scopes"])
        let c = GithubAccountFormState.scopesText(saved["scopes"])
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertTrue(c.contains("repo") && c.contains("workflow"))
        // A row without the key reads as fine-grained too: GitHub sent no scopes header.
        XCTAssertEqual(GithubAccountFormState.scopesText(JSON.null), a)
    }

    func testFactsListTheVerifiedIdentity() {
        XCTAssertEqual(GithubAccountFormState.facts(saved).map(\.kind), [.login, .githubID, .scopes])
        XCTAssertTrue(GithubAccountFormState.facts(saved)[0].value.contains("acme-bot"))
        XCTAssertEqual(GithubAccountFormState.facts(saved)[1].value, "4242")
        XCTAssertEqual(GithubAccountFormState.facts([:]), [])
    }

    func testTakenByAnotherAccountMatchesCaseInsensitively() {
        let s = GithubAccountFormState(row: saved)
        let accounts: [JSON] = [saved, ["id": 2, "label": "", "login": "other", "repos": ["Acme/Web"]]]
        XCTAssertNil(s.takenBy("a/b", accounts: accounts))
        XCTAssertNotNil(s.takenBy("acme/web", accounts: accounts))
        XCTAssertTrue(s.takenBy("acme/web", accounts: accounts)?.contains("other") == true)
        XCTAssertNil(s.takenBy("x/y", accounts: accounts))
    }

    func testRepoRowsMarkGoneAndTakenProjects() {
        var s = GithubAccountFormState(row: saved)
        s.toggle("old/gone")
        let accounts: [JSON] = [saved, ["id": 2, "label": "Other", "repos": ["Acme/Web", "a/b"]]]
        let rows = s.repoRows(projects: ["a/b", "acme/web", "x/y"], accounts: accounts)
        XCTAssertEqual(rows.map(\.repo), ["a/b", "acme/web", "x/y", "old/gone"])
        // A ticked project is never marked taken, even when another account also lists it.
        XCTAssertEqual(rows[0], GithubAccountRepoRow(repo: "a/b", on: true, gone: false, takenBy: nil))
        XCTAssertEqual(rows[1].takenBy, "Other")
        XCTAssertFalse(rows[1].on)
        XCTAssertTrue(rows[1].muted)
        XCTAssertEqual(rows[2], GithubAccountRepoRow(repo: "x/y", on: false, gone: false, takenBy: nil))
        XCTAssertFalse(rows[2].muted)
        XCTAssertTrue(rows[3].on && rows[3].gone && rows[3].muted)
        XCTAssertEqual(GithubAccountFormState(row: [:]).repoRows(projects: [], accounts: accounts), [])
    }

    func testEditsCutToTheLimitAndMarkTheFormEdited() {
        var s = GithubAccountFormState(row: saved)
        XCTAssertFalse(s.edit(.label, "Bot"))
        XCTAssertFalse(s.dirty)
        XCTAssertTrue(s.edit(.label, String(repeating: "x", count: 500)))
        XCTAssertEqual(s.text(.label).count, GithubAccountField.label.limit)
        XCTAssertTrue(s.dirty)
        XCTAssertFalse(s.edit(.label, String(repeating: "x", count: 300)))
        XCTAssertTrue(s.edit(.token, String(repeating: "t", count: 5000)))
        XCTAssertEqual(s.text(.token).count, GithubAccountField.token.limit)
    }

    func testTickingAProjectMarksTheFormEdited() {
        var s = GithubAccountFormState(row: saved)
        XCTAssertFalse(s.setTicked("a/b", true))
        XCTAssertFalse(s.dirty)
        XCTAssertTrue(s.setTicked("a/b", false))
        XCTAssertEqual(s.repos, [])
        XCTAssertTrue(s.dirty)
        s.dirty = false
        s.toggle("c/d")
        XCTAssertTrue(s.dirty)
    }

    func testTheTokenCueSaysWhetherOneIsStored() {
        XCTAssertEqual(GithubAccountFormState(row: [:]).tokenCue, GithubAccountField.token.def.cue)
        XCTAssertNotEqual(GithubAccountFormState(row: saved).tokenCue, GithubAccountField.token.def.cue)
        XCTAssertFalse(GithubAccountFormState(row: saved).tokenCue.isEmpty)
    }

    func testARefusalUsesTheConflictsWordsElseTheAppsOwn() {
        let conflict = APIError(.http, status: 409, message: "assigned")
        XCTAssertEqual(GithubAccountFormState.refusal(conflict, otherwise: "x"), GithubAccountFormState.saveProblem(conflict))
        XCTAssertEqual(GithubAccountFormState.refusal(APIError(.http, status: 400, message: "bad"), otherwise: "x"), "x")
        XCTAssertEqual(GithubAccountFormState.refusal(CancellationError(), otherwise: "y"), "y")
    }

    func testOnlyAConflictGetsItsOwnWords() {
        XCTAssertNotNil(GithubAccountFormState.saveProblem(APIError(.http, status: 409, message: "assigned")))
        for status in [400, 404, 502, 503] {
            XCTAssertNil(GithubAccountFormState.saveProblem(APIError(.http, status: status, message: "x")), "\(status)")
        }
        XCTAssertNil(GithubAccountFormState.saveProblem(APIError(.network)))
    }

    func testLinesNameTheLoginAndAMissingToken() {
        XCTAssertTrue(GithubAccountFormState.sidebarLine(saved).contains("acme-bot"))
        XCTAssertTrue(GithubAccountFormState.sidebarLine(saved).contains("a/b"))
        XCTAssertTrue(GithubAccountFormState.subtitle(saved).contains("acme-bot"))
        XCTAssertEqual(GithubAccountFormState.title(saved), "Bot")
        XCTAssertTrue(GithubAccountFormState.title(["login": "acme-bot"]).contains("acme-bot"))
        XCTAssertNotEqual(GithubAccountFormState.subtitle(saved), GithubAccountFormState.subtitle(["repos": ["a/b"], "hasToken": false]))
        // Both lines decide a missing token from hasToken alone, whatever the login says.
        let tokenless: JSON = ["login": "acme-bot", "repos": ["a/b"], "hasToken": false]
        XCTAssertTrue(GithubAccountFormState.sidebarLine(tokenless).contains("no token"))
        XCTAssertTrue(GithubAccountFormState.subtitle(tokenless).contains("no token"))
        XCTAssertFalse(GithubAccountFormState.sidebarLine(saved).contains("no token"))
        XCTAssertFalse(GithubAccountFormState.subtitle(saved).contains("no token"))
        XCTAssertFalse(GithubAccountFormState.sidebarLine(["hasToken": true, "repos": []]).contains("no token"))
    }

    func testRoutes() {
        XCTAssertEqual(APIRoute.named("settings_github_accounts")?.path, "settings/github/accounts")
        XCTAssertEqual(APIRoute.named("create_github_account")?.method, "POST")
        XCTAssertEqual(APIRoute.named("update_github_account")?.path, "settings/github/accounts/{id}")
        XCTAssertEqual(APIRoute.named("delete_github_account")?.method, "DELETE")
        XCTAssertEqual(GithubAccountFormState.record.answerKey, "account")
    }
}

private extension Result where Failure == FormProblem {
    var failureMessage: String? { if case .failure(let p) = self { return p.message }; return nil }
}
