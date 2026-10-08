// A project's Memories tab on its board (core /memories): what its agents remember between sessions, listed with their
// kind and description, each opened to read and edit, added by hand and deleted. An Admin token also sees the health
// report: which need verifying (verify, archive, restore) and which look duplicated (merged into one).
import SwiftUI

@MainActor
final class ProjectMemoriesModel: ObservableObject {
    let repo: String
    @Published private(set) var memories: [Memory] = []
    @Published private(set) var duplicates: [MemoryDuplicate] = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published var selected: Int?
    @Published var showArchived = false
    /// The editor's fields, for the memory open or a new one (`editingNew`).
    @Published var name = ""
    @Published var type = "project"
    @Published var summary = ""
    @Published var text = ""
    @Published var editingNew = false
    /// Whether the editor holds what is not saved: a new memory with anything typed, or fields that differ from the one open.
    var dirty: Bool {
        if editingNew { return !name.isEmpty || !summary.isEmpty || !text.isEmpty }
        guard let m = current else { return false }
        return name != m.name || type != m.type || summary != m.description || text != m.body
    }

    init(repo: String) { self.repo = repo }

    static var offered: Bool { Store.shared.supports("memories") }
    var admin: Bool { Store.shared.isAdmin && Store.shared.supports("memories_health") }
    var current: Memory? { memories.first { $0.id == selected } }
    var shown: [Memory] { memories.filter { showArchived || !$0.archived } }
    var needingVerification: Int { memories.filter { $0.needsVerification && !$0.archived }.count }

    func open() { if !loaded { Task { await load() } } }
    func load() async {
        let r = await boardCall("memories", ["repo": .string(repo)])
        var health: JSON?
        if admin { health = await boardCall("memories_health", ["repo": .string(repo)]).value }
        switch r {
        case .failure(let e): if e.kind != .cancelled { error = e.description }
        case .success(let v):
            memories = MemoryLogic.merge(list: v, health: health)
            duplicates = MemoryLogic.duplicates(health).filter { d in d.ids.allSatisfy { id in memories.contains { $0.id == id && !$0.archived } } }
            loaded = true; error = nil
            if let s = selected, !memories.contains(where: { $0.id == s }) { selected = nil }
        }
    }

    func select(_ m: Memory) {
        guard leave() else { return }
        selected = m.id; editingNew = false
        name = m.name; type = m.type; summary = m.description; text = m.body
    }
    func startNew() {
        guard leave() else { return }
        selected = nil; editingNew = true
        name = ""; type = "project"; summary = ""; text = ""
    }
    private func leave() -> Bool { !dirty || confirmDiscard("The changes to this memory have not been saved.") }

    func save() {
        let n = name.cTrimmed
        guard MemoryLogic.validName(n) else { error = "Name it with letters, digits, - and _ (a slug)."; return }
        guard !text.cTrimmed.isEmpty else { error = "Write what the memory holds."; return }
        let op = editingNew ? "create_memory" : "update_memory"
        guard Store.shared.supports(op), !busy else { return }
        var body: JSON = ["repo": .string(repo), "name": .string(n), "type": .string(type), "description": .string(summary.cTrimmed), "body": .string(text)]
        if !editingNew, let id = selected { body["id"] = JSON(id) }
        busy = true; error = nil
        Task {
            let r = await boardCall(op, body)
            busy = false
            switch r {
            case .failure(let e): if e.kind != .cancelled { error = e.description }
            case .success(let v):
                editingNew = false
                await load()
                if let m = Memory(v["memory"]) { selected = m.id; name = m.name; type = m.type; summary = m.description; text = m.body }
            }
        }
    }
    func delete() {
        guard let m = current, Store.shared.supports("delete_memory"), !busy,
              Dialogs.confirm("Delete the memory \(m.name)?", "Its agents no longer remember it.", continueLabel: "Delete", destructive: true) else { return }
        busy = true
        Task {
            let r = await boardCall("delete_memory", ["id": JSON(m.id)])
            busy = false
            if let e = r.error { error = e.description; return }
            selected = nil
            await load()
        }
    }
    /// Verify, archive or restore, named by the revision last read, so a change made meanwhile is refused (409).
    func policy(_ action: String) {
        guard let m = current, let rev = m.revision, Store.shared.supports("memory_policy"), !busy else { return }
        busy = true
        Task {
            let r = await boardCall("memory_policy", ["id": JSON(m.id), "action": .string(action), "revision": .string(rev)])
            busy = false
            if let e = r.error { error = e.status == 409 ? "It changed since it was read; read again." : e.description }
            await load()
        }
    }
    /// Keeps the first's text joined with the second's, on the first, and archives the second.
    func merge(_ d: MemoryDuplicate) {
        guard d.ids.count == 2, let target = memories.first(where: { $0.id == d.ids[0] }), let source = memories.first(where: { $0.id == d.ids[1] }),
              let tr = target.revision, let sr = source.revision, Store.shared.supports("memories_merge"), !busy else { return }
        let merged = target.body.cTrimmed + "\n\n" + source.body.cTrimmed
        guard Dialogs.confirm("Merge \(source.name) into \(target.name)?", "\(target.name) keeps both texts, one after the other, and \(source.name) is archived.",
                              continueLabel: "Merge") else { return }
        busy = true
        Task {
            let r = await boardCall("memories_merge", ["targetId": JSON(target.id), "sourceId": JSON(source.id), "body": .string(merged), "revisions": JSON([tr, sr])])
            busy = false
            if let e = r.error { error = e.description }
            await load()
        }
    }
}

