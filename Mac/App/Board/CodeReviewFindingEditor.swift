// Overruling one code review finding's verdict, under the finding in the Code reviews tab (the iPhone's sheet): Fix,
// Optional, Dismissed or none, and why. Not fixing a finding needs the reason, so Save waits for one (CodeReviewFindingEdit).
import SwiftUI

struct CodeReviewFindingEditor: View {
    @ObservedObject var model: CodeReviewsModel
    @State var edit: CodeReviewFindingEdit
    @FocusState private var focused: Bool
    /// The choices in the order the segments show them; nil leaves the finding unverified.
    private let verdicts: [CodeReviewVerdict?] = CodeReviewVerdict.allCases.map(Optional.some) + [nil]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verdict").font(Theme.captionSemibold).foregroundStyle(Theme.muted)
            Segments(titles: verdicts.map { $0?.title ?? "None" }, selected: verdicts.firstIndex(of: edit.verdict)) { edit.verdict = verdicts[$0] }
            TextField(edit.needsReason ? "Why it will not be fixed" : "Why the verdict is what it is", text: $edit.reason, axis: .vertical)
                .lineLimit(2...8).focused($focused).dashField(focused: focused)
            if let error = model.saveError { Notice(message: error) }
            HStack(spacing: 8) {
                Button(model.saving == nil ? "Save" : "Saving\u{2026}") { model.save(edit) }
                    .dashButton(.prominent).disabled(!edit.canSave || model.saving != nil)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { model.cancelEdit() }.dashButton(.bordered).disabled(model.saving != nil)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: BriareusRadius.md).fill(Theme.raise))
        .onAppear { focused = true }
    }
}
