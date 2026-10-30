// The pull request's Code reviews tab (`GET /pulls/{number}/code-reviews`): every code review Briareus ran on it, newest
// first, each a card with how it ended, when, what it ran on and cost, its verdict counts, its session and summary, then
// its findings with the verify step's verdicts. Read-only: the review's own verify step rules on each finding.
import SwiftUI

struct PullCodeReviewsTab: View {
    @ObservedObject var model: PullModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = model.codeReviewsError { Notice(message: e) }
            if !model.codeReviewsRead {
                LoadingNote(text: "Loading code reviews\u{2026}")
            } else if model.codeReviews.isEmpty && model.codeReviewsError == nil {
                EmptyNote(title: "No code reviews yet", detail: "A code review started from this pull request's errands is stored here with its findings.")
            }
            ForEach(model.codeReviews) { review in
                CodeReviewCard(review: review, openSession: { model.openReviewSession($0) })
            }
        }
    }
}

/// One review: its status, date, run line and counts, the session it ran in, the summary it posted, and its findings.
private struct CodeReviewCard: View {
    var review: CodeReview
    var openSession: (String) -> Void

    var body: some View {
        BoardBox(padding: 12, radius: BriareusRadius.lg) {
            HStack(spacing: 8) {
                Badge(text: review.status.title, color: Theme.color(review.status.tone))
                if let at = review.createdAt {
                    Text(formatEventTime(at)).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let sid = review.openableSessionID {
                    Button("Open session") { openSession(sid) }.dashButton(.bordered)
                }
            }
            if !review.meta.isEmpty {
                Text(review.meta).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail).padding(.top, 6)
            }
            Text(review.counts.line).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).padding(.top, 4)
            if let summary = review.summary {
                MarkdownView(source: visibleMarkdown(summary), size: .footnote).padding(.top, 10)
            }
            if !review.findings.isEmpty {
                BoardRule().padding(.vertical, 10)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(review.findings) { CodeReviewFindingRow(finding: $0) }
                }
            }
        }
    }
}

/// A finding folded to its badges and title; open, where it is, what it says and why the verdict is what it is.
private struct CodeReviewFindingRow: View {
    var finding: CodeReviewFinding
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: { heading.contentShape(Rectangle()) }
                .buttonStyle(.plain).handCursor()
                .accessibilityLabel("\(finding.title), \(open ? "collapse" : "expand")")
            if open { details.padding(.leading, 22) }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(Theme.caption2).foregroundStyle(Theme.muted).frame(width: 16)
            Badge(text: finding.severityLabel, color: Theme.color(finding.severityTone))
            if let verdict = finding.verdict {
                Badge(text: verdict.title, color: Theme.color(verdict.tone))
            } else {
                Badge(text: "Unverified", color: Theme.muted)
            }
            if let verification = finding.verification {
                Badge(text: verification.title, color: Theme.color(verification.tone))
            }
            Text(finding.title).font(Theme.callout).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var details: some View {
        if let location = finding.location {
            Text(location).font(Theme.monoSmall).foregroundStyle(Theme.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let body = finding.body { MarkdownView(source: visibleMarkdown(body), size: .footnote) }
        if let comments = finding.comments {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.verdict.map { "Why \($0.title.lowercased())" } ?? "Verifier's note")
                    .font(Theme.captionSemibold).foregroundStyle(Theme.muted)
                Text(comments).font(Theme.footnote).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
