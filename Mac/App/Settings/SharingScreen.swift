// Admin sharing grants a member access to a project or registered service.
import SwiftUI

struct SharingScreen: View {
    @StateObject private var model = SharingModel()
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Sharing")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.paneMargin)
            }
        }
        .task(id: model.kind) { await model.load() }
        .onChange(of: model.dirty) { _, dirty in
            if dirty { guardLeaving { !model.dirty || confirmDiscard("Discard the unsaved sharing changes?") } }
        }
    }
    @ViewBuilder private var content: some View {
        if !model.available { EmptyNote(title: "Sharing is unavailable on this server or for this token.") }
        else {
            Text("Admins already have access. Removing a member’s grant takes effect on all their tokens.").font(Theme.footnote).foregroundStyle(Theme.muted)
            Picker("Resource type", selection: $model.kind) { ForEach(model.kinds) { Text($0.title).tag($0) } }
                .disabled(model.busy || model.dirty || model.uncertain)
            Picker("Resource", selection: Binding(get: { model.resourceID }, set: model.selectResource)) {
                ForEach(model.resources) { Text($0.title).tag($0.id) }
            }.disabled(model.busy || model.dirty || model.uncertain)
            if let error = model.error { NoticeBox(message: error) }
            if model.busy { LoadingNote() }
            if !model.loaded && !model.busy { Button("Retry") { Task { await model.load() } }.dashButton(.bordered) }
            if model.loaded {
                SharingMembers(model: model)
                HStack {
                    if store.supports("update_shares") { Button("Save grants") { save() }.dashButton(.prominent).disabled(!model.canSave) }
                    if model.dirty { SettingsDiscardButton(enabled: !model.busy, action: model.discard) }
                }
            }
            if model.uncertain {
                NoticeBox(message: "The save’s outcome is unknown. Reload the grants before editing again.")
                Button("Check saved grants") { model.checkOutcome() }.dashButton(.bordered)
            }
        }
    }
    private func save() {
        guard Dialogs.confirm("Replace this resource’s sharing grants?", "Only selected users remain explicitly shared; unselected members lose access.", continueLabel: "Save grants") else { return }
        model.save()
    }
}
