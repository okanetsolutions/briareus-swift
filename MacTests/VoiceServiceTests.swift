// Provisioning follows ElevenLabs' private-agent contract and never retries an uncertain write.
import XCTest
@testable import BriareusMacCore

private actor VoiceTransport: HTTPTransport {
    struct Call: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: JSON?
    }
    var calls: [Call] = []
    var replies: [HTTPResponse]
    init(_ replies: [(Int, String)]) {
        self.replies = replies.map { HTTPResponse(status: $0.0, contentType: "application/json", body: Data($0.1.utf8)) }
    }
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HTTPResponse {
        calls.append(Call(method: method, url: url, headers: headers, body: body.flatMap(JSON.parse)))
        return replies.removeFirst()
    }
}

final class VoiceServiceTests: XCTestCase {
    func testCreatesPrivateAgentThenObtainsShortLivedToken() async throws {
        let transport = VoiceTransport([(200, #"{"agent_id":"agent_one"}"#), (200, #"{"token":"ephemeral"}"#)])
        let service = VoiceService(transport: transport)
        let body = Voice.session(voice: Voice.defaultVoice, project: "o/r")
        let agent = try await service.upsert("agents", id: nil, body: body, key: "secret")
        let token = try await service.token(agent: agent, key: "secret")
        XCTAssertEqual(token, "ephemeral")
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.method), ["POST", "GET"])
        XCTAssertEqual(calls[0].url.absoluteString, "https://api.elevenlabs.io/v1/convai/agents/create")
        XCTAssertEqual(calls[0].body, body)
        XCTAssertEqual(URLComponents(url: calls[1].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "agent_one")
        for call in calls {
            XCTAssertEqual(call.url.host, "api.elevenlabs.io")
            XCTAssertEqual(call.headers["xi-api-key"], "secret")
            XCTAssertNil(call.headers["Authorization"])
        }
    }

    func testDeletedToolIsRecreatedButPermissionFailureIsNotRetried() async throws {
        let transport = VoiceTransport([(404, "{}"), (200, #"{"id":"new_tool"}"#), (403, "{}")])
        let service = VoiceService(transport: transport)
        let body = Voice.toolBody(.listConversations)
        let id = try await service.upsert("tools", id: "old", body: body, key: "secret")
        XCTAssertEqual(id, "new_tool")
        do {
            _ = try await service.upsert("tools", id: id, body: body, key: "secret")
            XCTFail("A forbidden write should fail")
        } catch let error as VoiceService.Failure { XCTAssertEqual(error.status, 403) }
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.method), ["PATCH", "POST", "PATCH"])
    }

    func testRedirectServerFailureAndMalformedTokenFailWithoutRetry() async throws {
        for (status, body) in [(302, "{}"), (503, "{}"), (200, "{}"), (200, "not json")] {
            let transport = VoiceTransport([(status, body)])
            do {
                _ = try await VoiceService(transport: transport).token(agent: "a", key: "secret")
                XCTFail("Expected an error for HTTP \(status) with \(body)")
            } catch {}
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
        }
    }
}
