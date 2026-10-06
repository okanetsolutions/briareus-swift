// The GitHub Projects fields of the issues a pull request closes, on a phone (the Mac's IssueProjects): on the board,
// each linked issue line ends with its project Status as a chip, read in the background one issue at a time, the rows
// the filters show first; on the pull request, the Projects section lists the boards those issues are on, each with its
// Status and the rest of its fields. Both read each issue with `issue`, keep its answer where the Mac keeps it, and show
// that saved copy first. A throttled (429) read stops and waits for the next board read.
import SwiftUI

/// One issue's boards, as `issue` answered them.
struct IssueProjectsEntry: Equatable {
    var number: Int
    var projects: JSON
    var error: String?

    init(number: Int, issue: JSON) {
        self.number = number; projects = issue["projects"]; error = issue["projectsError"].string
    }
}

/// A read that should stop the round: GitHub's rate limit, or one only abandoned.
private func stops(_ error: Error) -> Bool {
    error.isCancellation || ((error as? APIError).map { $0.kind == .http && $0.status == 429 } ?? false)
}

// MARK: - The board's Status chips

/// The Status each linked issue has on its project board, by issue number ("" for none), from that issue's own read.
@MainActor
final class IssueStatusReader: ObservableObject {
    let repo: String
    @Published private(set) var status: [Int: String] = [:]
    /// Reads go on only while the board is on show.
    var shown = false
    /// The issues read this visit.
    private var read: Set<Int> = []
    private var reading = false
    private var gen = 0
    private var pulls: [PullSummary] = []
    private var filter = BoardFilter()

    init(repo: String) { self.repo = repo }

    /// The Statuses of a row's linked issues, in its order; nil for one in another repository or not known yet.
    func statuses(_ pull: PullSummary) -> [String?] {
        pull.issues.map { $0.isForeign(repo) ? nil : status[$0.number] }
    }

    /// What was saved of the linked issues not known yet, so the statuses show before they are read again.
    private func restore() {
        var found: [Int: String] = [:]
        for pull in pulls {
            for l in pull.issues where !l.isForeign(repo) && status[l.number] == nil && found[l.number] == nil {
                guard let saved = Store.shared.cache.value(savedIssueKey(repo, l.number)) else { continue }
                found[l.number] = issueProjectStatus(saved["issue"]) ?? ""
            }
        }
        if !found.isEmpty { status.merge(found) { a, _ in a } }
    }

    /// Reads the next linked issue not read this visit: those of the rows the filters show first, then the rest.
    func next(pulls: [PullSummary], filter: BoardFilter) {
        self.pulls = pulls; self.filter = filter
        restore()
        next()
    }
    private func next() {
        guard shown, !reading, Store.shared.supports("issue") else { return }
        var number = 0
        for pass in 0..<2 where number == 0 {
            for pull in pulls where number == 0 && (pass == 1 || filter.passes(BoardRow(pull))) {
                number = pull.issues.first { !$0.isForeign(repo) && !read.contains($0.number) }?.number ?? 0
            }
        }
        guard number > 0 else { return }
        reading = true
        let g = gen
        Task {
            do {
                let v = try await Store.shared.call("issue", ["issue": JSON(number), "repo": .string(repo)])
                guard g == gen else { return }
                reading = false
                read.insert(number)
                status[number] = issueProjectStatus(v["issue"]) ?? ""
                Store.shared.cache.store(v, savedIssueKey(repo, number))
            } catch {
                guard g == gen else { return }
                reading = false
                // Throttling stops the round and leaves this issue unread, so it and the rest wait for the next board read.
                if stops(error) { return }
                read.insert(number)
            }
            next()
        }
    }

    /// Pulling down reads every issue again.
    func reset() { gen += 1; reading = false; read = [] }
}

// MARK: - The pull request's Projects section

/// The projects of the issues a pull request closes, as GitHub's sidebar shows them: one `issue` read per linked issue in
/// this repository, once per visit and on refresh, kept in the order the pull request lists them. The round keeps the
/// issue numbers it reads, so a list that changes partway starts it again.
@MainActor
final class IssueProjectsReader {
    static let maxIssues = 10
    let repo: String
    /// What the issues said; nil while nothing is known, or when the pull request links none.
    private(set) var entries: [IssueProjectsEntry]?
    private var round: [Int] = []
    private var incoming: [IssueProjectsEntry?]?
    private var read = false
    private var reading = false
    private var gen = 0
    private let linked: () -> [Int]
    private let changed: () -> Void

    init(repo: String, linked: @escaping () -> [Int], changed: @escaping () -> Void) {
        self.repo = repo; self.linked = linked; self.changed = changed
    }

