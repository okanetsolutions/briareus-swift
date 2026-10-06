// One Forge site inside a project's Forge tab, in place of the server's list of sites (the Windows client's forge_site.c):
// its Overview (everything Forge says about it, read again), its Deploy script and its Environment (.env), each editable and
// saved back to Forge through the server's proxy (/forge/accounts/{account}/servers/{server}/sites/{site}[/deployment-script
// |/env]). The .env is a production secret: it is read only when asked for, and replacing it is confirmed first.
import AppKit
import SwiftUI

enum ForgeSiteTab: Int { case overview, script, env }

@MainActor
final class ForgeSiteModel: ObservableObject {
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
    @Published var tab = ForgeSiteTab.overview
    @Published private(set) var siteError: String?
    @Published private(set) var readingSite = false
    @Published private(set) var texts = [Draft(), Draft()]
    @Published var autoSource = false
    private var savedAutoSource = false
    /// The .env was asked for.
    @Published private(set) var envWanted = false
    private var closed = false

    init(account: Double, server: JSON, site: JSON) {
        self.account = account; self.server = server; self.site = site
        siteLoad()
    }

    var name: String { site["name"].nonEmpty ?? "Forge site" }
    private var args: JSON {
        ["account": .number(account), "server": server["id"], "site": site["id"]]
    }
    var openEditor: Editor? { tab == .script ? .script : tab == .env ? .env : nil }
    func text(_ e: Editor) -> Draft { texts[e.rawValue] }
    func changed(_ e: Editor) -> Bool {
        let t = texts[e.rawValue]
        return t.loaded && (t.edit != t.saved || (e == .script && autoSource != savedAutoSource))
    }
    var anyChanged: Bool { changed(.script) || changed(.env) }

    // MARK: - Loading

    private func siteLoad() {
        guard !readingSite, Store.shared.supports("forge_site") else { return }
        readingSite = true
        Task {
            let r = await boardCall("forge_site", args)
            readingSite = false
            if r.error?.kind == .cancelled { return }
            if let s = r.value?["site"], s.isObject { siteError = nil; site = s } else { siteError = r.error?.description ?? unexpectedResponse }
        }
    }
    private func textLoad(_ e: Editor) {
        let op = e == .script ? "forge_deploy_script" : "forge_env"
        guard !texts[e.rawValue].loading, Store.shared.supports(op) else { return }
        texts[e.rawValue].error = nil
        texts[e.rawValue].loading = true
        Task {
            let r = await boardCall(op, args)
            texts[e.rawValue].loading = false
            if closed { return }
            switch r {
            case .failure(let err): if err.kind != .cancelled { texts[e.rawValue].error = err.description }
            case .success(let v):
                let content = v["content"].string ?? ""
                texts[e.rawValue].saved = content
                texts[e.rawValue].edit = content
                texts[e.rawValue].loaded = true
                if e == .script { autoSource = v["autoSource"].is(true); savedAutoSource = autoSource }
            }
        }
    }
    /// What the open tab needs, read once: the script on its first showing, the .env only once asked for.
    private func tabLoad() {
        if tab == .script && !texts[0].loaded { textLoad(.script) }
        if tab == .env && envWanted && !texts[1].loaded { textLoad(.env) }
    }
    func select(_ t: ForgeSiteTab) { tab = t; tabLoad() }
    func reveal() { envWanted = true; tabLoad() }

    // MARK: - Editing

    func binding(_ e: Editor) -> Binding<String> {
        Binding(get: { self.texts[e.rawValue].edit }, set: { v in
            guard v != self.texts[e.rawValue].edit else { return }
            self.texts[e.rawValue].edit = v
            self.edited(e)
        })
    }
    func toggleAutoSource() { autoSource.toggle(); edited(.script) }
    private func edited(_ e: Editor) {
        texts[e.rawValue].notice = nil
        // Another project, chosen in the sidebar, asks first while there are unsaved changes.
        if anyChanged { guardLeaving { [weak self] in self?.canLeave() ?? true } }
    }

    // MARK: - Saving

