// The settings forms' bodies and unsaved-change tracking, as screen_settings.c, screen_provider_settings.c and
// screen_db_servers.c build them.
import XCTest
@testable import BriareusMacCore

final class SettingsLogicTests: XCTestCase {
    func testListsSplitTrimAndDropBlankLines() {
        XCTAssertEqual(SettingsText.list(from: " composer install \n\n  npm ci\r\n"), ["composer install", "npm ci"])
        XCTAssertEqual(SettingsText.listText(["a", 1, "b"]), "a\nb")
        XCTAssertEqual(SettingsText.lineCount("a\nb\nc"), 3)
        XCTAssertEqual(SettingsText.numberText(12.5), "12.5")
        XCTAssertEqual(SettingsText.numberText(.null), "")
    }

    func testRowHasEveryKeyWhenEmpty() {
        XCTAssertTrue(SettingsText.rowHas([:], "anything"))
        XCTAssertTrue(SettingsText.rowHas(["a": nil], "a"))
        XCTAssertFalse(SettingsText.rowHas(["a": 1], "b"))
    }

    func testProjectBodyKeepsUnknownFieldsAndDropsServerOnes() throws {
        var s = ProjectFormState(row: ["id": 4, "repo": "o/r", "sortOrder": 2, "createdAt": 1, "extra": "kept", "setupCommands": ["a"],
                                       "workerBudgetUsd": nil, "reviewProviderId": 2, "reviewModel": "m", "reviewEffort": "high"])
        XCTAssertEqual(s.id, 4)
        XCTAssertFalse(s.tabChanged(.project))
        s.texts[.setup] = "a\n\n b "
        XCTAssertTrue(s.tabChanged(.project))
        s.texts[.budget] = "25"
        let body = try s.body().get()
        XCTAssertEqual(body["extra"], "kept")
        XCTAssertTrue(body["id"].isNull && body["sortOrder"].isNull && body["createdAt"].isNull)
        XCTAssertEqual(body["setupCommands"], ["a", "b"])
        XCTAssertEqual(body["workerBudgetUsd"], 25)
        XCTAssertEqual(body["reviewProviderId"], 2)
        // A field the server's projects do not carry is not sent.
        XCTAssertNil(body.object?["localDir"])
    }

    func testProjectActiveSwitchAndAutonomousLoopAreSent() throws {
        var s = ProjectFormState(row: ["id": 4, "repo": "o/r", "enabled": true, "autonomousReviewLoop": false])
        XCTAssertTrue(s.bool(.enabled))
        s.bools[.enabled] = false
        XCTAssertTrue(s.tabChanged(.project))
        s.bools[.autoLoop] = true
        XCTAssertTrue(s.tabChanged(.review))
        let body = try s.body().get()
        XCTAssertEqual(body["enabled"], false)
        XCTAssertEqual(body["autonomousReviewLoop"], true)
        // A server whose projects predate the loop gets no key for it.
        XCTAssertNil(try ProjectFormState(row: ["repo": "o/r", "enabled": true]).body().get().object?["autonomousReviewLoop"])
    }

    func testProjectBodyRefusesABadRepoOrBudget() {
        var s = ProjectFormState(row: [:])
        s.texts[.repo] = "nope"
        XCTAssertEqual(s.body().failureMessage, "Enter the repository as owner/name.")
        s.texts[.repo] = "o/r"
        s.texts[.budget] = "-3"
        if case .failure(let p) = s.body() {
            XCTAssertEqual(p.tab, ProjectTab.orchestrator.rawValue)
            XCTAssertTrue(p.message.hasPrefix("Budget (USD) must be a number"))
        } else { XCTFail() }
    }

