// Attachment chips, picker button and saved prompts for the Mac composer.
import AppKit
import SwiftUI

// MARK: - Views

/// The chips above the composer's text: `rounded-md bg-field border`, 24px tall, the name and size, ✕ at the right.
struct AttachmentChips: View {
    @ObservedObject var files: Attachments
    var enabled = true
    var body: some View {
        if !files.items.isEmpty {
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(files.items) { item in
                    HStack(spacing: 6) {
                        Text(attachmentChipLabel(name: item.name, size: item.size, uploaded: item.fileID != nil))
                            .font(Theme.caption).foregroundStyle(item.fileID != nil ? Theme.ink : Theme.muted)
                            .lineLimit(1).truncationMode(.tail)
                        Button { if enabled { files.remove(item.id) } } label: {
                            Text("\u{2715}").font(Theme.caption).foregroundStyle(Theme.muted).frame(width: 16, height: 24)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 8).padding(.trailing, 6)
                    .frame(height: 24)
                    .frame(maxWidth: 280, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

/// `#btn-attach`: the 📎 left of the microphone, for files the clipboard or a drop cannot bring.
struct AttachButton: View {
    var enabled: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("\u{1F4CE}").font(.system(size: 15)).opacity(enabled ? 1 : 0.35)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Attach files")
    }
}

// MARK: - Saved prompts

/// The prompts kept for the composer (core /prompts): a project's own and the ones offered everywhere, read once per
/// project and kept while the app runs.
@MainActor
final class SavedPrompts {
    static let shared = SavedPrompts()
    private var byRepo: [String: [SavedPrompt]] = [:]

    static var offered: Bool { Store.shared.supports("prompts") }

    func list(_ repo: String?) async -> [SavedPrompt] {
        let key = repo ?? ""
        if let l = byRepo[key] { return l }
        var args: JSON = [:]
        if let repo { args["repo"] = .string(repo) }
        guard let v = await boardCall("prompts", args).value else { return [] }
        let l = SavedPrompt.list(v)
        byRepo[key] = l
        return l
    }
    func forget() { byRepo = [:] }

    /// 📚's menu: the prompts to put in the composer, then Save the text as a prompt, Edit a prompt and Delete a prompt.
    func pick(repo: String?, text: String, insert: @escaping (SavedPrompt) -> Void) {
        Task { [owner = NSApp.modalWindow] in
            let prompts = await list(repo)
            guard owner == nil || (NSApp.modalWindow === owner && owner?.isVisible == true) else { return }
            var rows = prompts.map { p in MenuRow(title: (p.everywhere ? "🌐 " : "") + p.title) }
            if prompts.isEmpty { rows.append(MenuRow(title: "No saved prompts yet", enabled: false)) }
            rows.append(.divider)
            let canSave = Store.shared.supports("create_prompt") && !text.cTrimmed.isEmpty
            rows.append(MenuRow(title: "Save the message as a prompt…", enabled: canSave))
            let canEdit = Store.shared.supports("update_prompt") && !prompts.isEmpty
            rows.append(MenuRow(title: "Edit a prompt…", enabled: canEdit))
            let canDelete = Store.shared.supports("delete_prompt") && !prompts.isEmpty
            rows.append(MenuRow(title: "Delete a prompt…", enabled: canDelete))
            guard let i = popUpMenu(rows) else { return }
            if i < prompts.count { insert(prompts[i]); return }
            let actions = rows.count - 3
            if i == actions { save(repo: repo, text: text) }
            else if i == actions + 1 { edit(from: prompts) }
            else if i == actions + 2 { delete(from: prompts) }
        }
    }

    private func save(repo: String?, text: String) {
        guard let title = Dialogs.text("Save as a prompt", label: "Its title, as the 📚 menu lists it.", okLabel: "Save")?.cTrimmed, !title.isEmpty else { return }
        var everywhere = true
        if repo != nil {
            guard let c = Dialogs.choose("Offer it on", choices: ["This project only", "Every project"]) else { return }
            everywhere = c == 1
        }
        var body: JSON = ["title": .string(title), "body": .string(text)]
        if let repo, !everywhere { body["repo"] = .string(repo) }
        Task {
            let r = await boardCall("create_prompt", body)
            if let e = r.error { Dialogs.alert("The prompt was not saved", e.description) }
            forget()
        }
    }
    /// Its title, then its text; where it is offered stays as it was.
    private func edit(from prompts: [SavedPrompt]) {
        guard let i = popUpMenu(prompts.map { MenuRow(title: $0.title) }), let id = prompts[i].serverID else { return }
        let p = prompts[i]
        guard let title = Dialogs.text("Edit the prompt", label: "Its title, as the 📚 menu lists it.", okLabel: "Next",
                                       current: p.title)?.cTrimmed, !title.isEmpty,
              let body = Dialogs.text("Edit the prompt", label: "What it puts in the message box.", okLabel: "Save",
                                      current: p.body, multiline: true),
              !body.cTrimmed.isEmpty else { return }
        Task {
            let r = await boardCall("update_prompt", ["id": JSON(id), "title": .string(title), "body": .string(body)])
            if let e = r.error { Dialogs.alert("The prompt was not saved", e.description) }
            forget()
        }
    }
    private func delete(from prompts: [SavedPrompt]) {
        guard let i = popUpMenu(prompts.map { MenuRow(title: $0.title) }), let id = prompts[i].serverID,
              Dialogs.confirm("Delete the prompt \(prompts[i].title)?", continueLabel: "Delete", destructive: true) else { return }
        Task {
            let r = await boardCall("delete_prompt", ["id": JSON(id)])
            if let e = r.error { Dialogs.alert("The prompt was not deleted", e.description) }
            forget()
        }
    }
}

/// 📚: the saved prompts.
struct PromptsButton: View {
    var repo: String?
    var text: String
    var insert: (SavedPrompt) -> Void
    var body: some View {
        Button { SavedPrompts.shared.pick(repo: repo, text: text, insert: insert) } label: {
            Text("\u{1F4DA}").font(.system(size: 14))
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Saved prompts")
    }
}
