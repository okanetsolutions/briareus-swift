// What the project's conversation list draws around its rows: the Show more row ending a long list.
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
