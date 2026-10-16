// The spinning line under a working conversation's transcript: what the agent is doing, from `workingLineText`.
import SwiftUI

/// The agent at work: the spinner's glyph and "Thinking…", "Queued…", "Starting up…" or the background work it waits on.
struct WorkingIndicator: View {
    let status: String
    let background: [BackgroundTask]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 3 : 0.12)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
            HStack(spacing: 8) {
                Text(reduceMotion ? "\u{273B}" : workingGlyph(tick)).font(.body.weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 16)
                Text(workingLineText(status: status, background: background, tick: tick)).font(.subheadline).foregroundStyle(Theme.accent)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .accessibilityElement().accessibilityLabel(status == "running" && background.isEmpty ? "Agent is working" : workingLineText(status: status, background: background, tick: 0))
    }
}
