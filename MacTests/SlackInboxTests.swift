// Ported from the Windows client's tests/core_slack_tests.c: timestamps compare as decimal strings, messages merge by ts,
// pages advance and stop instead of looping, names resolve, mrkdwn renders as Markdown, and a draft is sent once.
import XCTest
@testable import BriareusMacCore

final class SlackInboxTests: XCTestCase {
    private let history = #"{"messages":[{"ts":"1712345678.000002","user":"U1","text":"new"},{"ts":"1712345678.000001","user":"U1","text":"parent","reply_count":1}],"nextCursor":"","hasMore":true}"#
    private let thread = #"{"messages":[{"ts":"1712345678.000001","text":"parent"},{"ts":"1712345679.000001","thread_ts":"1712345678.000001","text":"reply"}],"nextCursor":"","hasMore":false}"#
    private let people: [String: JSON] = ["U1": JSON.parse(#"{"id":"U1","name":"ana","real_name":"Ana","profile":{"display_name":"Ana Ops"}}"#)!]

    func testTimestampsCompareAsDecimalStrings() {
        XCTAssertTrue(SlackTS.valid("1712345678.000001")); XCTAssertTrue(SlackTS.valid("000000000001.123456789"))
        for bad in [nil, "", "1", ".1", "1.", "1234567890123.1", "1.1234567890", "1.2e3", "-1.1", "1.1x"] { XCTAssertFalse(SlackTS.valid(bad), bad ?? "nil") }
        XCTAssertLessThan(SlackTS.compare("9.1", "10.01"), 0); XCTAssertGreaterThan(SlackTS.compare("10.01", "9.1"), 0)
        XCTAssertEqual(SlackTS.compare("01.10", "1.1"), 0); XCTAssertGreaterThan(SlackTS.compare("1.101", "1.100999999"), 0)
        XCTAssertLessThan(SlackTS.compare("1.123456781", "1.123456782"), 0)
    }

    func testMessagesMergeByTimestampOldestFirst() {
        var m = SlackMessages()
        XCTAssertTrue(m.merge(j(#"{"ts":"1.000000001","text":"old","user":"U1"}"#)))
        XCTAssertTrue(m.merge(j(#"{"ts":"1.000000001","text":"edited","reply_count":2}"#)))
        XCTAssertEqual(m.list.count, 1); XCTAssertEqual(m.list[0].raw["user"].string, "U1"); XCTAssertEqual(m.list[0].raw["text"].string, "edited")
        XCTAssertEqual(m.list[0].replyCount, 2)
        XCTAssertTrue(m.merge(j(#"{"ts":"0.9","text":"older"}"#)))
        XCTAssertEqual(m.list.map(\.ts), ["0.9", "1.000000001"])
        XCTAssertFalse(m.merge(j(#"{"ts":1712345678.1}"#)))
        m.remove("1.000000001"); m.remove("missing")
        XCTAssertEqual(m.list.count, 1)
    }

    func testPagesAdvanceAndStopRatherThanLoop() {
        var m = SlackMessages(), p = SlackPage()
        XCTAssertTrue(p.merge(j(#"{"messages":[],"nextCursor":"next","hasMore":true}"#), into: &m, thread: false))
        XCTAssertTrue(p.more); XCTAssertFalse(p.stalled); XCTAssertEqual(p.cursor, "next"); XCTAssertEqual(p.arguments["cursor"].string, "next")
        XCTAssertTrue(p.merge(j(history), into: &m, thread: false))
        XCTAssertTrue(p.more); XCTAssertEqual(p.latest, "1712345678.000001"); XCTAssertEqual(p.cursor, "")
        XCTAssertEqual(p.arguments["latest"].string, "1712345678.000001")
        XCTAssertEqual(m.list.map(\.ts), ["1712345678.000001", "1712345678.000002"])
        // The bound is exclusive: the edge itself is not read again.
        XCTAssertTrue(p.merge(j(#"{"messages":[{"ts":"1712345678.000001","text":"exclusive"},{"ts":"1712345677.999999","text":"older"}],"nextCursor":"","hasMore":false}"#), into: &m, thread: false))
        XCTAssertEqual(m.list.count, 3); XCTAssertFalse(p.more); XCTAssertEqual(m.list[1].raw["text"].string, "parent")
        // A thread reads forward from its parent.
        var t = SlackMessages(), tp = SlackPage()
        XCTAssertTrue(tp.merge(j(thread), into: &t, thread: true))
        XCTAssertTrue(t.list[0].isThreadParent); XCTAssertFalse(t.list[1].isThreadParent); XCTAssertFalse(t.list[1].inChannel)
        tp = SlackPage()
        XCTAssertTrue(tp.merge(j(#"{"messages":[{"ts":"1.1"},{"ts":"1.2"}],"nextCursor":"","hasMore":true}"#), into: &t, thread: true))
        XCTAssertEqual(tp.oldest, "1.2"); XCTAssertTrue(tp.more); XCTAssertNil(tp.latest)
        XCTAssertTrue(tp.merge(j(#"{"messages":[],"nextCursor":"a","hasMore":false}"#), into: &t, thread: true)); XCTAssertTrue(tp.more)
        XCTAssertTrue(tp.merge(j(#"{"messages":[],"nextCursor":"a","hasMore":true}"#), into: &t, thread: true)); XCTAssertTrue(tp.stalled); XCTAssertFalse(tp.more)
        var e = SlackPage()
        XCTAssertTrue(e.merge(j(#"{"messages":[],"nextCursor":"","hasMore":true}"#), into: &t, thread: false)); XCTAssertTrue(e.stalled)
        XCTAssertFalse(e.merge(j("{}"), into: &t, thread: false))
        XCTAssertFalse(e.merge(j(#"{"messages":[],"nextCursor":5,"hasMore":true}"#), into: &t, thread: false))
    }

    func testPeopleAndConversationsHaveNames() {
        XCTAssertEqual(SlackNames.person("U1", people: people), "Ana Ops"); XCTAssertEqual(SlackNames.person("U2", people: people), "U2")
        XCTAssertEqual(SlackNames.person(nil, people: people), "Unknown author")
        let rows = j(#"[{"id":"C1","name":"general"},{"id":"G1","name":"private","is_private":true},{"id":"D1","user":"U1","is_im":true},{"id":"G2","name":"mpdm-team","is_mpim":true},{"id":"G9"}]"#).items
        XCTAssertEqual(rows.map { SlackNames.conversation($0, people: people) }, ["general", "private", "Ana Ops", "mpdm-team", "G9"])
        XCTAssertEqual(rows.map(SlackNames.glyph), ["#", "🔒", "@", "👥", "#"])
    }

    func testMrkdwnRendersAsMarkdown() {
        let p: [String: JSON] = ["U1": j(#"{"id":"U1","profile":{"display_name":"Ana"}}"#)]
        let m = j(#"{"text":"Hello <@U1> <#C1|general> <!here> <!date^1|today> <https://example.com/a|open> <http://x|unsafe> *bold* _italic_ ~gone~ &amp; &lt; &gt; [text] `*code*`\n```\n*literal*\n```"}"#)
        XCTAssertEqual(SlackText.message(m, people: p), "Hello @Ana #general here today [open](https://example.com/a) unsafe **bold** _italic_ ~~gone~~ & < > \\[text\\] `*code*`\n```\n*literal*\n```")
        let rich = SlackText.message(j(#"{"blocks":[{"type":"section","text":{"type":"mrkdwn","text":"*Block*"},"fields":[{"type":"plain_text","text":"metadata"}]},{"type":"rich_text","elements":[{"type":"text","text":"rich fallback"}]}],"attachments":[{"fallback":"attachment"},{"text":"second"}],"files":[{"title":"Report","mimetype":"application/pdf","size":42,"permalink":"https://slack.com/file"},{"name":"private","url_private_download":"https://secret.example"}]}"#), people: p)
        XCTAssertTrue(rich.contains("**Block**\nmetadata\nrich fallback")); XCTAssertTrue(rich.contains("attachment\nsecond"))
        XCTAssertTrue(rich.contains("Report (application/pdf, 42 bytes)")); XCTAssertTrue(rich.contains("[Open in browser](https://slack.com/file)"))
        XCTAssertFalse(rich.contains("secret.example")); XCTAssertTrue(rich.contains("open Slack to get it"))
        XCTAssertEqual(SlackText.message(j(#"{"blocks":[{"type":"image"}]}"#), people: p), "[Slack block content]")
        XCTAssertEqual(SlackText.message(j("{}"), people: p), "[Message without text]")
        // Unpaired emphasis stays literal; code is left as it is.
        XCTAssertEqual(SlackText.markdown("*literal `*code*`", people: [:]), "\\*literal `*code*`")
        XCTAssertEqual(SlackText.markdown("~literal <https://example.com/~|open>", people: [:]), "\\~literal [open](https://example.com/~)")
        XCTAssertEqual(SlackText.markdown("*literal\n```*code*```", people: [:]), "\\*literal\n```\n*code*\n```")
        XCTAssertEqual(SlackText.markdown("`*literal* ~literal~`", people: [:]), "`*literal* ~literal~`")
        XCTAssertEqual(SlackText.markdown("*bold `*code*` end*", people: [:]), "**bold `*code*` end**")
        // A line Markdown would take for a block is plain text in Slack.
        XCTAssertEqual(Markdown.parse(SlackText.markdown("# not a heading", people: [:])).first?.kind, .paragraph)
        XCTAssertEqual(Markdown.parse(SlackText.markdown("- not a list", people: [:])).first?.kind, .paragraph)
        XCTAssertEqual(Markdown.parse(SlackText.markdown("1. not a list", people: [:])).first?.kind, .paragraph)
    }

    func testADraftIsSentOnceAndAnUncertainOneWaits() {
        var d = SlackDraft()
        XCTAssertFalse(d.begin())
        d.text = "human reply"
        XCTAssertTrue(d.begin()); XCTAssertFalse(d.begin())
        XCTAssertEqual(d.finish(ok: false, refusal: false, receipt: .null, channel: "C1"), .ambiguous)
        XCTAssertTrue(d.uncertain); XCTAssertFalse(d.sending); XCTAssertEqual(d.text, "human reply"); XCTAssertFalse(d.begin())
        d.recover()
        XCTAssertTrue(d.begin()); XCTAssertEqual(d.finish(ok: false, refusal: true, receipt: .null, channel: "C1"), .refused); XCTAssertFalse(d.uncertain)
        XCTAssertTrue(d.begin())
        XCTAssertEqual(d.finish(ok: true, refusal: false, receipt: j(#"{"channel":"C1","ts":"1712345680.000001"}"#), channel: "C1"), .confirmed)
        XCTAssertEqual(d.text, ""); XCTAssertNil(d.sentText)
        d.text = "again"; XCTAssertTrue(d.begin())
        // A receipt for another channel is not this send's.
        XCTAssertEqual(d.finish(ok: true, refusal: false, receipt: j(#"{"channel":"C2","ts":"1.1"}"#), channel: "C1"), .ambiguous)
        d.recover(); d.text = "again"; XCTAssertTrue(d.begin())
        XCTAssertEqual(d.finish(ok: true, refusal: false, receipt: j(#"{"channel":"C1","ts":"1.1","workspaceChanged":true}"#), channel: "C1"), .workspaceChanged)
        XCTAssertFalse(SlackText.valid("   ")); XCTAssertTrue(SlackText.valid(String(repeating: "a", count: 8000)))
        XCTAssertFalse(SlackText.valid(String(repeating: "😀", count: 4001)))
    }
}