    /// The linked issues' projects: what was saved of them at once, then each issue read again.
    func load() {
        guard !reading, Store.shared.supports("issue") else { return }
        let numbers = linked()
        // Read once per visit, unless the issues it links have changed since.
        if read && numbers == round { return }
        read = false
        // A pull request that no longer links any issue drops the projects it showed.
        if numbers.isEmpty {
            if entries != nil { entries = nil; changed() }
            return
        }
        if entries == nil {
            let saved = numbers.compactMap { n in Store.shared.cache.value(savedIssueKey(repo, n)).map { IssueProjectsEntry(number: n, issue: $0["issue"]) } }
            if !saved.isEmpty { entries = saved; changed() }
        }
        // A round throttled partway carries on where it stopped.
        if incoming == nil { incoming = [] }
        next()
    }

    /// Reads the next linked issue, or, once they are all in, shows what they said.
    private func next() {
        let numbers = linked()
        // A list that changed partway, as when the board's row replaces the saved one, starts the round again on it.
        if numbers != round { round = numbers; incoming = [] }
        let at = incoming?.count ?? 0
        if at < numbers.count {
            let number = numbers[at]
            reading = true
            let g = gen
            Task {
                do {
                    let v = try await Store.shared.call("issue", ["issue": JSON(number), "repo": .string(repo)])
                    guard g == gen else { return }
                    reading = false
                    incoming?.append(IssueProjectsEntry(number: number, issue: v["issue"]))
                    Store.shared.cache.store(v, savedIssueKey(repo, number))
                } catch {
                    guard g == gen else { return }
                    reading = false
                    // Throttling stops the round with this issue unread, so it and the rest are read on the next poll.
                    if stops(error) { return }
                    // One that cannot be read keeps what was shown of it, if anything; the others still show.
                    incoming?.append(entries?.first { $0.number == number })
                }
                next()
            }
            return
        }
        entries = (incoming ?? []).compactMap { $0 }
        incoming = nil
        read = true
        changed()
    }

    /// Pulling down reads them again; a paused round is dropped.
    func reset() { gen += 1; reading = false; read = false; incoming = nil }
}

extension PullScreenModel {
    /// The issues it closes that are in this repository: the board's row first, else the pull request's own.
    func linkedIssues() -> [Int] {
        Array(closes.filter { !$0.isForeign(repo) }.map(\.number).prefix(IssueProjectsReader.maxIssues))
    }
}

/// The Projects section: each board the closed issues are on, named after its issue when there is more than one, with
/// its Status and the rest of its fields, and a link to it on GitHub; or why there are none.
struct PullProjectsSection: View {
    var entries: [IssueProjectsEntry]?

    var body: some View {
        let list = entries ?? []
        let shown = list.flatMap { e in e.projects.items.map { (e, $0) } }
        ForEach(Array(shown.enumerated()), id: \.offset) { _, pair in
            IssueProjectSection(project: pair.1, from: list.count > 1 ? "#\(pair.0.number)" : nil)
        }
        if shown.isEmpty {
            Section {
                if entries == nil {
                    HStack(spacing: 8) { ProgressView(); Text("Reading the issues' projects…").foregroundStyle(.secondary) }
                } else if let refused = list.lazy.compactMap(\.error).first {
                    Text(verbatim: "GitHub would not read the projects with the server’s token, which needs Projects: read.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ErrorNotice(message: refused)
                } else {
                    Text("None of the issues it closes is on a project board.").foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Theme.row)
        }
    }
}

/// One Projects v2 board an issue is on: its Status and the rest of its fields, under its title (with `from`, the issue it
/// came through, when given), and Open on GitHub. The issue screen lists its own projects with it too.
struct IssueProjectSection: View {
    var project: JSON
    var from: String?

    var body: some View {
        let title = project["title"].string ?? "Project"
        let url = project["url"].string
        Section {
            LabeledContent("Status", value: project["status"].nonEmpty ?? "No status")
            ForEach(Array(project["fields"].items.enumerated()), id: \.offset) { _, f in
                if let name = f["name"].string, let value = f["value"].string ?? f["value"].number.map({ String(format: "%g", $0) }) {
                    LabeledContent(name) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
                }
            }
            if safeWebURL(url) {
                Button { boardOpenWeb(url) } label: { Label("Open the project on GitHub", systemImage: "safari") }
            }
        } header: {
            Label(from.map { "\(title) · \($0)" } ?? title, systemImage: "rectangle.split.3x1")
        }
        .listRowBackground(Theme.row)
    }
}
