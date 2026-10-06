// The GitHub Projects fields of the issues a pull request closes (screen_pulls.c's issue_status_* and issue_projects_*):
// on the board, each linked issue line ends with its project Status as a chip, read in the background one issue at a
// time, the rows the filters show first; on the pull request, the sidebar's Projects item lists the boards those issues
// are on, each with its Status and the rest of its fields. Both read each issue with `issue`, keep its answer where the
// issue screen keeps its own, and show that saved copy first. A throttled (429) read stops and waits for the next poll.
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

private func throttled(_ e: APIError?) -> Bool { e?.kind == .http && e?.status == 429 }

// MARK: - The board's Status chips

/// The Status each linked issue has on its project board, by issue number ("" for none), from that issue's own read.
@MainActor
final class IssueStatusReader {
    let repo: String
    private(set) var status: [Int: String] = [:]
    /// The issues read this visit.
    private var read: Set<Int> = []
    private var reading = false
    private var gen = 0
    private let rows: () -> (pulls: [PullSummary], filter: BoardFilter)
    private let changed: () -> Void

    init(repo: String, rows: @escaping () -> (pulls: [PullSummary], filter: BoardFilter), changed: @escaping () -> Void) {
        self.repo = repo; self.rows = rows; self.changed = changed
    }

    /// The Statuses of a row's linked issues, in its order; nil for one in another repository or not known yet.
    func statuses(_ pull: PullSummary) -> [String?] {
        pull.issues.map { $0.isForeign(repo) ? nil : status[$0.number] }
    }

    /// What was saved of the linked issues not known yet, so the statuses show before they are read again.
    func restore() {
        var any = false
        for pull in rows().pulls {
            for l in pull.issues where !l.isForeign(repo) && status[l.number] == nil {
                guard let saved = Store.shared.cache.value(savedIssueKey(repo, l.number)) else { continue }
                status[l.number] = issueProjectStatus(saved["issue"]) ?? ""
                any = true
            }
        }
        if any { changed() }
    }

    /// Reads the next linked issue not read this visit: those of the rows the filters show first, then the rest. Only
    /// while the board is the screen on show.
    func next() {
        guard !reading, Store.shared.supports("issue"), Navigator.shared.top.id == "pulls:\(repo)" else { return }
        let (pulls, filter) = rows()
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
            let r = await boardCall("issue", ["issue": JSON(number), "repo": .string(repo)])
            guard g == gen else { return }
            reading = false
            // Throttling stops the round and leaves this issue unread, so it and the remaining reads wait for the next
            // poll rather than hitting the limit again.
            if throttled(r.error) || r.error?.kind == .cancelled { return }
            read.insert(number)
            if let v = r.value {
                status[number] = issueProjectStatus(v["issue"]) ?? ""
                Store.shared.cache.store(v, savedIssueKey(repo, number))
                changed()
            }
            next()
        }
    }

    /// Refresh reads every issue again.
    func reset() { gen += 1; reading = false; read = [] }
}

// MARK: - The pull request's Projects item

/// The projects of the issues a pull request closes, as GitHub's sidebar shows them: one `issue` read per linked issue in
/// this repository, once per visit and on refresh, kept in the sidebar's order. The round keeps the issue numbers it
/// reads, so a list that changes partway starts it again.
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
                let r = await boardCall("issue", ["issue": JSON(number), "repo": .string(repo)])
                guard g == gen else { return }
                reading = false
                // Throttling stops the round with this issue unread, so it and the rest are read on the next poll.
                if throttled(r.error) || r.error?.kind == .cancelled { return }
                if let v = r.value {
                    incoming?.append(IssueProjectsEntry(number: number, issue: v["issue"]))
                    Store.shared.cache.store(v, savedIssueKey(repo, number))
                } else {
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

    /// Refresh reads them again; a paused round is dropped.
    func reset() { gen += 1; reading = false; read = false; incoming = nil }
}

extension PullModel {
    /// The issues the Development item lists that are in this repository: the board's row first, else the pull request's own.
    func linkedIssues() -> [Int] {
        let issues = boardRow.map(\.issues).flatMap { $0.isEmpty ? nil : $0 } ?? BoardLink.parseList(pr["issues"])
        return Array(issues.filter { !$0.isForeign(repo) }.map(\.number).prefix(IssueProjectsReader.maxIssues))
    }
}

/// The sidebar's Projects item: each board the closed issues are on, named after its issue when there is more than one,
/// opening on GitHub, with its Status and the rest of its fields; or why there are none.
struct PullProjectsItem: View {
    var entries: [IssueProjectsEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Projects").font(Theme.captionSemibold).foregroundStyle(Theme.muted).lineLimit(1).padding(.bottom, 8)
            let shown = entries.flatMap { e in e.projects.items.map { (e, $0) } }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, pair in
                IssueProjectView(project: pair.1, from: entries.count > 1 ? "#\(pair.0.number)" : nil).padding(.top, i > 0 ? 10 : 0)
            }
            if shown.isEmpty {
                if let refused = entries.lazy.compactMap(\.error).first {
                    Text(verbatim: "GitHub would not read its projects with the server’s token, which needs Projects: read. \(refused)")
                        .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("None yet").font(Theme.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One Projects v2 board an issue is on: its title (with `from`, the issue it came through, when given), which opens it
/// on GitHub, then its Status and the rest of its fields.
struct IssueProjectView: View {
    var project: JSON
    var from: String?

    var body: some View {
        let title = project["title"].string ?? "Project"
        let url = project["url"].string
        VStack(alignment: .leading, spacing: 2) {
            GlyphLabel(glyph: 0xE8FD, text: from.map { "\(title) · \($0)" } ?? title, font: Theme.footnoteSemibold)
                .contentShape(Rectangle())
                .onTapGesture { if safeWebURL(url) { openWebURL(url) } }
                .handCursor(safeWebURL(url))
                .padding(.bottom, 2)
            field("Status", project["status"].nonEmpty ?? "No status")
            ForEach(Array(project["fields"].items.enumerated()), id: \.offset) { _, f in
                if let name = f["name"].string, let value = f["value"].string ?? f["value"].number.map({ String(format: "%g", $0) }) {
                    field(name, value)
                }
            }
        }
    }

    /// A name on the left and its value on the right, as a project's fields are listed: the name in two fifths of the
    /// sidebar's width.
    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                .frame(width: 90, alignment: .leading)
            Text(value).font(Theme.footnote).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 20)
    }
}
