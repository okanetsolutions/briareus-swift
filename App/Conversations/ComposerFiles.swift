// The files for a composer's next message or first prompt, as the Mac's Attachments (attach.c, attach_list.c): photos
// from the library or files from the Files app, each read off the main thread and uploaded in turn, and shown as a chip with
// ✕ above the text until it is sent.
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ComposerFiles: ObservableObject {
    /// A file for the next message: uploading until `fileID` is set.
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var size: Int?
        var fileID: String?
    }

    @Published private(set) var items: [Item] = []
    /// Why files could not be attached, for an alert.
    @Published var notice: String?
    /// What the files go with: `message` or `start_session`.
    let call: String
    private let queue = AttachmentUploadQueue()
    private var uploads: [UUID: Task<Void, Never>] = [:]

    init(call: String) { self.call = call }

    /// Whether the server takes files with `call` from this token.
    var supported: Bool { Store.shared.supportsAttachments(on: call) }
    var count: Int { items.count }
    var full: Bool { items.count >= attachmentsMax }
    var uploading: Bool { items.contains { $0.fileID == nil } }
    /// The uploaded files' ids, as the call's `attachments`; nil when there are none.
    var ids: JSON? {
        guard !items.isEmpty else { return nil }
        return .array(items.compactMap { $0.fileID.map(JSON.string) })
    }

    // MARK: Taking files

    /// Files picked in the Files app: security-scoped, so each is opened for the read.
    func take(_ urls: [URL]) {
        let batch = prepareAttachmentFiles(urls, attached: items.count)
        notice = joinedAttachmentErrors([notice, batch.error])
        for file in batch.files {
            enqueue(name: file.url.lastPathComponent, size: file.size) { await loadAttachmentFile(file) }
        }
    }

    /// Photos and videos are loaded only when their upload's turn comes. A photo goes as JPEG unless it is PNG, JPEG or GIF.
    func take(_ picked: [PhotosPickerItem]) {
        let stamp = ComposerFiles.stamp()
        for (n, item) in picked.enumerated() {
            let base = picked.count == 1 ? stamp : "\(stamp)-\(n + 1)"
            enqueue(name: "A photo") {
                let type = item.supportedContentTypes.first
                guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
                    return ([], attachmentRefusal("A photo", "could not be read"))
                }
                let encoded = await Task.detached(priority: .userInitiated) { ComposerFiles.encode(data, type: type, base: base) }.value
                guard let encoded else { return ([], attachmentRefusal("A photo", "could not be encoded")) }
                if encoded.1.count > APIClient.uploadLimit {
                    return ([], attachmentRefusal(encoded.0, "is larger than 500 MiB, the most a message takes"))
                }
                return ([encoded], nil)
            }
        }
    }

    nonisolated private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: Date())
    }
    nonisolated private static func encode(_ data: Data, type: UTType?, base: String) -> (String, Data)? {
        guard let type, type.conforms(to: .image) else {
            return ("media-\(base).\(type?.preferredFilenameExtension ?? "bin")", data)
        }
        if type.conforms(to: .png) { return ("photo-\(base).png", data) }
        if type.conforms(to: .jpeg) { return ("photo-\(base).jpg", data) }
        if type.conforms(to: .gif) { return ("photo-\(base).gif", data) }
        guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) else { return nil }
        return ("photo-\(base).jpg", jpeg)
    }

    // MARK: Uploading

    /// Reserve a chip before reading, so queued files count towards the limit and can be removed without being read.
    private func enqueue(name: String, size: Int? = nil, read: @escaping @MainActor () async -> (files: [(String, Data)], error: String?)) {
        guard items.count < attachmentsMax else { notice = joinedAttachmentErrors([notice, "At most \(attachmentsMax) files go with one message."]); return }
        let item = Item(name: name, size: size)
        items.append(item)
        let id = item.id
        uploads[id] = queue.enqueue {
            defer { self.uploads[id] = nil }
            let result = await read()
            guard !Task.isCancelled, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
            guard let (name, bytes) = result.files.first else {
                self.remove(id)
                self.notice = joinedAttachmentErrors([self.notice, result.error])
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
                self.notice = joinedAttachmentErrors([self.notice, "\(name) could not be attached: \(errorText(error))"])
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

// MARK: - Views

/// The chips above the composer's text: the name and size (… while uploading), ✕ to take it off.
struct AttachmentChipRow: View {
    @ObservedObject var files: ComposerFiles
    var enabled = true
    var body: some View {
        if !files.items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(files.items) { item in
                        HStack(spacing: 4) {
                            if item.fileID == nil { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary) }
                            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                            if let size = item.size { Text(formatFileSize(size)).font(.caption2).foregroundStyle(.secondary) }
                            Button { files.remove(item.id) } label: {
                                Image(systemName: "xmark.circle.fill").font(.footnote).foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(!enabled)
                            .accessibilityLabel("Remove \(item.name)")
                        }
                        .padding(.leading, 9).padding(.trailing, 2).padding(.vertical, 2)
                        .background(Theme.field, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line, lineWidth: 0.5))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// The 📎 button: a menu of the photo library and the Files app, each opening its own picker.
struct AttachMenu: View {
    @ObservedObject var files: ComposerFiles
    var enabled = true
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            Button("Files", systemImage: "folder") { choosingFiles = true }
        } label: {
            Image(systemName: "paperclip").font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 32, height: 32).background(Theme.field, in: Circle())
        }
        .disabled(!enabled || files.full)
        .accessibilityLabel("Attach files")
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: max(1, attachmentsMax - files.count),
                      matching: .any(of: [.images, .screenshots, .videos]))
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            files.take(picked)
            photos = []
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): files.take(urls)
            case .failure(let error): files.notice = "The files could not be opened: \(error.localizedDescription)"
            }
        }
        .alert("Attachments", isPresented: Binding(get: { files.notice != nil }, set: { if !$0 { files.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(files.notice ?? "") }
    }
}
