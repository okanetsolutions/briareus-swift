// Overruling one code review finding's verdict, under the finding in the Code reviews tab (the iPhone's sheet): Fix,
// Optional, Dismissed or none, how well it is established, and why. Not fixing a finding needs the reason and the evidence
// the review outcome asks, so Save waits for them (CodeReviewFindingEdit).
import SwiftUI

struct CodeReviewFindingEditor: View {
    @ObservedObject var model: CodeReviewsModel
    @State var edit: CodeReviewFindingEdit
    @FocusState private var focused: Bool
    private let verdicts = CodeReviewVerdict.choices
    private let levels = CodeReviewVerification.choices

    var body: some View {
        BoardBox(padding: 10, radius: BriareusRadius.md) { fields }
            .onAppear { focused = true }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verdict").font(Theme.captionSemibold).foregroundStyle(Theme.muted)
            Segments(titles: verdicts.map(CodeReviewVerdict.choiceTitle), selected: verdicts.firstIndex(of: edit.verdict)) { edit.verdict = verdicts[$0] }
            Text("Evidence").font(Theme.captionSemibold).foregroundStyle(Theme.muted)
            Segments(titles: levels.map(CodeReviewVerification.choiceTitle), selected: levels.firstIndex(of: edit.verification)) { edit.verification = levels[$0] }
            if let hint = edit.verificationHint { Text(hint).font(Theme.footnote).foregroundStyle(Theme.muted) }
            TextField(edit.reasonPrompt, text: $edit.reason, axis: .vertical)
                .lineLimit(2...8).focused($focused).dashField(focused: focused)
            if let hint = edit.reasonHint { Text(hint).font(Theme.footnote).foregroundStyle(Theme.muted) }
            if let error = model.editError { Notice(message: error) }
            HStack(spacing: 8) {
                Button(model.busy ? "Saving\u{2026}" : "Save") { model.save(edit) }
                    .dashButton(.prominent).disabled(!model.canSave(edit) || model.busy)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { model.cancelEdit() }.dashButton(.bordered).disabled(model.busy)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