    func testTheProjectsBoardIsEditedAsItsAddress() throws {
        var s = ProjectFormState(row: ["repo": "o/r", "projectBoard": ["owner": "hq", "ownerType": "organization", "number": 1, "view": 42]])
        XCTAssertEqual(s.text(.board), "https://github.com/orgs/hq/projects/1/views/42")
        XCTAssertFalse(s.tabChanged(.project))
        s.texts[.board] = " https://github.com/users/ana/projects/3 "
        XCTAssertTrue(s.tabChanged(.project))
        XCTAssertEqual(try s.body().get()["projectBoard"], ["owner": "ana", "ownerType": "user", "number": 3, "view": nil])
        s.texts[.board] = ""
        XCTAssertTrue(try s.body().get()["projectBoard"].isNull)
        s.texts[.board] = "https://github.com/hq/projects/1"
        if case .failure(let p) = s.body() {
            XCTAssertEqual(p.tab, ProjectTab.project.rawValue)
            XCTAssertTrue(p.message.hasPrefix("GitHub Projects board must be the board's address on GitHub"))
        } else { XCTFail() }
        // A server whose projects name no board has no such field.
        XCTAssertFalse(ProjectFormState(row: ["repo": "o/r"]).offered(.board))
    }

    func testStepRuntimesLeftOnTheReviewAreNoEntry() throws {
        var s = ProjectFormState(row: ["repo": "o/r", "stepRuntimes": ["testSheet": ["providerId": 3, "model": "x", "effort": ""]]])
        XCTAssertEqual(s.pick(.testSheet).providerId, 3)
        s.picks[.testSheet] = RuntimePick()
        s.picks[.testRun] = RuntimePick(providerId: 5, model: "m", effort: nil)
        let body = try s.body().get()
        XCTAssertTrue(body["stepRuntimes"]["testSheet"].isNull)
        XCTAssertEqual(body["stepRuntimes"]["testRun"], ["providerId": 5, "model": "m", "effort": ""])
        XCTAssertTrue(s.tabChanged(.review))
        XCTAssertFalse(s.tabChanged(.orchestrator))
    }

    func testPickTextKeepsAProviderTheCatalogLost() {
        let s = ProjectFormState(row: ["repo": "o/r", "reviewProviderId": 9, "reviewModel": "m"])
        XCTAssertEqual(s.pickText(.review, part: 0, catalog: RuntimeCatalog()), "Provider #9 (unavailable)")
        XCTAssertEqual(s.pickText(.review, part: 0, catalog: nil), "Provider #9")
        XCTAssertEqual(s.pickText(.review, part: 1, catalog: nil), "m")
        XCTAssertEqual(s.pickText(.review, part: 2, catalog: nil), "—")
        XCTAssertEqual(s.pickText(.worker, part: 0, catalog: nil), "Same as the orchestrator")
    }

    func testProviderModeAndBody() throws {
        var s = ProviderFormState(row: ["id": 2, "label": "Max", "binary": "claude", "apiKey": "", "baseUrl": "", "hasLogin": true])
        XCTAssertFalse(s.token)
        XCTAssertTrue(s.canLogIn)
        s.texts[.apiKey] = "secret"
        // The login mode drops the endpoint and its token.
        XCTAssertEqual(try s.body().get()["apiKey"], "")
        XCTAssertNil(try s.body().get().object?["hasLogin"])
        s.token = true
        XCTAssertEqual(try s.body().get()["apiKey"], "secret")
        XCTAssertTrue(s.tabChanged(.provider))
        s.texts[.label] = ""
        XCTAssertEqual(s.body().failureMessage, "Enter a label: it is what the provider picker shows.")
        XCTAssertNotNil(try? s.body(validate: false).get())
        XCTAssertTrue(ProviderFormState(row: ["binary": "opencode"]).usesToken)
        XCTAssertFalse(ProviderFormState.modeOffered("grok"))
    }

