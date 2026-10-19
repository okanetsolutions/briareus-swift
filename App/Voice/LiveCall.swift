// The iPhone's private ElevenLabs call. The SDK owns the microphone, echo cancellation, audio routing and playback.
import AVFoundation
import Combine
import ElevenLabs

@MainActor
final class LiveCall {
    enum Event: Sendable {
        case ready, heard(String), said(String), agent(speaking: Bool, busy: Bool), activity(Bool)
        case tool(id: String, name: String, args: JSON)
    }

    private var conversation: Conversation?
    private var events: AsyncThrowingStream<Event, Error>.Continuation?
    private var observers = Set<AnyCancellable>()
    private var closed = false

    func open(key: String, voice: String, project: String, held: String?) async throws -> AsyncThrowingStream<Event, Error> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceService.Failure(status: 0, message: "Allow Briareus to use the microphone in Settings on your iPhone.")
        }
        try checkOpen()
        let token = try await prepare(key: key, voice: voice, project: project, held: held)
        try checkOpen()
        let (stream, continuation) = AsyncThrowingStream<Event, Error>.makeStream()
        events = continuation
        let config = ConversationConfig(
            onError: { error in continuation.finish(throwing: error) },
            onAgentResponse: { text, _ in continuation.yield(.said(text)) },
            onUserTranscript: { text, _ in continuation.yield(.heard(text)) },
            onVadScore: { score in continuation.yield(.activity(score > 0.5)) },
            onUnhandledClientToolCall: { call in
                continuation.yield(.tool(id: call.toolCallId, name: call.toolName, args: JSON.parse(call.parametersData) ?? [:]))
            })
        let active = try await ElevenLabs.startConversation(conversationToken: token, config: config,
            onAgentReady: { continuation.yield(.ready) },
            onDisconnect: { reason in
                if case .error = reason {
                    continuation.finish(throwing: VoiceService.Failure(status: 0, message: "The connection with ElevenLabs was lost."))
                } else { continuation.finish() }
            })
        // A hang-up during provisioning or SDK startup must also close the late connection.
        if closed || Task.isCancelled { await active.endConversation(); throw CancellationError() }
        conversation = active
        active.$agentState.sink { state in
            continuation.yield(.agent(speaking: state == .speaking, busy: state != .listening))
        }.store(in: &observers)
        return stream
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        if closed { throw CancellationError() }
    }

    /// Provision once per key and schema, then refresh the private agent's project and prompt for this call.
    private func prepare(key: String, voice: String, project: String, held: String?) async throws -> String {
        let service = VoiceService()
        let defaults = UserDefaults.standard
        let cacheKey = "voice.elevenlabs.resources"
        var cached = defaults.string(forKey: cacheKey).flatMap(JSON.parse) ?? [:]
        var ids: [String] = []
        if held == nil {
            for tool in VoiceTool.allCases {
                try checkOpen()
                let body = Voice.toolBody(tool)
                let saved = cached[tool.rawValue]
                let id: String
                if saved["body"] == body, let previous = saved["id"].nonEmpty { id = previous }
                else { id = try await service.upsert("tools", id: saved["id"].nonEmpty, body: body, key: key) }
                try checkOpen()
                cached[tool.rawValue] = ["id": .string(id), "body": body]
                defaults.set(cached.serialized(), forKey: cacheKey)
                ids.append(id)
            }
        }
        try checkOpen()
        let body = Voice.session(voice: voice, project: project, conversation: held, toolIDs: ids)
        let agent = try await service.upsert("agents", id: cached["agent"].nonEmpty, body: body, key: key)
        try checkOpen()
        cached["agent"] = .string(agent)
        defaults.set(cached.serialized(), forKey: cacheKey)
        return try await service.token(agent: agent, key: key)
    }

    func context(_ text: String) async throws { try await conversation?.updateContext(text) }
    func speak(_ text: String) async throws { try await conversation?.sendMessage(text) }
    func answer(id: String, output: String) async throws {
        try await conversation?.sendToolResult(for: id, result: output, isError: JSON.parse(output)?["error"].nonEmpty != nil)
    }
    func mute(_ on: Bool) async throws { try await conversation?.setMuted(on) }

    func close() {
        closed = true
        observers.removeAll()
        events?.finish(); events = nil
        let active = conversation
        conversation = nil
        Task { await active?.endConversation() }
    }
}
