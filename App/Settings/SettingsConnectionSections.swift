// This device’s connection identity and sign-out controls.
import SwiftUI

struct SettingsConnectionSections: View {
    @EnvironmentObject private var store: Store
    @StateObject private var model = ConnectionSettingsModel()

    var body: some View {
        Group { connection }
        .alert(model.confirm == .revoke ? "Revoke this device token?" : "Forget this connection?",
               isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } }), presenting: model.confirm) { action in
            Button(action == .revoke ? "Revoke and disconnect" : "Forget", role: .destructive) { model.run(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action == .revoke
                 ? "The token stops working on the server and this device disconnects."
                 : "The token and the saved conversations are removed from this device. The token itself keeps working until it is revoked.")
        }
    }

    // MARK: Connection

    @ViewBuilder private var connection: some View {
        Section("Connection") {
            Label { Text(store.server).textSelection(.enabled) } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.ok)
            }
            if let device = store.device {
                LabeledContent("Device", value: device.label)
                LabeledContent("Access", value: settingsPermissionTitle(device.permission))
                LabeledContent("Expires", value: device.expiry.formatted(date: .abbreviated, time: .omitted))
            }
        }
        .listRowBackground(Theme.row)
        if let device = store.device {
            Section("Permitted projects") {
                if device.isAdmin || device.repos.isEmpty {
                    Label("All projects", systemImage: "square.stack.3d.up")
                } else {
                    ForEach(device.repos, id: \.self) { repo in
                        Text(repo).textSelection(.enabled)
                    }
                }
            }
            .listRowBackground(Theme.row)
        }
        Section {
            if store.supports("revoke_token") {
                Button("Revoke token and disconnect", role: .destructive) { model.confirm = .revoke }
            }
            Button("Forget this connection", role: .destructive) { model.confirm = .forget }
            if let error = model.error { ErrorNotice(message: error) }
        } footer: {
            Text("Revoking disables this token on the server. Forgetting removes it and the saved conversations from this device only; revoke it later on the server with `npm run create-token -- --revoke`. Neither action stops running agents.")
        }
        .listRowBackground(Theme.row)
        .disabled(model.busy)
    }

}
