// A pull request's ▶ Run tab: what it asks the server, and what each answer or failure changes.
import XCTest
@testable import BriareusMacCore

final class RunServeTests: XCTestCase {
    func testFirstStartPreparesANewSession() {
        var run = RunServe()
        XCTAssertTrue(run.needsServing)
        let request = run.start(repo: "o/r", number: 7, canSwitch: true)
        XCTAssertEqual(request?.operation, "serve_pull")
        XCTAssertEqual(request?.arguments["prNumber"].int32, 7)
        XCTAssertEqual(request?.switched, false)
        XCTAssertTrue(run.busy)
        XCTAssertNil(run.start(repo: "o/r", number: 7, canSwitch: true))
    }

    func testServedAnswerShowsTheAddress() {
        var run = RunServe()
        _ = run.start(repo: "o/r", number: 7, canSwitch: true)
        let out = run.served(j(#"{"session":{"id":"s1"},"profile":"web","url":"https://a.example"}"#))
        XCTAssertEqual(out, RunServed(show: "https://a.example", reload: false, startAgain: false))
        XCTAssertEqual(run.session, "s1")
        XCTAssertEqual(run.profile, "web")
        XCTAssertFalse(run.busy)
        XCTAssertFalse(run.needsServing)
    }

    func testSameAddressAgainReloads() {
        var run = RunServe(url: "https://a.example", session: "s1", profile: "web")
        _ = run.start(repo: "o/r", number: 7, canSwitch: true)
        XCTAssertTrue(run.served(j(#"{"profile":"web","url":"https://a.example"}"#)).reload)
    }

    func testUnsafeAddressIsAnError() {
        var run = RunServe()
        _ = run.start(repo: "o/r", number: 7, canSwitch: true)
        XCTAssertNil(run.served(j(#"{"url":"http://a.example"}"#)).show)
        XCTAssertNotNil(run.error)
    }

    func testPickedProfileSwitchesTheServingSession() {
        var run = RunServe(url: "https://a.example", session: "s1", profile: "web")
        XCTAssertTrue(run.pick("api", profiles: ["web", "api"]))
        let request = run.start(repo: "o/r", number: 7, canSwitch: true)
        XCTAssertEqual(request?.operation, "serve")
        XCTAssertEqual(request?.arguments["sessionId"].string, "s1")
        XCTAssertEqual(request?.arguments["profile"].string, "api")
        XCTAssertEqual(request?.switchingTo, "api")
        XCTAssertFalse(run.pick("api", profiles: ["web", "api"]))
    }

    func testPickWhileOutServesAgainOnTheAnswer() {
        var run = RunServe()
        _ = run.start(repo: "o/r", number: 7, canSwitch: true)
        XCTAssertFalse(run.pick("api", profiles: ["web", "api"]))
        XCTAssertTrue(run.served(j(#"{"session":{"id":"s1"},"profile":"web","url":"https://a.example"}"#)).startAgain)
    }

    func testGoneSessionIsForgottenAndARefusedSwitchGoesBack() {
        var gone = RunServe(url: "https://a.example", session: "s1", profile: "web", want: "api")
        _ = gone.start(repo: "o/r", number: 7, canSwitch: true)
        XCTAssertTrue(gone.failed("Gone", status: 404, message: nil, switched: true))
        XCTAssertNil(gone.session)
        XCTAssertNil(gone.url)

        var refused = RunServe(url: "https://a.example", session: "s1", profile: "web", want: "api")
        _ = refused.start(repo: "o/r", number: 7, canSwitch: true)
        XCTAssertFalse(refused.failed("No", status: 422, message: nil, switched: true))
        XCTAssertEqual(refused.want, "web")
        XCTAssertEqual(refused.session, "s1")
        XCTAssertFalse(refused.busy)
    }

    func testForgetKeepsThePick() {
        var run = RunServe(url: "https://a.example", session: "s1", profile: "web", want: "api", busy: true)
        run.forget()
        XCTAssertEqual(run, RunServe(want: "api"))
        XCTAssertEqual(run.shownProfile(["web"]), "api")
        XCTAssertEqual(RunServe().shownProfile(["web", "api"]), "web")
    }
}
