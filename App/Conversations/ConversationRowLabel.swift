// A conversation's row in the project's list, drawn from Core's ConversationRow.
import SwiftUI

/// A conversation in a list: its mark, its title, and a line of provider, branch, state and age. Equatable on its row's
/// values, so a live update redraws only the rows that changed.
struct ConversationRowLabel: View, Equatable {
    let row: ConversationRow
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ConversationMark(dot: row.dot, tone: row.markTone).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.body.weight(.medium)).lineLimit(2)
                    .foregroundStyle(row.closed ? .secondary : .primary)
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if row.pinned { Image(systemName: "pin.fill").font(.caption).accessibilityLabel("Pinned") }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.pullBadge ?? "")
    }
}

/// A pull request takes the status dot's place, coloured by its state and checks (`tone`, Core's `markTone`), as
/// Claude's list shows it; a conversation at work keeps its dot.
struct ConversationMark: View {
    let dot: String
    let tone: String?
    var body: some View {
        if let tone {
            Image(systemName: "arrow.triangle.pull").font(.caption.weight(.semibold)).foregroundStyle(Self.color(tone))
                .accessibilityHidden(true)
        } else {
            StatusDot(status: dot)
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
