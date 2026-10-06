// Update.swift (core_update_tests.c): reading GitHub's latest release, comparing versions, the hosts a download may use,
// its checks, and the bundle swapped in beside a backup.
import XCTest
@testable import BriareusMacCore

private let build = Data("PK\u{3}\u{4} the new build".utf8)
private let buildURL = "https://github.com/okanetsolutions/briareus-swift/releases/download/v1.85.0/Briareus-mac.zip"
private let assetURL = "https://release-assets.githubusercontent.com/github-production-release-asset/1?sig=abc"

private func releaseJSON(sha: String = updateSHA256(build)) -> String {
    #"{"tag_name":"v1.85.0","html_url":"https://github.com/okanetsolutions/briareus-swift/releases/tag/v1.85.0","#
        + #""assets":[{"name":"Briareus-iphone-simulator.zip","size":9,"digest":"sha256:\#(sha)","browser_download_url":"https://github.com/z.zip"},"#
        + #"{"name":"Briareus-mac.zip","size":\#(build.count),"digest":"sha256:\#(sha.uppercased())","browser_download_url":"\#(buildURL)"}]}"#
}

// MARK: - Stub

private struct Answer {
    var url: String
    var status = 200
    var location: String? = nil
    var body = Data()
    var fail = false
}

private final class Stub: @unchecked Sendable {
    let answers: [Answer]
    private let lock = NSLock()
    private var _urls: [String] = [], _accept: String?
    init(_ answers: [Answer]) { self.answers = answers }
    var urls: [String] { lock.withLock { _urls } }
    var lastAccept: String? { lock.withLock { _accept } }
    var updates: Updates {
        Updates(fetch: { [self] url, accept in
            lock.withLock { _urls.append(url); _accept = accept }
            guard let a = answers.first(where: { $0.url == url }) else { return .received(status: 404, location: nil, body: Data()) }
            if a.fail { return .failed("The request timed out.") }
            return .received(status: a.status, location: a.location, body: a.body)
        })
    }
}

final class UpdateTests: XCTestCase {
    private func parsed() -> UpdateRelease { UpdateRelease.parse(Data(releaseJSON().utf8))! }

    // MARK: Releases and versions

    func testAReleaseReadsItsArchiveWithSizeAndDigest() {
        let r = parsed()
        XCTAssertEqual(r.version, "1.85.0")
        XCTAssertEqual(r.page, "https://github.com/okanetsolutions/briareus-swift/releases/tag/v1.85.0")
        XCTAssertEqual(r.url, buildURL)
        XCTAssertEqual(r.sha256, updateSHA256(build))
        XCTAssertEqual(r.size, build.count)
    }

    func testAReleaseWithoutACheckedArchiveIsRefused() {
        let sha = updateSHA256(build)
        let cases = [
            #"{"tag_name":"v1.85.0","assets":[]}"#,
            #"{"tag_name":"v1.85.0","assets":[{"name":"Briareus-mac.zip","size":16,"browser_download_url":"\#(buildURL)"}]}"#,
            #"{"tag_name":"v1.85.0","assets":[{"name":"Briareus-mac.zip","size":16,"digest":"sha1:abc","browser_download_url":"\#(buildURL)"}]}"#,
            #"{"tag_name":"v1.85.0","assets":[{"name":"Briareus-mac.zip","size":16,"digest":"sha256:xyz","browser_download_url":"\#(buildURL)"}]}"#,
            #"{"tag_name":"v1.85.0","assets":[{"name":"Briareus-mac.zip","size":0,"digest":"sha256:\#(sha)","browser_download_url":"\#(buildURL)"}]}"#,
            #"{"tag_name":"v1.85.0","assets":[{"name":"Briareus-mac.zip","size":16,"digest":"sha256:\#(sha)"}]}"#,
            #"{"assets":[{"name":"Briareus-mac.zip","size":16,"digest":"sha256:\#(sha)","browser_download_url":"\#(buildURL)"}]}"#,
            "not json",
        ]
        for c in cases { XCTAssertNil(UpdateRelease.parse(Data(c.utf8)), c) }
    }

