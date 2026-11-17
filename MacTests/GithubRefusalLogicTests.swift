// GitHub's refusals as both apps show them (GithubRefusalLogic.swift): the core's `no GitHub token for <repo>` recognised
// wherever it appears and kept apart from GitHub's own refusals, the server's words carried through as the detail, the
// loaded account named, and `APIError` saying the missing token instead of a generic failure.
import XCTest
@testable import BriareusMacCore

final class GithubRefusalLogicTests: XCTestCase {
    // MARK: Recognising the missing token

    func testTheMissingTokenNamesItsRepository() {
        XCTAssertEqual(missingGithubTokenRepo("no GitHub token for acme/api"), "acme/api")
        XCTAssertEqual(missingGithubTokenRepo("Error: no GitHub token for acme/api."), "acme/api")
        XCTAssertEqual(missingGithubTokenRepo("No github token for acme/api (retry later)"), "acme/api")
    }

    func testOtherMessagesAreNotAMissingToken() {
        XCTAssertNil(missingGithubTokenRepo(nil))
        XCTAssertNil(missingGithubTokenRepo(""))
        XCTAssertNil(missingGithubTokenRepo("Resource not accessible by personal access token"))
        XCTAssertNil(missingGithubTokenRepo("no GitHub token for "))
    }

    // MARK: Refusals

    func testAMissingTokenIsItsOwnRefusalWithoutTheRawMessage() {
        for subject in [GithubReadSubject.issues, .projects, .board] {
            let r = githubRefusal(subject, error: "no GitHub token for acme/api")
            XCTAssertTrue(r.missingToken)
            XCTAssertNil(r.detail)
            XCTAssertTrue(r.explanation.contains("acme/api"))
            XCTAssertEqual(r.explanation, missingGithubTokenText("acme/api"))
        }
    }

    func testGithubsRefusalKeepsTheServersWordsAsTheDetail() {
        let r = githubRefusal(.issues, error: "  Resource not accessible by integration \n")
        XCTAssertFalse(r.missingToken)
        XCTAssertEqual(r.detail, "Resource not accessible by integration")
        XCTAssertNil(githubRefusal(.projects, error: "   ").detail)
        XCTAssertNil(githubRefusal(.board, error: nil).detail)
    }

    func testEachSubjectExplainsDifferently() {
        let texts = Set([GithubReadSubject.issues, .projects, .board].map { githubRefusal($0, error: "x").explanation })
        XCTAssertEqual(texts.count, 3)
    }

    func testTheRefusalNamesTheLoadedAccount() {
        let account = GithubAccountIdentity(id: 4, label: "acme-bot", login: "acme", globalFallback: false, hasToken: true)
        let named = githubRefusal(.projects, error: "x", account: account)
        XCTAssertTrue(named.explanation.contains(githubAccountPhrase(account)))
        XCTAssertTrue(named.explanation.contains("acme-bot"))
        let generic = githubRefusal(.projects, error: "x")
        XCTAssertTrue(generic.explanation.contains(githubAccountPhrase(nil)))
        XCTAssertNotEqual(named.explanation, generic.explanation)
    }

    // MARK: APIError

    func testAPIErrorSaysTheMissingTokenInsteadOfAGenericFailure() {
        let e = APIError(.http, status: 503, message: "no GitHub token for acme/api")
        XCTAssertEqual(e.missingGithubToken, "acme/api")
        XCTAssertEqual(e.description, missingGithubTokenText("acme/api"))
        XCTAssertEqual(e.serverMessage, e.description)
    }

    func testAMissingTokenIsADefiniteRefusalThoughItIsA503() {
        XCTAssertTrue(APIError(.http, status: 503, message: "no GitHub token for acme/api").isRefusal)
        XCTAssertFalse(APIError(.http, status: 503, message: "GitHub account registry is not loaded").isRefusal)
        XCTAssertTrue(APIError(.http, status: 409, message: "conflict").isRefusal)
    }

    func testOtherErrorsAreUnchanged() {
        let e = APIError(.http, status: 503, message: "GitHub account registry is not loaded")
        XCTAssertNil(e.missingGithubToken)
        XCTAssertNotEqual(e.description, missingGithubTokenText("acme/api"))
        XCTAssertNil(APIError(.network, message: "no GitHub token for acme/api").missingGithubToken)
        XCTAssertEqual(e.serverMessage, "GitHub account registry is not loaded")
    }
}
