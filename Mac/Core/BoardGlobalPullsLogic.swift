// The board across the device's projects: its lists, regular board filters and partial reads shared by both apps.
import Foundation

/// Background reads keep cached board rows in place; initial loads and user refreshes show progress.
func boardShowsLoading(loaded: Bool, refreshing: Bool) -> Bool { !loaded || refreshing }

/// The tabs the board across every project offers: a project board's lists that make sense without one repository.
enum GlobalBoardTab: Hashable, CaseIterable, Sendable {
    case pulls, issues, review

    var filterKinds: [FilterKind] {
        switch self {
        case .pulls: return [.author, .reviewer, .label]
        case .issues: return [.author, .assignee, .label]
        case .review: return []
        }
    }
    var loadingText: String { self == .issues ? "Loading issues…" : "Loading pull requests…" }
    /// The symbol an empty tab shows, the one the project board's rows use.
    var symbol: String { self == .issues ? "smallcircle.filled.circle" : "arrow.triangle.pull" }
}

/// The Review List tab's label on the Mac's boards, its count once the board is read.
func boardReviewTabLabel(count: Int?) -> String { count.map { "✓ Review List \($0)" } ?? "✓ Review List" }

/// The rows each tab of the board across every project lists.
struct GlobalBoardRows: Equatable, Sendable {
    var pulls: [GlobalPullRow] = []
    var issues: [GlobalIssueRow] = []
    var review: [GlobalPullRow] = []
    /// The Issues tab's notices for the projects whose issues GitHub would not list.
    var issueRefusals: [GlobalIssueRefusal] = []
    /// The Issues tab's notes for the projects whose open issues the server cut to the most recently updated.
    var issueTruncations: [GlobalIssueTruncation] = []

    func count(_ tab: GlobalBoardTab) -> Int {
        switch tab {
        case .pulls: return pulls.count
        case .issues: return issues.count
        case .review: return review.count
        }
    }
}

/// A project whose issues GitHub would not list, and the notice that says so.
struct GlobalIssueRefusal: Equatable, Sendable {
    let project: Project
    let message: String
    var notice: String { "\(project.repo): GitHub would not read this repository’s issues. \(message)" }
}

/// A project with more open issues than the server listed, and the note that says only the newest are shown.
struct GlobalIssueTruncation: Equatable, Sendable {
    let project: Project
    var notice: String { "\(project.repo) has more open issues; only the most recently updated are listed." }
}

struct GlobalPullRow: Identifiable, Equatable, Sendable {
    let project: Project
    let pull: PullSummary
    let stack: StackPosition?
    let repoKey: String
    var id: String { "\(repoKey)#\(pull.number)" }

    var boardRow: BoardRow {
        var row = BoardRow(pull)
        row.stackPosition = stack?.position ?? row.stackPosition
        return row
    }

    init(project: Project, pull: PullSummary, stack: StackPosition?) {
        self.project = project; self.pull = pull; self.stack = stack
        repoKey = project.repo.lowercased()
    }
}

/// An open issue on the board across every project, with what the server sent for it, which the issue screen opens with.
struct GlobalIssueRow: Identifiable, Equatable, Sendable {
    let project: Project
    let issue: IssueSummary
    let raw: JSON
    let repoKey: String
    var id: String { "\(repoKey)#\(issue.number)" }

    init(project: Project, issue: IssueSummary, raw: JSON) {
        self.project = project; self.issue = issue; self.raw = raw
        repoKey = project.repo.lowercased()
    }
}

struct GlobalPullProject: Equatable, Sendable {
    var project: Project
    var rows: [GlobalPullRow] = []
    var issues: [GlobalIssueRow] = []
    /// What GitHub said when it would not list the repository's issues; its pull requests are unaffected.
    var issuesError: String?
    /// Whether the server listed only the most recently updated open issues, as the project's own board notes.
    var issuesTruncated = false
    /// The board's stacks and author, which decide its Review List as the project's own board does.
    var stacks: JSON = .null
    var author: String?
    var error: APIError?

