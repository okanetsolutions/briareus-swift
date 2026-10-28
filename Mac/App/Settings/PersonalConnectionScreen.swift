// Personal connections remain available to members with Manage access, without admin settings.
import SwiftUI

struct PersonalConnectionScreen: View {
    @StateObject private var model: PersonalConnectionModel
    init(kind: PersonalConnectionKind) { _model = StateObject(wrappedValue: PersonalConnectionModel(kind: kind)) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: model.kind.title)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.available { EmptyNote(title: "This connection is unavailable on this server or for this token.") }
                    else {
                        Text(model.kind.explanation).font(Theme.footnote).foregroundStyle(Theme.muted)
                        if let status = model.status { Text(status.summary).font(Theme.bodySemibold) }
                        if !model.loaded { LoadingNote() }
                        if let error = model.error { NoticeBox(message: error) }
                        Button("Refresh status") { Task { await model.load() } }.dashButton(.bordered).disabled(model.busy || model.dirty)
                        if model.canConnect { fields }
                        if model.uncertain {
                            NoticeBox(message: "The request’s outcome is unknown. Read the connection status before trying again.")
                            Button("Check connection status") { model.checkOutcome() }.dashButton(.bordered)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(Theme.paneMargin)
            }
        }
        .task { await model.load() }
        .onChange(of: model.dirty) { _, dirty in
            if dirty { guardLeaving { !model.dirty || confirmDiscard("Discard the unsaved connection details?") } }
        }
        .onDisappear { model.discard() }
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.kind == .homeAssistant {
                Text("Home Assistant address").font(Theme.caption)
                TextField("http://homeassistant.local:8123", text: $model.url).textFieldStyle(.plain).modifier(FieldStyle())
            }
            Text("Access token").font(Theme.caption)
            SecureField("Write-only access token", text: $model.token).textFieldStyle(.plain).modifier(FieldStyle())
            HStack {
                Button(model.busy ? "Saving…" : "Save connection") { model.save() }.dashButton(.prominent).disabled(!model.canSave)
                if model.dirty { Button("Discard changes") { model.discard() }.dashButton(.plain) }
                if model.canDisconnect { Button("Disconnect") { disconnect() }.dashButton(.destructive) }
            }
        }.disabled(model.busy || model.uncertain)
    }
    private func disconnect() {
        guard Dialogs.confirm("Disconnect this personal connection?", model.kind.explanation, continueLabel: "Disconnect", destructive: true) else { return }
        model.disconnect()
    }
}
