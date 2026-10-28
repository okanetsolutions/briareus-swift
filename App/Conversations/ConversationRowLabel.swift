// Conversation rows, shared by the project and All lists.
import SwiftUI

/// A conversation in a list: its mark, its title, and a line of provider, branch, state and age; a ⚑ while a review
/// round waits on it.
struct ConversationRowLabel: View {
    let session: Session
    var working = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ConversationMark(session: session).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                    .foregroundStyle(session.isClosed ? .secondary : .primary)
                Text(session.conversationRowDetail()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if session.isPinned { Image(systemName: "pin.fill").font(.caption).accessibilityLabel("Pinned") }
            if working { ProgressView().controlSize(.small) }
            if session.heldRound != nil {
                Image(systemName: "flag.fill").font(.caption).foregroundStyle(Theme.warn).accessibilityLabel("Findings waiting")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(session.pullBadge ?? "")
    }
}

/// A pull request takes the status dot's place, coloured by its state and checks, as Claude's list shows it; a
/// conversation at work keeps its pulsing dot.
struct ConversationMark: View {
    let session: Session
    var body: some View {
        if let tone = session.pullTone, !session.isActive {
            Image(systemName: "arrow.triangle.pull").font(.caption.weight(.semibold)).foregroundStyle(Self.color(tone))
                .accessibilityHidden(true)
        } else {
            StatusDot(status: session.conversationState == "waiting" ? "queued" : session.status)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
    }
    /// Purple once merged, grey when closed unmerged or a draft; while open, the checks' colour.
    static func color(_ tone: String) -> Color {
        switch tone {
        case "merged": return .purple
        case "closed", "draft": return .secondary
        case "failing": return Theme.danger
        case "pending": return Theme.warn
        default: return Theme.ok
        }
    }
}
