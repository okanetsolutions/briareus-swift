// The WAHA inbox's objects: accounts and their pairing, chats, messages merged by id, ticks and quotes.
import XCTest
@testable import BriareusMacCore

final class WhatsAppInboxTests: XCTestCase {
    func testAccountsChatsAndMessagesRead() {
        let a = WhatsAppAccount(j(#"{"id":"default","status":"WORKING","me":{"id":"5491112345678@c.us","name":""}}"#))!
        XCTAssertTrue(a.working); XCTAssertEqual(a.me, "+5491112345678"); XCTAssertEqual(a.statusText, "connected")
        XCTAssertTrue(WhatsAppAccount(j(#"{"id":"default","status":"SCAN_QR_CODE","me":null}"#))!.pairing)
        XCTAssertNil(WhatsAppAccount(j("{}")))
        let c = WhatsAppChat(j(#"{"id":"120363@g.us","name":"","unreadCount":null,"lastMessage":{"id":"m1","timestamp":1791400000,"fromMe":true,"text":"hola","ack":3}}"#))!
        XCTAssertTrue(c.isGroup); XCTAssertEqual(c.name, "120363"); XCTAssertEqual(c.unread, 0)
        XCTAssertEqual(c.last?.ticks, "✓✓"); XCTAssertTrue(c.last!.read)
        let m = WhatsAppMessage(j(#"{"id":"m2","timestamp":1791400001,"from":"549@c.us","fromMe":false,"participant":"549@c.us","text":"","hasMedia":true,"media":{"mimetype":"image/jpeg","filename":"photo.jpg"},"ack":null,"replyTo":{"id":"x","participant":"me","text":"","hasMedia":true}}"#))!
        XCTAssertNil(m.ticks); XCTAssertEqual(m.mediaName, "photo.jpg"); XCTAssertEqual(m.quoteText, "📎 Attachment")
        XCTAssertNil(WhatsAppMessage(j(#"{"id":"m3"}"#)))
    }

    func testMessagesMergeByIdOldestFirst() {
        var list = WhatsAppMessages()
        let older = WhatsAppMessage(j(#"{"id":"a","timestamp":10,"fromMe":true,"ack":1}"#))!
        let newer = WhatsAppMessage(j(#"{"id":"b","timestamp":20}"#))!
        list.merge([newer, older])
        XCTAssertEqual(list.list.map(\.id), ["a", "b"])
        list.merge([WhatsAppMessage(j(#"{"id":"a","timestamp":10,"fromMe":true,"ack":3}"#))!])
        XCTAssertEqual(list.list.count, 2); XCTAssertEqual(list.list[0].ack, 3)
        XCTAssertEqual(WhatsAppText.phone("123@c.us"), "+123"); XCTAssertEqual(WhatsAppText.phone("abc@lid"), "abc")
        XCTAssertFalse(WhatsAppText.valid(" \n")); XCTAssertTrue(WhatsAppText.valid("ok"))
        XCTAssertNotNil(WhatsAppText.qrImage(j(#"{"mimetype":"image/png","data":"iVBORw0KGgo="}"#)))
        XCTAssertNil(WhatsAppText.qrImage(j(#"{"mimetype":"text/html","data":"PGI+"}"#)))
    }
}