    func testVersionsCompareByNumberNotByText() {
        XCTAssertTrue(updateNewer("v1.85.0", "1.84.0"))
        XCTAssertTrue(updateNewer("1.100.0", "1.99.0"))
        XCTAssertTrue(updateNewer("2.0.0", "1.99.9"))
        XCTAssertTrue(updateNewer("v1.84.1", "1.84.0"))
        XCTAssertTrue(updateNewer("1.84.0.1", "1.84.0"))
        XCTAssertTrue(updateNewer("1.1.0", "1.0"))
        XCTAssertFalse(updateNewer("v1.84.0", "1.84.0"))
        XCTAssertFalse(updateNewer("1.83.0", "1.84.0"))
        XCTAssertFalse(updateNewer("1.85.0-beta", "1.84.0"))
        XCTAssertFalse(updateNewer("", "1.84.0"))
        XCTAssertFalse(updateNewer(nil, "1.84.0"))
        XCTAssertFalse(updateNewer("1.85.0", "nightly"))
        XCTAssertFalse(updateNewer("1..2", "1.0"))
        XCTAssertFalse(updateNewer("1.2.3.4.5", "1.0"))
    }

    func testDownloadsStayOnGitHubsOwnHosts() {
        XCTAssertTrue(updateURLAllowed(Update.latestURL))
        XCTAssertTrue(updateURLAllowed(buildURL))
        XCTAssertTrue(updateURLAllowed(assetURL))
        XCTAssertTrue(updateURLAllowed("https://objects.githubusercontent.com/x"))
        XCTAssertTrue(updateURLAllowed("HTTPS://GitHub.com/x"))
        XCTAssertFalse(updateURLAllowed("http://github.com/x"))
        XCTAssertFalse(updateURLAllowed("https://github.com.evil.example/x"))
        XCTAssertFalse(updateURLAllowed("https://evilgithubusercontent.com/x"))
        XCTAssertFalse(updateURLAllowed("https://githubusercontent.com/x"))
        XCTAssertFalse(updateURLAllowed("https://github.com@evil.example/x"))
        XCTAssertFalse(updateURLAllowed("https://github.com:8443/x"))
        XCTAssertFalse(updateURLAllowed("https:///x"))
        XCTAssertFalse(updateURLAllowed("/relative"))
        XCTAssertFalse(updateURLAllowed(nil))
    }

