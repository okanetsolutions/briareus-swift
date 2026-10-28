// What the conversation lists draw around their rows: the Show more row ending a long list, shared by the project and
// All lists, and the project list's findings button.
import SwiftUI

/// The last row of a long list: a button drawing the next page, with how many conversations wait below it.
struct ShowMoreRow: View {
    let hidden: Int
    let more: () -> Void
    var body: some View {
        Button(action: more) {
            Label("Show \(min(hidden, conversationPageSize)) more (\(hidden) not shown)", systemImage: "ellipsis.circle")
        }
    }
}

/// The ⚑ with how many review rounds wait, the count inside the button's bounds: a navigation bar cuts off what hangs
/// outside them.
struct FindingsCountIcon: View {
    let count: Int
    var body: some View {
        Image(systemName: "flag")
            .padding(.horizontal, 8).padding(.vertical, 6)
            .overlay(alignment: .topTrailing) {
                Text(String(count)).font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15).background(Theme.warn, in: Capsule())
            }
    }
}
