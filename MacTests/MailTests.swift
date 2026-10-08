// Ported from the Windows client's tests/core_mail_tests.c: the accounts carry no credentials and providers come from the
// server, the sync window is validated, and a sign-in's callback is checked for destination, state, expiry and single use.
import XCTest
@testable import BriareusMacCore

final class MailTests: XCTestCase {
    private let list = #"{"accounts":[{"id":7,"provider":"gmail","email":"a@example.com","label":"Work","enabled":true,"syncDays":60,"status":"reauth","syncing":false,"lastSyncAt":1791400000000,"lastSyncError":"Access revoked","messages":12,"unread":3,"createdAt":1791300000000,"updatedAt":1791400000001}],"providers":["gmail"],"callbackUrl":"https://core.example/oauth/mail/callback","defaults":{"label":"","enabled":true,"syncDays":30}}"#
    private var accounts: MailAccounts { MailAccounts(j(list))! }
    private func start(server: Bool, redirect: String = "http://127.0.0.1:8888/callback", expires: Double = 1791400900000) -> JSON {
        var s: JSON = ["url": "https://accounts.google.com/o/oauth2/v2/auth?state=s%2B1", "state": "s+1", "redirectUri": .string(redirect)]
        s["finishesOnServer"] = .bool(server)
        s["expiresAt"] = JSON(expires)
        return s
    }
    private let early = Date(timeIntervalSince1970: 1791400000)

