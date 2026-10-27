// The cross-project conversation list: project identity, search, closed filtering and a stable working-first order.
import Foundation

struct AllSessions: Equatable, Sendable {
    enum EmptyState: Equatable, Sendable {
        case noSessions, noMatches

        var title: String {
            switch self {
            case .noSessions: return "No sessions yet"
            case .noMatches: return "No matching sessions"
            }
        }
    }

    static let unavailableMessage = "Sessions are unavailable on this server or for this device."

    var sessions: [Session]
    var projects: [Project]

    var count: Int { sessions.count }
    var busy: Bool { sessions.contains(where: \.isActive) }
    /// Why a filtered list has no rows: nothing exists, or the current filters hid it.
    var emptyState: EmptyState { sessions.isEmpty ? .noSessions : .noMatches }

    /// Counts are complete after a successful projects read and a valid session cache for every project, including empty lists.
    func cacheIsLoaded(projectsLoaded: Bool, cachedRepos: Set<String>) -> Bool {
        projectsLoaded && projects.allSatisfy { cachedRepos.contains($0.repo) }
    }

    /// The project's display name, falling back to the repository when it is absent from the project list.
    func projectTitle(for session: Session) -> String {
        projects.first { $0.repo == session.repo }?.title ?? session.repo ?? ""
    }

    /// Working conversations first, then newest created; equal or missing dates use the session id for stability.
    func shown(search: String, showClosed: Bool) -> [Session] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            (showClosed || !session.isClosed) && (needle.isEmpty ||
                [session.displayTitle, session.repo ?? "", projectTitle(for: session)]
                    .contains { $0.localizedCaseInsensitiveContains(needle) })
        }.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let left = boardDateEpoch(lhs.raw["createdAt"].string) ?? 0
            let right = boardDateEpoch(rhs.raw["createdAt"].string) ?? 0
            return left == right ? lhs.id < rhs.id : left > right
        }
    }
}
