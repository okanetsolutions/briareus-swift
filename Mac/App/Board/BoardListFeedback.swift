// The project board's read and write notices, with progress above its rows throughout a load or reload.
import SwiftUI

struct BoardListFeedback: View {
    let error: String?
    let writeError: String?
    let uncertain: Bool
    let loading: Bool

    var body: some View {
        if let error { Notice(message: error); Spacer().frame(height: 10) }
        if let writeError {
            Notice(message: writeError)
            if uncertain {
                Text("The request may have completed. Refresh (F5) and look for its conversation in the project before starting another agent.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            Spacer().frame(height: 10)
        }
        if loading { LoadingNote(text: "Loading pull requests…").padding(.horizontal, -8) }
    }
}
