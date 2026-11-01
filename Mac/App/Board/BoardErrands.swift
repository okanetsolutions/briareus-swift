// The board's errands as a row and the pull request screen draw them: the glyph before each errand's label (emoji that
// mirror the Windows client), the label itself, which errands a row offers, and the run-loop hop a dialog-opening errand
// starts through.
import SwiftUI

/// The glyph before an errand's label.
func actionIcon(_ id: String) -> String {
    switch id {
    case "run": return "▶"
    case "review": return "⌕"
    case "solve-conflicts": return "🔀"
    case "fix-checks": return "🧪"
    case "implement-feedback": return "🛠"
    case "test-sheet": return "📋"
    case "test-run": return "🎬"
    case "pr-body-summary": return "✎"
    case "delete-self-comments": return "🧹"
    default: return ""
    }
}
/// An errand button's label, `glyph label` as C writes it (`"%s %s"` in one 13px run, the line centred in the button). The
/// glyph is drawn as its own 13px run centred on the label's line: inline, Apple Color Emoji's fallback box hangs 3pt under
/// the baseline, which drops the emoji (🧹 🧪 💬 🔀) below the words, where Segoe UI Emoji sits on the line.
struct ErrandLabel: View {
    var id: String
    var label: String
    var body: some View {
        let icon = actionIcon(id)
        HStack(alignment: .center, spacing: 4) {
            if !icon.isEmpty { Text(verbatim: icon).font(Theme.footnote) }
            Text(verbatim: label).font(Theme.footnote).truncationMode(.tail)
        }
        .lineLimit(1)
    }
}
/// The errands this app can start on a row: what the server offers for it, less what the token or server lacks.
@MainActor
func rowActions(catalog: JSON, pull: PullSummary?, failedChecks: Int) -> [BoardAction] {
    BoardAction.startable(catalog: catalog, pull: pull, failedChecks: failedChecks, canManage: Store.shared.canManage,
                          supports: { Store.shared.supports($0) })
}
/// Runs `body` from the run loop rather than where it was called. SwiftUI runs a button's action inside a block on the main
/// queue, and a SwiftUI dialog run modally from there takes no typing: its text box waits on the main queue, which waits
/// for the dialog. Errands and edits that open one start through this.
@MainActor
func afterThisEvent(_ body: @escaping @MainActor () -> Void) {
    RunLoop.main.perform { MainActor.assumeIsolated(body) }
}
