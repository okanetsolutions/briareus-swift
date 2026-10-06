// The meeting assistant's sound (the Windows client's app/meet_audio.c and app/loopback.c). It hears the meeting app
// through ScreenCaptureKit, which captures one application's audio as the Windows client's per-app WASAPI loopback does,
// and needs the Screen & System Audio Recording permission; it speaks into a virtual audio device (BlackHole 2ch, or any
// output the user picks), which the meeting app takes as its microphone, as VB-Cable is on Windows. The user's own
// microphone is never opened: the meeting hears only the assistant until the user switches the meeting app back to
// their microphone. Its voice never plays on this Mac's speakers. Everything runs at 24 kHz mono 16-bit, as the agent's
// conversation does.
import AVFoundation
import AppKit
import CoreAudio
import ScreenCaptureKit

/// A running app the assistant can listen to: a meeting app or a browser.
struct MeetApp: Hashable {
    var label: String
    var bundleID: String
    var pid: pid_t
}

enum MeetApps {
    /// The apps meetings are held in, by bundle identifier, with what the menu calls them.
    private static let known: [(id: String, label: String)] = [
        ("com.microsoft.teams2", "Microsoft Teams"), ("com.microsoft.teams", "Microsoft Teams (classic)"), ("us.zoom.xos", "Zoom"),
        ("com.cisco.webexmeetingsapp", "Webex"), ("Cisco-Systems.Spark", "Webex"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"), ("com.apple.FaceTime", "FaceTime"), ("com.google.Chrome", "Google Chrome (Meet)"),
        ("com.microsoft.edgemac", "Microsoft Edge (Meet)"), ("org.mozilla.firefox", "Firefox (Meet)"), ("com.brave.Browser", "Brave (Meet)"),
        ("company.thebrowser.Browser", "Arc (Meet)"), ("com.apple.Safari", "Safari (Meet)"),
    ]

    /// The meeting apps running now, each label once.
    @MainActor static func running() -> [MeetApp] {
        let apps = NSWorkspace.shared.runningApplications
        var found: [MeetApp] = []
        for k in known {
            guard !found.contains(where: { $0.label == k.label }),
                  let app = apps.first(where: { $0.bundleIdentifier == k.id && !$0.isTerminated }) else { continue }
            found.append(MeetApp(label: k.label, bundleID: k.id, pid: app.processIdentifier))
        }
        return found
    }

    /// Whether a capturable application is the meeting app's own or one of its helpers, which play a browser's and an
    /// Electron app's sound (the Windows client listens to the app's whole process tree). Safari plays through WebKit's
    /// shared processes.
    static func belongs(_ bundleID: String, to app: MeetApp) -> Bool {
        if bundleID == app.bundleID || bundleID.hasPrefix(app.bundleID + ".") { return true }
        return app.bundleID == "com.apple.Safari" && bundleID.hasPrefix("com.apple.WebKit.")
    }
}

/// An output device the assistant's voice can be played into.
struct MeetOutputDevice: Hashable {
    var id: AudioDeviceID
    var uid: String
    var name: String
}

enum MeetDevices {
    /// Every device with output channels, as Core Audio lists them.
    static func outputs() -> [MeetOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return MeetOutputDevice(id: id, uid: uid, name: name)
        }
    }
    /// A virtual cable a meeting app can take as its microphone: BlackHole first, then the others.
    static func virtualCable(_ devices: [MeetOutputDevice] = outputs()) -> MeetOutputDevice? {
        for word in ["BlackHole", "Loopback", "VB-Cable", "CABLE", "Soundflower"] {
            if let d = devices.first(where: { $0.name.localizedCaseInsensitiveContains(word) }) { return d }
        }
        return nil
    }
    /// The device saved by `uid`, or the virtual cable when none was chosen.
    static func chosen(_ uid: String, _ devices: [MeetOutputDevice] = outputs()) -> MeetOutputDevice? {
        uid.isEmpty ? virtualCable(devices) : devices.first { $0.uid == uid }
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

// MARK: - Rings

/// One producer, one consumer, under a lock; past `max` samples the oldest go, so a slow reader never adds delay.
final class PCMRing: @unchecked Sendable {
    private var data: [Int16]
    private var read = 0, count = 0
    private let max: Int
    private let lock = NSLock()

    init(capacity: Int, max: Int) { data = [Int16](repeating: 0, count: capacity); self.max = Swift.min(max, capacity) }

    func write(_ pcm: UnsafeBufferPointer<Int16>) {
        lock.lock(); defer { lock.unlock() }
        var pcm = pcm
        if pcm.count > max { pcm = UnsafeBufferPointer(rebasing: pcm[(pcm.count - max)...]) }
        if count + pcm.count > max { let drop = count + pcm.count - max; read = (read + drop) % data.count; count -= drop }
        let at = (read + count) % data.count
        for (i, v) in pcm.enumerated() { data[(at + i) % data.count] = v }
        count += pcm.count
    }
    /// Up to `n` samples, oldest first; fewer when fewer came.
    func take(_ n: Int, into out: UnsafeMutablePointer<Int16>) -> Int {
        lock.lock(); defer { lock.unlock() }
        let taken = Swift.min(n, count)
        for i in 0..<taken { out[i] = data[(read + i) % data.count] }
        read = (read + taken) % data.count; count -= taken
        return taken
    }
    /// `n` samples as floats for the output device, silence past what there was.
    func take(_ n: Int, floats out: UnsafeMutablePointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        let taken = Swift.min(n, count)
        for i in 0..<n { out[i] = i < taken ? Float(data[(read + i) % data.count]) / 32768 : 0 }
        read = (read + taken) % data.count; count -= taken
    }
    func clear() { lock.lock(); read = 0; count = 0; lock.unlock() }
    var available: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - The meeting's sound

/// Why the sound could not start, said to the user.
struct MeetAudioError: Error { var text: String }

final class MeetAudio: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static func ms(_ n: Int) -> Int { Meet.sampleRate * n / 1000 }

    /// What the assistant hears, and its voice.
    private let heard = PCMRing(capacity: ms(5000), max: ms(2000))
    private let said = PCMRing(capacity: ms(120000), max: ms(120000))
    private let queue = DispatchQueue(label: "com.okanetsolutions.briareus.meeting.audio")
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Meet.sampleRate), channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private let mutedLock = NSLock()
    private var isMuted = false
    /// The capture stopped on its own, with why.
    var onStopped: ((String) -> Void)?

    /// Starts hearing `app` (nil: every app but Briareus) and speaking into `device`.
    static func start(app: MeetApp?, device: MeetOutputDevice) async throws -> MeetAudio {
        let audio = MeetAudio()
        do {
            try audio.startSpeaking(device)
            try await audio.startHearing(app)
        } catch {
            audio.stop()
            throw error
        }
        return audio
    }

    private func startSpeaking(_ device: MeetOutputDevice) throws {
        // The voice plays on the chosen device alone, never on the speakers this Mac is set to.
        guard let unit = engine.outputNode.audioUnit else { throw MeetAudioError(text: "The audio output could not be opened.") }
        var id = device.id
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw MeetAudioError(text: "\(device.name) could not be opened for playback.")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(Meet.sampleRate), channels: 1)!
        let said = self.said
        let source = AVAudioSourceNode(format: format) { _, _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            said.take(Int(frames), floats: out)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { throw MeetAudioError(text: "\(device.name) could not start: \(error.localizedDescription)") }
    }

    private func startHearing(_ app: MeetApp?) async throws {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw MeetAudioError(text: "Briareus hears the meeting app through screen and audio recording. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Briareus and join again.")
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw MeetAudioError(text: "The meeting app's sound could not be reached: \(error.localizedDescription)") }
        guard let display = content.displays.first else { throw MeetAudioError(text: "No display to record the meeting app's sound from.") }
        let filter: SCContentFilter
        if let app {
            let apps = content.applications.filter { $0.processID == app.pid || MeetApps.belongs($0.bundleIdentifier, to: app) }
            guard !apps.isEmpty else { throw MeetAudioError(text: "\(app.label) is not running any more.") }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        } else {
            // Every app but this one.
            let me = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Meet.sampleRate
        config.channelCount = 1
        // The picture is not wanted: the smallest, once a second.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw MeetAudioError(text: "The meeting app's sound could not be recorded: \(error.localizedDescription)")
        }
        self.stream = stream
    }

