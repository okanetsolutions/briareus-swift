// Reused by settings forms so discarding typed values always asks first.
import SwiftUI

struct SettingsDiscardButton: View {
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button("Discard changes") {
            if confirmDiscard("Discard the unsaved changes?") { action() }
        }.dashButton(.plain).disabled(!enabled)
    }
}
