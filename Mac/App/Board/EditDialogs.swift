// Edits shared by one pull request and one issue (screen_pulls.c, MARK: - Edits): the title and description in a dialog of
// their own (dialog_edit_item), the labels as a comma-separated list, and the assignees from a ▾ menu that assigns or
// unassigns the user. "Assign me" needs the user's GitHub login, which the API does not give: it is asked the first time
// and kept in the user's defaults, as the Windows client keeps it in the registry.
import AppKit
import SwiftUI

@MainActor
enum BoardEdits {
    private static let loginKey = "githubLogin"

    /// The user's own GitHub login, which "Assign me" adds; nil until saved.
    static var login: String? {
        guard let v = UserDefaults.standard.string(forKey: loginKey), !v.isEmpty else { return nil }
        return v
    }
    /// Asks for the login, the saved one filled in; false when cancelled or left blank.
    @discardableResult
    static func askLogin() -> Bool {
        guard let typed = Dialogs.text("Your GitHub login", label: "The GitHub user \u{201C}Assign me\u{201D} adds", okLabel: "Save", current: login ?? "") else { return false }
        guard let first = boardNamesParse(typed, logins: true).first else { return false }
        UserDefaults.standard.set(first, forKey: loginKey)
        return true
    }

    /// The ▾ beside the assignees: assign or unassign the user, edit the list, or change which login "me" is. What the pick
    /// sends as `assignees`, which replaces GitHub's list whole, or nil for nothing to send. `current` is copied by the
    /// caller before the menu opens, since the screen may read them again while it is up.
    static func assignees(_ current: [String], number: Int) -> [String]? {
        let items = [BoardPopupMenu.Item(title: assignMeLabel(current, me: login)), BoardPopupMenu.Item(title: "Edit assignees…"), .divider,
                     BoardPopupMenu.Item(title: login.map { "Change my GitHub login (\($0))…" } ?? "Set my GitHub login…")]
        switch BoardPopupMenu.show(items) {
        case 0:
            if login == nil && !askLogin() { return nil }
            return boardAssigneesToggle(current, login: login).assignees
        case 1:
            guard let typed = Dialogs.text("Assignees of #\(number)", label: "GitHub logins, comma separated (ten at most)", okLabel: "Save",
                                           current: boardNamesJoin(current)) else { return nil }
            return boardNamesParse(typed, logins: true)
        case 3:
            askLogin()
            return nil
        default:
            return nil
        }
    }

    /// The labels typed over the current ones, or nil when cancelled.
    static func labels(_ current: [PullLabel], number: Int) -> [String]? {
        guard let typed = Dialogs.text("Labels of #\(number)", label: "Label names, comma separated", okLabel: "Save",
                                       current: boardLabelNamesJoin(current)) else { return nil }
        return boardNamesParse(typed, logins: false)
    }

    /// The title and description after the edit dialog, as only the fields that changed; nil when cancelled or unchanged.
    /// `what` is "issue" or "pull request".
    static func details(_ what: String, number: Int, title: String, body: String) -> JSON? {
        guard let edited = EditItemDialog.run(caption: "Edit \(what) #\(number)", title: title, body: body) else { return nil }
        return detailsEdited(title: title, body: body, newTitle: edited.title, newBody: edited.body)
    }

    /// Strings as the `labels` or `assignees` an edit sends.
    static func list(_ names: [String]) -> JSON { .array(names.map { .string($0) }) }
}

// MARK: - Edit dialog

/// An issue's or pull request's title and description (dialog_edit_item): the title in a field, the Markdown description in
/// a box under it, and Save, which a blank title keeps off. Returns the title trimmed and the description as typed.
@MainActor
private enum EditItemDialog {
    static func run(caption: String, title: String, body: String) -> (title: String, body: String)? {
        let state = EditItemState()
        state.title = title
        // GitHub keeps a body as it was typed, often with CRLF; the box shows plain line breaks.
        state.body = body.replacingOccurrences(of: "\r\n", with: "\n")
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 651, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = caption
        let finish: (Bool) -> Void = { ok in
            state.confirmed = ok
            NSApp.stopModal()
            panel.orderOut(nil)
        }
        panel.contentViewController = NSHostingController(rootView: EditItemView(state: state, finish: finish))
        panel.center()
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in if NSApp.modalWindow === panel { NSApp.stopModal() } }
        }
        NSApp.runModal(for: panel)
        NotificationCenter.default.removeObserver(closeObserver)
        guard state.confirmed, !state.title.cTrimmed.isEmpty else { return nil }
        return (state.title.cTrimmed, state.body)
    }
}

@MainActor
private final class EditItemState: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    var confirmed = false
}

private struct EditItemView: View {
    @ObservedObject var state: EditItemState
    var finish: (Bool) -> Void
    @FocusState private var focus: Field?
    private enum Field { case title, body }
    /// GitHub takes a description of up to 65,536 characters.
    private static let bodyLimit = 65_536

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Title").font(Theme.footnote).foregroundStyle(Theme.muted).frame(height: 22, alignment: .leading)
            TextField("", text: $state.title)
                .textFieldStyle(.plain).font(Theme.footnote)
                .focused($focus, equals: .title)
                .padding(.horizontal, 8).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focus == .title ? Theme.accent : Theme.line, lineWidth: 1))
                .onSubmit { if canSave { finish(true) } }
            Text("Description (Markdown)").font(Theme.footnote).foregroundStyle(Theme.muted).frame(height: 22, alignment: .leading).padding(.top, 12)
            TextEditor(text: $state.body)
                .font(Theme.monoSmall).scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focus == .body ? Theme.accent : Theme.line, lineWidth: 1))
                .frame(minHeight: 280, maxHeight: .infinity)
                .onChange(of: state.body) { _, v in if v.count > Self.bodyLimit { state.body = String(v.prefix(Self.bodyLimit)) } }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Save") { finish(true) }.dashButton(.prominent, stretch: true).frame(width: 98).disabled(!canSave)
                Button("Cancel") { finish(false) }.dashButton(.bordered, stretch: true).frame(width: 98).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 16)
        .frame(minWidth: 520, minHeight: 440)
        .background(Theme.canvas)
        .onAppear { focus = .title }
    }

    private var canSave: Bool { !state.title.cTrimmed.isEmpty }
}
