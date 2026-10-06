// A session's shared browser (`/sessions/{id}/browser`): the Chromium its agent drives and the app watches and drives too
// (core/browser.c). The pieces with no window in them: the server-sent event stream's parser, the frame's base64, the
// tabs, where a frame is drawn and how a pointer maps back to the page, the keys the server takes, the queue input waits
// in, and typed addresses.
import Foundation

// MARK: - Server-sent events

/// Reads an event stream fed in pieces of any size, as text/event-stream lays it out: lines ending in CR, LF or CRLF,
/// `field: value`, comments starting with a colon, and a blank line ending each event. Each event that completes goes to
/// `emit` with its `event:` name ("message" when it had none) and its `data:` lines joined by newlines.
struct SSEParser {
    /// The longest line or event kept; past it, the event is dropped (a frame is a few hundred kilobytes).
    static let maxEvent = 32 * 1024 * 1024

    private var line: [UInt8] = []
    private var data: [UInt8] = []
    private var event: String?
    private var afterCR = false, hasData = false, overflow = false

    init() {}

    private mutating func resetEvent() {
        data = []; event = nil; hasData = false; overflow = false
    }
    private mutating func endLine(_ emit: (String, String) -> Void) {
        if line.isEmpty {
            if hasData && !overflow { emit(event ?? "message", String(decoding: data, as: UTF8.self)) }
            resetEvent()
            return
        }
        if line[0] == UInt8(ascii: ":") { return }
        let colon = line.firstIndex(of: UInt8(ascii: ":"))
        let name = line[..<(colon ?? line.endIndex)]
        var value = colon.map { line.index(after: $0) } ?? line.endIndex
        if colon != nil, value < line.endIndex, line[value] == UInt8(ascii: " ") { value += 1 }
        let rest = line[value...]
        if name.elementsEqual("data".utf8) {
            if hasData { data.append(UInt8(ascii: "\n")) }
            data.append(contentsOf: rest)
            hasData = true
            if data.count > SSEParser.maxEvent { overflow = true; data = [] }
        } else if name.elementsEqual("event".utf8) {
            event = String(decoding: rest, as: UTF8.self)
        }
        // `id:` and `retry:` are for reconnecting, which the app does on its own terms.
    }

    mutating func feed<C: Collection>(_ bytes: C, emit: (String, String) -> Void) where C.Element == UInt8, C.Index == Int {
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let c = bytes[i]
            // A CR ends a line; an LF straight after it belongs to the same line end.
            if c == 0x0A && afterCR { afterCR = false; i += 1; continue }
            afterCR = c == 0x0D
            if c == 0x0D || c == 0x0A {
                endLine(emit)
                line = []
                i += 1
                continue
            }
            if line.count >= SSEParser.maxEvent { overflow = true; i += 1; continue }
            // Runs of ordinary bytes go in at once: a frame's line is hundreds of kilobytes.
            var end = i + 1
            while end < bytes.endIndex && bytes[end] != 0x0D && bytes[end] != 0x0A { end += 1 }
            line.append(contentsOf: bytes[i..<end])
            i = end
        }
    }
}

/// Standard base64, padding optional; nil for anything else.
func base64Decode(_ text: String?) -> Data? {
    guard var t = text else { return nil }
    while t.hasSuffix("=") { t.removeLast() }
    if t.utf8.count % 4 == 1 { return nil }
    t += String(repeating: "=", count: (4 - t.utf8.count % 4) % 4)
    return Data(base64Encoded: t)
}

// MARK: - State

struct BrowserTab: Equatable, Sendable {
    var id: String
    var url: String
    var title: String

    /// Its title for the strip: the page title, else its address.
    var label: String { !title.isEmpty ? title : !url.isEmpty && url != "about:blank" ? url : "New tab" }
}

struct BrowserState: Equatable, Sendable {
    var on = false
    var running = false
    var tabs: [BrowserTab] = []
    /// The tab in view, or nil.
    var active: String?

    init(on: Bool = false, running: Bool = false) { self.on = on; self.running = running }

    /// Takes `tabs` and `active` from a `tabs` event or a Browser record, and `on` and `running` when the record has them.
    mutating func read(_ record: JSON) {
        guard record.isObject else { return }
        if let b = record["on"].bool { on = b }
        if let b = record["running"].bool { running = b }
        if record["tabs"].isArray {
            tabs = record["tabs"].items.compactMap { t in
                guard let id = t["id"].nonEmpty else { return nil }
                return BrowserTab(id: id, url: t["url"].string ?? "", title: t["title"].string ?? "")
            }
        }
        if record.object?["active"] != nil { active = record["active"].string }
    }
    /// The tab in view, or nil.
    var activeTab: BrowserTab? { active.flatMap { a in tabs.first { $0.id == a } } }

    /// A session record's `browser`: off while it is null or absent; `running` says whether it is up.
    static func sessionOn(_ session: JSON) -> (on: Bool, running: Bool) {
        let b = session["browser"]
        return (b.isObject, b.isObject && b["running"].is(true))
    }
}

// MARK: - Drawing and pointing

struct BrowserRect: Equatable, Sendable {
    var left = 0, top = 0, right = 0, bottom = 0
    var width: Int { right - left }
    var height: Int { bottom - top }
}

