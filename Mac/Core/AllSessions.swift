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

    var sessions: [Session] { didSet { shown = Self.ordered(sessions) } }
    var projects: [Project]
    /// The open sessions, newest pins first, then working ones, then newest created; equal or missing dates use the
    /// session id for stability. Sorted once per list, as every redraw of the lists and their counts reads it.
    private(set) var shown: [Session]

    init(sessions: [Session], projects: [Project]) {
        self.sessions = sessions; self.projects = projects
        shown = Self.ordered(sessions)
    }
    static func == (a: Self, b: Self) -> Bool { a.sessions == b.sessions && a.projects == b.projects }

    /// The open sessions the All list shows; closed ones are left out of the list and its count.
    var count: Int { shown.count }
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

    /// Each date is read once, not once per comparison.
    private static func ordered(_ sessions: [Session]) -> [Session] {
        sessions.filter { !$0.isClosed }
            .map { s in
                (session: s, pinned: s.pinnedAt ?? "", active: s.isActive, created: boardDateEpoch(s.raw["createdAt"].string) ?? 0)
            }
            .sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned > rhs.pinned }
                if lhs.active != rhs.active { return lhs.active }
                return lhs.created == rhs.created ? lhs.session.id < rhs.session.id : lhs.created > rhs.created
            }
            .map(\.session)
    }
}
