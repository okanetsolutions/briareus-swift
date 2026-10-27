// The tabs of a board, a project's or every project's: a row of buttons, the open one underlined, over a rule.
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

/// A board's row of tabs over its rule, which reaches the pane's edges past the `Theme.paneMargin` the row is drawn in.
struct BoardTabStrip<Tab: Hashable>: View {
    var labels: [(Tab, String)]
    var active: Tab
    var select: (Tab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(labels, id: \.0) { tab, label in BoardTabButton(label: label, active: active == tab) { select(tab) } }
                Spacer(minLength: 0)
            }
            BoardRule().padding(.horizontal, -Theme.paneMargin)
        }
    }
}
