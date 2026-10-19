// ElevenLabs provisioning and short-lived WebRTC credentials. The API key only reaches this fixed HTTPS origin.
import Foundation

struct VoiceService: Sendable {
    struct Failure: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { message }
    }

    var transport: any HTTPTransport = URLSessionTransport()

    func request(_ method: String, path: String, body: JSON? = nil, key: String) async throws -> JSON {
        let response = try await transport.send(method: method,
            url: URL(string: "https://api.elevenlabs.io/v1/convai/\(path)")!,
            headers: ["xi-api-key": key, "Content-Type": "application/json", "Accept": "application/json"],
            body: body?.data, timeout: 30)
        let answer = JSON.parse(response.body)
        guard (200..<300).contains(response.status) else {
            let detail = answer?["detail"] ?? .null
            let why = detail["message"].nonEmpty ?? detail.nonEmpty ?? detail[0]["msg"].nonEmpty
            throw Failure(status: response.status, message: response.status == 401 || response.status == 403
                ? "ElevenLabs refused the API key or its permissions. Check Settings › Voice."
                : "ElevenLabs answered HTTP \(response.status)\(why.map { ": \($0)" } ?? ".")")
        }
        guard let answer else { throw Failure(status: response.status, message: "ElevenLabs returned an invalid response.") }
        return answer
    }

    /// Refreshes a cached resource; a deleted resource is created again. Writes are never retried after a timeout.
    func upsert(_ resource: String, id: String?, body: JSON, key: String) async throws -> String {
        if let id {
            do {
                _ = try await request("PATCH", path: "\(resource)/\(id)", body: body, key: key)
                return id
            } catch let error as Failure where error.status == 404 {}
        }
        let answer = try await request("POST", path: resource == "agents" ? "agents/create" : resource, body: body, key: key)
        guard let id = Meet.createdID(answer) else {
            throw Failure(status: 0, message: "ElevenLabs did not return the new resource's ID.")
        }
        return id
    }

    func token(agent: String, key: String) async throws -> String {
        let encoded = agent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let answer = try await request("GET", path: "conversation/token?agent_id=\(encoded)", key: key)
        guard let token = answer["token"].nonEmpty else {
            throw Failure(status: 0, message: "ElevenLabs did not return a conversation token.")
        }
        return token
    }
}
