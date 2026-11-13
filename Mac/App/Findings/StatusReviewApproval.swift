// A `review-approval` item of ◉ Status's Waiting on you list, read out in place (the iPhone's StatusReviewApprovals): the
// pull request's review outcome with its security pass (ReviewOutcomeCard), then the approvals its risk asks for with
// what set the risk shown and Approve (ReviewApprovalsCard), so a person approves without opening the pull request.
// Its own CodeReviewsModel reads `code_reviews`; once a write lands, the attention inbox is read again.
import SwiftUI

struct StatusReviewApproval: View {
    @StateObject private var model: CodeReviewsModel

    init(repo: String, number: Int) {
        _model = StateObject(wrappedValue: CodeReviewsModel(repo: repo, number: number) {
            Task { _ = await AttentionModel.shared.load() }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = model.error { Notice(message: e) }
            if let outcome = model.outcome { ReviewOutcomeCard(outcome: outcome) }
            if let approvals = model.outcome?.approvals, approvals.shown {
                ReviewApprovalsCard(approvals: approvals, model: model, riskOpen: true)
            }
            if !model.read { LoadingNote(text: "Loading the review\u{2026}") }
        }
        .task { await model.load() }
    }
}