    func testSHA256MatchesTheStandardVectors() {
        XCTAssertEqual(updateSHA256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(updateSHA256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: Checking and downloading

    func testTheCheckReadsTheLatestReleaseFromTheAPI() async {
        let s = Stub([Answer(url: Update.latestURL, body: Data(releaseJSON().utf8))])
        let r = await s.updates.check()
        XCTAssertEqual(try r.get().version, "1.85.0")
        XCTAssertEqual(s.lastAccept, "application/vnd.github+json")
    }

    func testAFailedCheckSaysWhy() async {
        func error(_ answers: [Answer]) async -> String? {
            if case .failure(let e) = await Stub(answers).updates.check() { return e.message }
            return nil
        }
        let limited = await error([Answer(url: Update.latestURL, status: 403, body: Data("{}".utf8))])
        XCTAssertTrue(limited?.contains("limiting") == true)
        let offline = await error([Answer(url: Update.latestURL, fail: true)])
        XCTAssertEqual(offline, "The request timed out.")
        let missing = await error([Answer(url: "https://elsewhere")])
        XCTAssertEqual(missing, "No release was found on GitHub.")
        let broken = await error([Answer(url: Update.latestURL, status: 500)])
        XCTAssertEqual(broken, "GitHub answered the update request with HTTP 500.")
        let bare = await error([Answer(url: Update.latestURL, body: Data(#"{"tag_name":"v2.0.0","assets":[]}"#.utf8))])
        XCTAssertTrue(bare?.contains("no Briareus-mac.zip") == true)
    }

    func testTheDownloadFollowsRedirectsAndChecksTheBytes() async {
        let s = Stub([Answer(url: buildURL, status: 302, location: assetURL), Answer(url: assetURL, body: build)])
        let r = await s.updates.download(parsed())
        XCTAssertEqual(try r.get(), build)
        XCTAssertEqual(s.urls, [buildURL, assetURL])
        XCTAssertEqual(s.lastAccept, "application/octet-stream")
    }

    func testADownloadThatDoesNotMatchIsRefused() async {
        let bodies = ["PK\u{3}\u{4} the old build", "PK\u{3}\u{4} short", "MZ\u{3}\u{4} the new build"].map { Data($0.utf8) }
        for body in bodies {
            let r = await Stub([Answer(url: buildURL, body: body)]).updates.download(parsed())
            guard case .failure(let e) = r else { return XCTFail("accepted \(body)") }
            XCTAssertTrue(e.message.contains("does not match"))
        }
        // The right bytes against a release that records another digest.
        let other = UpdateRelease.parse(Data(releaseJSON(sha: String(repeating: "a", count: 64)).utf8))!
        let r = await Stub([Answer(url: buildURL, body: build)]).updates.download(other)
        XCTAssertThrowsError(try r.get())
    }

    func testARedirectOffGitHubOrInALoopIsNotFollowed() async {
        let away = Stub([Answer(url: buildURL, status: 302, location: "https://evil.example/Briareus-mac.zip")])
        if case .failure(let e) = await away.updates.download(parsed()) { XCTAssertTrue(e.message.contains("evil.example")) } else { XCTFail() }
        XCTAssertEqual(away.urls.count, 1)

        let loop = Stub([Answer(url: buildURL, status: 302, location: buildURL)])
        if case .failure(let e) = await loop.updates.download(parsed()) {
            XCTAssertEqual(e.message, "The update was redirected too many times.")
        } else { XCTFail() }
        XCTAssertEqual(loop.urls.count, 6)
    }

    // MARK: Installing

    private func tempApp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("briareus-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("Briareus.app")
    }
    /// A bundle whose one file says which build it is.
    private func bundle(_ at: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: at.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: at.appendingPathComponent("Contents/build"))
    }
    private func read(_ app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("Contents/build"))).map { String(decoding: $0, as: UTF8.self) }
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testTheNewBuildReplacesTheOldWhichIsKeptUntilCleanup() throws {
        let app = try tempApp(), old = updateSibling(app, ".old"), staged = updateSibling(app, ".new")
        let fresh = app.deletingLastPathComponent().appendingPathComponent("unpacked/Briareus.app")
        try bundle(app, "the old build")
        try bundle(old, "an older backup")
        try bundle(fresh, "the new build")
        XCTAssertNoThrow(try updateInstall(app: app, fresh: fresh).get())
        XCTAssertEqual(read(app), "the new build")
        XCTAssertEqual(read(old), "the old build")
        XCTAssertFalse(exists(staged))
        XCTAssertFalse(exists(fresh))
        XCTAssertTrue(updateCleanup(app: app))
        XCTAssertFalse(exists(old))
        XCTAssertTrue(updateCleanup(app: app))
        XCTAssertEqual(read(app), "the new build")
    }

    func testAnInstallThatCannotMoveTheAppLeavesItAlone() throws {
        let app = try tempApp(), staged = updateSibling(app, ".new"), old = updateSibling(app, ".old")
        let fresh = app.deletingLastPathComponent().appendingPathComponent("unpacked/Briareus.app")
        // Nothing to move aside: the new bundle must not stay behind.
        try bundle(fresh, "the new build")
        guard case .failure(let e) = updateInstall(app: app, fresh: fresh) else { return XCTFail() }
        XCTAssertTrue(e.message.contains("release page"))
        XCTAssertFalse(exists(staged) || exists(app) || exists(fresh))
        // A folder it cannot write in.
        try bundle(app, "the old build")
        try bundle(fresh, "the new build")
        let folder = app.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard case .failure(let f) = updateInstall(app: app, fresh: fresh) else { return XCTFail() }
        XCTAssertTrue(f.message.contains("could not be saved"))
        XCTAssertEqual(read(app), "the old build")
        XCTAssertFalse(exists(staged) || exists(old))
    }
}
