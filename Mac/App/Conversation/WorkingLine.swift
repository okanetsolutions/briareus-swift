// The spinning line under a working conversation's transcript: what the agent is doing, from `workingLineText`.
import SwiftUI

/// The agent at work: the spinner's glyph in the accent and "Thinking…", "Queued…", "Starting up…" or the background work it
/// waits on.
struct WorkingLine: View {
    var status: String
    var background: [BackgroundTask]
    var answered: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
            HStack(spacing: 8) {
                Text(workingGlyph(tick)).font(Theme.bodySemibold).foregroundStyle(Theme.accent).frame(width: 16)
                Text(verbatim: workingLineText(status: status, background: background, answered: answered, tick: tick)).font(Theme.footnote).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(height: 24)
        }
    }
}
