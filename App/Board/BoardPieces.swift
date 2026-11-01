// What the board's screens share on a phone: the rows of pull requests, issues and conversations, and the badges and chips
// they carry. The errands, their catalog and the runner that starts one are in BoardErrands.swift.
import SwiftUI
import UIKit

// MARK: - Links

/// Opens an https address in Safari; anything else is refused.
@MainActor
func boardOpenWeb(_ url: String?) {
    guard safeWebURL(url), let url, let u = URL(string: url) else { return }
    UIApplication.shared.open(u)
}

// MARK: - Badges and chips

/// A small capsule: a symbol and a word in one colour on its tint.
struct BoardBadge: View {
    let text: String
    let systemImage: String?
    let color: Color
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 9
    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: iconSize, weight: .semibold)) }
            Text(text).font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Lays its subviews out left to right, wrapping when a line is full.
struct BoardFlowLayout: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, f) in zip(subviews, arrange(subviews, width: bounds.width)) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let ideal = v.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, width), height: ideal.height)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; row = max(row, size.height)
        }
        return frames
    }
}

/// GitHub labels as chips: the label's colour tints the chip, the name stays in the text colour so a pale one still reads.
struct BoardLabelChips: View {
    let labels: [PullLabel]
    var body: some View {
        BoardFlowLayout(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                let color = Theme.color(label)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(label.name).font(.caption2.weight(.medium)).lineLimit(1)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(color.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
                .accessibilityElement(children: .ignore).accessibilityLabel("Label \(label.name)")
            }
        }
    }
}

/// A review verdict's symbol and colour.
func reviewStyle(_ status: ReviewStatus) -> (symbol: String, color: Color) {
    (status.symbol ?? "clock", Theme.color(status.tone))
}

/// When a row last changed, short.
struct BoardUpdated: View {
    let date: Date?
    var body: some View {
        if let date { Text(formatRelative(date)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
    }
}

// MARK: - Rows

/// An issue or pull request named under a row, with the state that says whether it is still open work, and `status` (an
/// issue's Status on its project board) as a chip after it. A pull request's row leaves the state of the issues it closes
/// out (`showState`).
struct BoardLinkedRow: View {
    let link: BoardLink
    let repo: String
    var status: String? = nil
    var showState = true
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
            Text(link.reference(repo)).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(link.title).font(.caption).lineLimit(1)
            if showState, let state = LinkedState(link) {
                Text(state.text).font(.caption2).foregroundStyle(Theme.color(state.tone))
            }
            if let status, !status.isEmpty {
                Text(status).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.field, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 0.5))
                    .accessibilityLabel("Status \(status)")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A pull request as the board shows it: title and number, its standing as badges, the errand it asks for, its labels, who
/// holds, wrote and reviews it split by pipes, and the issues it closes.
struct BoardPullRow: View {
    let pull: PullSummary
    let stack: StackPosition?
    let repo: String
    /// The conversations at work on it right now.
    var activeRuns = 0
    /// The label of the errand its state asks for, when this device could start it.
    var suggested: String? = nil
    /// The project Status of each issue it closes, in its order; nil or "" for none.
    var issueStatus: [String?] = []
    var showsIssues = true

    private var content: PullRowContent { PullRowContent(pull: pull, stack: stack, activeRuns: activeRuns, suggested: suggested) }
    private var tint: Color { pull.hasConflicts ? Theme.danger : pull.draft ? .secondary : Theme.ok }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.pull").font(.subheadline).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(pull.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The branch is the pull request's page's to show.
                    Text(verbatim: "#\(pull.number)").font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 4)
                    BoardUpdated(date: pull.updatedAt)
                }
                let content = content
                if !content.marks.isEmpty {
                    BoardFlowLayout(spacing: 5) {
                        ForEach(Array(content.marks.enumerated()), id: \.offset) { _, mark in
                            BoardBadge(text: mark.text, systemImage: mark.symbol, color: Theme.color(mark.tone))
                                .accessibilityLabel(mark.spoken)
                        }
                    }
                }
                if !pull.labels.isEmpty { BoardLabelChips(labels: pull.labels) }
                Text(content.who.joined(separator: " | ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if showsIssues {
                    ForEach(Array(pull.issues.enumerated()), id: \.offset) { i, link in
                        BoardLinkedRow(link: link, repo: repo, status: i < issueStatus.count ? issueStatus[i] : nil, showState: false)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// How much of an epic is done, over every sub-issue GitHub knows, which may be more than the rows under it.
struct BoardEpicProgress: View {
    let progress: SubIssueProgress
    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.fraction).tint(Theme.accent).frame(width: 70)
            Text(progress.text).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.spoken)
    }
}

/// An issue as the board shows it: who holds it, the epic's progress, its labels, its epic, and what answers it.
struct BoardIssueRow: View {
    let issue: IssueSummary
    let repo: String
    /// Set on a row drawn under its epic, where the indent already says whose it is.
    var nested = false
    /// Whether the sub-issues under it are hidden; nil for a row with none to hide.
    var folded: Bool?
    var fold: (() -> Void)?
    var body: some View {
        let content = IssueRowContent(issue: issue, repo: repo, nested: nested)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: issue.isEpic ? "square.stack.3d.up" : "smallcircle.filled.circle").font(.subheadline)
                .foregroundStyle(content.answered ? Theme.accent : Theme.ok).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(issue.title).font(.body.weight(.medium)).lineLimit(2)
                    if let folded, let fold {
                        Spacer(minLength: 4)
                        Button(action: fold) {
                            Image(systemName: folded ? "chevron.right.circle" : "chevron.down.circle").font(.body)
                                .foregroundStyle(.secondary).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(folded ? "Show sub-issues" : "Hide sub-issues")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    factLine(content.facts).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    BoardUpdated(date: issue.updatedAt)
                }
                if let progress = content.progress { BoardEpicProgress(progress: progress) }
                if !issue.labels.isEmpty { BoardLabelChips(labels: issue.labels) }
                if let parentLine = content.parentLine {
                    Label(parentLine, systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(Array(issue.pulls.enumerated()), id: \.offset) { _, link in BoardLinkedRow(link: link, repo: repo) }
            }
        }
        .padding(.vertical, 3)
    }
}

/// A row's facts as one line, " · " between them, each in its tone.
func factLine(_ facts: [RowFact]) -> Text {
    facts.enumerated().reduce(Text(verbatim: "")) { line, item in
        let fact = Text(verbatim: item.element.text).foregroundColor(Theme.color(item.element.tone))
        return item.offset == 0 ? fact : line + Text(verbatim: " · ").foregroundColor(.secondary) + fact
    }
}

/// A conversation run on a pull request or issue: its status, title, and status · model.
struct BoardSessionRow: View {
    let session: Session
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(status: session.status).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle).lineLimit(2).foregroundStyle(session.isClosed ? .secondary : .primary)
                Text(sessionSubtitle(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
