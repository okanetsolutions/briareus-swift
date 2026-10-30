// A pull request's Code reviews tab (`GET /pulls/{n}/code-reviews`), as the Mac's: every stored review, newest first, a
// section each with its status, when it ran, what it ran on and its counts, the conversation that ran it, its summary,
// then its findings with the verify step's verdict. Read-only: the words and tones are CodeReviewLogic's.
import SwiftUI

/// The reviews as sections of the pull request's list.
struct PullCodeReviewsTab: View {
    let reviews: [CodeReview]
    /// False until the reviews were read once: the tab shows it is loading rather than empty.
    let read: Bool
    let error: String?

    var body: some View {
        if let error {
            Section { ErrorNotice(message: error) }.listRowBackground(Theme.row)
        }
        if reviews.isEmpty {
            if !read && error == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if error == nil {
                ContentUnavailableView("No code reviews", systemImage: "checklist",
                                       description: Text("Reviews run on this pull request show here with their findings."))
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        } else {
            ForEach(reviews) { CodeReviewSection(review: $0) }
        }
    }
}

/// One review: its heading, summary and findings.
private struct CodeReviewSection: View {
    let review: CodeReview
    @Environment(\.navigate) private var navigate

    var body: some View {
        Section {
            CodeReviewHeading(review: review)
            if let id = review.openableSessionID {
                Button { navigate(.conversation(id: id, session: nil)) } label: {
                    Label("Open session", systemImage: "bubble.left.and.bubble.right")
                }
            }
            if let summary = review.summary.map(visibleMarkdown), !summary.isEmpty {
                DisclosureGroup("Summary") { MarkdownText(summary).font(.callout) }
            }
            ForEach(review.findings) { CodeReviewFindingRow(finding: $0) }
        }
        .listRowBackground(Theme.row)
    }
}

/// The status in its tone, the date, what it ran on and the counts.
private struct CodeReviewHeading: View {
    let review: CodeReview
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BoardBadge(text: review.status.title, systemImage: nil, color: Theme.color(review.status.tone))
                if let at = review.createdAt { Text(formatRelative(at)).font(.caption).foregroundStyle(.secondary) }
            }
            if !review.meta.isEmpty { Text(review.meta).font(.caption).foregroundStyle(.secondary) }
            Text(review.counts.line).font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A finding folded to its badges and title; open, where it is, what it says and why it got its verdict.
private struct CodeReviewFindingRow: View {
    let finding: CodeReviewFinding
    var body: some View {
        DisclosureGroup {
            if let location = finding.location {
                Text(location).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let body = finding.body.map(visibleMarkdown), !body.isEmpty { MarkdownText(body).font(.callout) }
            if let reason = finding.comments, !reason.isEmpty {
                Text(reason).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    BoardBadge(text: finding.severityLabel, systemImage: nil, color: Theme.color(finding.severityTone))
                    if let verdict = finding.verdict {
                        BoardBadge(text: verdict.title, systemImage: nil, color: Theme.color(verdict.tone))
                    } else {
                        BoardBadge(text: "Unverified", systemImage: nil, color: .secondary)
                    }
                    if let verification = finding.verification {
                        Text(verification.title).font(.caption).foregroundStyle(Theme.color(verification.tone))
                    }
                }
                Text(finding.title).font(.subheadline).multilineTextAlignment(.leading)
            }
        }
    }
}
