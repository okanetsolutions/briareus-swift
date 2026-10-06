// The meeting assistant's words with an ElevenLabs agent (the Windows client's core/meet.c): the agent's settings (the
// user's voice, the prompt, the project's read-only tools from MeetTools.swift), the events its conversation WebSocket
// sends and takes, the meeting's running transcript, and the record kept of each meeting.
// No sockets and no audio here: the Mac app's Meeting carries the events, MeetAudio the sound.
import Foundation

/// Meetings are joined with an ElevenLabs agent; GPT-Live 1 and GPT-Realtime 2.1 mini are kept only to read and price
/// the meetings the Windows client recorded with them.
enum MeetModel: Int, CaseIterable, Sendable {
    case live, realtime, agent

    var id: String { ["gpt-live-1", "gpt-realtime-2.1-mini", "elevenlabs-agent"][rawValue] }
    var label: String { ["GPT-Live 1", "GPT-Realtime 2.1 mini", "ElevenLabs agent"][rawValue] }
}

enum Meet {
    /// Both directions are mono 16-bit PCM at this rate.
    static let sampleRate = 24000
    static let host = "api.elevenlabs.io"
    /// The agent the app keeps in the user's ElevenLabs workspace, brought up to date as each meeting starts.
    static let agentName = "Briareus meeting assistant"
    /// Fast, and good at choosing tools.
    static let agentLLM = "claude-haiku-4-5"
    /// ElevenLabs' most natural model for real time.
    static let ttsModel = "eleven_v4_turbo"
    /// US dollars per minute of an agent's call, ElevenAgents' rate on every plan (2026-10); the LLM is billed on top.
    static let agentMinuteCost = 0.08
    /// A meeting runs at most this long before ElevenLabs ends it: the most it allows.
    static let maxSeconds = 2 * 60 * 60
    /// The placeholders a prompt the user writes may hold, each filled from the persona.
    static let placeholders = "{name}, {project} and {wake_words}"
}

/// Who the assistant speaks for and how, in a meeting about `project`, with ElevenLabs voice `voice`. An `independent`
/// assistant takes part on its own: it speaks when it judges it useful. Otherwise it speaks only when addressed: when a
/// turn says one of the comma-separated `wakeWords`, and stays silent otherwise.
/// A `prompt` or `firstMessage` the user wrote replaces the one made from these, its placeholders filled.
struct MeetPersona: Equatable, Sendable {
    var name: String?
    var wakeWords: String?
    var project: String?
    var voice: String?
    var introduce = false
    var independent = false
    var prompt: String? = nil
    var firstMessage: String? = nil

    init(name: String? = nil, wakeWords: String? = nil, project: String? = nil, voice: String? = nil, introduce: Bool = false,
         independent: Bool = false, prompt: String? = nil, firstMessage: String? = nil) {
        self.name = name; self.wakeWords = wakeWords; self.project = project; self.voice = voice
        self.introduce = introduce; self.independent = independent; self.prompt = prompt; self.firstMessage = firstMessage
    }

    fileprivate var nameOf: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? "the user" }
    fileprivate var projectOf: String { project.flatMap { $0.isEmpty ? nil : $0 } ?? "this project" }
    fileprivate var wakeWordsOf: String { wakeWords.flatMap { $0.isEmpty ? nil : $0 } ?? nameOf }
}

// MARK: - The agent

extension Meet {
    /// The agent's system prompt: the user's, or the one made from the persona.
    static func instructions(_ p: MeetPersona) -> String {
        if let prompt = p.prompt, !prompt.isEmpty { return fill(prompt, p) }
        return madeInstructions(p)
    }
    /// `text` with {name}, {project} and {wake_words} filled from the persona.
    static func fill(_ text: String?, _ p: MeetPersona) -> String {
        (text ?? "").replacingOccurrences(of: "{name}", with: p.nameOf)
            .replacingOccurrences(of: "{project}", with: p.projectOf)
            .replacingOccurrences(of: "{wake_words}", with: p.wakeWordsOf)
    }
    /// The default prompt with its placeholders unfilled, as the user starts writing from.
    static func defaultPrompt(independent: Bool) -> String {
        madeInstructions(MeetPersona(name: "{name}", wakeWords: "{wake_words}", project: "{project}", introduce: true, independent: independent))
    }
    static func defaultFirstMessage(introduce: Bool) -> String {
        firstMessage(MeetPersona(name: "{name}", introduce: introduce))
    }

