import XCTest
@testable import BriareusMacCore

private final class Recorder: HTTPTransport, @unchecked Sendable {
    var url: URL?, body: Data?
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HTTPResponse {
        self.url = url; self.body = body
        return HTTPResponse(status: 200, contentType: "application/json", retryAfter: nil, body: Data("{}".utf8))
    }
}

final class RouteQueryTests: XCTestCase {
    func testAWritesQueryArgumentsGoInItsAddress() async throws {
        let rec = Recorder()
        let client = try APIClient(address: ServerAddress("https://example.com")!, token: "brm_" + String(repeating: "a", count: 43), transport: rec)
        _ = try await client.call("dispatch_deployment", ["repo": "o/r", "planId": "p1"])
        XCTAssertEqual(rec.url?.absoluteString, "https://example.com/api/v1/deployments/dispatch?repo=o%2Fr")
        let body = JSON.parse(String(decoding: rec.body ?? Data(), as: UTF8.self))!
        XCTAssertEqual(body["planId"].string, "p1"); XCTAssertTrue(body["repo"].isNull)
    }
}
