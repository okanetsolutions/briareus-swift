// The server itself, for an Admin token: draining it for maintenance (no new turns start, and it says when nothing is left
// running, so it can be restarted safely), its workspace clone slots (what holds each, cleaned or set up afresh when idle),
// and the prompt templates its agents are briefed with.
import SwiftUI

@MainActor
final class ServerSettingsModel: ObservableObject {
    @Published private(set) var maintenance: JSON?
    @Published private(set) var workspaces: [JSON] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?

    static var offered: Bool {
        let s = Store.shared
        return s.isAdmin && (s.supports("maintenance") || s.supports("settings_workspaces") || s.supports("settings_templates"))
    }

    func load() async -> APIError? {
        var failure: APIError?
        if Store.shared.supports("maintenance") {
            switch await boardCall("maintenance") {
            case .success(let v): maintenance = v
            case .failure(let e): failure = e
            }
        }
        if Store.shared.supports("settings_workspaces") {
            switch await boardCall("settings_workspaces") {
            case .success(let v): workspaces = v["workspaces"].items
            case .failure(let e): failure = e
            }
        }
        error = failure.flatMap { $0.kind == .cancelled ? nil : $0.description }
        return failure
    }

    func setDraining(_ on: Bool) {
        guard Store.shared.supports("set_maintenance"), !busy else { return }
        if on {
            guard Dialogs.confirm("Drain the server?", "No new turn starts until you stop draining; what is running finishes. Use it before restarting or updating the server.",
                                  continueLabel: "Drain") else { return }
        }
        busy = true
        Task {
            let r = await boardCall("set_maintenance", ["draining": .bool(on)])
            busy = false
            switch r {
            case .success(let v): maintenance = v
            case .failure(let e): error = e.description
            }
        }
    }
    /// An idle slot's dependency trees removed, or its install fingerprints forgotten so its next session installs all.
    func slot(_ op: String, _ row: JSON) {
        guard let slot = row["slot"].nonEmpty, Store.shared.supports(op), !busy else { return }
        let ask = op == "clean_workspace"
            ? ("Clean \(slot)?", "Its vendor/ and node_modules/ are removed; its next session installs them again.")
            : ("Set \(slot) up afresh?", "Its next session runs every setup command again, instead of the ones whose inputs changed.")
        guard Dialogs.confirm(ask.0, ask.1, continueLabel: op == "clean_workspace" ? "Clean" : "Reset") else { return }
        busy = true
        Task {
            let r = await boardCall(op, ["slot": .string(slot)])
            busy = false
            switch r {
            case .success(let v):
                let removed = v["removed"].strings
                notice = op == "clean_workspace" ? (removed.isEmpty ? "\(slot): nothing to remove." : "\(slot): removed \(removed.joined(separator: ", ")).") : "\(slot): its next session sets up afresh."
            case .failure(let e): error = e.description
            }
            _ = await load()
        }
    }
}