/// Where a `frameW` × `frameH` picture goes inside a `viewW` × `viewH` area: as large as fits without stretching, never
/// larger than the picture, centred. An empty rectangle when either has no size.
func browserFit(viewW: Int, viewH: Int, frameW: Int, frameH: Int) -> BrowserRect {
    guard viewW > 0, viewH > 0, frameW > 0, frameH > 0 else { return BrowserRect() }
    var w = viewW, h = Int(Int64(frameH) * Int64(viewW) / Int64(frameW))
    if h > viewH { h = viewH; w = Int(Int64(frameW) * Int64(viewH) / Int64(frameH)) }
    if w > frameW && h > frameH { w = frameW; h = frameH }
    w = max(w, 1); h = max(h, 1)
    let left = (viewW - w) / 2, top = (viewH - h) / 2
    return BrowserRect(left: left, top: top, right: left + w, bottom: top + h)
}

/// The page point under a view point, in the frame's CSS pixels: nil when the point is outside the drawn picture.
func browserPagePoint(drawn: BrowserRect, frameW: Int, frameH: Int, x: Int, y: Int) -> (x: Double, y: Double)? {
    let w = drawn.width, h = drawn.height
    guard w > 0, h > 0, frameW > 0, frameH > 0 else { return nil }
    guard x >= drawn.left, x < drawn.right, y >= drawn.top, y < drawn.bottom else { return nil }
    return ((Double(x - drawn.left) + 0.5) * Double(frameW) / Double(w), (Double(y - drawn.top) + 0.5) * Double(frameH) / Double(h))
}

/// The name the server takes in a `key` input for a Mac key code, or nil for a key it has none for. Letters and digits come
/// back as one lowercase or digit character (from the key's characters, whatever the modifiers), for shortcuts.
func browserKeyName(keyCode: UInt16, characters: String?) -> String? {
    switch keyCode {
    case 36, 76: return "Enter"
    case 48: return "Tab"
    case 51: return "Backspace"
    case 117: return "Delete"
    case 53: return "Escape"
    case 123: return "ArrowLeft"
    case 126: return "ArrowUp"
    case 124: return "ArrowRight"
    case 125: return "ArrowDown"
    case 115: return "Home"
    case 119: return "End"
    case 116: return "PageUp"
    case 121: return "PageDown"
    default: break
    }
    guard let c = characters?.lowercased(), c.count == 1, let s = c.unicodeScalars.first, s.isASCII,
          ("a"..."z").contains(Character(s)) || ("0"..."9").contains(Character(s)) else { return nil }
    return c
}

// MARK: - Input

/// Input waiting to go to `POST …/browser/input`, oldest first, sent one at a time so it arrives in order. Typing is
/// merged into one `type`, a pointer move replaces the move before it and scrolls add up, so a slow connection catches up.
struct BrowserInputs: Sendable {
    private(set) var items: [JSON] = []
    var count: Int { items.count }

    init() {}

    mutating func push(_ input: JSON?) {
        guard let input, input.isObject else { return }
        let type = input["type"].string
        if let last = items.last, let lastType = last["type"].string {
            if type == "type" && lastType == "type" {
                items[items.count - 1]["text"] = .string((last["text"].string ?? "") + (input["text"].string ?? ""))
                return
            }
            if type == "move" && lastType == "move" { items[items.count - 1] = input; return }
            if type == "wheel" && lastType == "wheel" {
                var merged = input
                merged["deltaX"] = JSON((last["deltaX"].number ?? 0) + (input["deltaX"].number ?? 0))
                merged["deltaY"] = JSON((last["deltaY"].number ?? 0) + (input["deltaY"].number ?? 0))
                items[items.count - 1] = merged
                return
            }
        }
        items.append(input)
    }
    /// The oldest input, or nil.
    mutating func pop() -> JSON? {
        if items.isEmpty { return nil }
        return items.removeFirst()
    }
    mutating func removeAll() { items = [] }
}

/// A URL as typed into the address field: https:// added when it has no scheme (http:// for a local address); nil when it
/// is empty or not http(s).
func browserAddress(_ typed: String?) -> String? {
    let t = (typed ?? "").cTrimmed
    if t.isEmpty || t.contains(where: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }) { return nil }
    let folded = t.lowercased()
    if folded == "about:blank" { return "about:blank" }
    let web = folded.hasPrefix("http://") || folded.hasPrefix("https://")
    // Another scheme ("file://", "chrome://") is one before the path; "://" further on is part of the page's address.
    let hostEnd = folded.firstIndex(where: { "/?#".contains($0) }).map { folded.distance(from: folded.startIndex, to: $0) } ?? folded.count
    let other = !web && (folded.range(of: "://").map { folded.distance(from: folded.startIndex, to: $0.lowerBound) < hostEnd } ?? false)
    // A local address has no certificate to show for itself: it is asked for over plain HTTP.
    let local = folded.hasPrefix("localhost") || folded.hasPrefix("127.0.0.1") || folded.hasPrefix("[::1]")
    if other { return nil }
    if web {
        let host = t[t.range(of: "://")!.upperBound...]
        return !host.isEmpty && !host.hasPrefix("/") ? t : nil
    }
    // "mailto:", "javascript:" and the like: a scheme without slashes is not an address. Only a colon before the path
    // counts: one after it ("/wiki/Special:Search") is part of the page.
    let head = t.prefix(hostEnd)
    if let colon = head.firstIndex(of: ":"), !local {
        let after = t[t.index(after: colon)...]
        let digits = after.prefix { $0.isASCII && $0.isNumber }
        let next = after.dropFirst(digits.count).first
        if digits.isEmpty || (next != nil && !"/?#".contains(next!)) { return nil }
    }
    return (local ? "http://" : "https://") + t
}
