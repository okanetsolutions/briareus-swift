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

    func testErrorsBelongToTheSelectedResource() {
        for tab in [ServerDashboardTab.overview, .history, .disks] {
            XCTAssertEqual(tab.error(server: "server-failed", sessions: "sessions-failed"), "server-failed")
            XCTAssertNil(tab.error(server: nil, sessions: "sessions-failed"))
        }
        XCTAssertEqual(ServerDashboardTab.sessions.error(server: "server-failed", sessions: "sessions-failed"), "sessions-failed")
        XCTAssertNil(ServerDashboardTab.sessions.error(server: "server-failed", sessions: nil))
    }

    func testPollingUsesTheSelectedResourcesSamplingInterval() {
        let server = HostStats(["intervalMs": 12000])
        let sessions = HostStats(["intervalMs": 3000])
        for tab in [ServerDashboardTab.overview, .history, .disks] {
            XCTAssertEqual(tab.pollSeconds(server: server, sessions: sessions), 12)
            XCTAssertEqual(tab.pollSeconds(server: nil, sessions: sessions), 5)
        }
        XCTAssertEqual(ServerDashboardTab.sessions.pollSeconds(server: server, sessions: sessions), 3)
        XCTAssertEqual(ServerDashboardTab.sessions.pollSeconds(server: server, sessions: nil), 5)
    }

    func testTabsFollowTheTokenCatalog() {
        XCTAssertEqual(ServerDashboardTab.available { _ in false }, [])
        XCTAssertEqual(ServerDashboardTab.available { $0 == "server_stats" }, [.overview, .history, .disks])
        XCTAssertEqual(ServerDashboardTab.available { $0 == "sessions_stats" }, [.sessions])
        XCTAssertEqual(ServerDashboardTab.available { $0 == "ssh_monitoring" }, [.sshServers])
        XCTAssertEqual(ServerDashboardTab.available { _ in true }, ServerDashboardTab.allCases)
    }
}