    mutating func adopt(_ board: JSON) throws {
        guard board["pulls"].isArray else { throw APIError(.nonJSON) }
        var seen: Set<Int> = []
        rows = PullSummary.parseList(board["pulls"]).filter { seen.insert($0.number).inserted }.map {
            GlobalPullRow(project: project, pull: $0, stack: StackPosition($0.raw["stack"], stacks: board["stacks"]))
        }
        var seenIssues: Set<Int> = []
        issues = board["issues"].items.compactMap { raw in
            IssueSummary(raw).flatMap { seenIssues.insert($0.number).inserted ? GlobalIssueRow(project: project, issue: $0, raw: raw) : nil }
        }
        issuesError = board["issuesError"].string
        issuesTruncated = board["issuesTruncated"].is(true)
        stacks = board["stacks"]
        author = board["author"].nonEmpty
        error = nil
    }

    /// The same rows under the project's current name.
    mutating func relabel(_ project: Project) {
        self.project = project
        rows = rows.map { GlobalPullRow(project: project, pull: $0.pull, stack: $0.stack) }
        issues = issues.map { GlobalIssueRow(project: project, issue: $0.issue, raw: $0.raw) }
    }

    /// The pull requests waiting on `me`'s review, or on the project's author's without a saved login.
    func reviewIDs(me: String?) -> Set<String> {
        let waiting = Set(reviewList(rows.map(\.pull), stacks: stacks, me: me ?? author).map(\.number))
        return Set(rows.filter { waiting.contains($0.pull.number) }.map(\.id))
    }
}

struct GlobalPullsState: Equatable, Sendable {
    var projects: [GlobalPullProject] = [] { didSet { rebuildRows() } }
    var error: APIError?
    var loaded = false
    var loading = false
    var refreshing = false
    var showsLoading: Bool { (loading || refreshing) && boardShowsLoading(loaded: loaded, refreshing: refreshing) }

    /// Newest first, with a stable repository and number order when dates are missing or equal.
    private(set) var rows: [GlobalPullRow] = []
    /// The open issues in the same order.
    private(set) var issueRows: [GlobalIssueRow] = []

    private mutating func rebuildRows() {
        rows = projects.flatMap(\.rows).sorted {
            globalNewerFirst($0.pull.updatedAt, $0.repoKey, $0.pull.number, $1.pull.updatedAt, $1.repoKey, $1.pull.number)
        }
        issueRows = projects.flatMap(\.issues).sorted {
            globalNewerFirst($0.issue.updatedAt, $0.repoKey, $0.issue.number, $1.issue.updatedAt, $1.repoKey, $1.issue.number)
        }
    }
    var hasErrors: Bool { error != nil || projects.contains { $0.error != nil } }
    var count: Int { rows.count }
    var subtitle: String { "\(count) open pull requests · \(issueRows.count) open issues · \(projects.count) projects" }

    /// The pull requests waiting on a review across every project, in the pull requests' order.
    func reviewRows(me: String?) -> [GlobalPullRow] {
        let waiting = projects.reduce(into: Set<String>()) { $0.formUnion($1.reviewIDs(me: me)) }
        return rows.filter { waiting.contains($0.id) }
    }

    /// The projects whose issues GitHub would not list, with what it said.
    var issueRefusals: [GlobalIssueRefusal] {
        projects.compactMap { entry in entry.issuesError.map { GlobalIssueRefusal(project: entry.project, message: $0) } }
    }

    /// The projects whose open issues the server cut short.
    var issueTruncations: [GlobalIssueTruncation] {
        projects.filter(\.issuesTruncated).map { GlobalIssueTruncation(project: $0.project) }
    }

