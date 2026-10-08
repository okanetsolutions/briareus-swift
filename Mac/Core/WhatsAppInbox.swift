// The operator's WhatsApp inbox through the server's WAHA (core #130): the linked phone and its pairing, the chats newest
// first, a chat's history and messages sent from here. WAHA keeps the history; the app merges what it reads by message id
// and keeps nothing on disk.
import Foundation

/// The linked phone: its WAHA session, how its connection stands, and who it is once paired.
struct WhatsAppAccount: Equatable, Sendable {
    var id: String
    var status: String
    var me: String?

    init?(_ j: JSON) {
        guard let id = j["id"].nonEmpty else { return nil }
        self.id = id
        status = j["status"].string ?? ""
        me = j["me"]["name"].nonEmpty ?? j["me"]["id"].nonEmpty.map(WhatsAppText.phone)
    }
    var working: Bool { status == "WORKING" }
    var pairing: Bool { status == "SCAN_QR_CODE" }
    var statusText: String {
        switch status {
        case "WORKING": return "connected"
        case "SCAN_QR_CODE": return "waiting to be linked"
        case "STARTING": return "starting"
        case "STOPPED": return "stopped"
        case "FAILED": return "failed"
        default: return status.lowercased()
        }
    }
}

struct WhatsAppMessage: Equatable, Sendable {
    var id: String
    var timestamp: Double
    var from: String
    var fromMe: Bool
    var participant: String?
    var text: String
    var hasMedia: Bool
    var mediaName: String?
    var mediaType: String?
    var ack: Int?
    var quoteAuthor: String?
    var quoteText: String?

    init?(_ j: JSON) {
        guard let id = j["id"].nonEmpty, let ts = j["timestamp"].number, ts.isFinite else { return nil }
        self.id = id; timestamp = ts
        from = j["from"].string ?? ""
        fromMe = j["fromMe"].is(true)
        participant = j["participant"].nonEmpty
        text = j["text"].string ?? ""
        hasMedia = j["hasMedia"].is(true)
        mediaName = j["media"]["filename"].nonEmpty
        mediaType = j["media"]["mimetype"].nonEmpty
        ack = j["ack"].int32.map { Int($0) }
        if j["replyTo"].isObject {
            quoteAuthor = j["replyTo"]["participant"].nonEmpty
            quoteText = j["replyTo"]["text"].nonEmpty ?? (j["replyTo"]["hasMedia"].is(true) ? "📎 Attachment" : nil)
        }
    }
    var date: Date { Date(timeIntervalSince1970: timestamp) }
    /// The ticks after a message sent from the phone: one when the server has it, two when delivered, read ones in blue.
    var ticks: String? {
        guard fromMe, let ack else { return nil }
        switch ack {
        case -1: return "!"
        case 0: return "🕓"
        case 1: return "✓"
        default: return "✓✓"
        }
    }
    var read: Bool { (ack ?? 0) >= 3 }
}

/// A chat as the list shows it.
struct WhatsAppChat: Equatable, Sendable {
    var id: String
    var name: String
    var unread: Int
    var last: WhatsAppMessage?

    init?(_ j: JSON) {
        guard let id = j["id"].nonEmpty else { return nil }
        self.id = id
        name = j["name"].nonEmpty ?? WhatsAppText.phone(id)
        unread = j["unreadCount"].int32.map { Int($0) } ?? 0
        last = WhatsAppMessage(j["lastMessage"])
    }
    var isGroup: Bool { id.hasSuffix("@g.us") }
}

/// A chat's messages, oldest first, each once by id; a later read of one replaces it (its ticks move on).
struct WhatsAppMessages: Equatable, Sendable {
    private(set) var list: [WhatsAppMessage] = []
    mutating func merge(_ items: [WhatsAppMessage]) {
        for m in items {
            if let i = list.firstIndex(where: { $0.id == m.id }) { list[i] = m } else { list.append(m) }
        }
        list.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }
}

enum WhatsAppText {
    static let limit = 8000
    /// 1-8000 characters, not only spaces.
    static func valid(_ text: String) -> Bool { text.utf16.count <= limit && text.contains { !$0.isWhitespace } }
    /// A chat id's number: `5491112345678@c.us` → `+5491112345678`.
    static func phone(_ id: String) -> String {
        let parts = id.split(separator: "@", maxSplits: 1)
        let user = parts.first.map(String.init) ?? id
        // Only a person's id (`@c.us`, `@s.whatsapp.net`) is a phone number; a group's is not.
        let person = parts.count < 2 || parts[1] == "c.us" || parts[1] == "s.whatsapp.net"
        return person && !user.isEmpty && user.allSatisfy(\.isNumber) ? "+" + user : user
    }
    /// The QR code's image from `{ mimetype, data }`, decoded; nil unless it is a PNG or JPEG.
    static func qrImage(_ j: JSON) -> Data? {
        guard let type = j["mimetype"].string, type == "image/png" || type == "image/jpeg", let data = j["data"].string else { return nil }
        return Data(base64Encoded: data)
    }
}
