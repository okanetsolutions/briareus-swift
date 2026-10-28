// Toolbar and unsaved-change guard shared by native settings forms.
import SwiftUI

/// What a settings form's toolbar and guard need: whether it holds unsaved changes, what to say before they go, and its
/// actions.
struct SettingsFormChrome: ViewModifier {
    var title: String
    var dirty: Bool
    var discardMessage: String
    var saveTitle: String
    var canSave: Bool
    var saving: Bool
    var onSave: () -> Void
    var showsSave = true
    /// Clone and Delete, for a saved row; nil hides each.
    var cloneTitle: String?
    var onClone: (() -> Void)?
    var deleteTitle: String?
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLeave = false

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // With changes not saved, going back asks first, and the edge swipe that would skip the question is off.
            .navigationBarBackButtonHidden(dirty)
            .toolbar {
                if dirty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { confirmLeave = true } label: {
                            HStack(spacing: 4) { Image(systemName: "chevron.backward").fontWeight(.semibold); Text("Back") }
                        }
                        .accessibilityLabel("Back")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if onClone != nil || onDelete != nil {
                        Menu {
                            if let onClone { Button(cloneTitle ?? "Clone", systemImage: "plus.square.on.square", action: onClone) }
                            if let onDelete { Button(deleteTitle ?? "Delete", systemImage: "trash", role: .destructive, action: onDelete) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                        .disabled(saving)
                    }
                    if showsSave {
                        Button(action: onSave) {
                            if saving { ProgressView() } else { Text(saveTitle).fontWeight(.semibold) }
                        }
                        .disabled(!canSave)
                        .accessibilityLabel(saving ? "Saving" : saveTitle)
                    }
                }
            }
            .alert("Discard unsaved changes?", isPresented: $confirmLeave) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(discardMessage)
            }
    }
}
