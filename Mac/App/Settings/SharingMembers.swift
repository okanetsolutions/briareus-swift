// Read-only catalogs show membership as values; only an advertised write route exposes toggles.
import SwiftUI

struct SharingMembers: View {
    @ObservedObject var model: SharingModel
    @ObservedObject private var store = Store.shared
    var body: some View {
        SectionTitle(title: "Shared with")
        if model.resources.isEmpty { EmptyNote(title: "No resources of this type.") }
        else if model.users.isEmpty { EmptyNote(title: "No users are available.") }
        else {
            ForEach(model.users) { user in
                if store.supports("update_shares") {
                    Toggle(isOn: Binding(get: { model.picked.contains(user.id) }, set: { _ in model.toggle(user) })) {
                        Text("\(user.name) · \(user.detail)").font(Theme.body)
                    }.disabled(model.busy || model.uncertain)
                } else {
                    VStack(alignment: .leading) {
                        LabeledContent(user.name, value: model.membership(user).title).font(Theme.body)
                        Text(user.detail).font(Theme.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}
