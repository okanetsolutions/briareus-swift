// One Forge site, as the Mac's site page (ForgeSiteView.swift) on a phone: its Overview (everything Forge says about it,
// read again), its Deploy script and its Environment (.env), each editable and saved back to Forge through the server's
// proxy (/forge/accounts/{account}/servers/{server}/sites/{site}[/deployment-script|/env]). The .env is a production
// secret: it is read only when asked for with Show .env, and replacing it is confirmed first.
import SwiftUI

private enum ForgeSiteTab: Hashable { case overview, script, env }

@MainActor
private final class ForgeSiteModel: ObservableObject {
    /// The deploy script's and the .env's state: what was read, whether it was, the text being edited.
    struct Draft {
        var saved = ""
        var loaded = false
        var edit = ""
        var error: String?
        /// A save's word that it went through.
        var notice: String?
        var loading = false
        var saving = false
    }
    enum Editor: Int { case script, env }

    let account: Double
    let server: JSON
    @Published private(set) var site: JSON
    @Published var tab = ForgeSiteTab.overview { didSet { tabLoad() } }
    @Published private(set) var siteError: String?
    @Published private(set) var readingSite = false
    @Published private(set) var texts = [Draft(), Draft()]
    @Published var autoSource = false
    private var savedAutoSource = false
    /// The .env was asked for.
    @Published private(set) var envWanted = false

    init(account: Double, server: JSON, site: JSON) {
        self.account = account; self.server = server; self.site = site
    }

    var name: String { site["name"].nonEmpty ?? "Forge site" }
    private var args: JSON { ["account": .number(account), "server": server["id"], "site": site["id"]] }
    var openEditor: Editor? { tab == .script ? .script : tab == .env ? .env : nil }
    func text(_ e: Editor) -> Draft { texts[e.rawValue] }
    func changed(_ e: Editor) -> Bool {
        let t = texts[e.rawValue]
        return t.loaded && (t.edit != t.saved || (e == .script && autoSource != savedAutoSource))
    }
    var anyChanged: Bool { changed(.script) || changed(.env) }
    var saving: Bool { texts[0].saving || texts[1].saving }

    // MARK: Loading

    func siteLoad() async {
        guard !readingSite, Store.shared.supports("forge_site") else { return }
        readingSite = true
        defer { readingSite = false }
        do {
            let r = try await Store.shared.call("forge_site", args)
            if r["site"].isObject { siteError = nil; site = r["site"] } else { siteError = settingsUnexpectedResponse }
        } catch {
            if let text = failure(error) { siteError = text }
        }
    }
    private func textLoad(_ e: Editor) {
        let op = e == .script ? "forge_deploy_script" : "forge_env"
        guard !texts[e.rawValue].loading, Store.shared.supports(op) else { return }
        texts[e.rawValue].error = nil
        texts[e.rawValue].loading = true
        Task {
            defer { texts[e.rawValue].loading = false }
            do {
                let v = try await Store.shared.call(op, args)
                let content = v["content"].string ?? ""
                texts[e.rawValue].saved = content
                texts[e.rawValue].edit = content
                texts[e.rawValue].loaded = true
                if e == .script { autoSource = v["autoSource"].is(true); savedAutoSource = autoSource }
            } catch {
                if let text = failure(error) { texts[e.rawValue].error = text }
            }
        }
    }
    /// What the open tab needs, read once: the script on its first showing, the .env only once asked for.
    private func tabLoad() {
        if tab == .script && !texts[0].loaded { textLoad(.script) }
        if tab == .env && envWanted && !texts[1].loaded { textLoad(.env) }
    }
    func reveal() { envWanted = true; tabLoad() }

    // MARK: Editing

    func binding(_ e: Editor) -> Binding<String> {
        Binding(get: { self.texts[e.rawValue].edit }, set: { v in
            guard v != self.texts[e.rawValue].edit else { return }
            self.texts[e.rawValue].edit = v
            self.texts[e.rawValue].notice = nil
        })
    }
    var autoSourceBinding: Binding<Bool> {
        Binding(get: { self.autoSource }, set: { v in
            self.autoSource = v
            self.texts[0].notice = nil
        })
    }

    // MARK: Saving

