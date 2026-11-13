// The human approvals a pull request's risk asks for, under the review outcome on its Code reviews tab (the Mac's
// ReviewApprovalsCard): how many count of how many, what set the risk tier, why the requirement stands as it does, every
// approval on record with whether it counts, and Approve and Withdraw for a token that may record them. The words and
// tones are ReviewOutcomeLogic's and ReviewApprovalsLogic's.
import SwiftUI

struct ReviewApprovalsSection: View {
    let approvals: ReviewApprovals
    @ObservedObject var model: CodeReviewsModel
    @State private var approving = false
    @State private var withdrawing: ReviewApproval?
    @State private var note = ""
    /// Starts with what set the risk shown, as Status does for the approval it asks for.
    var riskOpen = false

    var body: some View {
        Section {
            LabeledContent("Approvals") { Text(approvals.line).foregroundStyle(Theme.color(approvals.tone)) }
            if let explanation = approvals.explanation { Text(explanation).font(.footnote).foregroundStyle(.secondary) }
            ForEach(approvals.listedReasons) { reason in
                Text(reason.message).font(.footnote).foregroundStyle(reason.isNote ? .secondary : Theme.color(reason.tone))
            }
            if !approvals.riskReasons.isEmpty { RiskReasonsGroup(reasons: approvals.riskReasons, open: riskOpen) }
            ForEach(approvals.approvals) { approval in
                ApprovalRow(approval: approval)
                if model.canWithdraw(approval) {
                    Button(role: .destructive) { note = ""; withdrawing = approval } label: {
                        progressLabel("Withdraw \(approval.who)'s approval", "arrow.uturn.backward", model.isWithdrawing(approval))
                    }
                    .disabled(model.busy)
                }
            }
            if let error = model.approvalError { ErrorNotice(message: error) }
            if model.canApprove {
                Button { note = ""; approving = true } label: { progressLabel("Approve this revision", "checkmark.seal", model.isApproving) }
                    .disabled(model.busy)
            }
        } header: {
            Text("Approvals")
        }
        .listRowBackground(Theme.row)
        .alert("Approve this revision?", isPresented: $approving) {
            TextField("Note (optional)", text: $note)
            Button("Approve") { model.approve(note: String(note.prefix(ReviewApprovalWrite.noteLimit))) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(approvals.approveConsequence)
        }
        .alert("Withdraw this approval?", isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }),
               presenting: withdrawing) { approval in
            TextField("Why (optional)", text: $note)
            Button("Withdraw", role: .destructive) { model.withdraw(approval, note: String(note.prefix(ReviewApprovalWrite.noteLimit))) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(ReviewApproval.withdrawConsequence)
        }
    }

    private func progressLabel(_ title: String, _ symbol: String, _ busy: Bool) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            if busy { Spacer(); ProgressView() }
        }
    }
}

/// What set the change's risk tier, folded.
private struct RiskReasonsGroup: View {
    let reasons: [RiskReason]
    @State private var open: Bool
    init(reasons: [RiskReason], open: Bool) { self.reasons = reasons; _open = State(initialValue: open) }
    var body: some View {
        DisclosureGroup("What set the risk", isExpanded: $open) {
            ForEach(reasons) { reason in
                VStack(alignment: .leading, spacing: 2) {
                    if let tier = reason.tier { Text("\(tier) risk").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(reason.message).font(.footnote)
                }
            }
        }
    }
}

/// One approval on record: who, whether it counts (or why not), where and for which head, when, and its note.
private struct ApprovalRow: View {
    let approval: ReviewApproval
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Label(approval.who, systemImage: approval.symbol).foregroundStyle(Theme.color(approval.tone))
                Spacer(minLength: 8)
                if let at = approval.at { Text(formatRelative(at)).font(.caption).foregroundStyle(.secondary) }
            }
            Text([approval.state, approval.detail].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                .font(.caption).foregroundStyle(.secondary)
            if let note = approval.note { Text(note).font(.footnote).textSelection(.enabled) }
            if let why = approval.withdrawLine { Text(why).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .accessibilityElement(children: .combine)
    }
}
