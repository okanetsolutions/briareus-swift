// The recovery report an interrupted session's conversation reads before resuming.
import XCTest
@testable import BriareusMacCore

final class RecoveryTests: XCTestCase {
    func testReportsSayWhetherAndHowASessionResumes() {
        let r = RecoveryReport(j(#"{"id":"s","status":"interrupted","expectedBranch":"dev-1","branch":"dev-1","head":"0123456789abcdef","changes":" M a.php\n?? b.php","available":true,"canResume":true,"reason":"Resume this checkout","phase":"conversation","fingerprint":"f1"}"#))!
        XCTAssertTrue(r.canResume); XCTAssertEqual(r.shortHead, "01234567"); XCTAssertEqual(r.changeCount, 2)
        XCTAssertEqual(RecoveryReport(j(#"{"canResume":true,"fingerprint":""}"#))?.canResume, false)
        XCTAssertNil(RecoveryReport(j(#"{"canResume":true}"#)))
        XCTAssertEqual(RecoveryReport(j(#"{"fingerprint":"x","changes":"(git status could not list the changes)"}"#))?.changeCount, 0)
        XCTAssertTrue(RecoveryReport.offered(status: "interrupted")); XCTAssertTrue(RecoveryReport.offered(status: "failed"))
        XCTAssertFalse(RecoveryReport.offered(status: "idle"))
    }
}
