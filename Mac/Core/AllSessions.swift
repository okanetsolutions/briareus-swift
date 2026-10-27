// The cross-project conversation list: project identity, search, closed filtering and a stable working-first order.
import Foundation

struct AllSessions: Equatable, Sendable {
    enum EmptyState: Equatable, Sendable {
        case noSessions, allClosed

        var title: String {
            switch self {
            case .noSessions: return "No sessions yet"
            case .allClosed: return "No open sessions"
            }
        }
    }

    static let unavailableMessage = "Sessions are unavailable on this server or for this device."

    var sessions: [Session]
    var projects: [Project]

    /// The open sessions the All list shows; closed ones are left out of the list and its count.
    var count: Int { sessions.filter { !$0.isClosed }.count }
    var busy: Bool { sessions.contains(where: \.isActive) }
    /// Why the list has no rows: nothing exists, or every session is closed.
    var emptyState: EmptyState { sessions.isEmpty ? .noSessions : .allClosed }

    /// Counts are complete after a successful projects read and a valid session cache for every project, including empty lists.
    func cacheIsLoaded(projectsLoaded: Bool, cachedRepos: Set<String>) -> Bool {
        projectsLoaded && projects.allSatisfy { cachedRepos.contains($0.repo) }
    }

    /// The project's display name, falling back to the repository when it is absent from the project list.
    func projectTitle(for session: Session) -> String {
        projects.first { $0.repo == session.repo }?.title ?? session.repo ?? ""
    }

    /// The open sessions, working ones first, then newest created; equal or missing dates use the session id for stability.
    var shown: [Session] {
        sessions.filter { !$0.isClosed }.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let left = boardDateEpoch(lhs.raw["createdAt"].string) ?? 0
            let right = boardDateEpoch(rhs.raw["createdAt"].string) ?? 0
            return left == right ? lhs.id < rhs.id : left > right
        }
    }
}
