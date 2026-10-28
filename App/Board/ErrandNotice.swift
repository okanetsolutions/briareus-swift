// An errand outcome, with its repository when shown on a cross-project board.
import SwiftUI

/// What an errand start left to say: why it failed, and whether it may have started anyway.
struct ErrandNotice: View {
    @ObservedObject var runner: ErrandRunner
    var place: String
    var repo: String? = nil
    var body: some View {
        if let e = runner.writeError {
            Section {
                ErrorNotice(message: repo.map { "\($0): \(e)" } ?? e)
                if runner.uncertain {
                    Text("The request may have completed. Look for its conversation \(place) before starting another agent.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("I have checked") { runner.checked() }.font(.callout)
                }
            }
            .listRowBackground(Theme.row)
        }
    }
}
