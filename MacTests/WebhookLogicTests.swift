// The ⚡ Webhook form both apps draw: the caps open on the record's values or the server's defaults, and Save sends the
// switches with whole-number caps in range, where Turns in a row takes 0 for no limit.
import XCTest
@testable import BriareusMacCore

final class WebhookLogicTests: XCTestCase {
    private let switches: [WebhookToggle: Bool] = [.armed: true, .instructions: false, .sshUnattended: true]

    func testCapsOpenOnTheRecordOrTheDefaults() {
        let hook: JSON = ["perHour": 120, "maxTurns": 0]
        XCTAssertEqual(WebhookField.perHour.text(hook), "120")
        XCTAssertEqual(WebhookField.maxTurns.text(hook), "0")
        XCTAssertEqual(WebhookField.perHour.text([:]), String(WebhookField.perHour.fallback))
        XCTAssertEqual(WebhookField.maxTurns.text([:]), String(WebhookField.maxTurns.fallback))
    }

    func testSaveSendsSwitchesAndCapsWithZeroTurnsUnlimited() {
        let save = webhookSave(switches: switches, caps: [.perHour: " 30 ", .maxTurns: "0"])
        XCTAssertEqual(save, .body(["armed": true, "instructions": false, "sshUnattended": true, "perHour": 30, "maxTurns": 0]))
        XCTAssertEqual(webhookSave(switches: [:], caps: [.perHour: "600", .maxTurns: "1000"]),
                       .body(["armed": false, "instructions": false, "sshUnattended": false, "perHour": 600, "maxTurns": 1000]))
    }

    func testSaveNamesTheFirstCapOutOfRange() {
        XCTAssertEqual(webhookSave(switches: switches, caps: [.perHour: "0", .maxTurns: "5"]), .invalid(.perHour))
        XCTAssertEqual(webhookSave(switches: switches, caps: [.perHour: "601", .maxTurns: "5"]), .invalid(.perHour))
        XCTAssertEqual(webhookSave(switches: switches, caps: [.perHour: "30", .maxTurns: "1001"]), .invalid(.maxTurns))
        XCTAssertEqual(webhookSave(switches: switches, caps: [.perHour: "30", .maxTurns: ""]), .invalid(.maxTurns))
        XCTAssertEqual(webhookSave(switches: switches, caps: [.perHour: "30"]), .invalid(.maxTurns))
    }
}
