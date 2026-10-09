// The files for a composer's next message or first prompt, as the Windows client's `.attach-list` (attach.c, attach_list.c):
// an image pasted from the clipboard, encoded as PNG, or files copied in Finder and pasted, dropped or picked with 📎, each
// read off the main thread, uploaded at once, and shown as a chip with ✕ above the text until it is sent.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Attachments: ObservableObject {
    /// A file for the next message: uploading until `fileID` is set.
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var size: Int
        var fileID: String?
    }

    @Published private(set) var items: [Item] = []
    /// What the files go with: `message` or `start_session`.
    let call: String
    private var uploads: [UUID: Task<Void, Never>] = [:]

    init(call: String) { self.call = call }

    /// Whether the server takes files with `call` from this token.
    var supported: Bool { Store.shared.supportsAttachments(on: call) }
    var count: Int { items.count }
    var uploading: Bool { items.contains { $0.fileID == nil } }
    /// The uploaded files' ids, as the call's `attachments`; nil when there are none.
    var ids: JSON? {
        guard !items.isEmpty else { return nil }
        return .array(items.compactMap { $0.fileID.map(JSON.string) })
    }

    private static func unsupported() {
        Dialogs.alert("Attachments", "This server does not take files with a message. Update Briareus to a version whose client API accepts uploads.")
    }

    // MARK: Taking files

    /// The pasteboard's files copied in Finder, else its image.
    private static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private static func hasImage(_ pb: NSPasteboard) -> Bool { pb.availableType(from: [.png, .tiff]) != nil }
    static func hasFiles(_ pb: NSPasteboard) -> Bool { !fileURLs(pb).isEmpty || hasImage(pb) }

    /// A paste that holds files or an image: true when it was taken as attachments and the text, if any, is not to be pasted.
    func paste(_ pb: NSPasteboard) -> Bool {
        guard Attachments.hasFiles(pb) else { return false }
        if !supported {
            if pb.string(forType: .string) != nil { return false }
            Attachments.unsupported()
            return true
        }
        // Files copied in Finder come first: a Finder copy carries the files' icons as an image too.
        let urls = Attachments.fileURLs(pb)
        if !urls.isEmpty { read(urls); return true }
        let data = pb.data(forType: .png) ?? pb.data(forType: .tiff)
        guard let data else { return false }
        Task {
            let result = await Task.detached(priority: .userInitiated) { Attachments.encodePNG(data) }.value
            self.arrived(result.files, error: result.error)
        }
        return true
    }
    /// Files dropped from Finder.
    func drop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if !supported { Attachments.unsupported(); return }
        read(urls)
    }
    /// The 📎 button: the open panel, several files at once.
    func pick() {
        if !supported { Attachments.unsupported(); return }
        let panel = NSOpenPanel()
        panel.title = "Attach files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        read(panel.urls)
    }

    private func read(_ urls: [URL]) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { Attachments.readFiles(urls) }.value
            self.arrived(result.files, error: result.error)
        }
    }

    nonisolated private static func readFiles(_ urls: [URL]) -> (files: [(String, Data)], error: String?) {
        var files: [(String, Data)] = [], errors: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { errors.append(attachmentRefusal(name, "could not be read")); continue }
            if directory.boolValue { errors.append(attachmentRefusal(name, "is a folder; attach its files")); continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = (attrs[.size] as? NSNumber)?.intValue else {
                errors.append(attachmentRefusal(name, "could not be read")); continue
            }
            if size == 0 { errors.append(attachmentRefusal(name, "is empty")); continue }
            if size > APIClient.uploadLimit { errors.append(attachmentRefusal(name, "is larger than 25 MB, the most a message takes")); continue }
            guard FileManager.default.isReadableFile(atPath: url.path) else { errors.append(attachmentRefusal(name, "could not be opened")); continue }
            guard let data = try? Data(contentsOf: url), data.count == size else { errors.append(attachmentRefusal(name, "could not be read")); continue }
            files.append((name, data))
        }
        return (files, errors.isEmpty ? nil : errors.joined(separator: "\n"))
    }

    /// The browser's pasted image is "image.png"; the Windows client names it by the moment, and so does this.
    nonisolated private static func encodePNG(_ data: Data) -> (files: [(String, Data)], error: String?) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'pasted-'yyyyMMddHHmmss'.png'"
        let name = f.string(from: Date())
        if let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]), !png.isEmpty, png.count <= APIClient.uploadLimit {
            return ([(name, png)], nil)
        }
        return ([], attachmentRefusal("The image", "could not be encoded as PNG"))
    }

    // MARK: Uploading

    /// The files read: each goes to the server at once, and the call carries their ids.
    private func arrived(_ files: [(String, Data)], error: String?) {
        var refused: [String] = error.map { [$0] } ?? []
        for (name, bytes) in files {
            if items.count >= attachmentsMax { refused.append("At most \(attachmentsMax) files go with one message."); break }
            let item = Item(name: name, size: bytes.count)
            items.append(item)
            let id = item.id
            uploads[id] = Task {
                do {
                    let fileID = try await Store.shared.upload(name: name, bytes: bytes)
                    guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                    self.items[i].fileID = fileID
                } catch {
                    guard !error.isCancellation, self.items.contains(where: { $0.id == id }) else { return }
                    self.remove(id)
                    Dialogs.alert("Attachment", "\(name) could not be attached: \(errorText(error))")
                }
                self.uploads[id] = nil
            }
        }
        if !refused.isEmpty { Dialogs.alert("Attachments", refused.joined(separator: "\n")) }
    }

    /// Takes a file off the message, cancelling its upload.
    func remove(_ id: UUID) {
        uploads[id]?.cancel(); uploads[id] = nil
        items.removeAll { $0.id == id }
    }
    /// Drops the files whose ids went with a call that succeeded; one attached since stays.
    func sent(_ ids: JSON?) {
        let sent = Set((ids ?? .null).items.compactMap(\.string))
        for item in items where item.fileID.map(sent.contains) == true { remove(item.id) }
    }
    /// Cancels the uploads under way and forgets the files.
    func clear() { for item in items { remove(item.id) } }
}

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
    private var byRepo: [String: [JSON]] = [:]

    static var offered: Bool { Store.shared.supports("prompts") }

    func list(_ repo: String?) async -> [JSON] {
        let key = repo ?? ""
        if let l = byRepo[key] { return l }
        var args: JSON = [:]
        if let repo { args["repo"] = .string(repo) }
        guard let v = await boardCall("prompts", args).value else { return [] }
        let l = v["prompts"].items.filter { $0["title"].nonEmpty != nil && $0["body"].string != nil }
            .sorted { ($0["sortOrder"].number ?? .infinity, $0["title"].string ?? "") < ($1["sortOrder"].number ?? .infinity, $1["title"].string ?? "") }
        byRepo[key] = l
        return l
    }
    func forget() { byRepo = [:] }

    /// 📚's menu: the prompts to put in the composer, then Save the text as a prompt and Delete a prompt.
    func pick(repo: String?, text: String, insert: @escaping (String) -> Void) {
        Task {
            let prompts = await list(repo)
            var rows = prompts.map { p in MenuRow(title: (p["repo"].nonEmpty == nil ? "🌐 " : "") + (p["title"].string ?? "")) }
            if prompts.isEmpty { rows.append(MenuRow(title: "No saved prompts yet", enabled: false)) }
            rows.append(.divider)
            let canSave = Store.shared.supports("create_prompt") && !text.cTrimmed.isEmpty
            rows.append(MenuRow(title: "Save the message as a prompt…", enabled: canSave))
            let canDelete = Store.shared.supports("delete_prompt") && !prompts.isEmpty
            rows.append(MenuRow(title: "Delete a prompt…", enabled: canDelete))
            guard let i = popUpMenu(rows) else { return }
            if i < prompts.count { insert(prompts[i]["body"].string ?? ""); return }
            let actions = rows.count - 2
            if i == actions { save(repo: repo, text: text) }
            else if i == actions + 1 { delete(from: prompts) }
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
    private func delete(from prompts: [JSON]) {
        guard let i = popUpMenu(prompts.map { MenuRow(title: $0["title"].string ?? "") }), let id = prompts[i]["id"].truncatedInt,
              Dialogs.confirm("Delete the prompt \(prompts[i]["title"].string ?? "")?", continueLabel: "Delete", destructive: true) else { return }
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
    var insert: (String) -> Void
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
