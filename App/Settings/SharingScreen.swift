// Admin sharing grants a member access to a project or registered service.
import SwiftUI

struct SharingScreen: View {
    @StateObject private var model = SharingModel()
    @EnvironmentObject private var store: Store
    @State private var confirming = false

    var body: some View {
        Form {
            if !model.available { Text("Sharing is unavailable on this server or for this token.") }
            else {
                Section {
                    Picker("Resource type", selection: $model.kind) {
                        ForEach(model.kinds) { Text($0.title).tag($0) }
                    }.disabled(model.busy || model.dirty || model.uncertain)
                    Picker("Resource", selection: Binding(get: { model.resourceID }, set: model.selectResource)) {
                        ForEach(model.resources) { Text($0.title).tag($0.id) }
                    }.disabled(model.busy || model.dirty || model.uncertain)
                    if let error = model.error { ErrorNotice(message: error) }
                    if model.busy { ProgressView() }
                    if !model.loaded && !model.busy { Button("Retry") { Task { await model.load() } } }
                } footer: { Text("Admins already have access. Removing a member’s grant takes effect on all their tokens.") }
                if model.loaded {
                    Section("Shared with") {
                        if model.resources.isEmpty { Text("No resources of this type.") }
                        else if model.users.isEmpty { Text("No users are available.") }
                        else {
                            ForEach(model.users) { user in
                                Toggle(isOn: Binding(get: { model.picked.contains(user.id) }, set: { _ in model.toggle(user) })) {
                                    VStack(alignment: .leading) { Text(user.name); Text(user.detail).font(.caption).foregroundStyle(.secondary) }
                                }.disabled(model.busy || model.uncertain || !store.supports("update_shares"))
                            }
                        }
                    }
                    if model.dirty { Button("Discard changes") { model.discard() }.disabled(model.busy) }
                }
                if model.uncertain {
                    Section {
                        Text("The save’s outcome is unknown. Reload the grants before editing again.")
                        Button("Check saved grants") { model.checkOutcome() }
                    }
                }
            }
        }
        .task(id: model.kind) { await model.load() }
        .modifier(SettingsFormChrome(title: "Sharing", dirty: model.dirty, discardMessage: "Discard the unsaved sharing changes?",
                                     saveTitle: "Save", canSave: model.canSave, saving: model.busy, onSave: { confirming = true }))
        .alert("Replace this resource’s sharing grants?", isPresented: $confirming) {
            Button("Save grants") { model.save() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only selected users remain explicitly shared with this resource; unselected members lose access.") }
    }
}