    func testAccountsAreCredentialFreeAndProvidersComeFromTheServer() {
        let a = accounts
        let m = a.find(7)!
        XCTAssertEqual(m.syncDays, 60); XCTAssertEqual(m.messages, 12); XCTAssertEqual(m.unread, 3)
        XCTAssertEqual(m.label, "Work"); XCTAssertEqual(m.email, "a@example.com"); XCTAssertEqual(m.lastSyncError, "Access revoked")
        XCTAssertTrue(m.enabled); XCTAssertFalse(m.syncing); XCTAssertTrue(m.needsSignIn)
        XCTAssertEqual(m.lastSyncAt, Date(timeIntervalSince1970: 1791400000))
        XCTAssertEqual(m.title, "Work (a@example.com)")
        XCTAssertTrue(a.available("gmail")); XCTAssertFalse(a.available("outlook")); XCTAssertFalse(a.available("future"))
        XCTAssertNil(a.find(8))
        let other = MailAccounts(j(#"{"accounts":[{"id":8,"provider":"future","email":"b@example.com","credentials":"never retain","status":"new-status","syncing":true}],"providers":["outlook","future",null]}"#))!
        XCTAssertFalse(other.gmail); XCTAssertTrue(other.outlook)
        XCTAssertEqual(other.accounts[0].status, "new-status"); XCTAssertTrue(other.accounts[0].syncing); XCTAssertNil(other.accounts[0].lastSyncAt)
        XCTAssertEqual(other.accounts[0].title, "b@example.com")
        XCTAssertNotNil(MailAccounts(j(#"{"accounts":[],"providers":[]}"#)))
        XCTAssertNil(MailAccounts(j("null")))
        XCTAssertNil(MailAccounts(j(#"{"accounts":[{"id":1,"provider":"gmail","email":"x"},{}],"providers":[]}"#)))
        XCTAssertNil(MailAccount(j(#"{"id":0}"#)))
    }

    func testTheSyncWindowIsAWholeNumberOfDaysFrom1To365() {
        for bad in ["", "0", "366", "-1", "+1", "1.5", "NaN", "1e2", "2x", "999999999999999999999999"] { XCTAssertNil(mailSyncDays(bad), bad) }
        XCTAssertEqual(mailSyncDays(" 365 "), 365); XCTAssertEqual(mailSyncDays("1"), 1)
    }

    func testACallbackMustMatchTheRedirectStateAndExpiry() {
        let s = MailSignIn(start(server: false), provider: "gmail", accountID: 7, accounts: accounts)!
        XCTAssertEqual(s.before[7], "reauth"); XCTAssertEqual(s.accountID, 7)
        let body = s.finishBody(pasted: "http://127.0.0.1:8888/callback?code=c%2B1&state=s%2B1&scope=mail", now: early)
        XCTAssertEqual(body?["state"].string, "s+1"); XCTAssertEqual(body?["code"].string, "c+1")
        let bad = [
            "https://evil.example/callback?state=s%2B1&code=c", "http://127.0.0.1:8889/callback?state=s%2B1&code=c",
            "http://127.0.0.1:8888/other?state=s%2B1&code=c", "http://127.0.0.1:8888/callback?state=wrong&code=c",
            "http://127.0.0.1:8888/callback?state=s%2B1&code=", "http://127.0.0.1:8888/callback?state=s%2B1&code=c&code=d",
            "http://127.0.0.1:8888/callback?state=s%2B1&state=s%2B1&code=c", "http://127.0.0.1:8888/callback?state=s%2B1&code=c&error=access_denied",
            "http://127.0.0.1:8888/callback?state=s%2B1&code=%00", "http://127.0.0.1:8888/callback?state=s%2B1&code=%0a",
            "http://127.0.0.1:8888/callback?state=s%2B1&code=%XX", "http://127.0.0.1:8888/callback?state=s%2B1&code=%",
            "http://127.0.0.1:8888/callback?state=s%2B1&code=c#state=wrong", "http://127.0.0.1:8888/callback?state=s%2B1&code=c&bare",
            "http://127.0.0.1:8888/callback", "http://127.0.0.1:8888/callback?code=c", "http://127.0.0.1:8888/callback?state=s%2B1&code=c+\u{7F}",
        ]
        for url in bad { XCTAssertNil(s.finishBody(pasted: url, now: early), url) }
        XCTAssertNil(s.finishBody(pasted: "http://127.0.0.1:8888/callback?state=s%2B1&code=c", now: s.expiresAt))
        var server = s; server.finishesOnServer = true
        XCTAssertNil(server.finishBody(pasted: "http://127.0.0.1:8888/callback?state=s%2B1&code=c", now: early))
    }

    func testMalformedAndUnofferedStartsAreRefused() {
        XCTAssertNil(MailSignIn(start(server: true), provider: "outlook", accountID: nil, accounts: accounts))
        let bad = ["javascript:alert(1)", "http://remote.example/x", "https://u@host/x", "https://host/x#fragment", "https://host/x?query", "http://127.0.0.1:0/x",
                   "http://localhost:65536/x", "http://localhost:8x", "http://localhost:8/a b", "http://localhost:8/a\\b",
                   "http://localhost.evil/callback", "http://127.0.0.10/callback", "http://localhost@evil/callback", "http://localhost:/callback",
                   "http://localhost:+80/callback", "http://localhost:999999999999999999999/callback", "http://localhost/callback?query", "http://localhost/callback#fragment",
                   "http://localhost/a\u{7F}", "http://[::1].evil/callback", "http://[::1]:0/callback", "http://[::2]/callback", "http://::1/callback"]
        for r in bad { XCTAssertNil(MailSignIn(start(server: true, redirect: r), provider: "gmail", accountID: nil, accounts: accounts), r) }
        XCTAssertNotNil(MailSignIn(start(server: true, redirect: "https://core.example/oauth/mail/callback"), provider: "gmail", accountID: nil, accounts: accounts))
        XCTAssertNotNil(MailSignIn(start(server: true, redirect: "http://localhost:8123/callback"), provider: "gmail", accountID: nil, accounts: accounts))
        var j = start(server: false); j["finishesOnServer"] = nil
        XCTAssertNil(MailSignIn(j, provider: "gmail", accountID: nil, accounts: accounts))
        XCTAssertNil(MailSignIn(start(server: false, expires: 0), provider: "gmail", accountID: nil, accounts: accounts))
        j = start(server: false); j["state"] = ""
        XCTAssertNil(MailSignIn(j, provider: "gmail", accountID: nil, accounts: accounts))
        j = start(server: false); j["url"] = "http://evil.example/"
        XCTAssertNil(MailSignIn(j, provider: "gmail", accountID: nil, accounts: accounts))
    }

    func testLoopbackRedirectsAndEmptyPaths() {
        var a = accounts; a.outlook = true
        for r in ["http://localhost/callback", "http://127.0.0.1/callback", "http://localhost", "http://127.0.0.1",
                  "http://localhost:80/callback", "http://127.0.0.1:65535/callback", "http://[::1]/callback", "http://[::1]:8888/callback"] {
            let s = MailSignIn(start(server: false, redirect: r), provider: "outlook", accountID: nil, accounts: a)
            XCTAssertNotNil(s, r)
            XCTAssertNotNil(s?.finishBody(pasted: "\(r)?state=s%2B1&code=c", now: early), r)
        }
        for r in ["http://localhost:8888", "http://localhost:8888/", "https://core.example", "https://core.example/"] {
            let s = MailSignIn(start(server: false, redirect: r), provider: "gmail", accountID: nil, accounts: accounts)!
            let origin = r.hasSuffix("/") ? String(r.dropLast()) : r
            for (k, path) in ["", "/", "//", "/callback"].enumerated() {
                XCTAssertEqual(s.finishBody(pasted: "\(origin)\(path)?state=s%2B1&code=c", now: early) != nil, k < 2, "\(r) \(path)")
            }
            XCTAssertNil(s.finishBody(pasted: "http://localhost:8889/?state=s%2B1&code=c", now: early))
            XCTAssertNil(s.finishBody(pasted: "http://localhost:8888.evil/?state=s%2B1&code=c", now: early))
        }
        let s = MailSignIn(start(server: false, redirect: "http://localhost:8888/callback"), provider: "gmail", accountID: nil, accounts: accounts)!
        XCTAssertNil(s.finishBody(pasted: "http://localhost:8888/callback/?state=s%2B1&code=c", now: early))
    }

    func testTheServerFinishedOnlyWhenTheRightAccountIsConnected() {
        var a = accounts
        var s = MailSignIn(start(server: true), provider: "gmail", accountID: 7, accounts: a)!
        XCTAssertFalse(s.completed(by: a))
        a.accounts[0].status = "connected"
        XCTAssertTrue(s.completed(by: a))
        s.finishesOnServer = false
        XCTAssertFalse(s.completed(by: a))
        // A sync is not a sign-in, and another account cannot finish this one's.
        a = accounts
        s = MailSignIn(start(server: true), provider: "gmail", accountID: 7, accounts: a)!
        a.accounts[0].syncing = true
        XCTAssertFalse(s.completed(by: a))
        a.accounts[0].status = "connected"; a.accounts[0].id = 8
        XCTAssertFalse(s.completed(by: a))
        // A new mailbox: a new account of the provider.
        s = MailSignIn(start(server: true), provider: "gmail", accountID: nil, accounts: accounts)!
        a.accounts[0].id = 9; a.accounts[0].provider = "outlook"
        XCTAssertFalse(s.completed(by: a))
        a.accounts[0].provider = "gmail"
        XCTAssertTrue(s.completed(by: a))
    }

    func testFailuresExplainReauthAnUnavailableProviderAndAWrongMailbox() {
        XCTAssertTrue(mailErrorMessage(status: 409, finishing: true, detail: nil).contains("different mailbox"))
        XCTAssertTrue(mailErrorMessage(status: 409, finishing: false, detail: nil).contains("sign-in again"))
        XCTAssertTrue(mailErrorMessage(status: 400, finishing: true, detail: nil).contains("expired"))
        XCTAssertTrue(mailErrorMessage(status: 400, finishing: false, detail: "Label too long").contains("200 characters"))
        XCTAssertEqual(mailErrorMessage(status: 400, finishing: false, detail: "Label too long: secret"), mailErrorMessage(status: 400, finishing: false, detail: nil))
        for code in [0, 400, 401, 403, 404, 429, 503, 500] { XCTAssertFalse(mailErrorMessage(status: code, finishing: false, detail: nil).isEmpty) }
        XCTAssertEqual(mailRetryDelay(failures: 1, retryAfter: nil), 10)
        XCTAssertEqual(mailRetryDelay(failures: 2, retryAfter: nil), 20)
        XCTAssertEqual(mailRetryDelay(failures: 5, retryAfter: nil), 60)
        XCTAssertEqual(mailRetryDelay(failures: 1, retryAfter: 90.5), 91)
    }

    // MARK: - The inbox

    private let page = #"{"messages":[{"accountId":7,"id":"AAMk/ab+c=","threadId":"t1","receivedAt":1791400000000,"from":{"name":"Ana","address":"ana@example.com"},"to":[{"name":"","address":"me@example.com"},{"name":"Bo","address":"bo@example.com"}],"cc":[],"replyTo":[],"subject":"","snippet":"Hello","labels":["INBOX","IMPORTANT"],"inInbox":true,"isRead":false,"isStarred":true,"attachments":[{"id":"x","name":"a.pdf","mimeType":"application/pdf","size":2048},{}],"webUrl":"https://mail.google.com/mail/#inbox/1"},{"accountId":8,"id":"m2","from":{"address":"x@example.com"}},{"id":"no account"}],"nextCursor":"c2"}"#

    func testMessagesReadAddressesLabelsAndAttachments() {
        let p = MailPage(j(page))!
        XCTAssertEqual(p.messages.count, 2); XCTAssertEqual(p.nextCursor, "c2")
        let m = p.messages[0]
        XCTAssertEqual(m.key, "7:AAMk/ab+c="); XCTAssertEqual(m.threadID, "t1")
        XCTAssertEqual(m.from, "Ana <ana@example.com>"); XCTAssertEqual(m.to, "me@example.com, Bo <bo@example.com>"); XCTAssertEqual(m.cc, "")
        XCTAssertEqual(m.shownSubject, "(No subject)"); XCTAssertEqual(m.labels, ["INBOX", "IMPORTANT"])
        XCTAssertTrue(m.inInbox); XCTAssertFalse(m.isRead); XCTAssertTrue(m.isStarred)
        XCTAssertEqual(m.attachments, [MailAttachment(name: "a.pdf", mimeType: "application/pdf", size: 2048), MailAttachment(name: "Unnamed", mimeType: "unknown type", size: 0)])
        XCTAssertEqual(m.webURL, "https://mail.google.com/mail/#inbox/1")
        XCTAssertNil(m.text)
        XCTAssertEqual(p.messages[1].from, "x@example.com")
        XCTAssertNil(MailPage(j(#"{"messages":{}}"#)))
        XCTAssertNil(MailPage(j(#"{"messages":[],"nextCursor":""}"#))?.nextCursor)
        // The body: its text only, with the truncation said.
        let full = MailMessage(j(#"{"accountId":7,"id":"m","body":{"text":"Hi\nthere","html":"<script>x</script>","truncated":true}}"#))!
        XCTAssertEqual(full.text, "Hi\nthere"); XCTAssertTrue(full.truncated)
    }

    func testTheFilterSendsOnlyWhatIsSetAndTriStatesAsZeroOrOne() {
        XCTAssertEqual(MailFilter().arguments(cursor: nil).count, 0)
        var f = MailFilter(account: 7, query: "  invoice ", label: "INBOX", thread: "t1", unread: false, inbox: true, starred: nil)
        let a = f.arguments(cursor: "c2")
        XCTAssertEqual(a["account"].truncatedInt, 7); XCTAssertEqual(a["q"].string, "invoice"); XCTAssertEqual(a["label"].string, "INBOX")
        XCTAssertEqual(a["thread"].string, "t1"); XCTAssertEqual(a["unread"].string, "0"); XCTAssertEqual(a["inbox"].string, "1")
        XCTAssertTrue(a["starred"].isNull); XCTAssertEqual(a["cursor"].string, "c2")
        XCTAssertFalse(f.isDefault)
        f.query = String(repeating: "x", count: 300)
        XCTAssertEqual(f.arguments(cursor: nil)["q"].string?.count, 200)
        XCTAssertTrue(MailFilter(account: 3).isDefault)
    }

    func testPagesMergeWithoutRepeatsOrUnreadableMailboxes() {
        let p = MailPage(j(page))!.messages
        XCTAssertEqual(mailMerge([], p, readable: [7]).map(\.key), ["7:AAMk/ab+c="])
        let both = mailMerge([], p, readable: [7, 8])
        XCTAssertEqual(mailMerge(both, p, readable: [7, 8]).count, 2)
        // The same id in another mailbox is another message.
        var other = p[0]; other.accountID = 8
        XCTAssertEqual(mailMerge(both, [other], readable: [7, 8]).count, 3)
        XCTAssertEqual(accounts.readable, [])
        XCTAssertEqual(MailAccounts(j(#"{"accounts":[{"id":1,"provider":"gmail","email":"a","status":"connected"},{"id":2,"provider":"gmail","email":"b","status":"reauth"}],"providers":[]}"#))!.readable, [1])
    }

    func testOnlyAPlainHTTPSHostOpensAtTheProvider() {
        XCTAssertTrue(mailWebURLSafe("https://outlook.office365.com/owa/?ItemID=AAMk%2F"))
        for bad in ["http://mail.google.com/", "https://user@evil.example/", "https://mail.google.com/a b", "https://ma\\il.google.com/", "javascript:alert(1)", "https://xn--e1a.example\u{7F}/"] {
            XCTAssertFalse(mailWebURLSafe(bad), bad)
        }
    }
}