    func stop() {
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        engine.stop()
        heard.clear(); said.clear()
    }

    // MARK: Hearing

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid, let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        if converter == nil || converter?.inputFormat != format { converter = AVAudioConverter(from: format, to: target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, let samples = out.int16ChannelData?[0], out.frameLength > 0 else { return }
        heard.write(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?("The meeting app's sound stopped: \(error.localizedDescription)")
    }

    /// The next `samples` of what the assistant hears from the meeting; silence where nothing came.
    func takeInput(_ samples: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: samples)
        _ = out.withUnsafeMutableBufferPointer { heard.take(samples, into: $0.baseAddress!) }
        return out
    }

    // MARK: Speaking

    /// Queues the assistant's speech, little-endian 16-bit samples, for the virtual microphone.
    func play(_ pcm: Data) {
        guard !muted else { return }
        pcm.withUnsafeBytes { raw in said.write(raw.bindMemory(to: Int16.self)) }
    }
    /// Drops speech not yet played, when someone starts talking over it.
    func flush() { said.clear() }
    /// A muted assistant is not heard in the meeting; its speech is dropped.
    var muted: Bool {
        get { mutedLock.lock(); defer { mutedLock.unlock() }; return isMuted }
        set { mutedLock.lock(); isMuted = newValue; mutedLock.unlock(); if newValue { flush() } }
    }
    /// Whether its speech is still playing.
    var speaking: Bool { said.available > Self.ms(60) }
}
