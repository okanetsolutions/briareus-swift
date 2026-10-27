import XCTest
@testable import BriareusMacCore

private final class Recorder: HTTPTransport, @unchecked Sendable {
    var url: URL?, body: Data?
    let response: String
    init(response: String = "{}") { self.response = response }
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HTTPResponse {
        self.url = url; self.body = body
        return HTTPResponse(status: 200, contentType: "application/json", retryAfter: nil, body: Data(response.utf8))
    }
}

final class RouteQueryTests: XCTestCase {
    func testUploadAtServerLimitSendsRawBytes() async throws {
        let rec = Recorder(response: #"{"file":{"id":"abcd1234"}}"#)
        let client = try APIClient(address: ServerAddress("https://example.com")!, token: "brm_" + String(repeating: "a", count: 43), transport: rec)
        let bytes = Data(count: 500 * 1024 * 1024)
        let id = try await client.upload(name: "large file.zip", bytes: bytes)
        XCTAssertEqual(id, "abcd1234")
        XCTAssertEqual(rec.url?.absoluteString, "https://example.com/api/v1/uploads?name=large%20file.zip")
        XCTAssertEqual(rec.body?.count, bytes.count)
    }

    func testUploadOverServerLimitRefusesBeforeSending() async throws {
        let rec = Recorder()
        let client = try APIClient(address: ServerAddress("https://example.com")!, token: "brm_" + String(repeating: "a", count: 43), transport: rec)
        do {
            _ = try await client.upload(name: "too-large.zip", bytes: Data(count: 500 * 1024 * 1024 + 1))
            XCTFail("Expected an oversized upload to be refused")
        } catch let error as APIError {
            XCTAssertEqual(error.kind, .http)
            XCTAssertEqual(error.status, 413)
        }
        XCTAssertNil(rec.url)
    }

    func testAWritesQueryArgumentsGoInItsAddress() async throws {
        let rec = Recorder()
        let client = try APIClient(address: ServerAddress("https://example.com")!, token: "brm_" + String(repeating: "a", count: 43), transport: rec)
        _ = try await client.call("dispatch_deployment", ["repo": "o/r", "planId": "p1"])
        XCTAssertEqual(rec.url?.absoluteString, "https://example.com/api/v1/deployments/dispatch?repo=o%2Fr")
        let body = JSON.parse(String(decoding: rec.body ?? Data(), as: UTF8.self))!
        XCTAssertEqual(body["planId"].string, "p1"); XCTAssertTrue(body["repo"].isNull)
    }
}
