// Overruling one code review finding's verdict, under the finding in the Code reviews tab (the iPhone's sheet): Fix,
// Optional, Dismissed or none, and why. Not fixing a finding needs the reason, so Save waits for one (CodeReviewFindingEdit).
import SwiftUI

struct CodeReviewFindingEditor: View {
    @ObservedObject var model: CodeReviewsModel
    @State var edit: CodeReviewFindingEdit
    @FocusState private var focused: Bool
    private let verdicts = CodeReviewVerdict.choices

    var body: some View {
        BoardBox(padding: 10, radius: BriareusRadius.md) { fields }
            .onAppear { focused = true }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verdict").font(Theme.captionSemibold).foregroundStyle(Theme.muted)
            Segments(titles: verdicts.map(CodeReviewVerdict.choiceTitle), selected: verdicts.firstIndex(of: edit.verdict)) { edit.verdict = verdicts[$0] }
            TextField(edit.reasonPrompt, text: $edit.reason, axis: .vertical)
                .lineLimit(2...8).focused($focused).dashField(focused: focused)
            if let error = model.editError { Notice(message: error) }
            HStack(spacing: 8) {
                Button(model.saving == nil ? "Save" : "Saving\u{2026}") { model.save(edit) }
                    .dashButton(.prominent).disabled(!edit.canSave || model.saving != nil)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { model.cancelEdit() }.dashButton(.bordered).disabled(model.saving != nil)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
