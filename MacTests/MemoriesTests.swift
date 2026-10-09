import XCTest
@testable import BriareusMacCore

final class MemoriesTests: XCTestCase {
    func testTheHealthReportLaysItsFlagsOverTheList() {
        let list = j(#"{"memories":[{"id":2,"repo":"o/r","name":"zeta","type":"feedback","description":"d","body":"b","jobId":null,"updatedAt":"2026-10-08T10:00:00Z"},{"id":1,"repo":"o/r","name":"alpha","body":"x"}]}"#)
        let health = j(#"{"memories":[{"id":1,"name":"alpha","needsVerification":true,"revision":"r1"},{"id":3,"name":"old","archived":true,"revision":"r3"}],"duplicates":[{"ids":[1,2],"similarity":0.91},{"ids":[1]}]}"#)
        let m = MemoryLogic.merge(list: list, health: health)
        XCTAssertEqual(m.map(\.name), ["alpha", "zeta", "old"])
        XCTAssertTrue(m[0].needsVerification); XCTAssertEqual(m[0].revision, "r1"); XCTAssertEqual(m[0].type, "project")
        XCTAssertTrue(m[2].archived); XCTAssertNil(m[1].jobID); XCTAssertNotNil(m[1].updatedAt)
        XCTAssertEqual(MemoryLogic.duplicates(health), [MemoryDuplicate(ids: [1, 2], similarity: 0.91)])
        XCTAssertEqual(MemoryLogic.merge(list: list, health: nil).count, 2)
        XCTAssertTrue(MemoryLogic.validName("deploy-notes_2")); XCTAssertFalse(MemoryLogic.validName("a b")); XCTAssertFalse(MemoryLogic.validName(""))
        XCTAssertEqual(Memory.typeLabel("user"), "About you")
    }

    func testANewerVersionIsToldApartByItsEditableFieldsOnly() {
        let a = Memory(j(#"{"id":1,"name":"alpha","body":"old"}"#))!
        var flagged = a; flagged.revision = "r2"; flagged.needsVerification = true
        XCTAssertTrue(a.sameText(flagged))
        var rewritten = a; rewritten.body = "new"
        XCTAssertFalse(a.sameText(rewritten))
    }
}
