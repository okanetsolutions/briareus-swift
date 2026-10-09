// A Laravel Envoyer account (core /settings/envoyer/accounts, an Admin token's): its name, its write-only API token and the
// one project whose clients may use it. Its Envoyer projects, servers and deployments are on that project's board.
import SwiftUI

@MainActor
final class EnvoyerAccountFormModel: ObservableObject {
    let row: JSON
    @Published var label: String
    @Published var repo: String
    @Published var token = ""
    @Published var saving = false
    @Published var error: String?

    init(row: JSON?, defaults: JSON?) {
        let r: JSON = row?.isObject == true ? row! : defaults?.isObject == true ? defaults! : [:]
        self.row = r
        label = r["label"].string ?? ""
        repo = r["repo"].string ?? ""
    }
    var id: Double { row["id"].number ?? 0 }
    var dirty: Bool { label != (row["label"].string ?? "") || repo != (row["repo"].string ?? "") || !token.isEmpty }

    func save() {
        let op = id != 0 ? "update_envoyer_account" : "create_envoyer_account"
        guard Store.shared.supports(op), !saving else { return }
        guard !label.cTrimmed.isEmpty else { error = "Name the account."; return }
        guard !repo.isEmpty else { error = "Choose the project the account is available to."; return }
        guard id != 0 || !token.cTrimmed.isEmpty else { error = "Paste the account's Envoyer API token."; return }
        var body: JSON = ["label": .string(label.cTrimmed), "repo": .string(repo)]
        if !token.cTrimmed.isEmpty { body["token"] = .string(token.cTrimmed) }
        if id != 0 { body["id"] = .number(id) }
        saving = true; error = nil
        Task {
            let r = await boardCall(op, body)
            saving = false
            switch r {
            case .failure(let e): error = e.message ?? e.description
            case .success(let v):
                token = ""
                post(.envoyerAccountsChanged)
                let saved = v["account"].isObject ? v["account"] : v
                Navigator.shared.show(.envoyerAccountSettings(row: saved, defaults: nil))
            }
        }
    }
    func delete() {
        guard id != 0, Store.shared.supports("delete_envoyer_account"),
              Dialogs.confirm("Delete \(row["label"].string ?? "this Envoyer account")?", "Its token is removed: its project can no longer deploy through it.",
                              continueLabel: "Delete", destructive: true) else { return }
        Task {
            let r = await boardCall("delete_envoyer_account", ["id": .number(id)])
            if let e = r.error { error = e.description; return }
            post(.envoyerAccountsChanged)
            Navigator.shared.clear()
        }
    }
}

struct EnvoyerAccountSettingsScreen: View {
    @StateObject private var model: EnvoyerAccountFormModel
    @ObservedObject private var settings = SettingsModel.shared
    @ObservedObject private var store = Store.shared

    init(row: JSON?, defaults: JSON?) { _model = StateObject(wrappedValue: EnvoyerAccountFormModel(row: row, defaults: defaults)) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: model.id != 0 ? (model.row["label"].nonEmpty ?? "Envoyer account") : "New Envoyer account",
                       subtitle: model.id != 0 ? "envoyer.io · \(model.row["repo"].string ?? "")" : "Deploy a project through Laravel Envoyer", buttons: buttons)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let e = model.error { NoticeBox(message: e) }
                    field("Name", "Acme production") { TextField("Acme production", text: $model.label).textFieldStyle(.roundedBorder) }
                    field("API token", model.id != 0 ? "Stored · paste a new one to replace it" : "Paste an Envoyer API token") {
                        SecureField(model.id != 0 ? "Stored · paste a new one to replace it" : "From envoyer.io › Account › API", text: $model.token).textFieldStyle(.roundedBorder)
                    }
                    Text("Give it the deployments:create scope for Deploy to work. The server stores it encrypted and never sends it back.").font(Theme.caption).foregroundStyle(Theme.muted)
                    field("Project", "") {
                        Picker("", selection: $model.repo) {
                            Text("Choose…").tag("")
                            ForEach(settings.projects.list.compactMap { $0["repo"].nonEmpty }, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: 360)
                    }
                    Text("Its Envoyer projects show on that project's board, in an Envoyer tab.").font(Theme.caption).foregroundStyle(Theme.muted)
                }
                .padding(Theme.paneMargin).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in model.save() }
    }
    private var buttons: [HeaderButton] {
        var b = [HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save this Envoyer account (⌘S)",
                              enabled: !model.saving && (model.dirty || model.id == 0), prominent: true) { model.save() }]
        if model.id != 0 && store.supports("delete_envoyer_account") {
            b.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this Envoyer account", destructive: true) { model.delete() })
        }
        return b
    }
    private func field<C: View>(_ title: String, _ hint: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(Theme.footnote).foregroundStyle(Theme.muted); content() }
    }
}
