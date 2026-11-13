// The human approvals a pull request's risk asks for, under the review outcome on its Code reviews tab (the iPhone's
// ReviewApprovalsSection): how many count of how many, what set the risk tier, why the requirement stands as it does,
// every approval on record with whether it counts, and Approve and Withdraw for a token that may record them, each with
// an optional note in a form under it. The words and tones are ReviewOutcomeLogic's and ReviewApprovalsLogic's.
import SwiftUI

struct ReviewApprovalsCard: View {
    var approvals: ReviewApprovals
    @ObservedObject var model: CodeReviewsModel
    /// The open note form: `approve`, or `approval:<id>` for a withdrawal; nil when none is open.
    @State private var form: String?
    @State private var showRisk = false

    var body: some View {
        BoardBox(padding: 12, radius: BriareusRadius.lg) {
            HStack(spacing: 8) {
                Text("Approvals").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                Text(approvals.line).font(Theme.footnote).foregroundStyle(Theme.color(approvals.tone)).lineLimit(1)
                Spacer(minLength: 8)
                if model.canApprove && form != "approve" {
                    Button { form = "approve" } label: { Label("Approve", systemImage: "checkmark.seal") }
                        .dashButton(.bordered).disabled(model.busy)
                }
            }
            if let explanation = approvals.explanation {
                Text(explanation).font(Theme.footnote).foregroundStyle(Theme.muted).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(approvals.listedReasons) { reason in
                Text(reason.message).font(Theme.footnote).padding(.top, 2)
                    .foregroundStyle(reason.isNote ? Theme.muted : Theme.color(reason.tone))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !approvals.riskReasons.isEmpty { RiskReasonList(reasons: approvals.riskReasons, open: $showRisk).padding(.top, 8) }
            if form == "approve" {
                ApprovalNoteForm(prompt: "Note (optional)", action: "Approve this revision", busy: model.isApproving,
                                 destructive: false, disabled: model.busy) { note in
                    model.approve(note: note) { if $0 { form = nil } }
                } cancel: { form = nil }
                .padding(.top, 10)
            }
            if !approvals.approvals.isEmpty {
                BoardRule().padding(.vertical, 10)
                approvalList
            }
            if let error = model.approvalError { Notice(message: error).padding(.top, 8) }
        }
    }

    private var approvalList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(approvals.approvals) { approval in
                let key = "approval:\(approval.id)"
                ApprovalLine(approval: approval, canWithdraw: model.canWithdraw(approval) && form != key, busy: model.busy) {
                    form = key
                }
                if form == key {
                    ApprovalNoteForm(prompt: "Why (optional)", action: "Withdraw approval", busy: model.isWithdrawing(approval),
                                     destructive: true, disabled: model.busy) { note in
                        model.withdraw(approval, note: note) { if $0 { form = nil } }
                    } cancel: { form = nil }
                    .padding(.leading, 22)
                }
            }
        }
    }
}

/// What set the change's risk tier, folded under a disclosure line.
private struct RiskReasonList: View {
    var reasons: [RiskReason]
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(Theme.caption2).foregroundStyle(Theme.muted).frame(width: 16)
                    Text("What set the risk").font(Theme.footnote).foregroundStyle(Theme.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
            if open {
                ForEach(reasons) { reason in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let tier = reason.tier { Badge(text: tier, color: Theme.muted) }
                        Text(reason.message).font(Theme.footnote).foregroundStyle(Theme.ink).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }
}

/// One approval on record: who, whether it counts (or why not), where and for which head, when, its note, and Withdraw.
private struct ApprovalLine: View {
    var approval: ReviewApproval
    var canWithdraw: Bool
    var busy: Bool
    var withdraw: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: approval.symbol).font(Theme.footnote).foregroundStyle(Theme.color(approval.tone)).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(approval.who).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                    Text(approval.state).font(Theme.footnote).foregroundStyle(Theme.color(approval.tone)).lineLimit(2)
                }
                let meta = [approval.detail, approval.at.map { formatEventTime($0) } ?? ""].filter { !$0.isEmpty }
                if !meta.isEmpty { Text(meta.joined(separator: " \u{00B7} ")).font(Theme.caption).foregroundStyle(Theme.muted) }
                if let note = approval.note {
                    Text(note).font(Theme.footnote).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let why = approval.withdrawLine {
                    Text(why).font(Theme.footnote).foregroundStyle(Theme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if canWithdraw {
                Button("Withdraw", action: withdraw).dashButton(.bordered).disabled(busy)
            }
        }
    }
}

/// An optional note and the button that sends it, for approving or withdrawing.
private struct ApprovalNoteForm: View {
    var prompt: String
    var action: String
    var busy: Bool
    var destructive: Bool
    /// Another save is under way, so neither button may be pressed.
    var disabled: Bool
    var send: (String) -> Void
    var cancel: () -> Void
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(prompt, text: $note, axis: .vertical)
                .lineLimit(1...4).focused($focused).dashField(focused: focused)
                .onChange(of: note) { _, v in if v.count > ReviewApprovalWrite.noteLimit { note = String(v.prefix(ReviewApprovalWrite.noteLimit)) } }
            HStack(spacing: 8) {
                Button(busy ? "Saving\u{2026}" : action) { send(note) }
                    .dashButton(destructive ? .destructive : .prominent).disabled(disabled)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel", action: cancel).dashButton(.bordered).disabled(disabled)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { focused = true }
    }
}
