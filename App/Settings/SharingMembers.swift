// Read-only catalogs show membership as values; only an advertised write route exposes toggles.
import SwiftUI

struct SharingMembers: View {
    @ObservedObject var model: SharingModel
    @EnvironmentObject private var store: Store
    var body: some View {
        Section("Shared with") {
            if model.resources.isEmpty { Text("No resources of this type.") }
            else if model.users.isEmpty { Text("No users are available.") }
            else {
                ForEach(model.users) { user in
                    if store.supports("update_shares") {
                        Toggle(isOn: Binding(get: { model.picked.contains(user.id) }, set: { _ in model.toggle(user) })) {
                            VStack(alignment: .leading) { Text(user.name); Text(user.detail).font(.caption).foregroundStyle(.secondary) }
                        }.disabled(model.busy || model.uncertain)
                    } else {
                        VStack(alignment: .leading) {
                            LabeledContent(user.name, value: model.membership(user).title)
                            Text(user.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