    func testProviderStatusHeadline() {
        XCTAssertNil(ProviderStatusText.headline(.null))
        XCTAssertEqual(ProviderStatusText.headline(["available": false])?.text, "The CLI is not installed on this machine")
        let ok = ProviderStatusText.headline(["auth": ["loggedIn": true, "email": "a@b"]])
        XCTAssertEqual(ok?.text, "Connected: a@b")
        XCTAssertEqual(ok?.dot, "idle")
        XCTAssertEqual(ProviderStatusText.headline(["auth": ["loggedIn": false]])?.dot, "failed")
        let r = ProviderStatusText.testResult(["models": ["a", "b"]], modelsNow: "a")
        XCTAssertEqual(r.text, "OK: the endpoint offers 2 models; they are in the Models tab, save to keep them")
        XCTAssertEqual(r.models, "a\nb")
    }

    func testProviderQuota() {
        let payload: JSON = ["providers": [
            ["id": "claude", "label": "Claude", "available": true, "auth": ["loggedIn": true],
             "accounts": [
                ["id": "a", "label": "Work", "auth": ["loggedIn": true, "detail": "a@b (max)"],
                 "usage": ["windows": [["label": "5h", "usedPct": 75, "resetsAt": "2026-01-02T10:00:00Z"]]]],
                ["id": "b", "auth": ["loggedIn": false], "usage": ["error": "Not logged in"]],
             ]],
            ["id": "codex", "available": false, "auth": ["loggedIn": true], "usage": ["windows": []]],
            ["id": "grok", "label": "Grok", "available": true, "auth": ["loggedIn": false]],
        ]]
        let ps = ProviderQuota.providers(payload)
        XCTAssertEqual(ps.map(ProviderQuota.title), ["Claude", "codex", "Grok"])
        XCTAssertEqual(ps.map(ProviderQuota.health), [.ready, .missing, .loggedOut])
        let accounts = ProviderQuota.accounts(ps[0])
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(ProviderQuota.accountName(accounts[0], of: ps[0]), "Work")
        XCTAssertEqual(ProviderQuota.accountName(accounts[1], of: ps[0]), "b")
        XCTAssertEqual(ProviderQuota.login(accounts[0]).text, "a@b (max)")
        XCTAssertTrue(ProviderQuota.login(accounts[1]).loggedOut)
        let now = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01 00:00 UTC
        let w = ProviderQuota.windows(accounts[0], now: now)
        XCTAssertEqual(w.map(\.label), ["5h"])
        XCTAssertEqual(w.first?.pct, 75)
        XCTAssertTrue(w.first?.right.hasPrefix("75% used · resets ") ?? false)
        XCTAssertNil(ProviderQuota.windowsNote(accounts[0]))
        XCTAssertEqual(ProviderQuota.windowsNote(accounts[1]), "Not logged in")
        // A provider with no accounts list stands for its own one login.
        let single = ProviderQuota.accounts(ps[1])
        XCTAssertEqual(single.count, 1)
        XCTAssertNil(ProviderQuota.accountName(single[0], of: ps[1]))
        XCTAssertEqual(ProviderQuota.login(single[0]).text, "logged in")
        XCTAssertEqual([10, 70, 89.9, 90].map(ProviderQuota.level), [.ok, .close, .close, .spent])
    }

    func testDBServerPortAndTest() throws {
        var s = DBServerFormState(row: ["id": 1, "host": "h", "port": 3306, "enabled": true, "password": " p "])
        XCTAssertEqual(s.text(.port), "3306")
        s.texts[.port] = "70000"
        XCTAssertEqual(s.body().failureMessage, "The port must be a whole number from 1 to 65535.")
        s.texts[.port] = ""
        let body = try s.body().get()
        XCTAssertTrue(body["port"].isNull)
        XCTAssertEqual(body["password"], " p ")
        XCTAssertEqual(DBServerFormState.testText(["version": "8.0", "databases": 1, "claimedBy": ["title": "Fix"]]),
                       "Healthy: MySQL 8.0, 1 database · claimed by session Fix")
        XCTAssertEqual(DBServerFormState.poolText(capacity: 1, total: 3),
                       "1 server in the pool, so 1 session with a database may be open at once. 2 more are listed but taken out of the pool.")
    }
}

private extension Result where Failure == FormProblem {
    var failureMessage: String? { if case .failure(let p) = self { return p.message }; return nil }
}
