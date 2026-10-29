// Contracts introduced by the October 29 backend changes, including older-server compatibility.
import XCTest
@testable import BriareusMacCore

final class RecentAPIChangesTests: XCTestCase {
    func testActionSettingsReadEditAndSaveCurrentNames() throws {
        var form = ProjectFormState(row: ["repo": "o/r", "prAuthor": "author", "qaTestRun": true,
                                          "actionProviderId": 3, "actionModel": "model", "actionEffort": "high",
                                          "stepRuntimes": [:]])
        XCTAssertEqual(form.text(.reviewAuthor), "author")
        XCTAssertTrue(form.bool(.testRun))
        XCTAssertEqual(form.pick(.review), RuntimePick(providerId: 3, model: "model", effort: "high"))
        XCTAssertFalse(form.tabChanged(.review))
        for field in [ProjectField.publish, .autoLoop, .testSheet, .feedbackSteps] { XCTAssertFalse(form.offered(field)) }
        XCTAssertTrue(form.stepEnabled(.testSheet))
        form.texts[.reviewAuthor] = " new-author "
        form.bools[.testRun] = false
        form.picks[.review] = RuntimePick(providerId: 5, model: "other", effort: "low")
        XCTAssertTrue(form.tabChanged(.review))
        XCTAssertFalse(form.stepEnabled(.testRun))
        let body = try form.body().get()
        XCTAssertEqual(body["prAuthor"], "new-author")
        XCTAssertEqual(body["qaTestRun"], false)
        XCTAssertEqual(body["actionProviderId"], 5)
        XCTAssertEqual(body["actionModel"], "other")
        XCTAssertEqual(body["actionEffort"], "low")
        for key in ["reviewAuthor", "reviewTestRun", "reviewProviderId", "reviewModel", "reviewEffort", "reviewTestSheet", "autonomousReviewLoop"] {
            XCTAssertNil(body.object?[key])
        }
    }

    func testLegacySettingsKeepTheirOriginalKeysAndOptionalSteps() throws {
        var form = ProjectFormState(row: ["repo": "o/r", "reviewAuthor": "old", "reviewTestRun": true,
                                          "reviewTestSheet": false, "reviewProviderId": 2, "reviewModel": "legacy", "reviewEffort": "max"])
        XCTAssertEqual(form.text(.reviewAuthor), "old")
        XCTAssertTrue(form.bool(.testRun))
        XCTAssertFalse(form.stepEnabled(.testSheet))
        XCTAssertTrue(form.offered(.review))
        form.texts[.reviewAuthor] = "updated"
        form.picks[.review] = RuntimePick(providerId: 4, model: "next", effort: "low")
        let body = try form.body().get()
        XCTAssertEqual(body["reviewAuthor"], "updated")
        XCTAssertEqual(body["reviewProviderId"], 4)
        XCTAssertEqual(body["reviewModel"], "next")
        XCTAssertNil(body.object?["actionProviderId"])
        XCTAssertNil(body.object?["prAuthor"])
    }

    func testKeyOnlyProvidersKeepCredentialsAndCannotOfferLogin() throws {
        for binary in ["dsh", "qwen"] {
            XCTAssertTrue(ProviderFormState.binaries.contains { $0.id == binary })
            var form = ProviderFormState(row: ["id": 1, "label": "Agent", "binary": .string(binary)])
            XCTAssertTrue(form.usesToken)
            XCTAssertFalse(form.canLogIn)
            XCTAssertFalse(ProviderFormState.modeOffered(binary))
            form.texts[.baseUrl] = " https://endpoint.example/v1 "
            form.texts[.apiKey] = " key "
            let body = try form.body().get()
            XCTAssertEqual(body["binary"], .string(binary))
            XCTAssertEqual(body["baseUrl"], "https://endpoint.example/v1")
            XCTAssertEqual(body["apiKey"], "key")
        }
    }

    func testClaudeReviewActionUsesActionsRatherThanTheRemovedSessionFlag() throws {
        let catalog: JSON = [["id": "review", "label": "Code review", "binary": "claude", "hint": "Claude review"]]
        let review = try XCTUnwrap(BoardAction.startable(catalog: catalog, pull: nil, failedChecks: 0,
                                                        canManage: true, supports: { $0 == "action" }).first)
        XCTAssertEqual(review.id, "review")
        XCTAssertEqual(review.binary, "claude")
        XCTAssertEqual(review.operation, "action")
        XCTAssertEqual(review.arguments(repo: "o/r", number: 8, branch: "feature"), ["repo": "o/r", "prNumber": 8, "action": "review"])
        let legacy = try XCTUnwrap(APIRoute.named("review"))
        XCTAssertFalse(Route.supportsBodyField([Route(method: "POST", path: "sessions", access: "manage", bodyFields: ["prompt", "qa"])], route: legacy))
        XCTAssertTrue(Route.supportsBodyField([Route(method: "POST", path: "sessions", access: "manage", bodyFields: ["review"])], route: legacy))
        XCTAssertEqual(BoardAction.startable(catalog: catalog, pull: nil, failedChecks: 0, canManage: false, supports: { _ in true }), [])
    }
    func testVoiceErrandsRespectTheCatalogAndLegacyReviewCapability() throws {
        let current: JSON = [["id": "review", "label": "Review", "binary": "claude"], ["id": "fix-checks", "label": "Fix checks"]]
        XCTAssertEqual(Voice.offeredErrand("review", catalog: current, legacyReviews: false)?.operation, "action")
        XCTAssertEqual(Voice.offeredErrand("fix-checks", catalog: current, legacyReviews: false)?.operation, "action")
        XCTAssertNil(Voice.offeredErrand("implement-feedback", catalog: current, legacyReviews: false))
        XCTAssertNil(Voice.offeredErrand("review", catalog: [], legacyReviews: false))
        XCTAssertEqual(Voice.offeredErrand("review", catalog: [], legacyReviews: true)?.operation, "review")
        XCTAssertNil(Voice.offeredErrand("delete-self-comments", catalog: current, legacyReviews: true))
    }

}