    private static func madeInstructions(_ p: MeetPersona) -> String {
        let name = p.nameOf, project = p.projectOf
        var s = "You speak for \(name) in a live meeting, in \(name)'s own voice, through their microphone. Speak as \(name), in the "
            + "first person. You hear everyone else in the meeting. "
        if p.independent {
            s += "Act independently on \(name)'s behalf: join the discussion when you have something useful to add, answer "
                + "questions put to \(name) and give updates as \(name) would. Do not talk over people. When the discussion does "
                + "not need you, call skip_turn and stay silent. "
        } else {
            s += "Speak only when someone addresses you by one of these names: \(p.wakeWordsOf), or asks you to answer. Everything "
                + "else said in the meeting is not for you: call skip_turn and stay silent, without a word. "
        }
        s += "Keep answers short and conversational, in plain spoken English. If someone sincerely asks whether they are "
            + "talking to an AI, do not deny it. "
        s += "The meeting is about the project \(project): use the tools for anything about its conversations, agents, pull "
            + "requests, issues or findings, say briefly that you are checking, and say only what they confirm. Never "
            + "invent project details.\n\n"
        s += MeetTool.instructions(project: project)
        return s
    }

    /// What the assistant says as it joins: the user's, or when `introduce` is set the one made for it; "" otherwise.
    static func firstMessage(_ p: MeetPersona) -> String {
        if let first = p.firstMessage { return fill(first, p) }
        guard p.introduce else { return "" }
        return "Hi everyone, I'm \(p.nameOf)'s AI assistant, joining for them. Ask me anything about the project."
    }

    /// The agent's settings, the body that creates it (POST /v1/convai/agents/create) and brings it up to date (PATCH
    /// /v1/convai/agents/{id}): its name, prompt, LLM, the project's tools by id, skip_turn, the voice and PCM both ways.
    static func agentBody(_ p: MeetPersona, toolIDs: [String]) -> JSON {
        // Turns: a meeting talks among itself, so the agent waits for a turn to end before it judges whether to speak.
        let config: JSON = [
            "asr": ["user_input_audio_format": "pcm_24000"],
            "turn": ["turn_eagerness": "patient"],
            "tts": ["model_id": .string(ttsModel), "voice_id": .string(p.voice ?? ""), "agent_output_audio_format": "pcm_24000"],
            "conversation": ["max_duration_seconds": JSON(maxSeconds)],
            "agent": [
                "first_message": .string(firstMessage(p)),
                "language": "en",
                "prompt": [
                    "prompt": .string(instructions(p)),
                    "llm": .string(agentLLM),
                    "tool_ids": JSON(toolIDs),
                    // skip_turn lets it stay silent through everything not for it.
                    "built_in_tools": ["skip_turn": ["type": "system", "name": "skip_turn", "params": ["system_tool_type": "skip_turn"]]],
                ],
            ],
        ]
        return ["name": .string(agentName), "conversation_config": config]
    }

    /// The conversation WebSocket's path on api.elevenlabs.io for the agent, opened with the API key in a header.
    static func agentWSPath(_ agentID: String?) -> String {
        // Agent ids are letters, digits and underscores; anything else is left out rather than escaped.
        let kept = (agentID ?? "").unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
        return "/v1/convai/conversation?agent_id=" + String(String.UnicodeScalarView(kept))
    }
    /// The path, with its signature, of the `signed_url` ElevenLabs answered for a private agent's conversation; nil when
    /// it is not a wss URL on api.elevenlabs.io.
    static func signedWSPath(_ answer: JSON) -> String? {
        let prefix = "wss://\(host)/"
        guard let url = answer["signed_url"].string, url.hasPrefix(prefix) else { return nil }
        return "/" + url.dropFirst(prefix.count)
    }
    /// The id in an answer that created an agent (`agent_id`) or a tool (`id`); nil without one.
    static func createdID(_ answer: JSON) -> String? { answer["agent_id"].nonEmpty ?? answer["id"].nonEmpty }
}

// MARK: - Events

