// Resource tabs belong to the Usage dashboard as well as its existing usage ledger.
import Foundation

enum UsageDashboardTab: Hashable, Identifiable, Sendable {
    case usage
    case server(ServerDashboardTab)

    var id: String {
        switch self {
        case .usage: return "usage"
        case .server(let tab): return "server-\(tab.id)"
        }
    }
    var title: String {
        switch self {
        case .usage: return "Usage"
        case .server(.overview): return "Server"
        case .server(let tab): return tab.title
        }
    }
    var serverTab: ServerDashboardTab? {
        if case .server(let tab) = self { return tab }
        return nil
    }
    /// A catalog change keeps a supported panel, otherwise returns to the ledger.
    func resolved(in tabs: [Self]) -> Self {
        tabs.contains(self) ? self : .usage
    }

    static func available(supports: (String) -> Bool) -> [Self] {
        [.usage] + ServerDashboardTab.available(supports: supports).map(Self.server)
    }
}
