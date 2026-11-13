// The review rules on a project's PR actions tab (the Mac's ProjectReviewRules): the security pass's policy, publishing
// the review outcome to GitHub, and setting the repository aside for the review benchmark, each with its note. The round
// limit is a box beside the PR author. Fields, choices and notes are SettingsLogic's.
import SwiftUI

struct ProjectReviewRules: View {
    let state: ProjectFormState
    let text: (ProjectField) -> Binding<String>
    let toggle: (ProjectField) -> Binding<Bool>

    var body: some View {
        if state.offered(.securityReview) || state.offered(.enforceOutcome) {
            Section {
                if state.offered(.securityReview) {
                    let def = ProjectField.securityReview.def
                    Picker(def.label, selection: text(.securityReview)) {
                        ForEach(def.choices, id: \.value) { Text($0.title).tag($0.value) }
                        let current = state.text(.securityReview)
                        if !def.choices.contains(where: { $0.value == current }) { Text(def.choiceTitle(current)).tag(current) }
                    }
                }
                check(.enforceOutcome)
            } header: {
                Text("Review outcome")
            } footer: {
                let security = state.offered(.securityReview) ? ProjectField.securityReview.def.hint : nil
                let enforce = state.offered(.enforceOutcome) ? ProjectField.enforceOutcome.note(on: state.bool(.enforceOutcome)) : nil
                Text([security, enforce].compactMap { $0 }.joined(separator: "\n\n"))
            }
            .listRowBackground(Theme.row)
        }
        if state.offered(.benchmark) {
            Section { check(.benchmark) } footer: {
                if let note = ProjectField.benchmark.note(on: state.bool(.benchmark)) { Text(note) }
            }
            .listRowBackground(Theme.row)
        }
    }

    @ViewBuilder private func check(_ f: ProjectField) -> some View {
        if state.offered(f) { Toggle(isOn: toggle(f)) { Text(f.def.label) }.tint(Theme.accent) }
    }
}
