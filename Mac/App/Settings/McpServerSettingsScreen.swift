// An MCP server whose tools Claude and Codex sessions get beside Briareus's own (core #124; the Windows client's MCP
// settings, #134): its tool name and label, a remote endpoint (Streamable HTTP) or a command run beside each session, the
// write-only headers or environment, the projects that get it, and, for a server that signs in with OAuth, its sign-in in
// the browser. The server checks it on save. Saved through /settings/mcp/servers, which needs an Admin token.
import AppKit
import SwiftUI

@MainActor
final class McpServerFormModel: ObservableObject {
    @Published var state: McpServerFormState
    @Published var saving = false
    @Published var deleting = false
    @Published var connecting = false
    @Published var error: String?
    @Published var notice: String?
    @Published var scrollToken = 0

    init(row: JSON?, defaults: JSON?) {
        let r: JSON = row?.isObject == true ? row! : defaults?.isObject == true ? defaults! : [:]
        state = McpServerFormState(row: r)
    }

    var busy: Bool { saving || deleting || connecting }
    /// The sign-in under way, when the server has one open: an https address to open in the browser.
    var signInURL: String? { state.row["signInUrl"].string.flatMap { mcpSecureURL($0) && $0.hasPrefix("https://") ? $0 : nil } }
    var signInNeedsPaste: Bool { signInURL != nil && state.row["signInNeedsPaste"].is(true) }

