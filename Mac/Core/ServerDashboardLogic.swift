// The Server page's tabs and the reads each visible panel needs, shared by both apps.
import Foundation

enum ServerDashboardTab: String, CaseIterable, Identifiable, Sendable {
    case overview, history, disks, sessions, sshServers

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .history: return "History"
        case .disks: return "Disks"
        case .sessions: return "Sessions"
        case .sshServers: return "SSH servers"
        }
    }

    /// SSH telemetry has its own model and slower sampling interval.
    var operation: String? {
        switch self {
        case .overview, .history, .disks: return "server_stats"
        case .sessions: return "sessions_stats"
        case .sshServers: return nil
        }
    }

    static func available(supports: (String) -> Bool) -> [Self] {
        allCases.filter { tab in
            supports(tab.operation ?? "ssh_monitoring")
        }
    }
}
