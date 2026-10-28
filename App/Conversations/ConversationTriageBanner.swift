// Opens the held review or incoming-feedback assessment from its conversation.
import SwiftUI

struct ConversationTriageBanner: View {
    let triage: JSON
    let open: () -> Void
    var body: some View {
        let count = triage["findings"].count
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "flag.fill").foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(triageTitle(triage)).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(count) finding\(count == 1 ? "" : "s") waiting for a verdict").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("Review").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            .padding(12)
            .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.top, 6)
        .background(Theme.canvas)
    }
}
