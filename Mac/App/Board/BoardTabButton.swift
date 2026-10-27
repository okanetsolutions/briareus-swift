// A tab in the project board, with an underline for the selected list.
import SwiftUI

/// One of `#proj-tabs`: 13px, the open one underlined in the accent, 34px tall.
struct BoardTabButton: View {
    var label: String
    var active: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Text(label).font(Theme.footnote).foregroundStyle(active || hovered ? Theme.ink : Theme.muted)
                .padding(.horizontal, 8).frame(height: 34)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(Theme.accent).frame(height: 2) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
