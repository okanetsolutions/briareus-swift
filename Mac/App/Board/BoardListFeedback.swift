// The project board's read and write notices, with progress for initial loads and user refreshes.
import SwiftUI

struct BoardListFeedback: View {
    let error: String?
    let writeError: String?
    let uncertain: Bool
    let loading: Bool
    let loadingText: String

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
        if loading { LoadingNote(text: loadingText).padding(.horizontal, -8) }
    }
}
