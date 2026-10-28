// The dashboard only offers supported panels and reads the resource shown by the selected tab.
import XCTest
@testable import BriareusMacCore

final class ServerDashboardLogicTests: XCTestCase {
    func testTabReadsAreIndependent() {
        XCTAssertEqual(ServerDashboardTab.overview.operation, "server_stats")
        XCTAssertEqual(ServerDashboardTab.history.operation, "server_stats")
        XCTAssertEqual(ServerDashboardTab.disks.operation, "server_stats")
        XCTAssertEqual(ServerDashboardTab.sessions.operation, "sessions_stats")
        // Remote monitoring owns its lifecycle and does not poll the Briareus server's stats.
        XCTAssertNil(ServerDashboardTab.sshServers.operation)
    }

    func testUnavailableSelectionFallsBackToAnOfferedTab() {
        let offered: [ServerDashboardTab] = [.sessions, .sshServers]
        XCTAssertEqual(ServerDashboardTab.sshServers.resolved(in: offered), .sshServers)
        XCTAssertEqual(ServerDashboardTab.overview.resolved(in: offered), .sessions)
        XCTAssertNil(ServerDashboardTab.overview.resolved(in: []))
    }

    func testTabsFollowTheTokenCatalog() {
        XCTAssertEqual(ServerDashboardTab.available { _ in false }, [])
        XCTAssertEqual(ServerDashboardTab.available { $0 == "server_stats" }, [.overview, .history, .disks])
        XCTAssertEqual(ServerDashboardTab.available { $0 == "sessions_stats" }, [.sessions])
        XCTAssertEqual(ServerDashboardTab.available { $0 == "ssh_monitoring" }, [.sshServers])
        XCTAssertEqual(ServerDashboardTab.available { _ in true }, ServerDashboardTab.allCases)
    }
}