struct ServerSettingsScreen: View {
    @StateObject private var model = ServerSettingsModel()
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Server", subtitle: "Maintenance and the workspace clone slots", buttons: [
                HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read it again") { Task { await model.load() } },
            ])
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let e = model.error { NoticeBox(message: e).padding(.bottom, 12) }
                    if let n = model.notice { Text(n).font(Theme.footnote).foregroundStyle(Theme.muted).padding(.bottom, 12) }
                    if let m = model.maintenance { maintenance(m) }
                    if store.supports("settings_workspaces") { workspaces }
                }
                .padding(.horizontal, Theme.paneMargin).padding(.vertical, 16)
                .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await poll(every: 5) { await model.load() } }
    }

    private func maintenance(_ m: JSON) -> some View {
        let draining = m["draining"].is(true), ready = m["ready"].is(true)
        let active = m["active"].items, ssh = m["sshRunning"].truncatedInt ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("Maintenance").font(Theme.bodySemibold).foregroundStyle(Theme.ink)
            HStack(spacing: 10) {
                Circle().fill(!draining ? Theme.ok : ready ? Theme.accent : Theme.warn).frame(width: 8, height: 8)
                Text(!draining ? "Running normally" : ready ? "Drained: nothing is running, it can be restarted" : "Draining: waiting for what is running")
                    .font(Theme.footnote).foregroundStyle(Theme.ink)
                Spacer()
                if store.supports("set_maintenance") {
                    Button(draining ? "Stop draining" : "Drain…") { model.setDraining(!draining) }
                        .dashButton(draining ? .bordered : .prominent).disabled(model.busy)
                }
            }
            if !active.isEmpty || ssh > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(active.enumerated()), id: \.offset) { _, s in
                        Button {
                            if let id = s["id"].nonEmpty { Navigator.shared.push(.conversation(id: id, session: nil)) }
                        } label: {
                            Text("\(s["title"].nonEmpty ?? s["id"].string ?? "Session") · \(s["status"].string ?? "")").font(Theme.footnote).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    if ssh > 0 { Text("\(ssh) SSH command\(ssh == 1 ? "" : "s") running").font(Theme.footnote).foregroundStyle(Theme.muted) }
                }
            } else if draining {
                Text("Nothing is running.").font(Theme.footnote).foregroundStyle(Theme.muted)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.bottom, 20)
    }

    private var workspaces: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspaces").font(Theme.bodySemibold).foregroundStyle(Theme.ink)
            Text("The clone slots sessions work in, one per session at a time.").font(Theme.footnote).foregroundStyle(Theme.muted).padding(.bottom, 4)
            ForEach(Array(model.workspaces.enumerated()), id: \.offset) { _, w in workspace(w) }
            if model.workspaces.isEmpty { Text("No workspaces yet.").font(Theme.footnote).foregroundStyle(Theme.muted) }
        }
    }
    private func workspace(_ w: JSON) -> some View {
        let held = w["claimedBy"].isObject
        var facts: [String] = []
        if let b = w["branch"].nonEmpty { facts.append(b) }
        if let h = w["head"].nonEmpty { facts.append(String(h.prefix(8))) }
        if w["dirty"].is(true) { facts.append("uncommitted changes") }
        if let kb = w["sizeKb"].number { facts.append(ByteCountFormatter.string(fromByteCount: Int64(kb * 1024), countStyle: .file)) }
        if w["vendor"].is(true) { facts.append("vendor/") }
        if w["nodeModules"].is(true) { facts.append("node_modules/") }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(w["slot"].string ?? "").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                    Text(w["repo"].string ?? "").font(Theme.caption).foregroundStyle(Theme.muted)
                }
                Text(facts.joined(separator: " · ")).font(Theme.caption).foregroundStyle(Theme.muted)
                if held {
                    let c = w["claimedBy"]
                    Text("held by \(c["title"].nonEmpty ?? c["id"].string ?? "a session")\(c["status"].nonEmpty.map { " · \($0)" } ?? "")").font(Theme.caption).foregroundStyle(Theme.accent)
                }
                if let e = w["error"].nonEmpty { Text(e).font(Theme.caption).foregroundStyle(Theme.danger) }
            }
            Spacer()
            if store.supports("clean_workspace") {
                Button("Clean…") { model.slot("clean_workspace", w) }.dashButton(.bordered).disabled(held || model.busy || !(w["vendor"].is(true) || w["nodeModules"].is(true)))
                    .help(held ? "A session holds it" : "Remove its vendor/ and node_modules/")
            }
            if store.supports("reset_workspace_setup") {
                Button("Set up afresh…") { model.slot("reset_workspace_setup", w) }.dashButton(.bordered).disabled(held || model.busy)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
    }
}

// MARK: - Prompt templates

@MainActor
final class TemplatesModel: ObservableObject {
    @Published private(set) var catalog: [JSON] = []
    @Published private(set) var defaults: JSON = [:]
    @Published var values: [String: String] = [:]
    @Published private(set) var saved: [String: String] = [:]
    @Published var selected: String?
    @Published private(set) var error: String?
    @Published private(set) var saving = false
    /// Set once the server's templates have arrived; until then `values` is empty and saving would wipe every override.
    @Published private(set) var loaded = false

