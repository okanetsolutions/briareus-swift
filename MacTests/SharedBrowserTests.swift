// SharedBrowser.swift (core_browser_tests.c): the shared browser's event stream parser, base64, tabs, frame fitting,
// pointer mapping, keys, input queue and typed addresses.
import XCTest
@testable import BriareusMacCore

final class SharedBrowserTests: XCTestCase {
    // MARK: Server-sent events

    private func feedAll(_ text: String, piece: Int) -> [(event: String, data: String)] {
        var seen: [(event: String, data: String)] = []
        var p = SSEParser()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            p.feed(Array(bytes[i..<min(i + piece, bytes.count)])) { seen.append(($0, $1)) }
            i += piece
        }
        return seen
    }

    func testEventsCarryTheirNameAndData() {
        let s = feedAll("event: tabs\ndata: {\"tabs\":[]}\n\nevent: frame\ndata: {\"data\":\"QQ==\"}\n\n", piece: 1000)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.first?.event, "tabs"); XCTAssertEqual(s.first?.data, "{\"tabs\":[]}")
        XCTAssertEqual(s.last?.event, "frame"); XCTAssertEqual(s.last?.data, "{\"data\":\"QQ==\"}")
    }
    func testEventsSurviveBeingFedAByteAtATimeWithAnyLineEnd() {
        for text in ["event: a\r\ndata: 1\r\n\r\nevent: b\r\ndata: 2\r\n\r\n", "event: a\rdata: 1\r\revent: b\rdata: 2\r\r",
                     "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n"] {
            for piece in 1...3 {
                let s = feedAll(text, piece: piece)
                XCTAssertEqual(s.map(\.event), ["a", "b"])
                XCTAssertEqual(s.map(\.data), ["1", "2"])
            }
        }
    }
    func testPingsAndUnknownFieldsAreSkippedAndDataLinesJoin() {
        let s = feedAll(": ping\n\nid: 4\nretry: 100\ndata:first\ndata: second\n\ndata\n\n", piece: 7)
        XCTAssertEqual(s.map(\.event), ["message", "message"])
        // `data` with no colon is an empty line of data.
        XCTAssertEqual(s.map(\.data), ["first\nsecond", ""])
    }
    func testAnEventWithoutDataOrWithoutItsBlankLineIsNotEmitted() {
        XCTAssertEqual(feedAll("event: closed\n\nevent: frame\ndata: {}", piece: 4).count, 0)
        // The name does not leak into the next event.
        let s = feedAll("event: tabs\n\ndata: x\n\n", piece: 100)
        XCTAssertEqual(s.map(\.event), ["message"])
    }
    func testALongFrameLineArrivesWhole() {
        let n = 300_000
        let body = String((0..<n).map { Character(UnicodeScalar(UInt8(65 + $0 % 26))) })
        let s = feedAll("event: frame\ndata: " + body + "\n\n", piece: 16384)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.data.utf8.count, n)
        XCTAssertEqual(s.first?.data, body)
    }

    func testBase64DecodesWithAndWithoutPadding() {
        XCTAssertEqual(base64Decode("aGVsbG8="), Data("hello".utf8))
        XCTAssertEqual(base64Decode("aGVsbG8"), Data("hello".utf8))
        XCTAssertEqual(base64Decode("/9j/"), Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(base64Decode(""), Data())
        XCTAssertNil(base64Decode("aGV*bG8="))
        XCTAssertNil(base64Decode("a"))
        XCTAssertNil(base64Decode(nil))
    }

    // MARK: State

    func testTabsAndTheActiveOneAreReadFromAnEvent() {
        var s = BrowserState()
        s.read(JSON.parse(Data("{\"tabs\":[{\"id\":\"t1\",\"url\":\"https://a.test/\",\"title\":\"A\"},{\"id\":\"\"},{\"id\":\"t2\",\"url\":\"about:blank\"}],\"active\":\"t2\"}".utf8))!)
        XCTAssertEqual(s.tabs.map(\.id), ["t1", "t2"])
        XCTAssertEqual(s.tabs.map(\.title), ["A", ""])
        XCTAssertEqual(s.activeTab?.url, "about:blank")
        XCTAssertFalse(s.on); XCTAssertFalse(s.running)
        // A record says whether it is on and up; one without tabs keeps them.
        s.read(JSON.parse(Data("{\"on\":true,\"running\":true,\"active\":null}".utf8))!)
        XCTAssertTrue(s.on); XCTAssertTrue(s.running)
        XCTAssertEqual(s.tabs.count, 2)
        XCTAssertNil(s.active); XCTAssertNil(s.activeTab)
    }
    func testATabIsLabelledByItsTitleThenItsAddress() {
        XCTAssertEqual(BrowserTab(id: "a", url: "https://x.test/", title: "X").label, "X")
        XCTAssertEqual(BrowserTab(id: "a", url: "https://x.test/", title: "").label, "https://x.test/")
        XCTAssertEqual(BrowserTab(id: "a", url: "about:blank", title: "").label, "New tab")
    }
    func testASessionSaysWhetherItsBrowserIsOnAndUp() {
        func on(_ text: String) -> (Bool, Bool) { let r = BrowserState.sessionOn(JSON.parse(Data(text.utf8))!); return (r.on, r.running) }
        XCTAssertTrue(on("{\"browser\":null}") == (false, false))
        XCTAssertTrue(on("{}") == (false, false))
        XCTAssertTrue(on("{\"browser\":{\"running\":false}}") == (true, false))
        XCTAssertTrue(on("{\"browser\":{\"running\":true}}") == (true, true))
    }

    // MARK: Drawing and pointing

    func testAFrameFitsItsAreaWithoutStretchingOrGrowing() {
        XCTAssertEqual(browserFit(viewW: 1000, viewH: 500, frameW: 1280, frameH: 720), BrowserRect(left: 56, top: 0, right: 944, bottom: 500))
        let r = browserFit(viewW: 1000, viewH: 1000, frameW: 1280, frameH: 720)
        XCTAssertEqual(r.width, 1000); XCTAssertEqual(r.height, 562); XCTAssertEqual(r.top, 219)
        // A larger area shows it at its own size.
        XCTAssertEqual(browserFit(viewW: 3000, viewH: 2000, frameW: 1280, frameH: 720), BrowserRect(left: 860, top: 640, right: 2140, bottom: 1360))
        XCTAssertEqual(browserFit(viewW: 0, viewH: 500, frameW: 1280, frameH: 720), BrowserRect())
        XCTAssertEqual(browserFit(viewW: 500, viewH: 500, frameW: 0, frameH: 720), BrowserRect())
    }
    func testAViewPointMapsBackToThePage() {
        let drawn = BrowserRect(left: 100, top: 50, right: 740, bottom: 410)   // 640 × 360 for a 1280 × 720 page
        var p = browserPagePoint(drawn: drawn, frameW: 1280, frameH: 720, x: 100, y: 50)
        XCTAssertTrue(p != nil && p!.x >= 0 && p!.x < 2 && p!.y >= 0 && p!.y < 2)
        p = browserPagePoint(drawn: drawn, frameW: 1280, frameH: 720, x: 420, y: 230)
        XCTAssertTrue(p != nil && p!.x > 640 && p!.x < 642 && p!.y > 360 && p!.y < 362)
        p = browserPagePoint(drawn: drawn, frameW: 1280, frameH: 720, x: 739, y: 409)
        XCTAssertTrue(p != nil && p!.x < 1280 && p!.y < 720)
        XCTAssertNil(browserPagePoint(drawn: drawn, frameW: 1280, frameH: 720, x: 99, y: 60))
        XCTAssertNil(browserPagePoint(drawn: drawn, frameW: 1280, frameH: 720, x: 740, y: 60))
        XCTAssertNil(browserPagePoint(drawn: drawn, frameW: 1280, frameH: 720, x: 200, y: 410))
        XCTAssertNil(browserPagePoint(drawn: drawn, frameW: 0, frameH: 720, x: 200, y: 60))
    }
    func testKeysAreNamedAsTheServerTakesThem() {
        XCTAssertEqual(browserKeyName(keyCode: 36, characters: "\r"), "Enter")
        XCTAssertEqual(browserKeyName(keyCode: 51, characters: nil), "Backspace")
        XCTAssertEqual(browserKeyName(keyCode: 116, characters: nil), "PageUp")
        XCTAssertEqual(browserKeyName(keyCode: 125, characters: nil), "ArrowDown")
        XCTAssertEqual(browserKeyName(keyCode: 0, characters: "a"), "a")
        XCTAssertEqual(browserKeyName(keyCode: 6, characters: "Z"), "z")
        XCTAssertEqual(browserKeyName(keyCode: 26, characters: "7"), "7")
        XCTAssertNil(browserKeyName(keyCode: 96, characters: nil))   // F5
        XCTAssertNil(browserKeyName(keyCode: 56, characters: ""))    // shift
        XCTAssertNil(browserKeyName(keyCode: 41, characters: ";"))
    }

    // MARK: Input

    private func input(_ text: String) -> JSON { JSON.parse(Data(text.utf8))! }
    func testTypingMergesMovesReplaceEachOtherAndScrollsAddUp() {
        var q = BrowserInputs()
        q.push(input("{\"type\":\"type\",\"text\":\"he\"}"))
        q.push(input("{\"type\":\"type\",\"text\":\"llo\"}"))
        q.push(input("{\"type\":\"down\",\"x\":1,\"y\":1}"))
        q.push(input("{\"type\":\"move\",\"x\":2,\"y\":2}"))
        q.push(input("{\"type\":\"move\",\"x\":3,\"y\":3}"))
        q.push(input("{\"type\":\"up\",\"x\":3,\"y\":3}"))
        q.push(input("{\"type\":\"key\",\"key\":\"Enter\"}"))
        q.push(input("{\"type\":\"key\",\"key\":\"Enter\"}"))
        q.push(nil)
        XCTAssertEqual(q.count, 6)
        XCTAssertEqual(q.pop()?["text"].string, "hello")
        XCTAssertEqual(q.pop()?["type"].string, "down")
        XCTAssertEqual(q.pop()?["x"].int, 3)
        XCTAssertEqual(q.pop()?["type"].string, "up")
        XCTAssertEqual(q.pop()?["key"].string, "Enter")
        XCTAssertEqual(q.pop()?["key"].string, "Enter")
        XCTAssertNil(q.pop())
        q.push(input("{\"type\":\"wheel\",\"x\":5,\"y\":5,\"deltaY\":100}"))
        q.push(input("{\"type\":\"wheel\",\"x\":6,\"y\":6,\"deltaY\":100,\"deltaX\":-20}"))
        XCTAssertEqual(q.count, 1)
        let j = q.pop()
        XCTAssertEqual(j?["deltaY"].int, 200); XCTAssertEqual(j?["deltaX"].int, -20); XCTAssertEqual(j?["x"].int, 6)
        q.push(input("{\"type\":\"type\",\"text\":\"x\"}"))
        q.removeAll()
        XCTAssertEqual(q.count, 0)
    }
    func testTypedAddressesBecomeWebURLs() {
        XCTAssertEqual(browserAddress("example.com"), "https://example.com")
        XCTAssertEqual(browserAddress("  https://Example.com/a?b=1  "), "https://Example.com/a?b=1")
        XCTAssertEqual(browserAddress("http://site.test"), "http://site.test")
        XCTAssertEqual(browserAddress("example.com:8443/x"), "https://example.com:8443/x")
        XCTAssertEqual(browserAddress("localhost:3000/login"), "http://localhost:3000/login")
        XCTAssertEqual(browserAddress("127.0.0.1"), "http://127.0.0.1")
        XCTAssertEqual(browserAddress("en.wikipedia.org/wiki/Special:Search"), "https://en.wikipedia.org/wiki/Special:Search")
        XCTAssertEqual(browserAddress("site.test?next=a:b#x:y"), "https://site.test?next=a:b#x:y")
        XCTAssertEqual(browserAddress("site.test/go?to=https://other.test"), "https://site.test/go?to=https://other.test")
        XCTAssertEqual(browserAddress("About:Blank"), "about:blank")
        for refused in ["", "   ", nil, "file:///C:/x", "chrome://settings", "javascript:alert(1)", "mailto:a@b.c", "two words", "https://"] {
            XCTAssertNil(browserAddress(refused), refused ?? "nil")
        }
    }
}
