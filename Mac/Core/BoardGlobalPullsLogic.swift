// The board's open pull requests across the device's projects: repository identity, search, and partial reads shared by both apps.
import Foundation

struct GlobalPullRow: Identifiable, Equatable, Sendable {
    let project: Project
    let pull: PullSummary
    let stack: StackPosition?
    let repoKey: String
    let searchText: String
    var id: String { "\(repoKey)#\(pull.number)" }

    init(project: Project, pull: PullSummary, stack: StackPosition?) {
        self.project = project; self.pull = pull; self.stack = stack
        repoKey = project.repo.lowercased()
        let fields = [project.repo, project.title, "#\(pull.number)", pull.title, pull.branch, pull.author ?? ""]
            + pull.assignees + pull.reviewers.map(\.user) + pull.labels.map(\.name)
        searchText = fields.joined(separator: " ").lowercased()
    }
}

struct GlobalPullProject: Equatable, Sendable {
    var project: Project
    var rows: [GlobalPullRow] = []
    var error: APIError?

    mutating func adopt(_ board: JSON) throws {
        guard board["pulls"].isArray else { throw APIError(.nonJSON) }
        var seen: Set<Int> = []
        rows = PullSummary.parseList(board["pulls"]).filter { seen.insert($0.number).inserted }.map {
            GlobalPullRow(project: project, pull: $0, stack: StackPosition($0.raw["stack"], stacks: board["stacks"]))
        }
        error = nil
    }
}

struct GlobalPullsState: Equatable, Sendable {
    var projects: [GlobalPullProject] = [] { didSet { rebuildRows() } }
    var error: APIError?
    var loaded = false
    var loading = false

    /// Newest first, with a stable repository and number order when dates are missing or equal.
    private(set) var rows: [GlobalPullRow] = []

    private mutating func rebuildRows() {
        rows = projects.flatMap(\.rows).sorted {
            let left = $0.pull.updatedAt ?? .distantPast, right = $1.pull.updatedAt ?? .distantPast
            if left != right { return left > right }
            if $0.repoKey != $1.repoKey { return $0.repoKey < $1.repoKey }
            return $0.pull.number > $1.pull.number
        }
    }
    var hasErrors: Bool { error != nil || projects.contains { $0.error != nil } }
    var count: Int { rows.count }
    var subtitle: String { "\(count) open pull requests · \(projects.count) projects" }

    func emptyTitle(filtered: Bool) -> String {
        if hasErrors { return "Pull requests could not all be loaded" }
        return filtered ? "No pull requests match the filters" : "No open pull requests"
    }

    /// Removed projects leave immediately; cached rows are used only for projects in the current list.
    mutating func replaceProjects(_ list: [Project], saved: (String) -> JSON?) {
        var seen: Set<String> = []
        projects = list.filter { seen.insert($0.repo.lowercased()).inserted }.map { project in
            var entry = projects.first { foldEqual($0.project.repo, project.repo) } ?? GlobalPullProject(project: project)
            entry.project = project
            entry.rows = entry.rows.map { GlobalPullRow(project: project, pull: $0.pull, stack: $0.stack) }
            let error = entry.error
            if let board = saved(project.repo) { try? entry.adopt(board) }
            entry.error = error
            return entry
        }
    }
}

struct GlobalPullsFilter: Equatable, Sendable {
    var query = ""
    /// Empty means every project, independently of the per-project board filters.
    var repo = ""
    var isOn: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !repo.isEmpty }

    /// Keep the picker's exact tag while present; a removed project returns to All projects without losing search.
    func reconciled(in state: GlobalPullsState) -> GlobalPullsFilter {
        var filter = self
        filter.repo = state.projects.first { foldEqual($0.project.repo, repo) }?.project.repo ?? ""
        return filter
    }

    func rows(in state: GlobalPullsState) -> [GlobalPullRow] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let repoKey = repo.lowercased()
        return state.rows.filter { row in
            (repoKey.isEmpty || repoKey == row.repoKey) && words.allSatisfy { row.searchText.contains($0) }
        }
    }
}

/// Reads repositories one at a time, publishing each answer so a slow or refused project does not hide the others.
@MainActor
final class GlobalPullsReader {
    private(set) var state = GlobalPullsState()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(saved: (String) -> JSON?) {
        if let answer = saved("projects"), let projects = Project.parseList(answer) {
            state.replaceProjects(projects, saved: { saved("pulls:\($0)") })
        }
    }

    /// A nil board means its shared cooldown is still running; retain its rows and report that updates are delayed.
    /// A fresh request waits for the active pass, then performs its own read before returning.
    func load(fresh: Bool = false, projects: () async throws -> JSON, saved: (String) -> JSON?,
              keepProjects: (JSON) -> Void = { _ in },
              read: (String) async throws -> JSON?, current: () -> Bool,
              changed: (GlobalPullsState) -> Void) async -> APIError? {
        while state.loading {
            guard fresh else { return nil }
            await withCheckedContinuation { waiting.append($0) }
        }
        guard !Task.isCancelled, current() else { return APIError(.cancelled) }
        state.loading = true
        changed(state)
        defer {
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
            return failed(error, current: current())
        }
        for index in state.projects.indices {
            do {
                try Task.checkCancellation()
                guard current() else { throw CancellationError() }
                let answer = try await read(state.projects[index].project.repo)
                try Task.checkCancellation()
                guard current() else { throw CancellationError() }
                if let answer { try state.projects[index].adopt(answer) }
                else if state.projects[index].error == nil { state.projects[index].error = APIError(.http, status: 429) }
            } catch {
                let error = normalized(error)
                if error.kind == .cancelled || error.unauthorized || !current() {
                    return failed(error, current: current())
                }
                state.projects[index].error = error
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