struct ProjectMemoriesTab: View {
    @ObservedObject var model: ProjectMemoriesModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            list.frame(width: 300)
            Rectangle().fill(Theme.line).frame(width: 1)
            editor.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { model.open() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if store.supports("create_memory") { Button("＋ New memory") { model.startNew() }.dashButton(.bordered) }
                Spacer()
                if model.memories.contains(where: \.archived) {
                    Toggle("Archived", isOn: $model.showArchived).toggleStyle(.checkbox).font(Theme.footnote)
                }
            }
            .padding(.bottom, 10).padding(.trailing, 10)
            if let e = model.error { Notice(message: e).padding(.bottom, 8).padding(.trailing, 10) }
            if model.admin && model.needingVerification > 0 {
                Text("\(model.needingVerification) need verifying").font(Theme.caption).foregroundStyle(Theme.warn).padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !model.loaded { LoadingNote(text: "Loading memories…") }
                    if model.loaded && model.memories.isEmpty { EmptyNote(title: "No memories yet.", detail: "Agents save what they learn here as they work.") }
                    ForEach(model.shown) { m in row(m) }
                    if !model.duplicates.isEmpty {
                        Text("Look duplicated").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).padding(.top, 14).padding(.bottom, 4)
                        ForEach(Array(model.duplicates.enumerated()), id: \.offset) { _, d in duplicate(d) }
                    }
                }
                .padding(.trailing, 10)
            }
        }
    }

    private func row(_ m: Memory) -> some View {
        Button { model.select(m) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Memory.typeLabel(m.type)).font(Theme.caption2).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 5).frame(height: 16).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
                    Text(m.name).font(Theme.footnoteSemibold).foregroundStyle(m.archived ? Theme.muted : Theme.ink).lineLimit(1)
                    if m.needsVerification && !m.archived { Text("verify").font(Theme.caption2).foregroundStyle(Theme.warn) }
                    if m.archived { Text("archived").font(Theme.caption2).foregroundStyle(Theme.muted) }
                }
                if !m.description.isEmpty { Text(m.description).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(2) }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(model.selected == m.id ? Theme.raise : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func duplicate(_ d: MemoryDuplicate) -> some View {
        let names = d.ids.compactMap { id in model.memories.first { $0.id == id }?.name }
        return HStack(spacing: 6) {
            Text("\(names.joined(separator: " ≈ ")) · \(Int(d.similarity * 100))%").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            if store.supports("memories_merge") { Button("Merge") { model.merge(d) }.dashButton(.bordered).disabled(model.busy) }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var editor: some View {
        if model.current != nil || model.editingNew {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(model.editingNew ? "New memory" : model.current?.name ?? "").font(Theme.title3).foregroundStyle(Theme.ink)
                        Spacer()
                        if let m = model.current, model.admin, m.revision != nil, store.supports("memory_policy") {
                            if m.archived { Button("Restore") { model.policy("restore") }.dashButton(.bordered).disabled(model.busy) }
                            else {
                                Button(m.needsVerification ? "Mark verified" : "Verified ✓") { model.policy("verify") }.dashButton(.bordered)
                                    .disabled(model.busy || !m.needsVerification)
                                Button("Archive") { model.policy("archive") }.dashButton(.bordered).disabled(model.busy)
                            }
                        }
                        if !model.editingNew && store.supports("delete_memory") {
                            Button { model.delete() } label: { Image(systemName: Glyph.symbol(0xE74D)) }.buttonStyle(IconButtonStyle(destructive: true)).help("Delete it")
                        }
                        Button(model.busy ? "Saving…" : "Save") { model.save() }.dashButton(.prominent)
                            .disabled(model.busy || (!model.dirty && !model.editingNew)).keyboardShortcut("s", modifiers: .command)
                    }
                    if let m = model.current {
                        Text([m.jobID.map { "last written by session \($0.prefix(8))" } ?? "edited by hand",
                              m.updatedAt.map { "updated \(formatRelative($0))" }, m.verifiedAt.map { "verified \(formatRelative($0))" }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.caption).foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 12) {
                        labeled("Name") { TextField("deploy-notes", text: $model.name).textFieldStyle(.roundedBorder).font(Theme.mono) }
                        labeled("Kind") {
                            Picker("", selection: $model.type) { ForEach(Memory.types, id: \.self) { Text(Memory.typeLabel($0)).tag($0) } }
                                .labelsHidden().frame(width: 140)
                        }
                    }
                    labeled("Description") { TextField("One line saying what it holds", text: $model.summary).textFieldStyle(.roundedBorder) }
                    labeled("Memory") {
                        TextEditor(text: $model.text).font(Theme.body).frame(minHeight: 240)
                            .scrollContentBackground(.hidden).padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                            
                    }
                }
                .padding(.leading, 18).padding(.bottom, 20)
            }
        } else {
            Text("Pick a memory to read or edit it.").font(Theme.footnote).foregroundStyle(Theme.muted).padding(.leading, 18)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.footnote).foregroundStyle(Theme.muted)
            content()
        }
    }
}
