import Foundation

/// What the voice mode connects with: the OpenAI API key, kept in this device's Keychain, and the choices kept in
/// its defaults.
@MainActor
final class VoiceSettings: ObservableObject {
    static let shared = VoiceSettings()

    private static let account = "openai"
    private enum Key { static let voice = "voice.voice", idle = "voice.idleMinutes" }

    @Published private(set) var hasKey: Bool
    @Published var voice: String { didSet { UserDefaults.standard.set(voice, forKey: Key.voice) } }
    /// Minutes of silence after which a conversation ends by itself, as GPT-Realtime bills the audio it hears.
    @Published var idleMinutes: Int { didSet { UserDefaults.standard.set(idleMinutes, forKey: Key.idle) } }

    private init() {
        let d = UserDefaults.standard
        hasKey = ((try? Keychain.read(Self.account, service: Keychain.voice)) ?? nil) != nil
        voice = d.string(forKey: Key.voice).flatMap { Voice.voices.contains($0) ? $0 : nil } ?? Voice.defaultVoice
        idleMinutes = d.object(forKey: Key.idle) as? Int ?? 3
    }

    func key() throws -> String? { try Keychain.read(Self.account, service: Keychain.voice) }

    func save(key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try Keychain.save(key, origin: Self.account, service: Keychain.voice)
        hasKey = true
    }

    func removeKey() throws {
        try Keychain.remove(Self.account, service: Keychain.voice)
        hasKey = false
    }
}

/// The finished conversations, kept on this phone to show their time and cost in Settings.
@MainActor
final class VoiceHistory: ObservableObject {
    static let shared = VoiceHistory()
    private static let key = "voice.history"
    /// The newest kept; older ones fall off.
    private static let limit = 1000

    @Published private(set) var records: [VoiceRecord]

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key).flatMap(JSON.parse) ?? []
        records = saved.items.compactMap(VoiceRecord.init)
    }

    var tally: VoiceTally { VoiceTally(records) }

    func add(_ record: VoiceRecord) {
        records.append(record)
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(JSON.array(records.map(\.json)).serialized(), forKey: Self.key)
    }
}
