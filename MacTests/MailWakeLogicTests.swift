// The ✉ Mail wake form: the record's rules and caps fill it, Save sends trimmed rules with their ids and whole-number caps
// in range, and the first rule or cap that cannot be sent is named; a project's mail tools and the usable mailboxes gate
// rules that are on.
import XCTest
@testable import BriareusMacCore

final class MailWakeLogicTests: XCTestCase {
    private let caps: [MailWakeCap: String] = [.perHour: "30", .maxTurns: "10"]

    func testRulesAndCapsOpenOnTheRecordOrTheDefaults() {
        let wake = j(#"{"rules":[{"id":"a1","account":3,"enabled":false,"to":"ops@x.io","from":"","subject":"Alert","since":5},{"account":4},"junk"],"perHour":120,"maxTurns":1}"#)
        XCTAssertEqual(mailWakeRules(wake), [MailWakeRule(id: "a1", account: 3, enabled: false, to: "ops@x.io", subject: "Alert"),
                                             MailWakeRule(account: 4)])
        XCTAssertEqual(MailWakeCap.perHour.text(wake), "120")
        XCTAssertEqual(MailWakeCap.maxTurns.text(wake), "1")
        XCTAssertEqual(MailWakeCap.perHour.text([:]), String(MailWakeCap.perHour.fallback))
        XCTAssertEqual(MailWakeCap.maxTurns.text([:]), String(MailWakeCap.maxTurns.fallback))
        XCTAssertEqual(mailWakeRules(.null), [])
    }

    func testASessionIsMarkedWhenARuleIsOn() {
        XCTAssertTrue(mailWakeOn(j(#"{"mailWake":{"rules":[{"account":1,"enabled":false},{"account":2}]}}"#)))
        XCTAssertFalse(mailWakeOn(j(#"{"mailWake":{"rules":[{"account":1,"enabled":false}]}}"#)))
        XCTAssertFalse(mailWakeOn(j(#"{"id":"s"}"#)))
    }

    func testTheProjectsMailToolsAndTheUsableMailboxes() {
        let projects = j(#"{"projects":[{"repo":"o/on","mailToolsEnabled":true},{"repo":"o/off","mailToolsEnabled":false},{"repo":"o/old"}]}"#)
        XCTAssertEqual(mailToolsEnabled(projects, repo: "o/on"), true)
        XCTAssertEqual(mailToolsEnabled(projects, repo: "o/off"), false)
        XCTAssertNil(mailToolsEnabled(projects, repo: "o/old"))
        XCTAssertNil(mailToolsEnabled(projects, repo: "o/none"))

        let accounts = MailAccounts(j(#"{"providers":["gmail"],"accounts":[{"id":1,"provider":"gmail","email":"a@x.io","enabled":true,"status":"connected"},{"id":2,"provider":"gmail","email":"b@x.io","enabled":false,"status":"connected"},{"id":3,"provider":"gmail","email":"c@x.io","enabled":true,"status":"reauth"}]}"#))!
        XCTAssertEqual(mailWakeMailboxes(accounts).map(\.id), [1])
    }

    func testAddressesAsTheServerTakesThem() {
        for ok in ["a@b.co", "first.last+tag@mail.example.org"] { XCTAssertTrue(mailWakeAddress(ok), ok) }
        for bad in ["", "a", "a@b", "@b.co", "a@.co", "a@b.", "a b@c.io", "a@b@c.io"] { XCTAssertFalse(mailWakeAddress(bad), bad) }
    }

    func testSaveSendsTrimmedRulesWithTheirIdsAndTheCaps() {
        let rules = [MailWakeRule(id: "a1", account: 3, to: " ops@x.io ", subject: " Alert "), MailWakeRule(account: 4, enabled: false)]
        XCTAssertEqual(mailWakeSave(rules: rules, caps: [.perHour: " 600 ", .maxTurns: "1000"], usable: [3], mailTools: true), .body(j(#"""
            {"rules":[{"id":"a1","account":3,"enabled":true,"to":"ops@x.io","from":"","subject":"Alert"},
                      {"account":4,"enabled":false,"to":"","from":"","subject":""}],
             "perHour":600,"maxTurns":1000}
            """#)))
        XCTAssertEqual(mailWakeSave(rules: [], caps: caps), .body(j(#"{"rules":[],"perHour":30,"maxTurns":10}"#)))
    }

    func testSaveNamesTheFirstProblem() {
        let ok = MailWakeRule(account: 1)
        XCTAssertEqual(mailWakeSave(rules: Array(repeating: ok, count: mailWakeRuleLimit + 1), caps: caps), .invalid(.tooMany))
        XCTAssertEqual(mailWakeSave(rules: [ok, MailWakeRule()], caps: caps), .invalid(.noMailbox(rule: 1)))
        XCTAssertEqual(mailWakeSave(rules: [MailWakeRule(account: 1, from: "nobody")], caps: caps), .invalid(.notAddress(rule: 0, .from)))
        XCTAssertEqual(mailWakeSave(rules: [MailWakeRule(account: 1, subject: String(repeating: "s", count: mailWakeTextLimit + 1))], caps: caps),
                       .invalid(.tooLong(rule: 0, .subject)))
        // Counted as the server counts: an emoji is two.
        XCTAssertEqual(mailWakeSave(rules: [MailWakeRule(account: 1, subject: String(repeating: "\u{1F4E7}", count: mailWakeTextLimit / 2 + 1))], caps: caps),
                       .invalid(.tooLong(rule: 0, .subject)))
        XCTAssertEqual(mailWakeSave(rules: [ok], caps: [.perHour: "0", .maxTurns: "5"]), .invalid(.cap(.perHour)))
        XCTAssertEqual(mailWakeSave(rules: [ok], caps: [.perHour: "30", .maxTurns: "0"]), .invalid(.cap(.maxTurns)))
        XCTAssertEqual(mailWakeSave(rules: [ok], caps: [.perHour: "30"]), .invalid(.cap(.maxTurns)))
        XCTAssertEqual(MailWakeProblem.notAddress(rule: 2, .to).rule, 2)
        XCTAssertNil(MailWakeProblem.cap(.perHour).rule)
    }

    func testRulesThatAreOnNeedAUsableMailboxAndTheProjectsMailTools() {
        XCTAssertEqual(mailWakeSave(rules: [MailWakeRule(account: 9)], caps: caps, usable: [1]), .invalid(.mailboxUnusable(rule: 0)))
        XCTAssertEqual(mailWakeSave(rules: [MailWakeRule(account: 1)], caps: caps, mailTools: false), .invalid(.mailToolsOff))
        // A rule that is off may keep a mailbox gone since, and rules that are off may be saved with the tools off.
        if case .invalid(let p) = mailWakeSave(rules: [MailWakeRule(account: 9, enabled: false)], caps: caps, usable: [1], mailTools: false) {
            XCTFail("refused \(p)")
        }
    }

    func testTheRoutes() {
        XCTAssertEqual(APIRoute.named("session_mail_wake")?.method, "GET")
        XCTAssertEqual(APIRoute.named("set_session_mail_wake")?.method, "PUT")
        XCTAssertEqual(APIRoute.named("set_session_mail_wake")?.path, "sessions/{sessionId}/mail-wake")
    }
}