extension Meet {
    /// The first message on the socket.
    static let startEvent = #"{"type":"conversation_initiation_client_data"}"#
    /// Little-endian samples, as the Mac holds them.
    static func audioEvent(_ pcm: [Int16]) -> String {
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        return #"{"user_audio_chunk":""# + data.base64EncodedString() + #""}"#
    }
    /// The answer to the server's ping `eventID`.
    static func pongEvent(_ eventID: Int) -> String { #"{"type":"pong","event_id":\#(eventID)}"# }
    /// A tool's answer back to the agent.
    static func toolResultEvent(callID: String, result: String, isError: Bool) -> String {
        (["type": "client_tool_result", "tool_call_id": .string(callID), "result": .string(result), "is_error": .bool(isError)] as JSON).serialized()
    }
    /// Asks for an answer to what was just said, whether or not the assistant was addressed.
    static let answerNowEvent = #"{"type":"user_message","text":"Answer the latest question or request in the meeting now, briefly."}"#
}

/// One event the agent's conversation sent.
enum MeetEvent: Equatable, Sendable {
    case other
    /// The conversation started.
    case ready
    /// Speech to play.
    case audio(Data)
    /// A whole turn the meeting said.
    case heardTurn(String)
    /// What the assistant said.
    case said(String)
    /// Someone talked over the assistant: unplayed speech is dropped.
    case interrupted
    /// The agent calls a tool: its call id, its name and its parameters.
    case tool(id: String, name: String, parameters: JSON)
    /// To answer with a pong.
    case ping(Int)
    case error(String)

    /// Reads one server event; nil for text that is not a JSON event.
    init?(_ text: String) {
        guard let e = JSON.parse(text), let type = e["type"].string else { return nil }
        switch type {
        case "conversation_initiation_metadata": self = .ready
        case "audio":
            if let b64 = e["audio_event"]["audio_base_64"].string, let data = Data(base64Encoded: b64) { self = .audio(data) } else { self = .other }
        case "user_transcript": self = .heardTurn(e["user_transcription_event"]["user_transcript"].string ?? "")
        case "agent_response": self = .said(e["agent_response_event"]["agent_response"].string ?? "")
        case "interruption": self = .interrupted
        case "ping": self = .ping(e["ping_event"]["event_id"].int32 ?? 0)
        case "client_tool_call":
            let call = e["client_tool_call"]
            if let id = call["tool_call_id"].nonEmpty, let name = call["tool_name"].nonEmpty {
                self = .tool(id: id, name: name, parameters: call["parameters"].isObject ? call["parameters"] : [:])
            } else { self = .other }
        case "client_error", "error":
            let err = e["error_event"]
            let message = err["message"].nonEmpty ?? err["error_name"].nonEmpty ?? e["message"].nonEmpty
            self = .error("ElevenLabs: \(message ?? "the agent reported an error.")")
        default: self = .other
        }
    }
}

// MARK: - The meeting's transcript

enum MeetSpeaker: Int, Sendable { case meeting = 1, assistant = 2, lookup = 3 }

/// The meeting so far as lines of "Meeting: …", "Assistant: …" and "Lookup: …", the oldest dropped past a limit.
struct MeetLog: Equatable, Sendable {
    static let limit = 24000
    private(set) var text = ""
    private(set) var speaker = 0

    init() {}

    /// Adds a piece of speech; a new speaker starts a new line.
    mutating func add(_ speaker: MeetSpeaker, _ piece: String?) {
        guard var piece, !piece.isEmpty else { return }
        if speaker.rawValue != self.speaker {
            if !text.isEmpty { text += "\n" }
            text += speaker == .assistant ? "Assistant: " : speaker == .lookup ? "Lookup: " : "Meeting: "
            self.speaker = speaker.rawValue
            piece = String(piece.drop { $0 == " " })
        }
        text += piece
        let bytes = Array(text.utf8)
        if bytes.count > Self.limit {
            // The oldest lines go, whole, once the record is well past the limit.
            if let cut = bytes[(bytes.count - Self.limit / 2)...].firstIndex(of: 10) {
                text = String(decoding: bytes[(cut + 1)...], as: UTF8.self)
            }
        }
    }
    /// Adds a whole line: a turn, an answer or a lookup, on its own line even after the same speaker.
    mutating func line(_ speaker: MeetSpeaker, _ line: String?) {
        guard let line, !line.isEmpty else { return }
        self.speaker = 0
        // A line's own line breaks would read as new speakers.
        add(speaker, String(line.map { $0 == "\n" || $0 == "\r" || $0 == "\r\n" ? " " : $0 }))
    }
    /// The last `max` bytes or fewer, starting at a line.
    func tail(_ max: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > max else { return text }
        let from = bytes.count - max
        if let nl = bytes[from...].firstIndex(of: 10) { return String(decoding: bytes[(nl + 1)...], as: UTF8.self) }
        return String(decoding: bytes[from...], as: UTF8.self)
    }

