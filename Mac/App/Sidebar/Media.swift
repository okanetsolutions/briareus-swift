// What Spotify (or, without it, Music) is playing, and its ⏮ ⏯ ⏭, for the foot of the sidebar, with the Mac's volume. The
// Windows client reads Windows' media sessions; a Mac publishes none to other apps, so the players are asked over Apple
// Events instead. No Spotify account or Web API: only the desktop app running. Nothing is asked of a player that is not
// running, so the app never launches one. The volume is Core Audio's: the default output device's, as the menu bar's
// Sound sets it, as the Windows client sets the Windows volume rather than the playing app's.
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class Media: ObservableObject {
    static let shared = Media()

    struct State: Equatable {
        var available = false   // a player is running and has a track
        var spotify = false     // and it is Spotify
        var playing = false
        var title = "", artist = ""
        var hasVolume = false   // the output's volume below can be read and set
        var muted = false
        var volume: Float = 0   // 0...1
    }
    /// `mute` flips the output's mute.
    enum Command { case previous, toggle, next, mute }

    @Published private(set) var state = State()
    private var task: Task<Void, Never>?
    private let queue = DispatchQueue(label: "briareus.media")

    private static let players = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]

    /// Reads every second while the app is in the foreground, every five otherwise.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read()
                let seconds: UInt64 = Store.shared.active ? 1 : 5
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }

    private func runningPlayer() -> (id: String, name: String)? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Media.players.first { running.contains($0.0) }.map { ($0.0, $0.1) }
    }

    private func read() async {
        guard let player = runningPlayer() else { if state != State() { state = State() }; return }
        let script = """
        tell application "\(player.name)"
            if player state is stopped then return ""
            set s to (player state as string)
            return s & (ASCII character 31) & (name of current track) & (ASCII character 31) & (artist of current track)
        end tell
        """
        let result: String? = await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                let out = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
                cont.resume(returning: error == nil ? out : nil)
            }
        }
        // Read once the player has answered, so a level set meanwhile (a drag) is not replaced by an older one.
        let volume = SystemVolume.read()
        var next = State()
        if let result, !result.isEmpty {
            let parts = result.components(separatedBy: "\u{1F}")
            next.available = true
            next.spotify = player.id == "com.spotify.client"
            next.playing = parts.first == "playing"
            next.title = parts.count > 1 ? parts[1] : ""
            next.artist = parts.count > 2 ? parts[2] : ""
            if let volume { next.hasVolume = true; next.volume = volume.level; next.muted = volume.muted }
        }
        if next != state { state = next }
    }

    /// Sends ⏮, ⏯ or ⏭ to the player shown; the state follows once the player has acted.
    func send(_ command: Command) {
        if command == .mute {
            // Shown at once: a volume reads back at once.
            if SystemVolume.toggleMute(), let v = SystemVolume.read() { state.volume = v.level; state.muted = v.muted }
            return
        }
        guard let player = runningPlayer() else { return }
        let verb = command == .previous ? "previous track" : command == .next ? "next track" : "playpause"
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(player.name)\" to \(verb)")?.executeAndReturnError(&error)
            Task { @MainActor in await Media.shared.read() }
        }
    }
}

// MARK: - Volume

extension Media {
    /// The wheel's step over the player, in percent.
    static let volumeStep = 5

    /// Sets the output's volume (0...1), which also unmutes it, and shows it at once.
    func setVolume(_ level: Float) {
        let level = min(max(level, 0), 1)
        guard SystemVolume.set(level) else { return }
        state.volume = level
        state.muted = false
    }

    /// The wheel over the player: `notches` steps up (positive) or down from the level shown.
    func stepVolume(_ notches: Int) {
        guard state.hasVolume, notches != 0 else { return }
        setVolume(Float(Self.steppedLevel(state.volume, notches: notches)) / 100)
    }

    /// The level in percent `notches` wheel steps from `volume`, rounded to the step, so a few notches land on 50% and
    /// not 47%.
    static func steppedLevel(_ volume: Float, notches: Int) -> Int {
        let level = Int((volume * 100).rounded()) + volumeStep * notches
        return min(max((level + (level >= 0 ? volumeStep / 2 : 0)) / volumeStep * volumeStep, 0), 100)
    }
}

/// The default output device's volume and mute through Core Audio. A device without a settable volume (some HDMI and
/// USB outputs) reads as nil, and the player shows no slider.
enum SystemVolume {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// The volume (0...1) and whether it is muted, or nil when the output has no volume to read.
    static func read() -> (level: Float, muted: Bool)? {
        guard let device = defaultOutput() else { return nil }
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &a) else { return nil }
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &level) == noErr else { return nil }
        var m = address(kAudioDevicePropertyMute)
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &m) { _ = AudioObjectGetPropertyData(device, &m, 0, nil, &size, &muted) }
        return (min(max(level, 0), 1), muted != 0)
    }

    /// Sets the volume and unmutes; false when the output takes no volume.
    @discardableResult
    static func set(_ level: Float) -> Bool {
        guard let device = defaultOutput() else { return false }
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &a), AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue else { return false }
        var value = Float32(level)
        guard AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr else { return false }
        setMute(device, false)
        return true
    }

    /// Flips the mute; false when the output has none.
    static func toggleMute() -> Bool {
        guard let device = defaultOutput(), let now = read() else { return false }
        return setMute(device, !now.muted)
    }

    @discardableResult
    private static func setMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var m = address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &m), AudioObjectIsPropertySettable(device, &m, &settable) == noErr, settable.boolValue else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &m, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
