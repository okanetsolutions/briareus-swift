// Personal GitHub and Home Assistant connections, independent of admin server settings.
import SwiftUI

struct PersonalConnectionScreen: View {
    @StateObject private var model: PersonalConnectionModel
    @State private var disconnecting = false
    init(kind: PersonalConnectionKind) { _model = StateObject(wrappedValue: PersonalConnectionModel(kind: kind)) }

    var body: some View {
        Form {
            if !model.available { Text("This connection is unavailable on this server or for this token.") }
            else {
                Section {
                    if let status = model.status { Text(status.summary) }
                    if !model.loaded { ProgressView() }
                    if let error = model.error { ErrorNotice(message: error) }
                    Button("Refresh status") { Task { await model.load() } }.disabled(model.busy)
                } footer: { Text(model.kind.explanation) }
                if model.canConnect {
                    Section("Connection") {
                        if model.kind == .homeAssistant {
                            TextField("Home Assistant address", text: $model.url).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        SecureField("Access token", text: $model.token).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(model.busy ? "Saving…" : "Save connection") { model.save() }.disabled(!model.canSave)
                        if model.dirty { SettingsDiscardButton(enabled: !model.busy, action: model.discard) }
                        if model.canDisconnect { Button("Disconnect", role: .destructive) { disconnecting = true }.disabled(model.busy || model.uncertain) }
                    }
                    .disabled(model.busy || model.uncertain)
                }
                if model.uncertain {
                    Section {
                        Text("The request’s outcome is unknown. Read the connection status before trying again.")
                        Button("Check connection status") { model.checkOutcome() }
                    }
                }
            }
        }
        .navigationTitle(model.kind.title)
        .task { await model.load() }
        .onDisappear { model.discard() }
        .alert("Disconnect this personal connection?", isPresented: $disconnecting) {
            Button("Disconnect", role: .destructive) { model.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(model.kind.explanation) }
        .modifier(SettingsFormChrome(title: model.kind.title, dirty: model.dirty, discardMessage: "Discard the unsaved connection details?",
                                     saveTitle: "Save", canSave: model.canSave, saving: model.busy, onSave: model.save, showsSave: model.canConnect))
    }
}