    var canSave: Bool {
        guard let e = openEditor else { return false }
        return !texts[e.rawValue].saving && changed(e) && Store.shared.supports(e == .script ? "set_forge_deploy_script" : "set_forge_env")
    }
    /// The .env's is confirmed by the screen first.
    func save() {
        guard let e = openEditor, canSave else { return }
        let op = e == .script ? "set_forge_deploy_script" : "set_forge_env"
        var a = args
        let sent = texts[e.rawValue].edit
        a["content"] = .string(sent)
        if e == .script { a["autoSource"] = .bool(autoSource) }
        let sentAuto = autoSource
        texts[e.rawValue].saving = true
        Task {
            defer { texts[e.rawValue].saving = false }
            do {
                let v = try await Store.shared.call(op, a)
                // Forge's .env answer carries `ok`; false is a refusal, said as one.
                if v["ok"].bool == false { texts[e.rawValue].error = "Forge did not accept the .env."; return }
                texts[e.rawValue].error = nil
                // What was sent is what Forge now holds; the script's answer is Forge's own word on it.
                let content = e == .script ? (v["content"].string ?? sent) : sent
                // What was typed while the save ran stays in the editor, unsaved.
                if texts[e.rawValue].edit == sent { texts[e.rawValue].edit = content }
                texts[e.rawValue].saved = content
                if e == .script { autoSource = v["autoSource"].bool ?? sentAuto; savedAutoSource = autoSource }
                texts[e.rawValue].notice = e == .script ? "Deploy script saved to Forge."
                    : "Forge accepted the .env and writes it to the server shortly. Clear the config cache and restart the queue workers for running code to pick it up."
            } catch {
                if let text = failure(error) { texts[e.rawValue].error = text }
            }
        }
    }

    /// Reads the open tab from Forge again; an editor with changes is left as it is.
    func refresh() async {
        guard let e = openEditor else { await siteLoad(); return }
        if (e == .env && !envWanted) || changed(e) { return }
        texts[e.rawValue] = Draft()
        if e == .script { autoSource = savedAutoSource }
        textLoad(e)
    }

    var discardMessage: String {
        let s = changed(.script), v = changed(.env)
        let what = (s ? "the deploy script" : "") + (s && v ? " and " : "") + (v ? "the .env" : "")
        return "The changes to \(what) of \(name) have not been saved to Forge."
    }

    /// The site's screen went away: the .env leaves memory with it.
    func close() { texts[1] = Draft(); envWanted = false }
}

struct ForgeSiteScreen: View {
    let repo: String
    @StateObject private var model: ForgeSiteModel
    @EnvironmentObject private var store: Store
    @State private var confirmEnv = false