    var canSave: Bool {
        guard let e = openEditor else { return false }
        return !texts[e.rawValue].saving && changed(e) && Store.shared.supports(e == .script ? "set_forge_deploy_script" : "set_forge_env")
    }
    func save() {
        guard let e = openEditor, canSave else { return }
        let op = e == .script ? "set_forge_deploy_script" : "set_forge_env"
        if e == .env && !Dialogs.confirm("Replace the .env of \(name)?",
                                         "Forge writes this file to the server in place of the current one. Running code keeps the old values until the config cache is cleared and the queue workers restart.",
                                         continueLabel: "Replace .env", destructive: true) { return }
        var a = args
        let sent = texts[e.rawValue].edit
        a["content"] = .string(sent)
        if e == .script { a["autoSource"] = .bool(autoSource) }
        let sentAuto = autoSource
        texts[e.rawValue].saving = true
        Task {
            let r = await boardCall(op, a)
            texts[e.rawValue].saving = false
            if closed { return }
            switch r {
            case .failure(let err): texts[e.rawValue].error = err.description
            case .success(let v):
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
            }
        }
    }

    /// Reads the open tab from Forge again.
    func refresh() {
        guard let e = openEditor else { siteLoad(); return }
        if e == .env && !envWanted { return }
        if changed(e) && !confirmDiscard("Reading it from Forge again drops the changes made here.") { return }
        texts[e.rawValue] = Draft()
        if e == .script { autoSource = savedAutoSource }
        textLoad(e)
    }
    /// True unless unsaved changes are kept when asked.
    func canLeave() -> Bool {
        if closed || !anyChanged { return true }
        let s = changed(.script), v = changed(.env)
        let what = (s ? "the deploy script" : "") + (s && v ? " and " : "") + (v ? "the .env" : "")
        guard confirmDiscard("The changes to \(what) of \(name) have not been saved to Forge.") else { return false }
        texts[0].edit = texts[0].saved; texts[1].edit = texts[1].saved; autoSource = savedAutoSource
        return true
    }
    /// The site leaves the tab: the .env leaves memory with it.
    func close() {
        closed = true
        texts = [Draft(), Draft()]
    }

    // MARK: - The header

    /// The open editor's Save.
    var headerButtons: [HeaderButton] {
        guard let e = openEditor, texts[e.rawValue].loaded else { return [] }
        let label = texts[e.rawValue].saving ? "Saving…" : e == .env ? "Save .env" : "Save"
        return [HeaderButton(glyph: Glyph.symbol(0xE74E), label: label,
                             tip: e == .env ? "Replace the site's .env on Forge (⌘S)" : "Save the deploy script to Forge (⌘S)",
                             enabled: canSave, prominent: true) { [weak self] in self?.save() }]
    }
}

