import XCTest
@testable import BriareusMacCore

private final class Recorder: HTTPTransport, @unchecked Sendable {
    var url: URL?, headers: [String: String] = [:]
    var status = 200
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HTTPResponse {
        self.url = url; self.headers = headers
        return HTTPResponse(status: status, contentType: "video/webm", retryAfter: nil, body: Data([1, 2, 3]))
    }
}

final class ServerFileTests: XCTestCase {
    func testOnlyThisServersFilesAreFetchedAndWithTheToken() async throws {
        let rec = Recorder()
        let token = "brm_" + String(repeating: "a", count: 43)
        let client = try APIClient(address: ServerAddress("https://example.com")!, token: token, transport: rec)
        let data = try await client.serverFile("https://example.com/api/v1/videos/o__r/pr-12/qa.webm", under: "videos/")
        XCTAssertEqual(data, Data([1, 2, 3])); XCTAssertEqual(rec.headers["Authorization"], "Bearer \(token)")
        // Another host, or another path on this one, never gets the token.
        rec.url = nil
        let other = try await client.serverFile("https://evil.example/api/v1/videos/x.webm", under: "videos/")
        XCTAssertNil(other); XCTAssertNil(rec.url)
        let elsewhere = try await client.serverFile("https://example.com/api/v1/sessions/x", under: "videos/")
        XCTAssertNil(elsewhere)
        rec.status = 404
        do { _ = try await client.serverFile("https://example.com/api/v1/videos/missing.webm", under: "videos/"); XCTFail("no error") }
        catch let e as APIError { XCTAssertEqual(e.status, 404) }
    }
}
