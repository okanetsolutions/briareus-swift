// Settings, as the Windows client's settings page: a sidebar of its own (← Back to sessions, the projects, the providers,
// the database pool, the SSH servers, the Forge accounts and the Slack workspaces, each with ＋ New) whose rows open their
// forms across the detail pane. Those routes need an Admin token; any other token gets a sentence saying so.
import SwiftUI

struct SettingsSidebar: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var navigator: Navigator
    @ObservedObject private var model = SettingsModel.shared

    private var selected: String? { navigator.selectedID }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 8)
                    SettingsBackRow { back() }
                    Color.clear.frame(height: 16)
                    content
                }
                .padding(.horizontal, Theme.sidebarMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            .focusEffectDisabled()
            // Backspace and Escape leave Settings as ← Back to sessions does, so a form with changes is asked first.
            .onKeyPress(keys: [.escape, .delete]) { _ in back(); return .handled }
            footer
        }
        .background(Theme.sidebar)
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
    }

    // MARK: Sections

    @ViewBuilder private var content: some View {
        // This computer's own settings come first: they need no Admin token.
        MeetingSettingsRow(selected: selected == Screen.meetingSettings.id)
        let why = settingsUnavailable("settings_projects", path: "settings/projects", what: "Project settings", manage: "projects")
        SectionHeader(title: "Projects", onNew: why == nil ? { model.newProject() } : nil)
        if let why {
            Explanation(text: why)
            ssh
            Color.clear.frame(height: 8)
        } else {
            projects
            // The providers sessions start on, then the database pool, below the projects as on the Windows client; a server
            // without the routes shows neither.
            if store.supports("settings_providers") {
                Color.clear.frame(height: 8)
                SectionHeader(title: "Providers", onNew: store.supports("create_provider") ? { model.newProvider() } : nil)
                providers
            }
            if store.supports("settings_db_servers") {
                Color.clear.frame(height: 8)
                // One open session with a database per server in the pool, so the pool's size heads the section, as the
                // sessions it lets run at once.
                let n = model.poolCapacity
                SectionHeader(title: "Database pool", note: n > 0 ? "· \(n) session\(n == 1 ? "" : "s")" : nil,
                              onNew: store.supports("create_db_server") ? { model.newServer() } : nil)
                servers
            }
            // The SSH servers agents may run commands on, as on the Windows client, then the Forge accounts and the Slack
            // workspaces on a server that has them.
            ssh
            if store.supports("settings_forge_accounts") { forge }
            if store.supports("settings_slack_workspaces") { slack }
            if store.supports("settings_mcp_servers") { mcp }
        }
    }

    @ViewBuilder private var projects: some View {
        let s = model.projects
        if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
        // The order is the dashboard sidebar's and the composer's, so it is moved from here: ↑ and ↓ on the row under the
        // pointer and on the open one, and the same in its right-click menu.
        let movable = s.list.count > 1 && store.supports("order_projects")
        ForEach(Array(s.list.enumerated()), id: \.offset) { i, row in
            let repo = row["repo"].string ?? ""
            ItemRow(label: row["label"].nonEmpty ?? repo, sub: repo, enabled: !row["enabled"].is(false), db: row["dbPoolEnabled"].is(true),
                    selected: selected == "project-settings:\(row["id"].int32 ?? 0)",
                    moves: movable ? ItemRow.Moves(up: i > 0 && !model.ordering, down: i + 1 < s.list.count && !model.ordering) { model.move(i, by: $0) } : nil) {
                model.openProject(i)
            }
                .contextMenu {
                    if store.supports("order_projects") {
                        Button("Move up") { model.move(i, by: -1) }.disabled(i == 0 || model.ordering)
                        Button("Move down") { model.move(i, by: 1) }.disabled(i + 1 >= s.list.count || model.ordering)
                    }
                }
        }
        // A project being added shows as its own row until it is saved.
        if selected == "project-settings:new" { ItemRow(label: "New project", sub: "not saved yet", enabled: false, selected: true) {} }
        if s.loaded && s.list.isEmpty && s.error == nil { Explanation(text: "No projects yet. ＋ New adds a repository sessions can be started against.") }
        if !s.loaded { LoadingNote(text: "Loading projects…") }
        Color.clear.frame(height: 8)
    }

    @ViewBuilder private var providers: some View {
        let s = model.providers
        if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
        ForEach(Array(s.list.enumerated()), id: \.offset) { i, row in
            let active = !row["active"].is(false)
            ProviderItemRow(label: row["label"].nonEmpty ?? "Provider #\(row["id"].int32 ?? 0)", active: active,
                            tags: [row["binary"].string ?? "", active ? "" : "inactive", row["hasLogin"].is(true) ? "own login" : "",
                                   row["baseUrl"].nonEmpty != nil ? "custom endpoint" : ""],
                            selected: selected == "provider-settings:\(row["id"].int32 ?? 0)") { model.openProvider(i) }
        }
        if selected == "provider-settings:new" {
            ProviderItemRow(label: "New provider", active: false, tags: ["not saved yet"], selected: true) {}
        }
        if s.loaded && s.list.isEmpty && s.error == nil { Explanation(text: "No providers yet. Add one so sessions can be started.") }
        if !s.loaded { LoadingNote(text: "Loading providers…") }
        Color.clear.frame(height: 8)
    }

    /// The database pool: each server with its dot and host:port.
    @ViewBuilder private var servers: some View {
        let s = model.servers
        if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
        ForEach(Array(s.list.enumerated()), id: \.offset) { i, row in
            let address = DBServerFormState.address(row)
            ItemRow(label: row["label"].nonEmpty ?? address, sub: address, enabled: row["enabled"].is(true),
                    selected: selected == "db-server:\(row["id"].int32 ?? 0)") { model.openServer(i) }
        }
        if selected == "db-server:new" { ItemRow(label: "New database server", sub: "not saved yet", enabled: false, selected: true) {} }
        if s.loaded && s.list.isEmpty && s.error == nil { Explanation(text: "No servers yet. Add one so sessions can claim a database of their own.") }
        if !s.loaded { LoadingNote(text: "Loading the database pool…") }
        Color.clear.frame(height: 8)
    }

    /// The SSH servers under the projects, as the web's settings sidebar lists them: each with its dot, label and project.
    @ViewBuilder private var ssh: some View {
        Color.clear.frame(height: 8)
        let why = settingsUnavailable("settings_ssh_servers", path: "settings/ssh/servers", what: "SSH servers", manage: "them")
        SectionHeader(title: "SSH servers", onNew: why == nil ? { model.newSSH() } : nil)
        if let why {
            Explanation(text: why)
        } else {
            let s = model.ssh
            if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
            ForEach(Array(s.list.enumerated()), id: \.offset) { i, row in
                let id = SSHServerFormState.rowID(row)
                ItemRow(label: row["label"].nonEmpty ?? row["host"].nonEmpty ?? "SSH server", sub: row["repo"].string ?? "",
                        enabled: !row["enabled"].is(false),
                        selected: id > 0 && selected == Screen.sshServerSettings(row: row, defaults: nil).id) { model.openSSH(i) }
            }
            // A server being registered shows as its own row until it is saved.
            if selected == "ssh-server:new" { ItemRow(label: "New SSH server", sub: "not saved yet", enabled: false, selected: true) {} }
            if s.loaded && s.list.isEmpty && s.error == nil {
                Explanation(text: "No SSH servers registered. ＋ New lets a project's sessions run commands on one, with approval.")
            }
            if !s.loaded { LoadingNote(text: "Loading SSH servers…") }
        }
    }

    /// The Forge accounts under the SSH servers: each with its dot (a token is stored), label, organization and projects.
    @ViewBuilder private var forge: some View {
        Color.clear.frame(height: 8)
        SectionHeader(title: "Forge accounts", onNew: store.supports("create_forge_account") ? { model.newForge() } : nil)
        let s = model.forge
        if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
        ForEach(Array(s.list.enumerated()), id: \.offset) { i, row in
            ItemRow(label: row["label"].nonEmpty ?? row["organization"].nonEmpty ?? "Forge account", sub: ForgeAccountFormState.sidebarLine(row),
                    enabled: row["hasToken"].is(true), selected: selected == Screen.forgeAccountSettings(row: row, defaults: nil).id) { model.openForge(i) }
        }
        // An account being added shows as its own row until it is saved.
        if selected == "forge-account:new" { ItemRow(label: "New Forge account", sub: "not saved yet", enabled: false, selected: true) {} }
        if s.loaded && s.list.isEmpty && s.error == nil {
            Explanation(text: "No Forge accounts yet. ＋ New adds a Laravel Forge organization and the projects that may use it.")
        }
        if !s.loaded { LoadingNote(text: "Loading Forge accounts…") }
    }

    /// The Slack workspaces under the Forge accounts: each with its dot (a token is stored), label, workspace and projects.
    @ViewBuilder private var slack: some View {
        Color.clear.frame(height: 8)
        SectionHeader(title: "Slack workspaces", onNew: store.supports("create_slack_workspace") ? { model.newSlack() } : nil)
        let s = model.slack
        if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
        ForEach(Array(s.list.enumerated()), id: \.offset) { i, row in
            ItemRow(label: row["label"].nonEmpty ?? row["team"].nonEmpty ?? "Slack workspace", sub: SlackWorkspaceFormState.sidebarLine(row),
                    enabled: row["hasToken"].is(true), selected: selected == Screen.slackWorkspaceSettings(row: row, defaults: nil).id) { model.openSlack(i) }
        }
        // A workspace being added shows as its own row until it is saved.
        if selected == "slack-workspace:new" { ItemRow(label: "New Slack workspace", sub: "not saved yet", enabled: false, selected: true) {} }
        if s.loaded && s.list.isEmpty && s.error == nil {
            Explanation(text: "No Slack workspaces yet. ＋ New lets a project's sessions send Slack messages as you and hear the replies.")
        }
        if !s.loaded { LoadingNote(text: "Loading Slack workspaces…") }
    }

    /// The MCP servers whose tools sessions get: each with its dot (ready), label, kind, status and projects.
    @ViewBuilder private var mcp: some View {
        Color.clear.frame(height: 8)
        SectionHeader(title: "MCP servers", onNew: store.supports("create_mcp_server") ? { model.newMcp() } : nil)
        let s = model.mcp
        if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
        ForEach(Array(s.list.enumerated()), id: \.offset) { i, row in
            ItemRow(label: row["label"].nonEmpty ?? row["name"].nonEmpty ?? "MCP server", sub: McpServerFormState.sidebarLine(row),
                    enabled: row["enabled"].is(true) && row["status"].string == "ready",
                    selected: selected == Screen.mcpServerSettings(row: row, defaults: nil).id) { model.openMcp(i) }
        }
        if selected == "mcp-server:new" { ItemRow(label: "New MCP server", sub: "not saved yet", enabled: false, selected: true) {} }
        if s.loaded && s.list.isEmpty && s.error == nil {
            Explanation(text: "No MCP servers yet. ＋ New gives sessions another server's tools, remote or run beside them.")
        }
        if !s.loaded { LoadingNote(text: "Loading MCP servers…") }
    }

    // MARK: Foot

    /// The foot, as the Windows client's settings page has it: `Settings` and `⎋ Sign out`, 12px muted, above a border.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 10).padding(.top, 6)
            HStack(spacing: 8) {
                Text("Settings").font(Theme.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button(action: signOut) { Text("⎋ Sign out").font(Theme.caption) }.buttonStyle(HoverInkStyle())
            }
            .frame(height: 18)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        }
        .background(Theme.sidebar)
    }

    private func signOut() {
        guard Dialogs.confirm("Sign out of this server?",
                              "The device token and the saved conversations are removed from this computer. Revoke the token itself in web Settings.",
                              continueLabel: "Sign out", destructive: true) else { return }
        store.forget()
    }

    /// The settings forms go with the sidebar that opened them, unless one keeps its unsaved changes.
    private func back() {
        if SettingsModel.isSettingsScreen(navigator.root) {
            navigator.clear()
            if SettingsModel.isSettingsScreen(navigator.root) { return }
        }
        navigator.sidebarMode = .projects
    }
}

