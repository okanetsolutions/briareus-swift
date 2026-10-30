// A pull request's Code reviews tab (`GET /pulls/{n}/code-reviews`), as the Mac's: every stored review, newest first, a
// section each with its status, whether it was handled, when it ran, what it ran on and its counts, the conversation that
// ran it, its summary, then its findings with their verdicts. A token that may write marks a stopped review handled or
// reopens it, and overrules a finding's verdict in CodeReviewFindingEditor. The words and tones are CodeReviewLogic's.
import SwiftUI

/// The reviews as sections of the pull request's list.
struct PullCodeReviewsTab: View {
    @ObservedObject var model: CodeReviewsModel

    var body: some View {
        let reviews = model.reviews, error = model.error
        if let message = model.notice {
            Section { ErrorNotice(message: message) }.listRowBackground(Theme.row)
        }
        if reviews.isEmpty {
            if !model.read && error == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if error == nil {
                ContentUnavailableView("No code reviews", systemImage: "checklist",
                                       description: Text("Reviews run on this pull request show here with their findings."))
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        } else {
            ForEach(reviews) { CodeReviewSection(review: $0, model: model) }
        }
    }
}

/// One review: its heading, Mark handled or Reopen, summary and findings.
private struct CodeReviewSection: View {
    let review: CodeReview
    @ObservedObject var model: CodeReviewsModel
    @Environment(\.navigate) private var navigate

    var body: some View {
        Section {
            CodeReviewHeading(review: review)
            if let id = review.openableSessionID {
                Button { navigate(.conversation(id: id, session: nil)) } label: {
                    Label("Open session", systemImage: "bubble.left.and.bubble.right")
                }
            }
            if let action = model.handlingAction(for: review) { HandlingButton(review: review, action: action, model: model) }
            if let summary = review.summary.map(visibleMarkdown), !summary.isEmpty {
                DisclosureGroup("Summary") { MarkdownText(summary).font(.callout) }
            }
            let editable = model.canEdit(review)
            ForEach(review.findings) { finding in
                CodeReviewFindingRow(finding: finding, edit: editable ? { model.edit(finding, of: review) } : nil)
            }
        }
        .listRowBackground(Theme.row)
    }
}

/// Mark handled, or Reopen a handled review; a spinner while it is saved.
private struct HandlingButton: View {
    let review: CodeReview
    let action: CodeReviewHandlingAction
    @ObservedObject var model: CodeReviewsModel

    var body: some View {
        Button { model.setHandled(review) } label: {
            HStack {
                Label(action.title, systemImage: action.symbol)
                if model.isSaving(review) { Spacer(); ProgressView() }
            }
        }
        .disabled(model.saving != nil)
    }
}

/// The status in its tone, the date, what it ran on and the counts.
private struct CodeReviewHeading: View {
    let review: CodeReview
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BoardBadge(text: review.status.title, systemImage: nil, color: Theme.color(review.status.tone))
                if let handling = review.handling {
                    BoardBadge(text: handling.title, systemImage: nil, color: Theme.color(handling.tone))
                }
                if let at = review.createdAt { Text(formatRelative(at)).font(.caption).foregroundStyle(.secondary) }
            }
            if !review.meta.isEmpty { Text(review.meta).font(.caption).foregroundStyle(.secondary) }
            Text(review.counts.line).font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A finding folded to its badges and title; open, where it is, what it says, why it got its verdict, and Change verdict
/// when `edit` is given.
private struct CodeReviewFindingRow: View {
    let finding: CodeReviewFinding
    let edit: (() -> Void)?
    var body: some View {
        DisclosureGroup {
            if let location = finding.location {
                Text(location).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let body = finding.body.map(visibleMarkdown), !body.isEmpty { MarkdownText(body).font(.callout) }
            if let reason = finding.comments, !reason.isEmpty {
                Text(reason).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let edit { Button("Change verdict", systemImage: "pencil", action: edit) }
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