    init(repo: String, account: Double, server: JSON, site: JSON) {
        self.repo = repo
        _model = StateObject(wrappedValue: ForgeSiteModel(account: account, server: server, site: site))
    }

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: $model.tab) {
                    Text("Overview").tag(ForgeSiteTab.overview)
                    if store.supports("forge_deploy_script") { Text(settingsTabTitle("Deploy script", changed: model.changed(.script))).tag(ForgeSiteTab.script) }
                    if store.supports("forge_env") { Text(settingsTabTitle(".env", changed: model.changed(.env))).tag(ForgeSiteTab.env) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text(Forge.joined([model.server["name"].nonEmpty.map { "On \($0)" }, model.site["status"].nonEmpty]))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            switch model.tab {
            case .overview: overview
            case .script: script
            case .env: env
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.siteLoad() }
        .onDisappear { model.close() }
        .modifier(SettingsFormChrome(
            title: model.name, dirty: model.anyChanged, discardMessage: model.discardMessage,
            saveTitle: model.openEditor == .env ? "Save .env" : "Save",
            canSave: model.canSave, saving: model.saving,
            onSave: { if model.openEditor == .env { confirmEnv = true } else { model.save() } }))
        .alert("Replace the .env of \(model.name)?", isPresented: $confirmEnv) {
            Button("Replace .env", role: .destructive) { model.save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Forge writes this file to the server in place of the current one. Running code keeps the old values until the config cache is cleared and the queue workers restart.")
        }
    }

    // MARK: Overview

    /// The site as Forge describes it and its repository, then everything else Forge says about it, as Forge names it
    /// (the deployment trigger URL's token hidden), and Open Site.
    @ViewBuilder private var overview: some View {
        let site = model.site
        if let e = model.siteError { SettingsErrorSection(error: e) }
        Section("Site") {
            field("Domain", site["name"])
            field("Status", site["status"])
            field("URL", site["url"])
            field("Deployment", site["deployment_status"])
            field("Quick deploy", site["quick_deploy"])
            if let url = Forge.siteURL(site).flatMap(URL.init(string:)) {
                Link(destination: url) { Label("Open Site", systemImage: "safari") }
            }
        }
        .listRowBackground(Theme.row)
        if site["repository"].isObject {
            Section("Repository") {
                ForEach(site["repository"].keys, id: \.self) { k in field(Forge.fieldLabel(k), site["repository"][k]) }
            }
            .listRowBackground(Theme.row)
        }
        Section {
            field("Forge id", site["id"])
            let shown: Set<String> = ["name", "status", "url", "deployment_status", "quick_deploy", "repository", "id"]
            ForEach(site.keys.filter { !shown.contains($0) && !site[$0].isObject }, id: \.self) { k in
                field(Forge.fieldLabel(k), site[k], mask: k.lowercased().contains("url"))
            }
        } header: {
            Text("Everything Forge reports")
        } footer: {
            if model.readingSite && model.siteError == nil { Text("Reading the site from Forge\u{2026}") }
        }
        .listRowBackground(Theme.row)
    }

    @ViewBuilder private func field(_ label: String, _ value: JSON, mask: Bool = false) -> some View {
        if let text = Forge.fieldText(value) { SettingsValueRow(label: label, value: mask ? Forge.maskedURL(text) : text) }
    }

    // MARK: Deploy script and .env

    @ViewBuilder private func status(_ e: ForgeSiteModel.Editor) -> some View {
        let t = model.text(e)
        if let error = t.error { SettingsErrorSection(error: error) }
        if let notice = t.notice { Section { SettingsVerdict(text: notice, ok: true) }.listRowBackground(Theme.row) }
    }

    @ViewBuilder private var script: some View {
        status(.script)
        if !model.text(.script).loaded {
            if model.text(.script).error == nil { loading }
        } else {
            Section {
                Toggle("Run with the site\u{2019}s .env loaded", isOn: model.autoSourceBinding).tint(Theme.accent)
                    .disabled(!store.supports("set_forge_deploy_script"))
            }
            .listRowBackground(Theme.row)
            Section {
                editor(.script, editable: store.supports("set_forge_deploy_script"))
            } footer: {
                Text("The commands Forge runs on each deployment of this site, from the site\u{2019}s directory. $FORGE_ variables such as $FORGE_SITE_BRANCH and $FORGE_PHP are set.")
            }
            .listRowBackground(Theme.row)
        }
    }

    @ViewBuilder private var env: some View {
        status(.env)
        if !model.envWanted {
            Section {
                Button { model.reveal() } label: { Label("Show .env", systemImage: "eye") }
            } header: {
                Text("The .env holds production secrets")
            } footer: {
                Text("It is read from Forge only when you ask for it, and shown here in full.")
            }
            .listRowBackground(Theme.row)
        } else if !model.text(.env).loaded {
            if model.text(.env).error == nil { loading }
        } else {
            Section {
                editor(.env, editable: store.supports("set_forge_env"))
            } footer: {
                // Once saved, the save's own note says what happens next.
                if model.text(.env).notice == nil {
                    Text("Saving replaces the whole file. Forge writes it to the server shortly after; it does not clear the config cache or restart queue workers.")
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    private var loading: some View {
        Section { HStack { Spacer(); ProgressView(); Spacer() } }.listRowBackground(Color.clear)
    }

    /// Plain monospaced text, as typed, growing with its lines.
    private func editor(_ e: ForgeSiteModel.Editor, editable: Bool) -> some View {
        PlainTextEditor(text: model.binding(e), editable: editable)
    }
}

/// The deploy script's and the .env's editor: a text view that takes what is typed as it is, with no capitals,
/// corrections, smart quotes or dashes, which would change a shell command or a value.
private struct PlainTextEditor: UIViewRepresentable {
    @Binding var text: String
    var editable: Bool

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func textViewDidChange(_ tv: UITextView) { if parent.text != tv.text { parent.text = tv.text } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        tv.adjustsFontForContentSizeCategory = true
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.spellCheckingType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.text = text
        return tv
    }
    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        tv.isEditable = editable
        if tv.text != text { tv.text = text }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fit.height, 320))
    }
}
