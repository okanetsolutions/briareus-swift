// The existing Usage destination exposes supported server resources alongside the ledger.
import XCTest
@testable import BriareusMacCore

final class UsageDashboardLogicTests: XCTestCase {
    func testUsageRemainsAvailableWithoutResourceRoutes() {
        XCTAssertEqual(UsageDashboardTab.available { _ in false }, [.usage])
        XCTAssertNil(UsageDashboardTab.usage.serverTab)
    }

    func testResourceTabsUseTheExistingCatalogAndSelection() {
        let tabs = UsageDashboardTab.available { $0 == "server_stats" || $0 == "ssh_monitoring" }
        XCTAssertEqual(tabs, [.usage, .server(.overview), .server(.history), .server(.disks), .server(.sshServers)])
        XCTAssertEqual(tabs.compactMap(\.serverTab), [.overview, .history, .disks, .sshServers])
        XCTAssertEqual(Set(tabs.map(\.id)).count, tabs.count)
    }

    func testSessionsOnlyTokenStillGetsItsResourcesBesideUsage() {
        XCTAssertEqual(UsageDashboardTab.available { $0 == "sessions_stats" }, [.usage, .server(.sessions)])
    }
}