    /// The transcript's lines as who said them and what: the meeting's turns, the assistant's answers and its lookups.
    static func lines(_ transcript: String) -> [(speaker: MeetSpeaker, text: String)] {
        transcript.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            for (prefix, speaker) in [("Meeting: ", MeetSpeaker.meeting), ("Assistant: ", .assistant), ("Lookup: ", .lookup)] where line.hasPrefix(prefix) {
                return (speaker, String(line.dropFirst(prefix.count)))
            }
            return nil
        }
    }
}

extension Meet {
    /// Text made fit to be said: no Markdown or code, whitespace collapsed, cut at a sentence within `max` bytes.
    static func spoken(_ text: String?, _ max: Int) -> String {
        let all = Array((text ?? "").utf8)
        var s: [UInt8] = []
        var fence = false, space = false
        var start = 0
        while start < all.count {
            var end = start
            while end < all.count && all[end] != 10 { end += 1 }
            var p = start
            while p < end && (all[p] == 32 || all[p] == 9) { p += 1 }
            if end - p >= 3 && all[p] == 96 && all[p + 1] == 96 && all[p + 2] == 96 { fence.toggle() }
            else if !fence {
                // A heading's hashes, a quote's mark and a list's bullet are not said.
                while p < end && (all[p] == 35 || all[p] == 62) { p += 1 }
                if p + 1 < end && (all[p] == 45 || all[p] == 42 || all[p] == 43) && all[p + 1] == 32 { p += 2 }
                while p < end {
                    let c = all[p]
                    p += 1
                    if c == 42 || c == 96 || c == 95 || c == 124 { continue }
                    if c == 32 || c == 9 || c == 13 { space = !s.isEmpty; continue }
                    if space { s.append(32); space = false }
                    s.append(c)
                }
                space = !s.isEmpty
            }
            start = end + 1
        }
        guard s.count > max else { return String(decoding: s, as: UTF8.self) }
        // Cut after the last sentence that fits, else at the last space, never inside a UTF-8 sequence.
        var cut = 0
        for i in 0..<max where (s[i] == 46 || s[i] == 33 || s[i] == 63) && (i + 1 >= s.count || s[i + 1] == 32) { cut = i + 1 }
        if cut == 0 { for i in 0..<max where s[i] == 32 { cut = i } }
        if cut == 0 { cut = max; while cut > 0 && s[cut] & 0xC0 == 0x80 { cut -= 1 } }
        return String(decoding: s[..<cut], as: UTF8.self)
    }
}

// MARK: - Cost

/// What a meeting used: the agent's minutes, or for the meetings before it, GPT-Live's voice seconds, Realtime's tokens
/// by kind, the seconds its input transcription heard and the characters ElevenLabs said.
struct MeetUsage: Equatable, Sendable {
    var seconds = 0.0
    var textIn = 0.0, textCached = 0.0, textOut = 0.0, audioIn = 0.0, audioCached = 0.0, audioOut = 0.0
    var transcribedSeconds = 0.0
    var spokenChars = 0.0

    init(seconds: Double = 0, textIn: Double = 0, textCached: Double = 0, textOut: Double = 0, audioIn: Double = 0,
         audioCached: Double = 0, audioOut: Double = 0, transcribedSeconds: Double = 0, spokenChars: Double = 0) {
        self.seconds = seconds; self.textIn = textIn; self.textCached = textCached; self.textOut = textOut
        self.audioIn = audioIn; self.audioCached = audioCached; self.audioOut = audioOut
        self.transcribedSeconds = transcribedSeconds; self.spokenChars = spokenChars
    }