    /// What an empty tab says: a refused or failed read before the filters, and the Review List asks for a login when
    /// neither a saved one nor the author of any project decides whose review it waits on.
    func emptyTitle(_ tab: GlobalBoardTab, filter: GlobalPullsFilter, me: String?) -> String {
        let filtered = filter[tab].isOn
        switch tab {
        case .pulls:
            if hasErrors { return "Pull requests could not all be loaded" }
            return filtered ? "No pull requests match the filters" : "No open pull requests"
        case .issues:
            if hasErrors || !issueRefusals.isEmpty { return "Issues could not all be loaded" }
            return filtered ? "No issues match the filters" : "No open issues"
        case .review:
            if hasErrors { return "Pull requests could not all be loaded" }
            if (me ?? "").isEmpty && !projects.contains(where: { $0.author != nil }) {
                return "Set your GitHub login"
            }
            return filtered ? "No pull requests match the filters" : "Nothing is waiting on your review"
        }
    }

    /// Removed projects leave immediately; cached rows are used only for projects in the current list.
    mutating func replaceProjects(_ list: [Project], saved: (String) -> JSON?) {
        var seen: Set<String> = []
        projects = list.filter { seen.insert($0.repo.lowercased()).inserted }.map { project in
            var entry = projects.first { foldEqual($0.project.repo, project.repo) } ?? GlobalPullProject(project: project)
            entry.relabel(project)
            let error = entry.error
            if let board = saved(project.repo) { try? entry.adopt(board) }
            entry.error = error
            return entry
        }
    }
}

/// The same filters as a project's board, independent for pulls and issues; Review List stays unfiltered.
struct GlobalPullsFilter: Equatable, Sendable {
    var pulls = BoardFilter()
    var issues = BoardFilter()

    init() {}
    init(saved: JSON) {
        pulls = BoardFilter(saved: saved["pulls"])
        issues = BoardFilter(saved: saved["issues"])
    }
    var saved: JSON { ["pulls": pulls.saved, "issues": issues.saved] }

    subscript(tab: GlobalBoardTab) -> BoardFilter {
        get {
            switch tab {
            case .pulls: return pulls
            case .issues: return issues
            case .review: return BoardFilter()
            }
        }
        set {
            switch tab {
            case .pulls: pulls = newValue
            case .issues: issues = newValue
            case .review: break
            }
        }
    }

    func rows(in state: GlobalPullsState) -> [GlobalPullRow] {
        state.rows.filter { pulls.passes($0.boardRow) }
    }
    func issueRows(in state: GlobalPullsState) -> [GlobalIssueRow] {
        state.issueRows.filter { issues.passes(BoardRow($0.issue)) }
    }
    func reviewRows(in state: GlobalPullsState, me: String?) -> [GlobalPullRow] { state.reviewRows(me: me) }

    /// Counts for the active tab's regular board pickers, across every project.
    func optionsRows(in state: GlobalPullsState, tab: GlobalBoardTab) -> [BoardRow] {
        switch tab {
        case .pulls: return state.rows.map(\.boardRow)
        case .issues: return state.issueRows.map { BoardRow($0.issue) }
        case .review: return []
        }
    }

    /// Notices stay visible even when none of a project's rows match the filters.
    func board(in state: GlobalPullsState, me: String?) -> GlobalBoardRows {
        GlobalBoardRows(pulls: rows(in: state), issues: issueRows(in: state), review: reviewRows(in: state, me: me),
                        issueRefusals: state.issueRefusals, issueTruncations: state.issueTruncations)
    }
}

/// Newest first; missing dates last, then repository and the higher number for a stable order.
private func globalNewerFirst(_ leftDate: Date?, _ leftRepo: String, _ leftNumber: Int,
                              _ rightDate: Date?, _ rightRepo: String, _ rightNumber: Int) -> Bool {
    let left = leftDate ?? .distantPast, right = rightDate ?? .distantPast
    if left != right { return left > right }
    if leftRepo != rightRepo { return leftRepo < rightRepo }
    return leftNumber > rightNumber
}

