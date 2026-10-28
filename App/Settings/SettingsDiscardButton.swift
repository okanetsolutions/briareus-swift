// Reused by settings forms so discarding typed values always asks first.
import SwiftUI

struct SettingsDiscardButton: View {
    var enabled = true
    let action: () -> Void
    @State private var confirming = false
    var body: some View {
        Button("Discard changes") { confirming = true }
            .disabled(!enabled)
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirming) {
                Button("Discard", role: .destructive, action: action)
                Button("Keep editing", role: .cancel) {}
            }
    }
}
