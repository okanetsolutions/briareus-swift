// Updates from the repository's GitHub releases (update.c): the latest one is read and compared with this build, and its
// Briareus-mac.zip is downloaded, matched against the size and SHA-256 GitHub records for it, and, once unpacked, the new
// Briareus.app is moved in place of the running one, which is kept beside it as Briareus.app.old until the next start.
import CryptoKit
import Foundation

enum Update {
    static let latestURL = "https://api.github.com/repos/okanetsolutions/briareus-swift/releases/latest"
    static let asset = "Briareus-mac.zip"
    static let maxBytes = 128 * 1024 * 1024
    static let maxRedirects = 5
    static let timeout: TimeInterval = 120
}

/// A release: its version without the `v`, its page, and the Mac app's archive's address, size and SHA-256 in lower-case hex.
struct UpdateRelease: Equatable, Sendable {
    var version: String
    var page: String?
    var url: String
    var sha256: String
    var size: Int

    /// Reads GitHub's release JSON. Nil without a version, or without a Briareus-mac.zip asset that has a size and a SHA-256.
    static func parse(_ data: Data) -> UpdateRelease? {
        guard let json = JSON.parse(data), let tag = json["tag_name"].nonEmpty,
              let asset = json["assets"].items.first(where: { $0["name"].string == Update.asset }),
              let url = asset["browser_download_url"].nonEmpty, let digest = asset["digest"].string, digest.hasPrefix("sha256:"),
              let size = asset["size"].int, size >= 4, size <= Update.maxBytes else { return nil }
        let hex = String(digest.dropFirst(7))
        guard hex.utf8.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        let version = tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
        return UpdateRelease(version: version, page: json["html_url"].string, url: url, sha256: hex.lowercased(), size: size)
    }
}

/// Up to four dot-separated numbers after an optional `v`; nil for anything else, a pre-release suffix included.
private func versionParts(_ text: String?) -> [Int]? {
    guard let text else { return nil }
    var z = Substring(text)
    if z.first == "v" || z.first == "V" { z = z.dropFirst() }
    let parts = z.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(parts.count) else { return nil }
    var out: [Int] = []
    for p in parts {
        guard !p.isEmpty, p.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(p) else { return nil }
        out.append(n)
    }
    return out + Array(repeating: 0, count: 4 - out.count)
}

/// Whether `candidate` ("v1.85.0" or "1.85.0") is a later version than `current`. False when either cannot be read.
func updateNewer(_ candidate: String?, _ current: String?) -> Bool {
    guard let a = versionParts(candidate), let b = versionParts(current) else { return false }
    for (x, y) in zip(a, b) where x != y { return x > y }
    return false
}

/// Whether an update request may go to `url`, or be redirected there: HTTPS to github.com, api.github.com or a host under
/// githubusercontent.com, where release downloads are served, on the default port.
func updateURLAllowed(_ url: String?) -> Bool {
    guard let url, url.utf8.count > 8, url.prefix(8).lowercased() == "https://" else { return false }
    let host = url.dropFirst(8).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    // Credentials or a port in the address would let it name one host and reach another.
    guard !host.isEmpty, !host.contains("@"), !host.contains(":"), !host.contains("\\") else { return false }
    let name = host.lowercased(), suffix = ".githubusercontent.com"
    return name == "github.com" || name == "api.github.com" || name.count > suffix.count && name.hasSuffix(suffix)
}

/// The SHA-256 of `data` as 64 lower-case hex digits.
func updateSHA256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// MARK: - Network

/// What one GET without following redirects received: its status, a redirect's Location and the body; or, when nothing
/// was received, why.
enum UpdateResponse: Sendable {
    case received(status: Int, location: String?, body: Data)
    case failed(String)
}
typealias UpdateFetch = @Sendable (_ url: String, _ accept: String) async -> UpdateResponse

