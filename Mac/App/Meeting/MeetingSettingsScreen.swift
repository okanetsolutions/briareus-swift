// ⚙ Settings → Meeting assistant (the Windows client's screen_meeting_settings.c): this Mac's settings for the assistant
// that joins meetings from a project (🎙 Meet): the ElevenLabs API key, kept in the keychain, the user's ElevenLabs voice,
// who it speaks for and how, the virtual microphone it speaks into, and the time and cost of every meeting recorded here.
import SwiftUI

enum MeetingField: Int, CaseIterable, Hashable {
    case key, voice, name, wake

    var def: SettingsField {
        switch self {
        case .key:
            return SettingsField(key: nil, kind: .text, label: "ElevenLabs API key", cue: "sk_…",
                                 hint: "Needs the ElevenLabs Agents and Text to Speech permissions. Kept in this Mac's keychain only, and sent to api.elevenlabs.io alone.",
                                 mono: true, secret: true)
        case .voice:
            return SettingsField(key: nil, kind: .text, label: "ElevenLabs voice ID", cue: "",
                                 hint: "The voice it speaks with, yours: ElevenLabs → Voices → your voice → ID.", mono: true)
        case .name: return SettingsField(key: nil, kind: .text, label: "Your name", cue: "", hint: "Who the assistant speaks for.")
        case .wake:
            return SettingsField(key: nil, kind: .text, label: "Wake words", cue: "Nadin, assistant, Briareus",
                                 hint: "Comma-separated. An assistant that does not act independently answers only when one of them is said, or on “Answer now”.")
        }
    }
}

@MainActor
final class MeetingSettingsModel: ObservableObject {
    @Published var texts: [MeetingField: String] = [:]
    @Published var independent = false
    @Published var introduce = true
    @Published var outputDevice = ""
    @Published private(set) var saved = MeetingSettings.load()
    @Published private(set) var hasKey = false
    @Published private(set) var devices: [MeetOutputDevice] = []
    @Published private(set) var totals: [MeetModel: MeetTotals] = [:]
    @Published private(set) var dirty = false
    @Published var message: (text: String, ok: Bool)?
    @Published var scrollToken = 0
    private var filling = false

    init() { reload(); fill() }

    func reload() {
        saved = MeetingSettings.load()
        hasKey = MeetingKey.saved
        devices = MeetDevices.outputs()
        totals = MeetTotals.of(MeetingHistory.all())
    }
    private func fill() {
        filling = true
        // A saved key is never shown back; the box says it is there.
        texts = [.key: "", .voice: saved.elevenVoice, .name: saved.name, .wake: saved.wakeWords]
        independent = saved.independent; introduce = saved.introduce; outputDevice = saved.outputDevice
        filling = false
        dirty = false
        Navigator.shared.leaveGuard = nil
    }

    func binding(_ f: MeetingField) -> Binding<String> {
        Binding(get: { self.texts[f] ?? "" }, set: { v in
            guard v != self.texts[f] else { return }
            self.texts[f] = v
            self.changed()
        })
    }
    func toggle(_ independent: Bool) {
        if independent { self.independent.toggle() } else { introduce.toggle() }
        changed()
    }
    func pickDevice() {
        let cable = MeetDevices.virtualCable(devices)
        var items = [PopupMenu.Item(title: cable.map { "The virtual cable found (\($0.name))" } ?? "The virtual cable found (none yet)", checked: outputDevice.isEmpty)]
        items += devices.map { PopupMenu.Item(title: $0.name, checked: $0.uid == outputDevice) }
        guard let chosen = PopupMenu.choose(items) else { return }
        let uid = chosen == 0 ? "" : devices[chosen - 1].uid
        guard uid != outputDevice else { return }
        outputDevice = uid
        changed()
    }
    func checkDevices() { devices = MeetDevices.outputs() }

