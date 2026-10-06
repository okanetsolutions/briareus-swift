// Ported from the Windows client's tests/app_sql_tests.c: the Database tab's mysql --batch output split into cells, and the
// quoting around names and logins.
import XCTest
@testable import BriareusMacCore

final class SQLTests: XCTestCase {
    func testBatchOutputSplitsIntoHeaderAndRows() {
        let t = SQLTable("id\tname\tnote\n1\tAda\tNULL\n2\tGrace\ta\\tb\\nc \\\\ d\n")
        XCTAssertEqual(t.cols, 3)
        XCTAssertEqual(t.rows, 3)
        XCTAssertEqual(t.cell(0, 1), "name")
        XCTAssertEqual(t.cell(1, 2), "NULL")
        XCTAssertEqual(t.cell(2, 1), "Grace")
        XCTAssertEqual(t.cell(2, 2), "a\tb\nc \\ d")
    }

    func testOneColumnKeepsEmptyValuesAndCRLF() {
        let t = SQLTable("Database\r\ninformation_schema\r\n\r\nshop\r\n")
        XCTAssertEqual(t.cols, 1)
        XCTAssertEqual(t.rows, 4)
        XCTAssertEqual(t.cell(1, 0), "information_schema")
        XCTAssertEqual(t.cell(2, 0), "")
        XCTAssertEqual(t.cell(3, 0), "shop")
    }

    func testShortRowsArePaddedAndEmptyOutputHasNoRows() {
        let t = SQLTable("a\tb\tc\n1\n")
        XCTAssertEqual(t.rows, 2)
        XCTAssertEqual(t.cell(1, 0), "1")
        XCTAssertEqual(t.cell(1, 2), "")
        XCTAssertEqual(SQLTable("").rows, 0)
    }

    func testNamesAndLoginsAreQuoted() {
        XCTAssertEqual(sqlIdent("my`table"), "`my``table`")
        XCTAssertEqual(shQuote("it's"), "'it'\"'\"'s'")
        let login = SQLLogin(host: "", port: 0, user: "o'neil", password: "secret")
        let cmd = login.remoteCommand
        XCTAssertTrue(cmd.contains("-h '127.0.0.1' -P 3306 -u 'o'\"'\"'neil'"))
        XCTAssertFalse(cmd.contains("\\"))
        // The password goes in through standard input, never on the command line.
        XCTAssertFalse(cmd.contains("secret"))
        XCTAssertEqual(login.input("SHOW DATABASES;"), "secret\nSHOW DATABASES;\n")
    }

    func testAPasswordWithALineBreakIsRefused() {
        XCTAssertNil(SQLLogin(host: "", port: 0, user: "u", password: "s3cret").problem)
        XCTAssertNotNil(SQLLogin(host: "", port: 0, user: "u", password: "s3cret\nx").problem)
        XCTAssertNotNil(SQLLogin(host: "", port: 0, user: "u", password: "s3cret\r").problem)
    }
}
