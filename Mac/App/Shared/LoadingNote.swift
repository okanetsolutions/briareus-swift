// The progress indicator and label used while a screen reads its content, including reloads with saved rows on show.
import SwiftUI

struct LoadingNote: View {
    var text = "Loading…"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.footnote).foregroundStyle(Theme.muted)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