/// Reads repositories one at a time, publishing each answer so a slow or refused project does not hide the others.
@MainActor
final class GlobalPullsReader {
    private(set) var state = GlobalPullsState()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var freshGeneration = 0
    private var lastFreshError: APIError?
    private var boardRevisions: [String: Int] = [:]
    private var refreshCount = 0

    init(saved: (String) -> JSON?) {
        if let answer = saved("projects"), let projects = Project.parseList(answer) {
            state.replaceProjects(projects, saved: { saved("pulls:\($0)") })
        }
    }

    /// A row action refreshed one project's board; update every tab without waiting for the next poll.
    func adopt(_ board: JSON, repo: String) throws {
        guard let index = state.projects.firstIndex(where: { foldEqual($0.project.repo, repo) }) else { return }
        try state.projects[index].adopt(board)
        boardRevisions[repo.lowercased(), default: 0] += 1
    }

    /// A nil board means its shared cooldown is still running; retain its rows and report that updates are delayed.
    /// Fresh requests queued during one pass share a follow-up fresh pass and wait for its result.
    func load(fresh: Bool = false, projects: () async throws -> JSON, saved: (String) -> JSON?,
              keepProjects: (JSON) -> Void = { _ in },
              cooldownError: (String) -> APIError? = { _ in nil },
              read: (String) async throws -> JSON?, current: () -> Bool,
              changed: (GlobalPullsState) -> Void) async -> APIError? {
        if fresh {
            refreshCount += 1
            state.refreshing = true
            changed(state)
        }
        defer {
            if fresh {
                refreshCount -= 1
                state.refreshing = refreshCount > 0
                changed(state)
            }
        }
        let requestedAfter = freshGeneration
        while state.loading {
            guard fresh else { return nil }
            await withCheckedContinuation { waiting.append($0) }
        }
        guard !Task.isCancelled, current() else { return APIError(.cancelled) }
        if fresh, freshGeneration > requestedAfter { return lastFreshError }
        if fresh { freshGeneration += 1 }
        var loadError: APIError?
        state.loading = true
        changed(state)
        defer {
            if fresh { lastFreshError = loadError }
            state.loading = false
            changed(state)
            let ready = waiting
            waiting.removeAll()
            ready.forEach { $0.resume() }
        }
        do {
            let answer = try await projects()
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            guard let list = Project.parseList(answer) else { throw APIError(.nonJSON) }
            keepProjects(answer)
            state.replaceProjects(list, saved: saved)
            state.error = nil
            changed(state)
        } catch {
            loadError = failed(error, current: current())
            return loadError
        }
        for index in state.projects.indices {
            let repo = state.projects[index].project.repo
            let revision = boardRevisions[repo.lowercased(), default: 0]
            do {
                try Task.checkCancellation()
                guard current() else { throw CancellationError() }
                let answer = try await read(repo)
                try Task.checkCancellation()
                guard current() else { throw CancellationError() }
                // A row action may have refreshed this repository while its poll was in flight.
                guard revision == boardRevisions[repo.lowercased(), default: 0] else { continue }
                if let answer { try state.projects[index].adopt(answer) }
                else if let error = cooldownError(state.projects[index].project.repo) { throw error }
                else if state.projects[index].error == nil { state.projects[index].error = APIError(.http, status: 429) }
            } catch {
                let error = normalized(error)
                if error.kind == .cancelled || error.unauthorized || !current() {
                    loadError = failed(error, current: current())
                    return loadError
                }
                if revision == boardRevisions[repo.lowercased(), default: 0] { state.projects[index].error = error }
            }
            changed(state)
        }
        state.loaded = true
        return nil
    }

    private func failed(_ error: Error, current: Bool) -> APIError {
        let error = normalized(error)
        if !current || error.unauthorized { state = GlobalPullsState() }
        else if error.kind != .cancelled { state.error = error; state.loaded = true }
        return error
    }

    private func normalized(_ error: Error) -> APIError {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return APIError(.cancelled) }
        return error as? APIError ?? APIError(.network, message: error.localizedDescription)
    }
}
