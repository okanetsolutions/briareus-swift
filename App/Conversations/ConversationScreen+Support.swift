// What the conversation screen leans on that is not its layout: the confirm button's label for each action it asks about,
// and where its transcript opens.
import SwiftUI

/// The confirm button of the dialog an action asks in.
func conversationConfirmLabel(_ action: String) -> String {
    switch action {
    case "delete": return "Delete"
    case "cancel": return "Stop"
    case "close": return "Close"
    case "reopen": return "Reopen"
    case "compact": return "Compact"
    case "clear": return "Clear"
    default: return "Confirm"
    }
}

extension View {
    /// Opens on the latest message; short transcripts still read from the top where the system allows it.
    @ViewBuilder func conversationStartsAtBottom() -> some View {
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset).defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
        } else { defaultScrollAnchor(.bottom) }
    }
}
