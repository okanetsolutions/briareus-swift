// Server responses kept on disk so a screen opens on what it last showed while the server is asked for changes.
// Every failure is silent: a missing or unreadable entry only means the screen waits for the network.
import Foundation

final class DiskCache: @unchecked Sendable {
    let directory: URL
    /// How the files are protected: on a Mac, readable only while it is unlocked; a phone in a car runs locked in a
    /// pocket, so its app passes `.completeFileProtectionUntilFirstUserAuthentication`.
    let protection: Data.WritingOptions
    private let lock = NSLock()
    /// Saves waiting for the writer, by key: a read sees them at once, and only the newest of a key is written.
    private var pending: [String: JSON] = [:]
    /// Bumped by every save and removal of a key, so a write overtaken meanwhile is dropped.
    private var revision: [String: Int] = [:]
    private var epoch = 0
    private let writer = DispatchQueue(label: "DiskCache.writer", qos: .utility)

    init(directory: URL, protection: Data.WritingOptions = .completeFileProtection) {
        self.directory = directory; self.protection = protection
    }

    /// The file name a key maps to; no path separators or dots.
    static func fileName(_ key: String) -> String {
        // Keys carry repository names and server ids; encoding leaves no path separators or dots.
        var s = ""
        for b in key.utf8 {
            if (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) { s.append(Character(UnicodeScalar(b))) }
            else { s += String(format: "%%%02X", b) }
        }
        return s.isEmpty ? "_" : s
    }
    private func url(_ key: String) -> URL { directory.appendingPathComponent(DiskCache.fileName(key)) }

    private func ensureDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return true
        } catch { return false }
    }
    private func write(_ data: Data, to url: URL) -> Bool {
        guard ensureDirectory() else { return false }
        do { try data.write(to: url, options: [.atomic, protection]); return true } catch {
            return (try? data.write(to: url, options: .atomic)) != nil
        }
    }

    /// The saved document, or nil.
    func value(_ key: String) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        if let saved = pending[key] { return saved }
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return JSON.parse(data)
    }
    /// Saves a document off the calling thread: a board's answer runs to hundreds of kilobytes, and turning it into text
    /// and comparing it with the file took the main thread with it on every poll. Reads see it at once.
    func store(_ value: JSON, _ key: String) {
        lock.lock()
        pending[key] = value
        let mine = bump(key)
        lock.unlock()
        writer.async { [self] in
            // Only the newest save of a key is written; one overtaken meanwhile leaves it to the later one.
            lock.lock()
            guard revision[key] == mine, let value = pending[key] else { lock.unlock(); return }
            lock.unlock()
            // Sorted keys make equal values equal bytes, so an unchanged poll result costs no write.
            let data = value.data, u = url(key)
            lock.lock(); defer { lock.unlock() }
            guard revision[key] == mine else { return }
            pending[key] = nil
            if let existing = try? Data(contentsOf: u), existing == data {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
            } else {
                _ = write(data, to: u)
            }
        }
    }
    /// Waits for the saves made so far to reach the disk.
    func flush() { writer.sync {} }
    private func bump(_ key: String) -> Int {
        epoch += 1
        revision[key] = epoch
        return epoch
    }

    /// A log of values, one JSON document per line, that grows without being rewritten. Returns an array.
    func lines(_ key: String) -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(key)) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { JSON.parse(Data($0)) }
    }
    @discardableResult
    func append(_ values: [JSON], _ key: String) -> Bool {
        guard !values.isEmpty else { return true }
        lock.lock(); defer { lock.unlock() }
        guard ensureDirectory() else { return false }
        let text = values.map { $0.serialized() + "\n" }.joined()
        let u = url(key)
        if let handle = try? FileHandle(forWritingTo: u) {
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); return true } catch { return false }
        }
        return write(Data(text.utf8), to: u)
    }
    @discardableResult
    func replace(_ values: [JSON], _ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending[key] = nil; _ = bump(key)
        return write(Data(values.map { $0.serialized() + "\n" }.joined().utf8), to: url(key))
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        pending[key] = nil; _ = bump(key)
        try? FileManager.default.removeItem(at: url(key))
    }
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        // A save still waiting is dropped with the rest: its revision no longer matches.
        for key in pending.keys { _ = bump(key) }
        pending = [:]
        try? FileManager.default.removeItem(at: directory)
    }
    /// Drops entries nothing has written for a while, such as transcripts of conversations never reopened.
    func prune(olderThan age: TimeInterval, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in names {
            let modified = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: u) }
        }
    }
}
