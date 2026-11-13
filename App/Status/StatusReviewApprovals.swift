// The pull requests waiting on your approval, as sections of the Status list (the Mac's StatusReviewApproval under
// ◉ Status's Waiting on you): each one's review outcome with its security pass (ReviewOutcomeSection, headed by the pull
// request and opening it), then the approvals its risk asks for with what set the risk shown and Approve
// (ReviewApprovalsSection), so a person approves without opening the pull request.
import SwiftUI

struct StatusReviewApprovals: View {
    @ObservedObject var model: StatusApprovalsModel

    var body: some View {
        if let error = model.error { ErrorNotice(message: error).listRowBackground(Theme.row) }
        ForEach(model.items) { item in
            if let pull = item.approvalPull { StatusPullApproval(repo: pull.repo, number: pull.number, title: item.title) }
        }
    }
}

/// One pull request's outcome and approvals, read on their own.
private struct StatusPullApproval: View {
    let title: String
    @StateObject private var model: CodeReviewsModel
    @Environment(\.navigate) private var navigate

    init(repo: String, number: Int, title: String) {
        self.title = title
        _model = StateObject(wrappedValue: CodeReviewsModel(repo: repo, number: number) {
            Task { await StatusApprovalsModel.shared.load() }
        })
    }

    var body: some View {
        Section {
            Button { navigate(.pull(repo: model.repo, number: model.number, stack: nil, summary: nil)) } label: {
                HStack {
                    Label(title, systemImage: "checkmark.seal")
                    Spacer(minLength: 8)
                    Text(model.repo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityHint("Opens the pull request")
            if let error = model.error { ErrorNotice(message: error) }
            if !model.read { ProgressView().frame(maxWidth: .infinity) }
        } header: {
            Text("Approval needed")
        }
        .listRowBackground(Theme.row)
        .task { await model.load() }
        if let outcome = model.outcome { ReviewOutcomeSection(outcome: outcome) }
        if let approvals = model.outcome?.approvals, approvals.shown {
            ReviewApprovalsSection(approvals: approvals, model: model, riskOpen: true)
        }
    }
}
