// A pull request page's sidebar (PullScreen), as GitHub's: its errands, checks, reviewers, assignees, labels, the
// projects of the issues it closes, milestone and Development, then the GitHub account the server uses for its project,
// read only on a click (GithubAccountItem, in GithubAccountPieces.swift).
import SwiftUI

/// The sidebar: only what the server reports, not notifications; the projects are those of the issues it closes. Each
/// item is keyed by what it is, so one arriving late leaves the identity of those after it (and their state) alone.
struct PullSidebar: View {
    @ObservedObject var model: PullModel
    /// The project's GitHub account, owned by PullScreen so a read survives the sidebar moving between layouts; its
    /// item and a Projects refusal share it.
    let account: ProjectGithubAccountModel
    var body: some View {
        let row = model.boardRow
        let projects = model.issueProjects.entries.map { (id: "projects", view: AnyView(PullProjectsItem(entries: $0, account: account))) }
        var items: [(id: String, view: AnyView)] = []
        if !model.actions.isEmpty { items.append(("actions", AnyView(actions(row)))) }
        if !model.pr.isNull { items.append(("checks", AnyView(checks))); items.append(("reviewers", AnyView(reviewers(row)))) }
        if let row {
            items.append(("assignees", AnyView(section("Assignees") {
                if row.assignees.isEmpty { Text("No one").font(Theme.caption).foregroundStyle(Theme.muted) }
                ForEach(row.assignees, id: \.self) { Text($0).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1) }
                if model.canEdit { editButton("Edit assignees ▾") { model.editAssignees() } }
            })))
            items.append(("labels", AnyView(section("Labels") {
                if row.labels.isEmpty { Text("None yet").font(Theme.caption).foregroundStyle(Theme.muted) }
                else { LabelChips(labels: row.labels, background: Theme.canvas) }
                if model.canEdit { editButton("Edit labels…") { model.editLabels() } }
            })))
            if let projects { items.append(projects) }
            if let milestone = row.raw["milestone"].string {
                items.append(("milestone", AnyView(section("Milestone") { Text(milestone).font(Theme.footnote).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true) })))
            }
        }
        if row == nil, let projects { items.append(projects) }
        let issues = (row?.issues.isEmpty == false) ? row!.issues : BoardLink.parseList(model.pr["issues"])
        if !issues.isEmpty { items.append(("development", AnyView(development(issues)))) }
        if ProjectGithubAccountModel.offered { items.append(("github", AnyView(GithubAccountItem(account: account)))) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Spacer().frame(height: 14); BoardRule() }
                Spacer().frame(height: 14)
                item.view
            }
        }
    }

    /// `.discussion-sidebar-item`: a small heading over its contents.
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.captionSemibold).foregroundStyle(Theme.muted).lineLimit(1).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The edit button under the assignees or labels.
    private func editButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).dashButton(.bordered).disabled(model.editing).padding(.top, 4)
    }

    /// The errands as the sidebar's first item: one full-width button per action, the one the state asks for filled.
    private func actions(_ row: PullSummary?) -> some View {
        section(model.busy ? "Actions · starting…" : "Actions") {
            VStack(spacing: 6) {
                ForEach(model.actions, id: \.id) { a in
                    let kind: ButtonKind = a.isSuggested(for: row) ? .prominent : a.isDestructive ? .destructive : .bordered
                    Button { model.act(a) } label: { ErrandLabel(id: a.id, label: a.label) }
                        .dashButton(kind, stretch: true).disabled(model.busy || model.uncertain).help(a.hint)
                }
            }
            Text("Uses the provider and model configured for this project. These actions run paid agents and may write to GitHub.")
                .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }

    /// The checks as counts only.
    private var checks: some View {
        let checks = model.pr["checks"]
        return section("Checks") {
            if checks["runs"].count == 0 { Text("No checks reported").font(Theme.caption).foregroundStyle(Theme.muted) }
            else {
                CheckCounts(passed: checks["passed"].int32 ?? 0, pending: checks["pending"].int32 ?? 0, failed: checks["failed"].int32 ?? 0)
            }
        }
    }

    private func reviewer(_ user: String, badge: BadgeSpec?, state: String?) -> some View {
        HStack(spacing: 8) {
            Text(user).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let badge { Badge(glyph: badge.glyph, text: badge.text, color: badge.color, background: Theme.canvas) }
            else if let state { Text(state).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
        }
        .frame(minHeight: 22)
    }
    private func reviewers(_ row: PullSummary?) -> some View {
        let reviews = model.pr["reviews"].items
        let requested = (row?.reviewers ?? []).filter { r in
            r.state == "requested" && !reviews.contains { foldEqual($0["user"].string, r.user) }
        }
        return section("Reviewers") {
            ForEach(Array(reviews.enumerated()), id: \.offset) { _, review in
                let user = review["user"].string ?? "Reviewer"
                let st = ReviewStatus(decision: nil, reviews: .array([review]))
                if st != .none {
                    let g = reviewGlyph(st)
                    reviewer(user, badge: BadgeSpec(glyph: g.symbol, text: st.text, color: g.color), state: nil)
                } else {
                    reviewer(user, badge: nil, state: review["state"].string)
                }
            }
            ForEach(requested, id: \.user) { r in
                reviewer(r.user, badge: BadgeSpec(glyph: Glyph.symbol(0xE823), text: "Review requested", color: Theme.muted), state: nil)
            }
            if reviews.isEmpty && requested.isEmpty { Text("No reviews").font(Theme.caption).foregroundStyle(Theme.muted) }
        }
    }

    private func development(_ issues: [BoardLink]) -> some View {
        section("Development") {
            Text("Successfully merging this pull request may close these issues.").font(Theme.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
            ForEach(Array(issues.enumerated()), id: \.offset) { _, link in
                let here = !link.isForeign(model.repo) && Store.shared.supports("issue")
                LinkedRow(link: link, repo: model.repo, action: here || safeWebURL(link.url) ? { openIssue(link, here: here) } : nil)
            }
        }
    }
    /// An issue of this repository opens here, which reads the rest itself; any other on GitHub.
    private func openIssue(_ link: BoardLink, here: Bool) {
        if here {
            var bare: JSON = ["number": JSON(link.number), "title": .string(link.title)]
            if let url = link.url { bare["url"] = .string(url) }
            Navigator.shared.push(.issue(repo: model.repo, issue: bare))
        } else { openWebURL(link.url) }
    }
}
