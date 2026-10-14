// The errands a device may start, the one a pull request's state suggests, and the one that removes what was written.
import XCTest
@testable import BriareusMacCore

final class ErrandLogicTests: XCTestCase {
    private func pull(_ text: String) -> PullSummary { PullSummary(j(text))! }

    func testReadOnlyTokenStartsNothing() {
        XCTAssertEqual(BoardAction.startable(catalog: .null, pull: nil, failedChecks: 0, canManage: false, supports: { _ in true }), [])
    }

    func testKeepsOnlyRoutesTheServerListsInOfferedOrder() {
        let offered = BoardAction.offered(catalog: .null, pull: nil, failedChecks: 0)
        let allowed = Set(offered.prefix(2).map(\.operation))
        let startable = BoardAction.startable(catalog: .null, pull: nil, failedChecks: 0, canManage: true, supports: { allowed.contains($0) })
        XCTAssertEqual(startable, offered.filter { allowed.contains($0.operation) })
        XCTAssertFalse(startable.isEmpty)
    }

    func testSuggestedFollowsThePullsRecommendation() {
        let p = pull(#"{"number":4,"title":"t","recommended":"fix-checks"}"#)
        let offered = BoardAction.offered(catalog: .null, pull: nil, failedChecks: 1)
        XCTAssertEqual(offered.filter { $0.isSuggested(for: p) }.map(\.id), ["fix-checks"])
        XCTAssertTrue(offered.allSatisfy { !$0.isSuggested(for: nil) })
    }

    func testOnlyDeletingCommentsIsDestructive() {
        let offered = BoardAction.offered(catalog: .null, pull: nil, failedChecks: 0)
        XCTAssertEqual(offered.filter(\.isDestructive).map(\.id), ["delete-self-comments"])
    }
}