// MARK: - Rows

/// "← Back to sessions", 12px, muted until hovered.
private struct SettingsBackRow: View {
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Text("← Back to sessions").font(Theme.caption).foregroundStyle(hovered ? Theme.ink : Theme.muted)
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A section's summary: its title, a muted note after it, and its ＋ New.
private struct SectionHeader: View {
    var title: String
    var note: String? = nil
    var onNew: (() -> Void)?
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.captionSemibold).foregroundStyle(Theme.muted).lineLimit(1)
            if let note { Text(note).font(Theme.caption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 8)
            if let onNew {
                Button(action: onNew) {
                    Text("＋ New").font(Theme.caption).foregroundStyle(hovered ? Theme.ink : Theme.muted).padding(.horizontal, 4)
                        .frame(height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
            }
        }
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: 20)
        .padding(.bottom, 4)
    }
}

/// A sentence in place of a list: why it cannot be shown, or that it is empty.
private struct Explanation: View {
    var text: String
    var body: some View {
        Text(text).font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of the projects, the pool or the SSH servers: its dot (`.dot.idle` when on, the plain grey dot when off), its label,
/// and its repository or address under it, with the pool's `db` tag after a project that claims a server. A project row
/// that can move has ↑ and ↓ at the right end of its first line while it is hovered or open.
private struct ItemRow: View {
    /// Which way the row can go now, and what a click on an arrow does with -1 or 1.
    struct Moves {
        var up: Bool
        var down: Bool
        var move: (Int) -> Void
    }
    var label: String
    var sub: String
    var enabled: Bool
    var db = false
    var selected: Bool
    var moves: Moves? = nil
    var action: () -> Void
    @State private var hovered = false
    private var arrows: Bool { moves != nil && (hovered || selected) }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        StatusDot(status: enabled ? "idle" : "")
                        Text(label).font(Theme.subheadline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    // The label stops short of the arrows while they show.
                    .padding(.trailing, arrows ? 50 : 0)
                    .frame(height: 22)
                    HStack(spacing: 8) {
                        Text(sub).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                        if db { Tag(text: "db") }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 18)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered || selected ? Theme.raise : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let moves, arrows {
                HStack(spacing: 2) {
                    MoveArrow(up: true, enabled: moves.up) { moves.move(-1) }
                    MoveArrow(up: false, enabled: moves.down) { moves.move(1) }
                }
                .padding(.top, 6).padding(.trailing, 6)
            }
        }
        .onHover { hovered = $0 }
    }
}

/// A project row's ↑ or ↓: 22px, raised, the sidebar's fill and the accent's border under the pointer. A disabled one still
/// takes the click, so the end of the list does not open the project under it.
private struct MoveArrow: View {
    var up: Bool
    var enabled: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        let lit = enabled && hovered
        Button { if enabled { action() } } label: {
            Image(systemName: Glyph.symbol(up ? 0xE70E : 0xE70D)).font(.system(size: 10))
                .foregroundStyle(!enabled ? Theme.muted.opacity(0.5) : lit ? Theme.ink : Theme.muted)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(lit ? Theme.sidebar : Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(lit ? Theme.accentDim : Theme.raise, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(up ? "Move up" : "Move down")
        .onHover { hovered = $0 }
    }
}

/// "This computer": the meeting assistant's row, its dot on once an ElevenLabs API key is saved.
private struct MeetingSettingsRow: View {
    var selected: Bool
    @ObservedObject private var meeting = Meeting.shared
    var body: some View {
        SectionHeader(title: "This computer", onNew: nil)
        ItemRow(label: "🎙 Meeting assistant", sub: meeting.hasKey ? "ElevenLabs API key saved" : "add an ElevenLabs API key",
                enabled: meeting.hasKey, selected: selected) { Navigator.shared.show(.meetingSettings) }
        Color.clear.frame(height: 16)
    }
}

/// A provider's row: its dot, label, and the Windows client's badges: the CLI it runs, and what sets it apart.
private struct ProviderItemRow: View {
    var label: String
    var active: Bool
    var tags: [String]
    var selected: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    StatusDot(status: active ? "idle" : "")
                    Text(label).font(Theme.subheadline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
                // As many as fit on the line, in order.
                ViewThatFits(in: .horizontal) {
                    ForEach((1...max(1, shown.count)).reversed(), id: \.self) { n in
                        HStack(spacing: 6) {
                            ForEach(Array(shown.prefix(n).enumerated()), id: \.offset) { _, t in Tag(text: t) }
                            Spacer(minLength: 0)
                        }
                    }
                    Color.clear.frame(height: 1)
                }
                .frame(height: 18, alignment: .top)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered || selected ? Theme.raise : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
    private var shown: [String] { tags.filter { !$0.isEmpty } }
}

/// A small bordered tag in the sidebar: `rounded border border-line px-1.5 text-[11px]`.
private struct Tag: View {
    var text: String
    var body: some View {
        Text(text).font(Theme.caption2).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
    }
}
