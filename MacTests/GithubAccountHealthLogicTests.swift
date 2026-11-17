// A project's server GitHub account and an admin's health check of it (GithubAccountHealthLogic.swift): the identity read
// from `GET /github/account`, its line for an assigned account, the global fallback and a missing token, the phrase a
// refusal names it with, which project shows it, and `GET /settings/github/health` read into rows for valid, invalid and
// throttled tokens.
import XCTest
@testable import BriareusMacCore

final class GithubAccountHealthLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var nowMs: Int { 1_800_000_000_000 }

    // MARK: Identity

    func testAnAssignedAccountReadsItsLabelAndLogin() throws {
        let a = try XCTUnwrap(GithubAccountIdentity(j(#"{"account":{"id":4,"label":"acme-bot","login":"acme","globalFallback":false,"hasToken":true}}"#)))
        XCTAssertEqual(a, GithubAccountIdentity(id: 4, label: "acme-bot", login: "acme", globalFallback: false, hasToken: true))
        XCTAssertTrue(a.line.contains("acme-bot"))
        XCTAssertTrue(a.line.contains("@acme"))
        XCTAssertNil(a.detail)
        XCTAssertEqual(a.tone, .ok)
        XCTAssertTrue(githubAccountPhrase(a).contains("acme-bot"))
        XCTAssertTrue(githubAccountPhrase(a).contains("@acme"))
    }

    func testTheGlobalFallbackNamesTheServersToken() throws {
        let a = try XCTUnwrap(GithubAccountIdentity(j(#"{"account":{"id":null,"label":"GITHUB_TOKEN","login":null,"globalFallback":true,"hasToken":true}}"#)))
        XCTAssertNil(a.id); XCTAssertNil(a.login); XCTAssertTrue(a.globalFallback)
        // The fallback reads apart from an assigned account and from a missing token.
        let assigned = GithubAccountIdentity(id: 4, label: "GITHUB_TOKEN", login: "acme", globalFallback: false, hasToken: true)
        XCTAssertNotEqual(a.line, assigned.line)
        XCTAssertNotEqual(a.line, GithubAccountIdentity(label: "GITHUB_TOKEN", globalFallback: true, hasToken: false).line)
        XCTAssertNotNil(a.detail)
        XCTAssertEqual(a.tone, .muted)
        XCTAssertNotEqual(githubAccountPhrase(a), githubAccountPhrase(assigned))
        XCTAssertNotEqual(githubAccountPhrase(a), githubAccountPhrase(nil))
        // A login a health check verified for the fallback shows with it.
        XCTAssertTrue(GithubAccountIdentity(label: "GITHUB_TOKEN", login: "srv", globalFallback: true, hasToken: true).line.contains("srv"))
    }

    func testAMissingTokenIsAFaultWhicheverAccountIsSelected() throws {
        let fallback = try XCTUnwrap(GithubAccountIdentity(j(#"{"label":"GITHUB_TOKEN","globalFallback":true,"hasToken":false}"#)))
        let assigned = try XCTUnwrap(GithubAccountIdentity(j(#"{"id":2,"label":"ops","login":"ops-bot","globalFallback":false,"hasToken":false}"#)))
        for a in [fallback, assigned] {
            XCTAssertEqual(a.tone, .danger)
            XCTAssertFalse(a.line.contains("ops-bot"))
            XCTAssertNotEqual(a.line, GithubAccountIdentity(label: "GITHUB_TOKEN", globalFallback: true, hasToken: true).line)
        }
        // The two missing tokens read the same line; the account it belongs to is in the detail and in a refusal's phrase.
        XCTAssertEqual(fallback.line, assigned.line)
        XCTAssertTrue(assigned.detail?.contains("ops") == true)
        XCTAssertTrue(githubAccountPhrase(assigned).contains("ops"))
        XCTAssertNotEqual(githubAccountPhrase(fallback), githubAccountPhrase(assigned))
    }

    func testAnAnswerWithoutTheAccountShapeIsNotAnIdentity() {
        XCTAssertNil(GithubAccountIdentity(j(#"{"account":null}"#)))
        XCTAssertNil(GithubAccountIdentity(j(#"{"label":"x"}"#)))
        XCTAssertNil(GithubAccountIdentity(j("[]")))
    }

    func testWithoutALoadedIdentityTheRefusalNamesTheProjectsAccount() {
        let general = githubAccountPhrase(nil)
        XCTAssertFalse(general.isEmpty)
        let unlabelled = GithubAccountIdentity(id: 1, label: "", login: "bot", globalFallback: false, hasToken: true)
        XCTAssertTrue(githubAccountPhrase(unlabelled).contains("@bot"))
        XCTAssertNotEqual(githubAccountPhrase(unlabelled), general)
    }

    func testOnlyASavedProjectShowsItsSavedRepositorysAccount() {
        XCTAssertEqual(ProjectFormState(row: j(#"{"id":3,"repo":"o/r"}"#)).githubRepo, "o/r")
        XCTAssertNil(ProjectFormState(row: j(#"{"repo":"o/r"}"#)).githubRepo)
        XCTAssertNil(ProjectFormState(row: j(#"{"id":3,"repo":""}"#)).githubRepo)
        var typing = ProjectFormState(row: j(#"{"id":3,"repo":"o/r"}"#))
        typing.texts[.repo] = "o/other"
        XCTAssertEqual(typing.githubRepo, "o/r")
    }

    func testRoutes() {
        XCTAssertEqual(APIRoute.named("github_account")?.path, "github/account")
        XCTAssertEqual(APIRoute.named("github_account")?.method, "GET")
        XCTAssertEqual(APIRoute.named("settings_github_health")?.path, "settings/github/health")
        XCTAssertEqual(APIRoute.named("settings_github_health")?.method, "GET")
    }

    // MARK: Health

    private func health(_ text: String) throws -> GithubAccountHealth { try XCTUnwrap(GithubAccountHealth(j(text))) }
    private func row(_ h: GithubAccountHealth, _ id: String) throws -> GithubHealthRow {
        try XCTUnwrap(h.rows(now: now).first { $0.id == id })
    }

    private var valid: String {
        #"""
        {"account":{"id":4,"label":"acme-bot","login":"acme","globalFallback":false,"hasToken":true},"healthy":true,
         "token":{"status":"valid","httpStatus":200},
         "scopes":{"status":"ok","granted":["repo","read:org"],"required":["repo"],"missing":[]},
         "repos":[{"repo":"acme/web","accessible":true,"status":"ok","httpStatus":200}],
         "rateLimit":{"core":{"remaining":4321,"limit":5000,"resetAt":\#(nowMs + 600_000)},
                      "graphql":{"remaining":91,"limit":5000,"resetAt":\#(nowMs + 60_000)},
                      "cooldownUntil":{"core":0,"graphql":0}}}
        """#
    }

    func testAValidTokenReadsHealthyWithEveryRow() throws {
        let h = try health(valid)
        XCTAssertTrue(h.healthy)
        XCTAssertEqual(h.token, .valid); XCTAssertEqual(h.tokenHTTPStatus, 200)
        XCTAssertEqual(h.account?.login, "acme")
        XCTAssertEqual(h.scopes, .init(status: .ok, granted: ["repo", "read:org"], required: ["repo"], missing: []))
        XCTAssertFalse(h.scopesUnreported)
        XCTAssertEqual(h.repos, [.init(repo: "acme/web", accessible: true, status: .ok, httpStatus: 200)])
        XCTAssertEqual(h.rateLimit?.core, .init(remaining: 4321, limit: 5000, resetAt: now.addingTimeInterval(600)))
        XCTAssertNil(h.rateLimit?.coreCooldown); XCTAssertNil(h.rateLimit?.graphqlCooldown)
        XCTAssertEqual(h.verdict.tone, .ok)
        let rows = h.rows(now: now)
        XCTAssertEqual(rows.map(\.id), ["token", "scopes", "repo:acme/web", "rate:core", "rate:graphql"])
        XCTAssertEqual(rows.map(\.section), [.token, .scopes, .repos, .rateLimits, .rateLimits])
        XCTAssertEqual(h.groups(now: now).map(\.section), GithubHealthSection.allCases)
        XCTAssertEqual(h.groups(now: now).last?.rows.map(\.id), ["rate:core", "rate:graphql"])
        XCTAssertEqual(try row(h, "token").tone, .ok)
        XCTAssertEqual(try row(h, "rate:core").tone, .ok)
        XCTAssertTrue(try row(h, "rate:core").value.contains("4321"))
        XCTAssertNotNil(try row(h, "rate:core").detail)   // its reset time
        // 91 of 5000 left is under a tenth of the budget.
        XCTAssertEqual(try row(h, "rate:graphql").tone, .warn)
    }

    func testAnInvalidTokenSkipsTheRepositories() throws {
        let h = try health(#"""
        {"account":{"id":4,"label":"acme-bot","login":"acme","globalFallback":false,"hasToken":true},"healthy":false,
         "token":{"status":"invalid","httpStatus":401},
         "scopes":{"status":"unknown","granted":null,"required":["repo","admin:repo_hook"],"missing":null},
         "repos":[{"repo":"acme/web","accessible":null,"status":"not_checked","httpStatus":null},
                  {"repo":"acme/api","accessible":null,"status":"not_checked","httpStatus":null}],
         "rateLimit":{"core":{"remaining":null,"limit":null,"resetAt":null},"graphql":null,"cooldownUntil":{"core":0,"graphql":0}}}
        """#)
        XCTAssertFalse(h.healthy)
        XCTAssertEqual(h.token, .invalid); XCTAssertEqual(h.tokenHTTPStatus, 401)
        XCTAssertEqual(h.verdict.tone, .danger)
        XCTAssertEqual(try row(h, "token").tone, .danger)
        // Unknown because the token never verified, not because it is fine-grained.
        XCTAssertFalse(h.scopesUnreported)
        XCTAssertEqual(h.scopes.required, ["repo", "admin:repo_hook"])
        XCTAssertEqual(try row(h, "scopes").tone, .muted)
        XCTAssertEqual(h.repos.map(\.status), [.notChecked, .notChecked])
        XCTAssertEqual(h.repos.map(\.accessible), [nil, nil])
        XCTAssertEqual(try row(h, "repo:acme/web").tone, .muted)
        XCTAssertNil(try row(h, "repo:acme/web").detail)
        // A bucket not observed yet, and one sent as null, are both unused rather than empty.
        XCTAssertEqual(h.rateLimit?.core, .init(remaining: nil, limit: nil, resetAt: nil))
        XCTAssertNil(h.rateLimit?.graphql)
        XCTAssertEqual(try row(h, "rate:core").tone, .muted)
        XCTAssertEqual(try row(h, "rate:graphql").tone, .muted)
    }

    func testARateLimitedTokenIsAWarningWithItsCooldown() throws {
        let h = try health(#"""
        {"account":{"id":null,"label":"GITHUB_TOKEN","login":null,"globalFallback":true,"hasToken":true},"healthy":false,
         "token":{"status":"rate_limited","httpStatus":null},
         "scopes":{"status":"unknown","granted":null,"required":["repo"],"missing":null},
         "repos":[{"repo":"acme/web","accessible":null,"status":"not_checked","httpStatus":null}],
         "rateLimit":{"core":{"remaining":0,"limit":5000,"resetAt":\#(nowMs + 900_000)},"graphql":null,
                      "cooldownUntil":{"core":\#(nowMs + 905_000),"graphql":0}}}
        """#)
        XCTAssertEqual(h.token, .rateLimited); XCTAssertNil(h.tokenHTTPStatus)
        XCTAssertEqual(h.verdict.tone, .warn)
        XCTAssertEqual(try row(h, "token").tone, .warn)
        XCTAssertNotNil(try row(h, "token").detail)   // a local cool-down, with no HTTP status
        XCTAssertEqual(h.rateLimit?.coreCooldown, now.addingTimeInterval(905))
        XCTAssertNil(h.rateLimit?.graphqlCooldown)
        XCTAssertEqual(try row(h, "rate:core").tone, .danger)
        // Once the cool-down has passed it no longer shows.
        let later = now.addingTimeInterval(1000)
        XCTAssertNotNil(try row(h, "rate:core").detail)
        XCTAssertNil(h.rows(now: later).first { $0.id == "rate:core" }?.detail)
    }

    func testAFineGrainedTokensUnknownScopesAreNotMissing() throws {
        let h = try health(#"""
        {"healthy":true,"token":{"status":"valid","httpStatus":200},
         "scopes":{"status":"unknown","granted":null,"required":["repo"],"missing":null},
         "repos":[{"repo":"acme/web","accessible":true,"status":"ok","httpStatus":200}],"rateLimit":null}
        """#)
        XCTAssertTrue(h.healthy)
        XCTAssertNil(h.scopes.granted); XCTAssertNil(h.scopes.missing)
        XCTAssertTrue(h.scopesUnreported)
        XCTAssertNotEqual(try row(h, "scopes").tone, .danger)
        // No token budget is reported, so no rate rows.
        XCTAssertNil(h.rateLimit)
        XCTAssertFalse(h.rows(now: now).contains { $0.section == .rateLimits })
        XCTAssertEqual(h.groups(now: now).map(\.section), [.token, .scopes, .repos])
    }

    func testARepositoryGithubCouldNotAnswerIsAWarningNotAFault() throws {
        let h = try health(#"""
        {"healthy":false,"token":{"status":"valid","httpStatus":200},
         "scopes":{"status":"ok","granted":["repo"],"required":["repo"],"missing":[]},
         "repos":[{"repo":"acme/web","accessible":true,"status":"ok","httpStatus":200},
                  {"repo":"acme/api","accessible":null,"status":"rate_limited","httpStatus":429}],"rateLimit":null}
        """#)
        XCTAssertEqual(try row(h, "repo:acme/api").tone, .warn)
        XCTAssertEqual(h.verdict.tone, .warn)
    }

    func testMissingScopesAndADeniedRepositoryNeedAttention() throws {
        let h = try health(#"""
        {"healthy":false,"token":{"status":"valid","httpStatus":200},
         "scopes":{"status":"missing","granted":["read:org"],"required":["repo"],"missing":["repo"]},
         "repos":[{"repo":"acme/web","accessible":false,"status":"no_access","httpStatus":404}],"rateLimit":null}
        """#)
        XCTAssertEqual(h.scopes.missing, ["repo"])
        XCTAssertEqual(try row(h, "scopes").tone, .danger)
        XCTAssertTrue(try row(h, "scopes").value.contains("repo"))
        XCTAssertEqual(h.repos.first?.accessible, false)
        XCTAssertEqual(try row(h, "repo:acme/web").tone, .danger)
        XCTAssertTrue(try row(h, "repo:acme/web").detail?.contains("404") == true)
        XCTAssertEqual(h.verdict.tone, .danger)
    }

    func testAMissingTokenHasNoBudgetAndAnAccountWithoutProjectsSaysSo() throws {
        let h = try health(#"""
        {"account":{"label":"GITHUB_TOKEN","globalFallback":true,"hasToken":false},"healthy":false,
         "token":{"status":"missing","httpStatus":null},
         "scopes":{"status":"unknown","granted":null,"required":["repo"],"missing":null},"repos":[],"rateLimit":null}
        """#)
        XCTAssertEqual(h.token, .missing)
        XCTAssertEqual(h.account?.hasToken, false)
        XCTAssertEqual(h.rows(now: now).map(\.section), [.token, .scopes, .repos])
        XCTAssertEqual(try row(h, "repos").tone, .muted)
    }

    func testAnUnknownStatusIsKeptAsUnknownAndAMalformedAnswerIsRefused() throws {
        let h = try health(#"{"healthy":false,"token":{"status":"weird"},"scopes":{},"repos":[{"repo":"a/b","status":"new"},{"status":"ok"}]}"#)
        XCTAssertEqual(h.token, .unknown)
        XCTAssertEqual(h.scopes.status, .unknown)
        XCTAssertEqual(h.repos.map(\.status), [.unknown])
        XCTAssertNil(GithubAccountHealth(j(#"{"token":{"status":"valid"}}"#)))
        XCTAssertNil(GithubAccountHealth(j(#"{"healthy":true}"#)))
    }
}