/// GitHub's API and downloads over URLSession, with redirects handed back to the caller to check, and no cookies or cache.
enum UpdateNetwork {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = Update.timeout
        c.httpAdditionalHeaders = ["User-Agent": "Briareus-Mac/1.0"]
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static let fetch: UpdateFetch = { url, accept in
        guard let u = URL(string: url), u.scheme == "https" else { return .failed("The update address is not an HTTPS URL.") }
        var request = URLRequest(url: u, timeoutInterval: Update.timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("GitHub could not be reached.") }
            if data.count > Update.maxBytes { return .failed("The download is too large.") }
            return .received(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"), body: data)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Checking for and downloading a release; tests swap the network for a stub.
struct Updates: Sendable {
    var fetch: UpdateFetch = UpdateNetwork.fetch

    /// A GET that follows redirects on the allowed hosts only and succeeds on a 2xx.
    private func get(_ url: String, accept: String) async -> Result<Data, UpdateError> {
        var current = url
        for _ in 0...Update.maxRedirects {
            guard updateURLAllowed(current) else { return .failure(UpdateError("The update was redirected to an address it may not use: \(current)")) }
            switch await fetch(current, accept) {
            case .failed(let why):
                return .failure(UpdateError(why.isEmpty ? "GitHub could not be reached." : why))
            case .received(let status, let location, let body):
                if (300..<400).contains(status), status != 304, let location, !location.isEmpty {
                    // A relative Location is resolved against the address that answered.
                    current = URL(string: location, relativeTo: URL(string: current))?.absoluteString ?? location
                    continue
                }
                if (200..<300).contains(status) { return .success(body) }
                return .failure(UpdateError(status == 403 || status == 429 ? "GitHub is limiting update checks from this network. Try again later."
                                            : status == 404 ? "No release was found on GitHub."
                                            : "GitHub answered the update request with HTTP \(status)."))
            }
        }
        return .failure(UpdateError("The update was redirected too many times."))
    }

    /// The latest release, whether or not it is newer than this build.
    func check() async -> Result<UpdateRelease, UpdateError> {
        switch await get(Update.latestURL, accept: "application/vnd.github+json") {
        case .failure(let e): return .failure(e)
        case .success(let body):
            guard let release = UpdateRelease.parse(body) else {
                return .failure(UpdateError("The latest release on GitHub has no \(Update.asset) to update to."))
            }
            return .success(release)
        }
    }

    /// The release's archive, through at most five redirects that all stay on the allowed hosts, checked against its size
    /// and SHA-256 and for a zip's `PK` start.
    func download(_ release: UpdateRelease) async -> Result<Data, UpdateError> {
        switch await get(release.url, accept: "application/octet-stream") {
        case .failure(let e): return .failure(e)
        case .success(let body):
            guard body.count == release.size, body.starts(with: [0x50, 0x4B, 0x03, 0x04]), updateSHA256(body) == release.sha256 else {
                return .failure(UpdateError("The downloaded update does not match the release on GitHub, so it was not installed."))
            }
            return .success(body)
        }
    }
}

struct UpdateError: Error, Equatable, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Installing

/// `app` with `suffix` after its name: Briareus.app.old, Briareus.app.new.
func updateSibling(_ app: URL, _ suffix: String) -> URL {
    app.deletingLastPathComponent().appendingPathComponent(app.lastPathComponent + suffix)
}

/// Puts the bundle at `fresh` in place of `app`: moved beside it as `.new`, the current one moved aside to `.old` (a
/// running app may be moved, its files staying open), then the new one moved in. Puts the old one back when that last step
/// fails; `fresh` is gone either way.
func updateInstall(app: URL, fresh: URL) -> Result<Void, UpdateError> {
    let fm = FileManager.default, staged = updateSibling(app, ".new"), old = updateSibling(app, ".old")
    func failure(_ what: String, _ error: Error) -> Result<Void, UpdateError> {
        .failure(UpdateError("\(what) (\(error.localizedDescription)) Download it from the release page instead."))
    }
    try? fm.removeItem(at: staged)
    do { try fm.moveItem(at: fresh, to: staged) } catch {
        try? fm.removeItem(at: fresh)
        return failure("The update could not be saved beside \(app.lastPathComponent).", error)
    }
    try? fm.removeItem(at: old)
    do { try fm.moveItem(at: app, to: old) } catch {
        try? fm.removeItem(at: staged)
        return failure("\(app.lastPathComponent) could not be moved aside.", error)
    }
    do { try fm.moveItem(at: staged, to: app) } catch {
        try? fm.moveItem(at: old, to: app)
        try? fm.removeItem(at: staged)
        return failure("The update could not be moved in.", error)
    }
    return .success(())
}

/// Deletes the `.old` a previous update left beside `app`. True when none is left.
@discardableResult
func updateCleanup(app: URL) -> Bool {
    let old = updateSibling(app, ".old")
    guard FileManager.default.fileExists(atPath: old.path) else { return true }
    return (try? FileManager.default.removeItem(at: old)) != nil
}