    func binding(_ f: McpServerField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in
            let value = String(v.prefix(f.limit))
            guard value != self.state.text(f) else { return }
            self.state.texts[f] = value
            if !value.isEmpty { self.state.clear.remove(f) }
            self.changed()
        })
    }
    func setStdio(_ on: Bool) { guard state.stdio != on else { return }; state.stdio = on; changed() }
    func setLoopback(_ on: Bool) { guard state.loopback != on else { return }; state.loopback = on; changed() }
    func toggleEnabled() { state.enabled.toggle(); changed() }
    func toggle(_ repo: String) { state.toggle(repo); changed() }
    func everyProject() { guard !state.repos.isEmpty else { return }; state.repos = []; changed() }
    func toggleClear(_ f: McpServerField) {
        if state.clear.contains(f) { state.clear.remove(f) } else { state.clear.insert(f); state.texts[f] = "" }
        changed()
    }

    private func changed() {
        if !state.dirty { state.dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard state.dirty else { return true }
        let leave = confirmDiscard(state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? state.row["name"].nonEmpty ?? "this MCP server") have not been saved." : "The new MCP server has not been saved.")
        if leave { state.dirty = false }
        return leave
    }
    private func showError(_ text: String) { error = text; scrollToken += 1 }
    /// The server's word on the row: what it saved, its status and any sign-in it opened.
    private func adopt(_ row: JSON) {
        state.row = row
        state.fill()
        post(.mcpServersChanged)
    }

    func save() {
        let id = state.id
        let op = id != 0 ? "update_mcp_server" : "create_mcp_server"
        guard !busy, Store.shared.supports(op) else { return }
        var body: JSON
        switch state.body() {
        case .failure(let p): showError(p.message); return
        case .success(let b): body = b
        }
        if id != 0 { body["id"] = .number(id) }
        saving = true; notice = nil
        Task {
            defer { saving = false }
            do {
                let r = try await Store.shared.call(op, body)
                let row = r["server"]
                guard row.isObject else { showError(unexpectedResponse); return }
                error = nil
                adopt(row)
                // A server that signs in with OAuth answers with the sign-in to open.
                if signInURL != nil { notice = "Saved. It signs in with OAuth: open the sign-in to finish setting it up." }
                if id == 0 { Navigator.shared.show(.mcpServerSettings(row: row, defaults: SettingsModel.shared.mcp.defaults)) }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    /// Checks it again; `signIn` starts a fresh sign-in even when the stored one works.
    func connect(signIn: Bool) {
        guard state.id != 0, !busy, Store.shared.supports("connect_mcp_server") else { return }
        connecting = true; notice = nil
        Task {
            defer { connecting = false }
            do {
                var body: JSON = ["id": .number(state.id)]
                if signIn { body["signIn"] = true }
                let r = try await Store.shared.call("connect_mcp_server", body)
                guard r["server"].isObject else { showError(unexpectedResponse); return }
                error = nil
                let dirty = state.dirty
                if !dirty { adopt(r["server"]) } else { state.row = r["server"]; post(.mcpServersChanged) }
                if let url = signInURL {
                    openWebURL(url)
                    notice = signInNeedsPaste
                        ? "Sign in in your browser. It ends on a page that does not load: paste that page's whole address here."
                        : "Sign in in your browser; the server finishes it. Check again once you are back."
                } else {
                    notice = "Checked: \(mcpStatusText(state.row["status"].string))."
                }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }
    /// The address a loopback sign-in ended on, pasted, which the server finishes it with.
    func pasteCallback() {
        guard state.id != 0, signInNeedsPaste, !busy, Store.shared.supports("finish_mcp_sign_in") else { return }
        guard let pasted = Dialogs.text("Finish the sign-in", label: "Paste the whole address the browser ended on (http://127.0.0.1:…/callback?code=…&state=…).",
                                        okLabel: "Finish")?.cTrimmed else { return }
        guard mcpCallbackURL(pasted) else { showError("That address has no code and state from a sign-in. Paste the whole address from the browser's address bar."); return }
        connecting = true
        Task {
            defer { connecting = false }
            do {
                let r = try await Store.shared.call("finish_mcp_sign_in", ["id": .number(state.id), "url": .string(pasted)])
                guard r["server"].isObject else { showError(unexpectedResponse); return }
                error = nil
                if !state.dirty { adopt(r["server"]) } else { state.row = r["server"]; post(.mcpServersChanged) }
                notice = "Signed in: \(mcpStatusText(state.row["status"].string))."
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func delete() {
        guard state.id != 0, !busy else { return }
        let name = state.row["label"].nonEmpty ?? state.row["name"].nonEmpty ?? "this MCP server"
        guard Dialogs.confirm("Delete \(name)?", "Sessions stop getting its tools, and its stored headers, environment and sign-in are removed.",
                              continueLabel: "Delete", destructive: true) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await Store.shared.call("delete_mcp_server", ["id": .number(state.id)])
                state.dirty = false
                Navigator.shared.clear()
                post(.mcpServersChanged)
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }
}

struct McpServerSettingsScreen: View {
    var row: JSON?
    var defaults: JSON?
    @StateObject private var model: McpServerFormModel
    @ObservedObject private var settings = SettingsModel.shared
    @FocusState private var focus: McpServerField?
    @EnvironmentObject private var store: Store

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: McpServerFormModel(row: row, defaults: defaults))
    }

    private var state: McpServerFormState { model.state }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: settingsUnavailable("settings_mcp_servers", path: "settings/mcp/servers", what: "MCP servers", manage: "them"),
                     scrollToken: model.scrollToken) {
            SettingsTabs(tabs: [SettingsTabs.Tab(id: 0, title: "MCP server", glyph: "puzzlepiece.extension", dot: state.dirty && state.changed)], open: 0) { _ in }
            if let error = model.error { NoticeBox(message: error).padding(.bottom, 16) }
            if let notice = model.notice {
                Text(notice).font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            }
            if state.id != 0 { status }
            SettingsPair { field(.name) } right: { field(.label) }
            SettingsCheck(label: "Sessions get its tools", on: state.enabled, height: 28) { model.toggleEnabled() }.padding(.bottom, 12)
            SettingsFieldLabel(label: "Kind", hint: nil)
            Segments(titles: ["Remote (HTTP)", "Command (stdio)"], selected: state.stdio ? 1 : 0, dangerFirst: false) { model.setStdio($0 == 1) }
                .padding(.bottom, 14)
            if state.stdio {
                field(.command)
                field(.args)
                secret(.env)
            } else {
                field(.url)
                secret(.headers)
                oauth
            }
            projects
        }
        .onAppear { if state.id == 0 { DispatchQueue.main.async { focus = .name } } }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in model.save() }
    }

    /// How it stands: its status and why, when it was checked and signed in, and the sign-in under way.
    private var status: some View {
        let r = state.row
        return Card(padding: 12, radius: 6) {
            VStack(alignment: .leading, spacing: 4) {
                SettingsStatusRow(label: "Status", value: mcpStatusText(r["status"].string))
                if let e = r["error"].nonEmpty { SettingsStatusRow(label: "Why", value: e) }
                SettingsStatusRow(label: "Signs in", value: r["auth"].string == "oauth" ? (r["signedIn"].is(true) ? "with OAuth · signed in" : "with OAuth · not signed in") : "no")
                if let ms = r["checkedAt"].number, ms > 0 { SettingsStatusRow(label: "Checked", value: formatRelative(Date(timeIntervalSince1970: ms / 1000))) }
                HStack(spacing: 8) {
                    if store.supports("connect_mcp_server") {
                        Button(model.connecting ? "Checking…" : "Check again") { model.connect(signIn: false) }.dashButton(.bordered).disabled(model.busy)
                        if r["auth"].string == "oauth" {
                            Button("Sign in again") { model.connect(signIn: true) }.dashButton(.bordered).disabled(model.busy)
                        }
                    }
                    if let url = model.signInURL {
                        Button("Open the sign-in ↗") { openWebURL(url) }.dashButton(.prominent)
                        if model.signInNeedsPaste && store.supports("finish_mcp_sign_in") {
                            Button("Paste the address it ended on…") { model.pasteCallback() }.dashButton(.bordered).disabled(model.busy)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.bottom, 18)
    }

    /// The OAuth client a remote server signs in as, and where its sign-in returns.
    private var oauth: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsFieldLabel(label: "OAuth sign-in", hint: "For a server that signs in with OAuth. Leave these empty to register automatically.")
                .padding(.top, 4)
            SettingsPair { field(.oauthClientId) } right: { secret(.oauthClientSecret) }
            SettingsPair { field(.oauthScope) } right: { field(.oauthClientName) }
            SettingsFieldLabel(label: "Returns to", hint: nil)
            Segments(titles: ["Briareus (callback)", "This computer (loopback)"], selected: state.loopback ? 1 : 0, dangerFirst: false) { model.setLoopback($0 == 1) }
                .padding(.bottom, 6)
            SettingsHint(text: state.loopback
                ? "For a server that only allows http://127.0.0.1 redirects: the sign-in ends on a page that does not load, and its address is pasted here."
                : "The provider returns to Briareus's own callback, which finishes the sign-in by itself.")
                .padding(.bottom, 14)
        }
    }

    /// The projects whose sessions get it; none ticked is every project.
    @ViewBuilder private var projects: some View {
        let listed = settings.projects.list.compactMap { $0["repo"].nonEmpty }
        let choices = settingsRepoChoices(projects: listed, ticked: state.repos)
        VStack(alignment: .leading, spacing: 0) {
            SettingsFieldLabel(label: "Projects", hint: "The projects whose sessions get its tools.")
            SettingsCheck(label: "Every project", on: state.repos.isEmpty, height: 28) { model.everyProject() }
            ForEach(choices, id: \.self) { repo in
                let gone = !listed.contains(repo)
                SettingsCheck(label: gone ? "\(repo) (not a project)" : repo, on: state.repos.contains(repo), height: 28, muted: gone) { model.toggle(repo) }
            }
        }
        .padding(.bottom, 14)
    }

    private var header: PaneHeader {
        let id = state.id
        var buttons: [HeaderButton] = []
        let op = id != 0 ? "update_mcp_server" : "create_mcp_server"
        buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save and check this MCP server (⌘S)",
                                    enabled: !model.busy && (state.dirty || id == 0) && store.supports(op), prominent: true) { model.save() })
        if id != 0 {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this MCP server",
                                        enabled: !model.busy && store.supports("delete_mcp_server"), destructive: true) { model.delete() })
        }
        let r = state.row
        return id != 0
            ? PaneHeader(title: r["label"].nonEmpty ?? r["name"].nonEmpty ?? "MCP server",
                         subtitle: "mcp__\(r["name"].string ?? "")__… · \(McpServerFormState.sidebarLine(r))", buttons: buttons)
            : PaneHeader(title: "New MCP server", subtitle: "Another server's tools for the sessions, remote or run beside them", buttons: buttons)
    }

    private func field(_ f: McpServerField) -> some View {
        SettingsFieldBox(def: f.def, text: model.binding(f), focus: $focus, key: f) { focus = next(after: f) }
    }
    /// A write-only box: says what is stored, and offers to remove it.
    private func secret(_ f: McpServerField) -> some View {
        var def = f.def
        def.cue = state.clear.contains(f) ? "Removed on save" : state.cue(f)
        return VStack(alignment: .leading, spacing: 0) {
            SettingsFieldBox(def: def, text: model.binding(f), focus: $focus, key: f) { focus = next(after: f) }
            if state.stored(f) {
                SettingsCheck(label: "Remove the stored \(f == .oauthClientSecret ? "secret" : f.def.label.lowercased()) on save",
                              on: state.clear.contains(f), height: 24) { model.toggleClear(f) }
                    .padding(.top, -6).padding(.bottom, 10)
            }
        }
    }
    private func next(after f: McpServerField) -> McpServerField {
        let order: [McpServerField] = state.stdio ? [.name, .label, .command, .args, .env]
            : [.name, .label, .url, .headers, .oauthClientId, .oauthClientSecret, .oauthScope, .oauthClientName]
        guard let i = order.firstIndex(of: f) else { return f }
        return order[(i + 1) % order.count]
    }
}