    fileprivate static let keys: [(String, WritableKeyPath<MeetUsage, Double>)] = [
        ("seconds", \.seconds), ("textIn", \.textIn), ("textCached", \.textCached), ("textOut", \.textOut), ("audioIn", \.audioIn),
        ("audioCached", \.audioCached), ("audioOut", \.audioOut), ("transcribedSeconds", \.transcribedSeconds), ("spokenChars", \.spokenChars),
    ]

    /// In US dollars, at the listed rates (2026-10).
    func cost(_ model: MeetModel) -> Double {
        let spoken = spokenChars * 0.00004
        switch model {
        case .agent: return seconds / 60 * Meet.agentMinuteCost
        case .live: return seconds / 60 * 0.05 + spoken
        case .realtime:
            let tokens = (textIn * 0.6 + textCached * 0.06 + textOut * 2.4 + audioIn * 10 + audioCached * 0.3 + audioOut * 20) / 1e6
            return tokens + transcribedSeconds / 60 * 0.0045 + spoken
        }
    }
}

// MARK: - Meeting records

/// One meeting, kept on this computer: how long it ran, what the voice cost, and how many project lookups it made and how
/// fast they came back. Meetings recorded before the tools held what the conversation's agent cost and answered.
struct MeetRecord: Equatable, Sendable {
    var model: MeetModel
    /// Unix seconds.
    var started = 0.0
    /// From joining to leaving.
    var seconds = 0.0
    var usage = MeetUsage()
    /// The conversation agent's cost over the meeting, for meetings before the tools; 0 since.
    var agentCost = 0.0
    /// Tool calls made, and answered.
    var requests = 0, answers = 0
    /// Their waits, added up.
    var answerSeconds = 0.0

    init(model: MeetModel, started: Double = 0, seconds: Double = 0, usage: MeetUsage = MeetUsage(), agentCost: Double = 0,
         requests: Int = 0, answers: Int = 0, answerSeconds: Double = 0) {
        self.model = model; self.started = started; self.seconds = seconds; self.usage = usage; self.agentCost = agentCost
        self.requests = requests; self.answers = answers; self.answerSeconds = answerSeconds
    }

    init?(_ value: JSON) {
        guard let model = MeetModel.allCases.first(where: { $0.id == value["model"].string }) else { return nil }
        self.model = model
        started = value["started"].number ?? 0
        seconds = value["seconds"].number ?? 0
        for (key, path) in MeetUsage.keys { usage[keyPath: path] = value["usage"][key].number ?? 0 }
        agentCost = value["agentCost"].number ?? 0
        requests = value["requests"].int32 ?? 0
        answers = value["answers"].int32 ?? 0
        answerSeconds = value["answerSeconds"].number ?? 0
    }

    var json: JSON {
        var u: JSON = [:]
        for (key, path) in MeetUsage.keys { u[key] = .number(usage[keyPath: path]) }
        // The cost as it was charged then, so a later change of rates does not rewrite history.
        return ["model": .string(model.id), "started": .number(started), "seconds": .number(seconds), "usage": u,
                "voiceCost": .number(usage.cost(model)), "agentCost": .number(agentCost), "requests": JSON(requests),
                "answers": JSON(answers), "answerSeconds": .number(answerSeconds)]
    }
}

struct MeetTotals: Equatable, Sendable {
    var meetings = 0, requests = 0, answers = 0
    var seconds = 0.0, voiceCost = 0.0, agentCost = 0.0, answerSeconds = 0.0

    init() {}
    /// Adds the records (MeetRecord.json objects) up by model.
    static func of(_ records: [JSON]) -> [MeetModel: MeetTotals] {
        var out: [MeetModel: MeetTotals] = [:]
        for m in MeetModel.allCases { out[m] = MeetTotals() }
        for j in records {
            guard let r = MeetRecord(j) else { continue }
            var t = out[r.model]!
            t.meetings += 1
            t.seconds += r.seconds
            t.voiceCost += j["voiceCost"].number ?? r.usage.cost(r.model)
            t.agentCost += r.agentCost
            t.requests += r.requests; t.answers += r.answers; t.answerSeconds += r.answerSeconds
            out[r.model] = t
        }
        return out
    }
}
