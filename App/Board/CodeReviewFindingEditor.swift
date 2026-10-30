// The sheet that overrules one code review finding's verdict (the Mac's inline CodeReviewFindingEditor): Fix, Optional,
// Dismissed or none, and why. Not fixing a finding needs the reason, so Save waits for one (CodeReviewFindingEdit).
import SwiftUI

extension View {
    /// The verdict editor, as a sheet over the pull request while a finding is being edited.
    func codeReviewEditor(_ model: CodeReviewsModel) -> some View { modifier(CodeReviewEditorSheet(model: model)) }
}

private struct CodeReviewEditorSheet: ViewModifier {
    @ObservedObject var model: CodeReviewsModel
    func body(content: Content) -> some View {
        content.sheet(item: $model.editing) { CodeReviewFindingEditor(model: model, edit: $0) }
    }
}

private struct CodeReviewFindingEditor: View {
    @ObservedObject var model: CodeReviewsModel
    @State var edit: CodeReviewFindingEdit
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(edit.title).font(.subheadline)
                    Picker("Verdict", selection: $edit.verdict) {
                        ForEach(CodeReviewVerdict.choices, id: \.self) { Text(CodeReviewVerdict.choiceTitle($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Verdict")
                }
                .listRowBackground(Theme.row)
                Section {
                    TextField(edit.reasonPrompt, text: $edit.reason, axis: .vertical).lineLimit(3...10)
                    if let error = model.editError { ErrorNotice(message: error) }
                } header: {
                    Text("Reason")
                } footer: {
                    if edit.needsReason { Text("A finding left unfixed says why.") }
                }
                .listRowBackground(Theme.row)
            }
            .scrollContentBackground(.hidden).background(Theme.canvas)
            .navigationTitle("Change verdict").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.saving != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    if model.saving != nil {
                        ProgressView()
                    } else {
                        Button("Save") { model.save(edit) }.bold().disabled(!edit.canSave)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.saving != nil)
    }
}