    func load() async {
        switch await boardCall("settings_templates") {
        case .failure(let e): if e.kind != .cancelled { error = e.description }
        case .success(let v):
            catalog = v["catalog"].items.filter { $0["id"].nonEmpty != nil }
            defaults = v["defaults"]
            var map: [String: String] = [:]
            let row = v["templates"].items.first?["values"] ?? [:]
            for k in row.keys { if let s = row[k].string { map[k] = s } }
            saved = map; values = map; loaded = true
            if selected == nil { selected = catalog.first?["id"].string }
            error = nil
        }
    }
    var dirty: Bool { values.filter { !$0.value.isEmpty } != saved.filter { !$0.value.isEmpty } }
    func text(_ id: String) -> Binding<String> {
        Binding(get: { self.values[id] ?? "" }, set: { self.values[id] = $0 })
    }
    func save() {
        guard loaded, dirty, Store.shared.supports("set_templates"), !saving else { return }
        var body: [String: JSON] = [:]
        for (k, v) in values where !v.cTrimmed.isEmpty { body[k] = .string(v) }
        saving = true
        Task {
            let r = await boardCall("set_templates", ["values": .object(body)])
            saving = false
            if let e = r.error { error = e.description } else { await load() }
        }
    }
}

struct TemplatesSettingsScreen: View {
    @StateObject private var model = TemplatesModel()
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Prompt templates", subtitle: "What the server briefs its agents with; empty uses the built-in text", buttons: [
                HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save the templates (⌘S)",
                             enabled: model.loaded && model.dirty && !model.saving && store.supports("set_templates"), prominent: true) { model.save() },
            ])
            if let e = model.error { NoticeBox(message: e).padding(Theme.paneMargin) }
            HStack(spacing: 0) {
                List(model.catalog, id: \.self, selection: $model.selected) { t in
                    let id = t["id"].string ?? ""
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t["label"].nonEmpty ?? id).font(Theme.footnote)
                        Text((model.values[id]?.isEmpty == false) ? "overridden" : "built-in").font(Theme.caption2).foregroundStyle(Theme.muted)
                    }
                    .tag(id)
                }
                .frame(width: 260)
                Rectangle().fill(Theme.line).frame(width: 1)
                editor.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in model.save() }
    }

    @ViewBuilder private var editor: some View {
        if let id = model.selected, let t = model.catalog.first(where: { $0["id"].string == id }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t["label"].nonEmpty ?? id).font(Theme.title3).foregroundStyle(Theme.ink)
                if let hint = t["hint"].nonEmpty { Text(hint).font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                if !t["vars"].strings.isEmpty {
                    Text("Placeholders: " + t["vars"].strings.map { "{{\($0)}}" }.joined(separator: " ")).font(Theme.monoSmall).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                HStack {
                    Text("Override").font(Theme.footnoteSemibold)
                    Spacer()
                    if model.values[id]?.isEmpty == false { Button("Use the built-in text") { model.values[id] = "" }.buttonStyle(.plain).font(Theme.footnote).foregroundStyle(Theme.accent) }
                }
                TextEditor(text: model.text(id)).font(Theme.mono).frame(minHeight: 200)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                if let builtIn = t["builtIn"].nonEmpty ?? model.defaults[id].nonEmpty {
                    Text("Built-in").font(Theme.footnoteSemibold).padding(.top, 4)
                    ScrollView { Text(builtIn).font(Theme.monoSmall).foregroundStyle(Theme.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(minHeight: 120).padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
                }
            }
            .padding(18)
        } else {
            Text(model.catalog.isEmpty ? "Loading…" : "Pick a template.").font(Theme.footnote).foregroundStyle(Theme.muted).padding(18)
        }
    }
}
