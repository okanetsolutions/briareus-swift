// Source feedback and the independent assessment shown beside the manual verdict controls.
import SwiftUI

struct FeedbackAssessmentView: View {
    let details: FeedbackAssessmentDetails
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(details.summary).font(.caption).foregroundStyle(details.verified ? Theme.muted : Theme.warn)
            DisclosureGroup(details.sourceTitle) {
                if let source = details.source { MarkdownText(source) }
            }
            DisclosureGroup("Verification evidence") { MarkdownText(details.evidence) }
            MarkdownText(details.reason)
        }
        .textSelection(.enabled)
    }
}
