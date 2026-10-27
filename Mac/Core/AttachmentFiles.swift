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

/// Inspect metadata off the main actor before reserving any chips.
func checkAttachmentFiles(_ urls: [URL]) -> (files: [AttachmentFile], error: String?) {
    var files: [AttachmentFile] = [], errors: [String] = []
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
        files.append(AttachmentFile(url: url, size: size))
    }
    return (files, joinedAttachmentErrors(errors))
}

/// Apply the current chip count after metadata checks, which may have suspended the caller.
func limitAttachmentFiles(_ batch: (files: [AttachmentFile], error: String?), attached: Int) -> (files: [AttachmentFile], error: String?) {
    let files = Array(batch.files.prefix(max(0, attachmentsMax - attached)))
    let limitError = files.count < batch.files.count ? "At most \(attachmentsMax) files go with one message." : nil
    return (files, joinedAttachmentErrors([batch.error, limitError]))
}

/// The security scope and handle stay open until the read worker has stopped.
func readAttachmentFile(_ file: AttachmentFile) async throws -> Data {
    try Task.checkCancellation()
    let scoped = file.url.startAccessingSecurityScopedResource()
    defer { if scoped { file.url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: file.url)
    defer { try? handle.close() }
    return try await readAttachmentBytes { try handle.read(upToCount: 1024 * 1024) }
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

/// Cancel the provider's load, and discard late bytes before the caller can start encoding them.
@MainActor
func loadAttachmentData(_ start: (@escaping @Sendable (Result<Data?, Error>) -> Void) -> Progress) async throws -> Data? {
    let progress = Progress(totalUnitCount: 1)
    let data: Data? = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let child = start { continuation.resume(with: $0) }
            progress.addChild(child, withPendingUnitCount: 1)
        }
    } onCancel: {
        progress.cancel()
    }
    try Task.checkCancellation()
    return data
}
