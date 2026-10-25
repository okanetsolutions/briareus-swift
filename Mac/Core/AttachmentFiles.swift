// Attachment metadata is checked before reserving chips; byte reads wait for their upload's turn.
import Foundation

struct AttachmentFile: Sendable {
    let url: URL
    let size: Int?
}

func joinedAttachmentErrors(_ errors: [String?]) -> String? {
    let lines = errors.compactMap { $0 }.filter { !$0.isEmpty }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

/// Invalid files never take a slot, and a selection reports the limit only once.
func prepareAttachmentFiles(_ urls: [URL], attached: Int) -> (files: [AttachmentFile], error: String?) {
    var files: [AttachmentFile] = [], errors: [String] = []
    var overLimit = false
    for url in urls {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
            errors.append(attachmentRefusal(name, "could not be read")); continue
        }
        if directory.boolValue { errors.append(attachmentRefusal(name, "is a folder; attach its files")); continue }
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if size == 0 { errors.append(attachmentRefusal(name, "is empty")); continue }
        if let size, size > APIClient.uploadLimit {
            errors.append(attachmentRefusal(name, "is larger than 500 MiB, the most a message takes")); continue
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            errors.append(attachmentRefusal(name, "could not be opened")); continue
        }
        guard attached + files.count < attachmentsMax else { overLimit = true; continue }
        files.append(AttachmentFile(url: url, size: size))
    }
    if overLimit { errors.append("At most \(attachmentsMax) files go with one message.") }
    return (files, joinedAttachmentErrors(errors))
}

/// The security scope and handle stay open until the read worker has stopped.
func readAttachmentFile(_ file: AttachmentFile) async throws -> Data {
    try Task.checkCancellation()
    let scoped = file.url.startAccessingSecurityScopedResource()
    defer { if scoped { file.url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: file.url)
    defer { try? handle.close() }
    let data = try await readAttachmentBytes { try handle.read(upToCount: 1024 * 1024) }
    if let size = file.size, data.count != size { throw CocoaError(.fileReadUnknown) }
    return data
}

/// Cancellation reaches the detached worker, which stops between chunks instead of reading the whole removed file.
func readAttachmentBytes(next: @escaping @Sendable () throws -> Data?) async throws -> Data {
    let worker = Task.detached(priority: .userInitiated) {
        var data = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try next(), !chunk.isEmpty else { break }
            try Task.checkCancellation()
            guard chunk.count <= APIClient.uploadLimit - data.count else { throw CocoaError(.fileReadTooLarge) }
            data.append(chunk)
        }
        guard !data.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return data
    }
    return try await withTaskCancellationHandler {
        try await worker.value
    } onCancel: {
        worker.cancel()
    }
}

/// Both composers report read failures the same way; cancelled chips discard this result.
func loadAttachmentFile(_ file: AttachmentFile) async -> (files: [(String, Data)], error: String?) {
    let name = file.url.lastPathComponent
    do { return ([(name, try await readAttachmentFile(file))], nil) }
    catch { return ([], attachmentRefusal(name, "could not be read")) }
}
