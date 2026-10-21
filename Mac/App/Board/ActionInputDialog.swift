// The errand input dialog (dialog_action_input): the question an errand such as Give feedback asks before its paid
// session starts, with the saved prompts (📚) and a voice note to fill its box.
import AppKit
import SwiftUI

/// Asks for an errand's input when it takes one; the others start straight away. Nil when cancelled.
@MainActor
func actionPrompt(_ action: BoardAction, repo: String, number: Int) -> String?? {
    guard action.input != nil else { return .some(nil) }
    guard let text = ActionInputDialog.run(action: action, repo: repo, number: number) else { return nil }
    return .some(text)
}

// MARK: - Errand input

/// The errand's question (dialog_action_input): its label as the title, the question, a box for the answer with the saved
/// prompts (📚) and a voice note button, and what it costs; Start stays off while a required answer is empty. Returns the answer trimmed.
@MainActor
enum ActionInputDialog {
    static func run(action: BoardAction, repo: String, number: Int) -> String? {
        let state = InputState()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 651, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = action.label
        let finish: (Bool) -> Void = { ok in
            state.confirmed = ok
            state.voice.discard()
            NSApp.stopModal()
            panel.orderOut(nil)
        }
        panel.contentViewController = NSHostingController(rootView: ActionInputView(action: action, repo: repo, number: number, state: state, finish: finish).noWritingTools())
        panel.center()
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in if NSApp.modalWindow === panel { NSApp.stopModal() } }
        }
        NSApp.runModal(for: panel)
        NotificationCenter.default.removeObserver(closeObserver)
        state.voice.discard()
        return state.confirmed ? state.text.cTrimmed : nil
    }
}

@MainActor
private final class InputState: ObservableObject {
    @Published var text = ""
    var confirmed = false
    let voice = BoardVoiceNote()
}

private struct ActionInputView: View {
    var action: BoardAction
    /// The project, whose own saved prompts 📚 lists beside the ones offered everywhere.
    var repo: String
    var number: Int
    @ObservedObject var state: InputState
    var finish: (Bool) -> Void
    @ObservedObject private var voice: BoardVoiceNote

    init(action: BoardAction, repo: String, number: Int, state: InputState, finish: @escaping (Bool) -> Void) {
        self.action = action; self.repo = repo; self.number = number; self.state = state; self.finish = finish
        voice = state.voice
    }

    private var canStart: Bool { !(state.text.cTrimmed.isEmpty && (action.input?.required ?? false)) }
    @FocusState private var focused: Bool

    /// IDD_ACTION_INPUT is 372×222 dialog units in Segoe UI 10pt, about 1.75 by 2.25 pixels a unit: the hint at the top,
    /// the box under it, the recording line with the voice button at its right, the note, then Start and Cancel at the
    /// bottom right. Every text is the dialog's 13px font; the hint in the text colour, the rest secondary.
    var body: some View {
        let hint = (action.input?.placeholder).flatMap { $0.isEmpty ? nil : $0 } ?? action.input?.label ?? ""
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: hint).font(Theme.footnote).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                .frame(height: 22, alignment: .leading)
            TextEditor(text: $state.text)
                .font(Theme.footnote).scrollContentBackground(.hidden)
                .focused($focused)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.accent : Theme.line, lineWidth: 1))
                .frame(height: 247)
                .padding(.top, 9).padding(.horizontal, 4)
            HStack(spacing: 8) {
                if SavedPrompts.offered {
                    PromptsButton(repo: repo, text: state.text) { prompt in
                        state.text = prompt.inserted(into: state.text)
                        focused = true
                    }
                }
                if Store.shared.canTranscribe {
                    Text(verbatim: voice.state == .recording ? "Recording \(formatClock(voice.elapsed)) · Esc discards" : "")
                        .font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Button(voice.buttonLabel) { voice.toggle(append) }
                        .dashButton(.bordered).frame(width: 192).disabled(!(voice.state == .idle || voice.state == .recording))
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 40)
            .padding(.top, 18)
            Text(verbatim: "\(action.hint). This runs a paid agent on pull request #\(number) and may write to GitHub.")
                .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 50, alignment: .topLeading)
                .padding(.top, 18)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Start") { finish(true) }.dashButton(.prominent, stretch: true).frame(width: 98).disabled(!canStart)
                Button("Cancel") { finish(false) }.dashButton(.bordered, stretch: true).frame(width: 98).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
        .frame(width: 651)
        .background(Theme.canvas)
        .onAppear { focused = true }
    }

    /// A transcript joins the box as append_control_text joins it: a space first unless the box is empty or ends in one.
    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        let gap = state.text.isEmpty || state.text.last.map { $0 == " " || $0 == "\n" || $0 == "\t" } == true ? "" : " "
        state.text += gap + text
    }
}
