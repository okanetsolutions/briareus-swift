// What the conversation lists draw around their rows: the Show more row ending a long list, shared by the project and
// All lists.
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
