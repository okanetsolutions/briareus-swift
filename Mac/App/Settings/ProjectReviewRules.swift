// The review rules on a project's PR actions tab (the iPhone's ProjectReviewRules): the security pass's policy, publishing
// the review outcome to GitHub, and setting the repository aside for the review benchmark, each with its note. The round
// limit is a box beside the PR author. Fields, choices and notes are SettingsLogic's.
import SwiftUI

struct ProjectReviewRules: View {
    var state: ProjectFormState
    /// Opens a choice field's menu.
    var choose: (ProjectField) -> Void
    var toggle: (ProjectField) -> Void

    var body: some View {
        if state.offered(.securityReview) {
            let def = ProjectField.securityReview.def
            HStack(alignment: .top, spacing: 14) {
                SettingsLabeledSelect(label: def.label, text: def.choiceTitle(state.text(.securityReview)), hint: def.hint) {
                    choose(.securityReview)
                }
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
        check(.enforceOutcome)
        check(.benchmark)
    }

    /// The switch and, when it says anything in its state, its note under it.
    @ViewBuilder private func check(_ f: ProjectField) -> some View {
        if state.offered(f) {
            SettingsCheck(label: f.def.label, on: state.bool(f)) { toggle(f) }.padding(.bottom, 10)
            if let note = f.note(on: state.bool(f)) { SettingsNote(text: note) }
        }
    }
}
