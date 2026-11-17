// GitHub's refusals as both apps show them (GithubRefusalLogic.swift): the core's `no GitHub token for <repo>` recognised
// only as the whole message (and, in `APIError`, only as its 503) and kept apart from GitHub's own refusals, the server's words carried through as the detail, the
// loaded account named, and `APIError` saying the missing token instead of a generic failure.
import XCTest
@testable import BriareusMacCore

final class GithubRefusalLogicTests: XCTestCase {
    // MARK: Recognising the missing token

    func testTheMissingTokenNamesItsRepository() {
        XCTAssertEqual(missingGithubTokenRepo("no GitHub token for acme/api"), "acme/api")
        XCTAssertEqual(missingGithubTokenRepo("  no GitHub token for acme/api\n"), "acme/api")
    }

    func testOtherMessagesAreNotAMissingToken() {
        XCTAssertNil(missingGithubTokenRepo(nil))
        XCTAssertNil(missingGithubTokenRepo(""))
        XCTAssertNil(missingGithubTokenRepo("Resource not accessible by personal access token"))
        XCTAssertNil(missingGithubTokenRepo("no GitHub token for "))
    }

    func testOnlyTheCoresWholeMessageIsAMissingToken() {
        XCTAssertNil(missingGithubTokenRepo("Error: no GitHub token for acme/api."))
        XCTAssertNil(missingGithubTokenRepo("pushed the branch, then no GitHub token for acme/api"))
        XCTAssertNil(missingGithubTokenRepo("No github token for acme/api"))
        XCTAssertNil(missingGithubTokenRepo("no GitHub token for acme/api (retry later)"))
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

    func testTheNoteAndNoticeSplitTheRefusal() {
        let refused = githubRefusal(.issues, error: "Resource not accessible")
        XCTAssertEqual(refused.note, refused.explanation)
        XCTAssertEqual(refused.notice, "Resource not accessible")
        let bare = githubRefusal(.board, error: nil)
        XCTAssertEqual(bare.note, bare.explanation)
        XCTAssertNil(bare.notice)
        let missing = githubRefusal(.projects, error: "no GitHub token for acme/api")
        XCTAssertNil(missing.note)
        XCTAssertEqual(missing.notice, missingGithubTokenText("acme/api"))
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

    func testAnIdentityWithNoTokenAtAllIsNotNamedAsTheAccountAskedWith() {
        let bare = GithubAccountIdentity(id: nil, label: "", login: nil, globalFallback: false, hasToken: false)
        let fallback = GithubAccountIdentity(id: nil, label: "", login: nil, globalFallback: true, hasToken: false)
        for subject in [GithubReadSubject.issues, .projects, .board] {
            let generic = githubRefusal(subject, error: "x").explanation
            XCTAssertEqual(githubRefusal(subject, error: "x", account: bare).explanation, generic)
            XCTAssertEqual(githubRefusal(subject, error: "x", account: fallback).explanation, generic)
        }
        let labelled = GithubAccountIdentity(id: 4, label: "acme-bot", login: nil, globalFallback: false, hasToken: false)
        XCTAssertTrue(githubRefusal(.issues, error: "x", account: labelled).explanation.contains(githubAccountPhrase(labelled)))
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

    func testTheMissingTokenCountsOnlyAsTheCores503() {
        for status in [500, 502, 504] {
            let e = APIError(.http, status: status, message: "no GitHub token for acme/api")
            XCTAssertNil(e.missingGithubToken)
            XCTAssertFalse(e.isRefusal)
            XCTAssertEqual(e.serverMessage, "no GitHub token for acme/api")
        }
        let partly = APIError(.http, status: 503, message: "pushed the branch, then no GitHub token for acme/api")
        XCTAssertNil(partly.missingGithubToken)
        XCTAssertFalse(partly.isRefusal)
    }

    func testABoardsIssuesErrorStandsForTheFailureItCarries() {
        let missing = APIError.githubRead(refused: "no GitHub token for acme/api")
        XCTAssertEqual(missing.status, 503)
        XCTAssertEqual(missing.missingGithubToken, "acme/api")
        let refused = APIError.githubRead(refused: "Resource not accessible by integration")
        XCTAssertEqual(refused.status, 502)
        XCTAssertNil(refused.missingGithubToken)
        XCTAssertEqual(refused.message, "Resource not accessible by integration")
    }

    func testOtherErrorsAreUnchanged() {
        let e = APIError(.http, status: 503, message: "GitHub account registry is not loaded")
        XCTAssertNil(e.missingGithubToken)
        XCTAssertNotEqual(e.description, missingGithubTokenText("acme/api"))
        XCTAssertNil(APIError(.network, message: "no GitHub token for acme/api").missingGithubToken)
        XCTAssertEqual(e.serverMessage, "GitHub account registry is not loaded")
    }
}