struct ForgeSiteView: View {
    @ObservedObject var model: ForgeSiteModel
    var server: JSON?
    var back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(String("\u{2039} All sites on \(server?["name"].nonEmpty ?? "this server")"), action: back)
                .buttonStyle(.plain).font(Theme.footnote).foregroundStyle(Theme.accent).frame(height: 22).handCursor()
                .padding(.bottom, 8)
            Text(model.name).font(Theme.title3).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            if let state = model.site["status"].nonEmpty {
                Text(state).font(Theme.footnote).foregroundStyle(Theme.muted).padding(.top, 2)
            }
            Spacer().frame(height: 6)
            TabNav {
                TabNavItem(glyph: Glyph.symbol(0xE946), title: "Overview", active: model.tab == .overview) { model.select(.overview) }
                if Store.shared.supports("forge_deploy_script") {
                    TabNavItem(glyph: Glyph.symbol(0xE756), title: "Deploy script", active: model.tab == .script, dot: model.changed(.script)) { model.select(.script) }
                }
                if Store.shared.supports("forge_env") {
                    TabNavItem(glyph: "lock.shield", title: "Environment", active: model.tab == .env, dot: model.changed(.env)) { model.select(.env) }
                }
            }
            Spacer().frame(height: 14)
            switch model.tab {
            case .overview:
                ScrollView { ForgeOverview(model: model).frame(maxWidth: ProjectForgeTab.readingWidth, alignment: .topLeading).padding(.bottom, 14) }
            case .script: script
            case .env: env
            }
        }
        // ⌘S saves the open editor.
        .background {
            Button("") { model.save() }.keyboardShortcut("s", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
    }

    @ViewBuilder private func status(_ e: ForgeSiteModel.Editor) -> some View {
        let t = model.text(e)
        if let error = t.error { NoticeBox(message: error).padding(.bottom, 10) }
        if let notice = t.notice {
            Text(notice).font(Theme.footnote).foregroundStyle(Theme.ok).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
        }
    }

    @ViewBuilder private var script: some View {
        status(.script)
        if !model.text(.script).loaded {
            if model.text(.script).error == nil { LoadingNote(text: "Reading the deploy script…").padding(.horizontal, -8) }
            Spacer(minLength: 0)
        } else {
            Text("The commands Forge runs on each deployment of this site, from the site’s directory. $FORGE_ variables such as $FORGE_SITE_BRANCH and $FORGE_PHP are set.")
                .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            SettingsCheck(label: "Run the script with the site’s .env loaded", on: model.autoSource) { model.toggleAutoSource() }.padding(.vertical, 8)
            editor(.script)
        }
    }

    @ViewBuilder private var env: some View {
        status(.env)
        if !model.envWanted {
            VStack(alignment: .leading, spacing: 12) {
                EmptyNote(title: "The .env holds production secrets", detail: "It is read from Forge only when you ask for it, and shown here in full.")
                GlyphButton(glyph: "eye", title: "Show .env", kind: .prominent) { model.reveal() }.padding(.leading, 8)
            }
            .padding(.top, 24)
            Spacer(minLength: 0)
        } else if !model.text(.env).loaded {
            if model.text(.env).error == nil { LoadingNote(text: "Reading the .env…").padding(.horizontal, -8) }
            Spacer(minLength: 0)
        } else {
            // Once saved, the save's own note says what happens next.
            if model.text(.env).notice == nil {
                Text("Saving replaces the whole file. Forge writes it to the server shortly after; it does not clear the config cache or restart queue workers.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            }
            editor(.env)
        }
    }

    /// The editor in a box down to the bottom of the pane.
    private func editor(_ e: ForgeSiteModel.Editor) -> some View {
        ForgeEditor(text: model.binding(e))
            .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            .padding(.bottom, 14)
    }
}

/// The Overview: the site as Forge describes it and its repository, then everything else Forge says about it, as Forge
/// names it (the deployment trigger URL's token hidden), and Open site.
private struct ForgeOverview: View {
    @ObservedObject var model: ForgeSiteModel

    var body: some View {
        let site = model.site
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.siteError { NoticeBox(message: e).padding(.bottom, 10) }
            BoardBox(padding: 14, radius: 10) {
                Text("Site").font(Theme.captionSemibold).foregroundStyle(Theme.muted)
                field("Domain", site["name"])
                field("Status", site["status"])
                field("URL", site["url"])
                field("Deployment", site["deployment_status"])
                field("Quick deploy", site["quick_deploy"])
                if site["repository"].isObject {
                    Text("Repository").font(Theme.captionSemibold).foregroundStyle(Theme.muted).padding(.top, 14)
                    ForEach(site["repository"].keys, id: \.self) { k in field(Forge.fieldLabel(k), site["repository"][k]) }
                }
            }
            BoardBox(padding: 14, radius: 10) {
                Text("Everything Forge reports").font(Theme.captionSemibold).foregroundStyle(Theme.muted)
                field("Forge id", site["id"])
                let shown: Set<String> = ["name", "status", "url", "deployment_status", "quick_deploy", "repository", "id"]
                ForEach(site.keys.filter { !shown.contains($0) && !site[$0].isObject }, id: \.self) { k in
                    field(Forge.fieldLabel(k), site[k], mask: k.lowercased().contains("url"))
                }
            }
            .padding(.top, 12)
            if let url = Forge.siteURL(site) {
                GlyphButton(glyph: Glyph.symbol(0xE8A7), title: "Open site") { openWebURL(url) }.padding(.top, 12)
            }
            if model.readingSite && model.siteError == nil {
                Text("Reading the site from Forge…").font(Theme.caption).foregroundStyle(Theme.muted).padding(.top, 8)
            }
        }
    }

    @ViewBuilder private func field(_ label: String, _ value: JSON, mask: Bool = false) -> some View {
        if let text = Forge.fieldText(value) { LabeledRow(label: label, value: mask ? Forge.maskedURL(text) : text).padding(.top, 5) }
    }
}

/// The deploy script's and the .env's editor: plain monospaced text, its lines unwrapped, scrolling both ways.
private struct ForgeEditor: NSViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ForgeEditor
        var updating = false
        init(_ parent: ForgeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let tv = notification.object as? NSTextView else { return }
            if parent.text != tv.string { parent.text = tv.string }
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Escape leaves the editor.
            if selector == #selector(NSResponder.cancelOperation(_:)) { textView.window?.makeFirstResponder(nil); return true }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = NSColor(Theme.ink)
        tv.insertionPointColor = NSColor(Theme.ink)
        // No wrapping: long lines scroll sideways, as the Windows client's edit does.
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        context.coordinator.updating = true
        tv.string = text
        context.coordinator.updating = false
    }
}
