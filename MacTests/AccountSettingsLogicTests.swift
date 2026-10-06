// The Forge account and Slack workspace forms' bodies and unsaved-change tracking, as screen_settings.c builds them.
import XCTest
@testable import BriareusMacCore

final class AccountSettingsLogicTests: XCTestCase {
    func testRepoChoicesListProjectsThenTickedOnesThatAreGone() {
        XCTAssertEqual(settingsRepoChoices(projects: ["a/b", "c/d", "a/b"], ticked: ["c/d", "x/y"]), ["a/b", "c/d", "x/y"])
    }

    func testForgeBodyKeepsTheStoredTokenWhenItsBoxIsEmpty() throws {
        var s = ForgeAccountFormState(row: ["id": 1727000000001, "label": "Prod", "organization": "acme", "hasToken": true, "repos": ["a/b"]])
        XCTAssertEqual(s.id, 1727000000001)
        XCTAssertEqual(s.text(.token), "")
        XCTAssertFalse(s.changed)
        var body = try s.body().get()
        XCTAssertNil(body.object?["token"])
        XCTAssertNil(body.object?["hasToken"])
        XCTAssertEqual(body["repos"], ["a/b"])
        s.texts[.token] = "  new  "
        s.toggle("c/d")
        XCTAssertTrue(s.changed)
        body = try s.body().get()
        XCTAssertEqual(body["token"], "new")
        XCTAssertEqual(body["repos"], ["a/b", "c/d"])
        // The same projects in another order are no change.
        s.texts[.token] = ""
        s.row["repos"] = ["c/d", "a/b"]
        XCTAssertFalse(s.changed)
    }

    func testForgeBodyNeedsAnOrganizationAndATokenOnce() {
        var s = ForgeAccountFormState(row: [:])
        XCTAssertEqual(s.body().failureMessage, "Enter the organization slug from your Forge URLs.")
        s.texts[.organization] = "acme"
        XCTAssertEqual(s.body().failureMessage, "Paste a Forge API token for this organization.")
        XCTAssertEqual(s.tokenCue, "Paste a Forge API token")
        XCTAssertEqual(ForgeAccountFormState(row: ["hasToken": true]).tokenCue, "Stored · type a new token to replace it")
    }

    func testForgeLines() {
        XCTAssertEqual(ForgeAccountFormState.sidebarLine(["organization": "acme", "repos": ["a/b"]]), "acme · a/b")
        XCTAssertEqual(ForgeAccountFormState.sidebarLine(["organization": "acme", "repos": []]), "acme · 0 projects")
        XCTAssertEqual(ForgeAccountFormState.subtitle(["organization": "acme", "repos": ["a/b"]]), "forge.laravel.com/acme · 1 project · no token")
    }

    func testSlackChannelsSplitOnCommasAndSpacesWithoutHashes() {
        XCTAssertEqual(SlackWorkspaceFormState.channels(from: " #general, deploys  general\nC0123 ,, #"), ["general", "deploys", "C0123"])
        XCTAssertEqual(SlackWorkspaceFormState.channelsText(["general", "", "deploys"]), "general, deploys")
    }

    func testSlackBodyAndChanges() throws {
        let row: JSON = ["id": 1727000000002, "label": "Acme", "team": "Acme", "hasToken": true, "hasSigningSecret": false,
                         "projects": [["repo": "a/b", "channels": ["general"], "directMessages": false, "permissionMode": "allow"]]]
        var s = SlackWorkspaceFormState(row: row)
        XCTAssertEqual(s.projects, [SlackProjectRule(repo: "a/b", channels: "general", directMessages: false, allow: true)])
        XCTAssertFalse(s.changed)
        // The channels compare as the server keeps them.
        s.projects[0].channels = "#general,"
        XCTAssertFalse(s.changed)
        s.toggle("c/d")
        XCTAssertTrue(s.changed)
        let body = try s.body().get()
        XCTAssertNil(body.object?["token"])
        XCTAssertNil(body.object?["signingSecret"])
        XCTAssertEqual(body["label"], "Acme")
        XCTAssertEqual(body["projects"], [
            ["repo": "a/b", "channels": ["general"], "directMessages": false, "permissionMode": "allow"],
            ["repo": "c/d", "channels": [], "directMessages": true, "permissionMode": "ask"],
        ])
        XCTAssertEqual(s.cue(.token), "Stored · paste a new token to replace it")
        XCTAssertEqual(s.cue(.signingSecret), "From the app's Basic Information")
        XCTAssertEqual(SlackWorkspaceFormState.subtitle(row), "Acme · 1 project · no replies")
        XCTAssertEqual(SlackWorkspaceFormState.sidebarLine(row), "Acme · a/b")
    }

    func testSlackNeedsATokenAndMarksProjectsAnotherWorkspaceServes() {
        let s = SlackWorkspaceFormState(row: ["id": 5])
        XCTAssertEqual(s.body().failureMessage, "Paste the Slack app's User OAuth Token (xoxp-…): messages go out as the user who installed the app.")
        let others: [JSON] = [["id": 5, "label": "Self", "projects": [["repo": "a/b"]]],
                              ["id": 6, "label": "", "projects": [["repo": "c/d"]]]]
        XCTAssertNil(s.takenBy("a/b", workspaces: others))
        XCTAssertEqual(s.takenBy("c/d", workspaces: others), "another")
        XCTAssertEqual(SlackWorkspaceFormState.subtitle(["projects": []]), "0 projects · no token")
    }

    func testRoutes() {
        XCTAssertEqual(APIRoute.named("update_forge_account")?.path, "settings/forge/accounts/{id}")
        XCTAssertEqual(APIRoute.named("delete_slack_workspace")?.method, "DELETE")
        XCTAssertEqual(APIRoute.named("settings_slack_workspaces")?.path, "settings/slack/workspaces")
    }
}

private extension Result where Failure == FormProblem {
    var failureMessage: String? { if case .failure(let p) = self { return p.message }; return nil }
}
