import XCTest
@testable import BriareusMacCore

private final class Recorder: HTTPTransport, @unchecked Sendable {
    var url: URL?, body: Data?
    let response: String
    let date: String?
    let status: Int
    init(response: String = "{}", date: String? = nil, status: Int = 200) { self.response = response; self.date = date; self.status = status }
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HTTPResponse {
        self.url = url; self.body = body
        return HTTPResponse(status: status, contentType: "application/json", retryAfter: nil, body: Data(response.utf8), date: date)
    }
}

final class RouteQueryTests: XCTestCase {
    func testClientEstablishesServerClockFromHTTPDate() async throws {
        let client = try APIClient(address: ServerAddress("https://example.com")!, token: "brm_" + String(repeating: "a", count: 43),
                                   transport: Recorder(date: "Tue, 27 Oct 2026 12:00:00 GMT"))
        XCTAssertNil(client.serverNow)
        _ = try await client.call("pulls", ["repo": "o/r"])
        let first = try XCTUnwrap(client.serverNow)
        let date = boardDateParse("2026-10-27T12:00:00Z")!
        XCTAssertGreaterThanOrEqual(first.timeIntervalSince(date), 0)
        XCTAssertLessThan(first.timeIntervalSince(date), 60)
        client.transport = Recorder(date: "invalid")
        _ = try await client.call("pulls", ["repo": "o/r"])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(client.serverNow), first)
    }

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

    func testARefusalCarriesTheServersCode() async throws {
        let rec = Recorder(response: #"{"error":"Out of rounds.","code":"review_round_limit","reviewRounds":{"used":3}}"#, status: 409)
        let client = try APIClient(address: ServerAddress("https://example.com")!, token: "brm_" + String(repeating: "a", count: 43), transport: rec)
        do {
            _ = try await client.call("action", ["repo": "o/r", "action": "review", "prNumber": 9])
            XCTFail("a 409 is thrown")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 409); XCTAssertEqual(e.code, "review_round_limit"); XCTAssertEqual(e.message, "Out of rounds.")
            XCTAssertTrue(e.isReviewRoundLimit)
        }
    }

    func testOnlyTheRoundLimitRefusalOffersAnotherRound() {
        XCTAssertTrue(APIError(.http, status: 409, code: "review_round_limit").isReviewRoundLimit)
        XCTAssertFalse(APIError(.http, status: 409, code: "review_round_in_progress").isReviewRoundLimit)
        XCTAssertFalse(APIError(.http, status: 409).isReviewRoundLimit)
        XCTAssertFalse(APIError(.http, status: 400, code: "review_round_limit").isReviewRoundLimit)
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