    private func changed() {
        guard !filling else { return }
        if !dirty { dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard dirty else { return true }
        let leave = confirmDiscard("The meeting assistant's settings have not been saved.")
        if leave { dirty = false }
        return leave
    }
    private func show(_ text: String, ok: Bool) { message = (text, ok); scrollToken += 1 }

    func save() {
        let key = (texts[.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do { try MeetingKey.save(key) } catch { show("The key could not be saved in the keychain.", ok: false); return }
        }
        var next = saved
        next.name = (texts[.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        next.wakeWords = (texts[.wake] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        next.elevenVoice = (texts[.voice] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        next.independent = independent; next.introduce = introduce; next.outputDevice = outputDevice
        next.save()
        reload(); fill()
        Meeting.shared.keyChanged()
        show(Meeting.shared.state != .off ? "Saved. The meeting under way keeps its settings until you join again." : "Saved.", ok: true)
    }
    func removeKey() {
        guard Dialogs.confirm("Remove the ElevenLabs API key?", "Meetings cannot be joined from this Mac until a key is saved again. The key itself stays valid at ElevenLabs.",
                              continueLabel: "Remove", destructive: true) else { return }
        if MeetingKey.remove() { reload(); Meeting.shared.keyChanged(); show("The key was removed from this Mac.", ok: true) }
        else { show("The key could not be removed from the keychain.", ok: false) }
    }
    func clearHistory() {
        guard Dialogs.confirm("Clear the meeting history?", "The times and costs of every meeting recorded on this Mac are deleted.",
                              continueLabel: "Clear", destructive: true) else { return }
        MeetingHistory.clear()
        reload()
    }
}

struct MeetingSettingsScreen: View {
    @StateObject private var model = MeetingSettingsModel()
    @FocusState private var focus: MeetingField?

    var body: some View {
        SettingsPage(header: header, unavailable: nil, scrollToken: model.scrollToken) {
            Color.clear.frame(height: 8)
            if let m = model.message {
                if m.ok {
                    Label(m.text, systemImage: "checkmark").font(Theme.footnote).foregroundStyle(Theme.ok).padding(.bottom, 14)
                } else {
                    NoticeBox(message: m.text).padding(.bottom, 14)
                }
            }
            SettingsNote(text: "On a project, 🎙 Meet joins your meeting: the assistant hears the meeting app, speaks through a virtual microphone, and looks up the project's conversations, pull requests, findings and issues. It only reads: it never starts, messages, merges or closes anything.")
            SettingsPair { field(.key) } right: { field(.voice) }
            SettingsPair { field(.name) } right: { field(.wake) }
            SettingsCheck(label: "Act independently: take part on my behalf and answer what is asked of me", on: model.independent) { model.toggle(true) }
                .padding(.bottom, 6)
            SettingsCheck(label: "Introduce itself as my AI assistant when it joins", on: model.introduce) { model.toggle(false) }
                .padding(.bottom, 6)
            SettingsNote(text: model.independent
                         ? "Acting independently, it decides for itself when to speak. It still says it is an AI if sincerely asked."
                         : "Otherwise it speaks only when you or it are addressed by a wake word, or when you choose “Answer now”.")
            microphone
            history
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in model.save() }
        .onAppear {
            // The history grows with each meeting left meanwhile.
            if !model.dirty { model.reload() }
        }
    }

    private var header: PaneHeader {
        var buttons = [HeaderButton(glyph: Glyph.symbol(0xE74E), label: "Save", tip: "Save (⌘S)", enabled: model.dirty, prominent: true) { model.save() }]
        if model.hasKey {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Remove the ElevenLabs API key from this Mac", destructive: true) { model.removeKey() })
        }
        return PaneHeader(title: "Meeting assistant",
                          subtitle: "\(model.hasKey ? "ElevenLabs API key saved" : "no ElevenLabs API key yet") · settings on this Mac", buttons: buttons)
    }

    private func field(_ f: MeetingField) -> some View {
        SettingsFieldBox(def: f.def, text: model.binding(f), hint: f == .key && model.hasKey ? "A key is saved: type a new key to replace it. " + (f.def.hint ?? "") : nil,
                         focus: $focus, key: f) {
            focus = MeetingField(rawValue: (f.rawValue + 1) % MeetingField.allCases.count)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).padding(.top, 12).padding(.bottom, 8)
    }

    /// The virtual microphone: the output device the assistant speaks into, which the meeting app takes as its microphone.
    @ViewBuilder private var microphone: some View {
        heading("Virtual microphone")
        let device = MeetDevices.chosen(model.outputDevice, model.devices)
        SettingsLabeledSelect(label: "Speaks into", text: model.outputDevice.isEmpty ? "The virtual cable found\(device.map { " (\($0.name))" } ?? "")"
                                                                                  : device?.name ?? "A device not connected now",
                              hint: "The output the assistant's voice plays on. A virtual cable such as BlackHole 2ch passes it to the meeting app as a microphone.") {
            model.pickDevice()
        }
        if let device {
            Label("\(device.name) is ready. In your meeting app, pick “\(device.name)” as the microphone and keep your usual speakers. The meeting then hears only the assistant, never your microphone: to speak yourself, switch the meeting app back to your microphone. The assistant speaks only into the meeting, so you will not hear it yourself: its words are in the project's 🎙 Meeting tab. It hears the meeting app through Screen & System Audio Recording, which macOS asks you to allow the first time.",
                  systemImage: "checkmark")
                .font(Theme.footnote).foregroundStyle(Theme.ok).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
        } else {
            Notice(message: model.outputDevice.isEmpty
                   ? "No virtual cable is installed. Install BlackHole 2ch (free, from existential.audio): it is the microphone the assistant speaks into."
                   : "The chosen device is not connected.")
            Button("Check again") { model.checkDevices() }.dashButton(.bordered).padding(.top, 8).padding(.bottom, 10)
        }
    }

    private func money(_ dollars: Double) -> String { String(format: dollars < 10 ? "$%.3f" : "$%.2f", dollars) }
    private func duration(_ seconds: Double) -> String {
        let s = Int(seconds + 0.5)
        return s >= 3600 ? String(format: "%dh %02dm", s / 3600, s / 60 % 60) : String(format: "%dm %02ds", s / 60, s % 60)
    }

    /// One model's meetings: what they took and cost. The GPT models' are only those another client recorded before
    /// the agent.
    private func modelBox(_ m: MeetModel) -> some View {
        let t = model.totals[m] ?? MeetTotals()
        let minutes = t.seconds / 60
        return BoardBox(padding: 12, radius: 8) {
            Text(m.label).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).padding(.bottom, 6)
            SettingsStatusRow(label: "Meetings", value: "\(t.meetings)")
            SettingsStatusRow(label: "Time in meetings", value: duration(t.seconds))
            SettingsStatusRow(label: "Voice", value: money(t.voiceCost))
            // Meetings before the tools asked the conversation's agent, which cost apart.
            if t.agentCost > 0 { SettingsStatusRow(label: "Conversation agent", value: money(t.agentCost)) }
            SettingsStatusRow(label: "Total", value: money(t.voiceCost + t.agentCost))
            SettingsStatusRow(label: "Per minute", value: minutes > 0 ? money((t.voiceCost + t.agentCost) / minutes) : "—")
            SettingsStatusRow(label: m == .live ? "Agent questions answered" : "Project lookups answered", value: "\(t.answers) of \(t.requests)")
            SettingsStatusRow(label: m == .live ? "Average answer time" : "Average lookup time",
                              value: t.answers > 0 ? String(format: "%.1f s", t.answerSeconds / Double(t.answers)) : "—")
        }
    }

    @ViewBuilder private var history: some View {
        heading("Meetings on this Mac")
        SettingsNote(text: "From joining to leaving. Voice is the ElevenLabs agent at $0.08 a minute, its LLM billed apart.")
        // The GPT models' boxes only while meetings recorded with them remain.
        let older = [MeetModel.realtime, .live].filter { (model.totals[$0]?.meetings ?? 0) > 0 }
        VStack(alignment: .leading, spacing: 14) {
            modelBox(.agent)
            ForEach(older, id: \.self) { modelBox($0) }
        }
        let any = MeetModel.allCases.contains { (model.totals[$0]?.meetings ?? 0) > 0 }
        Button("Clear the history") { model.clearHistory() }.dashButton(.bordered).disabled(!any).padding(.top, 12)
    }
}
