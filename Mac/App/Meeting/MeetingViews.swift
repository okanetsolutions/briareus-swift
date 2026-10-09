// The meeting assistant on a project (the Windows client's meeting_menu, meeting_prompt_edit and screen_pulls.c's
// Meeting tab): 🎙 Meet's menu in the project's header, the prompt written before joining, and the meeting's transcript
// as a chat.
import AppKit
import SwiftUI

@MainActor
enum MeetingMenu {
    /// 🎙 Meet's menu: join a meeting about `repo`, listening to a meeting app; or, in a meeting, mute, answer now, copy
    /// the transcript or leave.
    static func show(repo: String, title: String) {
        let meeting = Meeting.shared
        var items: [PopupMenu.Item] = []
        var apps: [MeetApp] = []
        enum Choice { case join(MeetApp?), mute, answer, copy, leave, settings }
        var choices: [Choice?] = []
        func add(_ item: PopupMenu.Item, _ choice: Choice?) { items.append(item); choices.append(choice) }
        if meeting.state != .off {
            add(PopupMenu.Item(title: meeting.isFor(repo) ? meeting.status : "A meeting about another project is running", enabled: false), nil)
            add(.separatorItem, nil)
            let live = meeting.state == .live
            add(PopupMenu.Item(title: "Mute the assistant", checked: meeting.muted, enabled: live), .mute)
            add(PopupMenu.Item(title: "Answer now", enabled: live && !meeting.muted), .answer)
            add(PopupMenu.Item(title: "Copy the meeting transcript"), .copy)
            add(.separatorItem, nil)
            add(PopupMenu.Item(title: "Leave the meeting"), .leave)
        } else {
            apps = MeetApps.running()
            add(PopupMenu.Item(title: "Join, listening to", enabled: false), nil)
            for app in apps { add(PopupMenu.Item(title: app.label), .join(app)) }
            add(PopupMenu.Item(title: "Every app except Briareus"), .join(nil))
        }
        add(.separatorItem, nil)
        add(PopupMenu.Item(title: "Meeting assistant settings…"), .settings)
        guard let i = PopupMenu.choose(items), let choice = choices[i] else { return }
        switch choice {
        case .mute: meeting.setMuted(!meeting.muted)
        case .answer: meeting.answerNow()
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(meeting.log.tail(1 << 20), forType: .string)
        case .leave: meeting.leave()
        case .settings:
            Navigator.shared.sidebarMode = .settings
            Navigator.shared.show(.meetingSettings)
        case .join(let app):
            if MeetingPrompt.edit(project: title) { meeting.join(repo: repo, title: title, app: app) }
        }
    }
}

/// The agent's system prompt and first message, written before joining from what was written last or the default;
/// saved for the next meeting on Join.
@MainActor
enum MeetingPrompt {
    private final class Reset: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func edit(project: String) -> Bool {
        var s = MeetingSettings.load()
        let madePrompt = Meet.defaultPrompt(independent: s.independent), madeFirst = Meet.defaultFirstMessage(introduce: s.introduce)
        let alert = NSAlert()
        alert.messageText = "Meeting assistant · \(project)"
        alert.informativeText = ""
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 600
        func label(_ text: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = width
            return l
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        let promptView = scroll.documentView as! NSTextView
        promptView.disableWritingTools()
        promptView.font = .systemFont(ofSize: 13)
        promptView.isRichText = false
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.string = s.prompt.isEmpty ? madePrompt : s.prompt
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        let first = NSTextField(string: s.firstMessage ?? madeFirst)
        first.translatesAutoresizingMaskIntoConstraints = false
        first.widthAnchor.constraint(equalToConstant: width).isActive = true
        let reset = Reset {
            promptView.string = madePrompt
            first.stringValue = madeFirst
        }
        let resetButton = NSButton(title: "Reset to default", target: reset, action: #selector(Reset.run))
        let stack = NSStackView(views: [
            label("System prompt: what the ElevenLabs agent is told. The project's tools and how to use them are part of it."), scroll,
            label("First message: what it says as it joins. Empty: it joins silently."), first,
            label("\(Meet.placeholders) are filled in as it joins. Saved for the next meeting."), resetButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = promptView
        alert.window.disableFieldEditorWritingTools(for: first)
        let joined = withExtendedLifetime(reset) { alert.runModal() == .alertFirstButtonReturn }
        guard joined else { return false }
        var prompt = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstMessage = first.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty prompt is the default.
        if prompt.isEmpty { prompt = madePrompt }
        // Kept as written only when it differs from the default, which follows the settings.
        s.prompt = prompt == madePrompt ? "" : prompt
        s.firstMessage = firstMessage == madeFirst ? nil : firstMessage
        s.save()
        return true
    }
}

/// The meeting as a chat: what the meeting said on the left, the assistant's answers on the right, and each lookup it
/// made between them, live and after the meeting, kept to its latest line.
struct MeetingTranscript: View {
    var transcript: String

    var body: some View {
        let lines = MeetLog.lines(transcript)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty {
                        Text("The assistant is joining. What the meeting says and what it answers shows here.")
                            .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line.speaker, line.text) }
                    Color.clear.frame(height: 6).id("end")
                }
                .padding(.horizontal, Theme.paneMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: lines.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    @ViewBuilder private func row(_ speaker: MeetSpeaker, _ text: String) -> some View {
        if speaker == .lookup {
            Text("🔎 Looked up: \(text.replacingOccurrences(of: "_", with: " "))")
                .font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity)
        } else {
            let mine = speaker == .assistant
            HStack(spacing: 0) {
                if mine { Spacer(minLength: 0) }
                VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                    Text(mine ? "Assistant" : "Meeting").font(Theme.caption).foregroundStyle(Theme.muted)
                    Text(text).font(Theme.body).foregroundStyle(Theme.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(mine ? Theme.accent.opacity(0.18) : Theme.raise))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(mine ? Theme.accentDim : Theme.line, lineWidth: 1))
                }
                .containerRelativeFrame(.horizontal, alignment: mine ? .trailing : .leading) { w, _ in w * 3 / 4 }
                if !mine { Spacer(minLength: 0) }
            }
        }
    }
}
