// A settings form saved as one record: which operation it sends, the id a save carries, how the answer fills it again, and
// what leaving it unsaved says.
import XCTest
@testable import BriareusMacCore

final class SettingsRecordFormTests: XCTestCase {
    func testNewRecordIsCreatedWithoutAnID() {
        var form = ForgeAccountFormState(row: [:])
        form.texts[.organization] = "acme"
        form.texts[.token] = "secret"
        XCTAssertTrue(form.isNew)
        XCTAssertEqual(form.saveOperation, ForgeAccountFormState.record.create)
        if case .success(let body) = form.saveRequest() { XCTAssertTrue(body["id"].isNull) }
    }

    func testExistingRecordIsUpdatedWithItsID() {
        let form = ForgeAccountFormState(row: j(#"{"id":7,"label":"Acme","organization":"acme","hasToken":true}"#))
        XCTAssertEqual(form.saveOperation, ForgeAccountFormState.record.update)
        guard case .success(let body) = form.saveRequest() else { return XCTFail("refused") }
        XCTAssertEqual(body["id"].int32, 7)
    }

    func testRefusalPassesThrough() {
        XCTAssertEqual(try? ForgeAccountFormState(row: [:]).saveRequest().get(), nil)
    }

    func testAnswerFillsTheFormOrIsRefused() {
        var form = ForgeAccountFormState(row: [:])
        XCTAssertNil(form.saved(j(#"{"other":{}}"#)))
        XCTAssertTrue(form.isNew)
        let row = form.saved(j(#"{"account":{"id":9,"label":"Acme","organization":"acme"}}"#))
        XCTAssertEqual(row?["id"].int32, 9)
        XCTAssertFalse(form.isNew)
        XCTAssertEqual(form.text(.organization), "acme")
    }

    func testIntAndDoubleIDsBothCount() {
        XCTAssertFalse(ProjectFormState(row: j(#"{"id":3,"repo":"o/r"}"#)).isNew)
        XCTAssertFalse(SSHServerFormState(row: j(#"{"id":3,"host":"h"}"#)).isNew)
    }

    func testDiscardNamesTheRecord() {
        XCTAssertNotEqual(ForgeAccountFormState(row: [:]).discardMessage,
                          ForgeAccountFormState(row: j(#"{"id":1}"#)).discardMessage)
        XCTAssertTrue(ForgeAccountFormState(row: j(#"{"id":1,"label":"Acme"}"#)).discardMessage.contains("Acme"))
    }

    func testEveryKindNamesDistinctOperations() {
        let records = [ProjectFormState.record, ProviderFormState.record, DBServerFormState.record, SSHServerFormState.record,
                       ForgeAccountFormState.record, SlackWorkspaceFormState.record]
        let operations = records.flatMap { [$0.create, $0.update, $0.delete] }
        XCTAssertEqual(Set(operations).count, operations.count)
    }
}
