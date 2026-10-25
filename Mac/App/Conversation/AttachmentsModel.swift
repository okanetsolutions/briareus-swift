// The files for a composer's next message or first prompt, as the Windows client's `.attach-list` (attach.c, attach_list.c):
// an image pasted from the clipboard, encoded as PNG, or files copied in Finder and pasted, dropped or picked with 📎, each
// read off the main thread and uploaded in turn, and shown as a chip with ✕ above the text until it is sent.
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
    private let queue = AttachmentUploadQueue()
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
        enqueue(name: "Pasted image") {
            await Task.detached(priority: .userInitiated) { Attachments.encodePNG(data) }.value
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
        for url in urls {
            enqueue(name: url.lastPathComponent) {
                await Task.detached(priority: .userInitiated) { Attachments.readFiles([url]) }.value
            }
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
            if size > APIClient.uploadLimit { errors.append(attachmentRefusal(name, "is larger than 500 MiB, the most a message takes")); continue }
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

    /// Reserve a chip before reading, so queued files count towards the limit and can be removed without being read.
    private func enqueue(name: String, read: @escaping @MainActor () async -> (files: [(String, Data)], error: String?)) {
        guard items.count < attachmentsMax else { Dialogs.alert("Attachments", "At most \(attachmentsMax) files go with one message."); return }
        let item = Item(name: name, size: 0)
        items.append(item)
        let id = item.id
        uploads[id] = queue.enqueue {
            defer { self.uploads[id] = nil }
            let result = await read()
            guard !Task.isCancelled, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
            guard let (name, bytes) = result.files.first else {
                self.remove(id)
                if let error = result.error { Dialogs.alert("Attachments", error) }
                return
            }
            self.items[i].name = name
            self.items[i].size = bytes.count
            do {
                let fileID = try await Store.shared.upload(name: name, bytes: bytes)
                guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].fileID = fileID
            } catch {
                guard !error.isCancellation, self.items.contains(where: { $0.id == id }) else { return }
                self.remove(id)
                Dialogs.alert("Attachment", "\(name) could not be attached: \(errorText(error))")
            }
        }
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
