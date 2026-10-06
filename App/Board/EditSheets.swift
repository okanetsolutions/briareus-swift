// Edits shared by one pull request and one issue on a phone (the Mac's EditDialogs): the title and description in a sheet
// of their own, the labels or the assignees as a comma-separated list in another, and the assignees' menu that assigns or
// unassigns the user. "Assign me" needs the user's GitHub login, which the API does not give: it is asked the first time
// and kept in the user's defaults, under the key the Mac app keeps it.
import SwiftUI

@MainActor
enum GitHubLogin {
    private static let key = "githubLogin"

    /// The user's own GitHub login, which "Assign me" adds; nil until saved.
    static var current: String? {
        guard let v = UserDefaults.standard.string(forKey: key), !v.isEmpty else { return nil }
        return v
    }
    /// Keeps the first login typed; false when it was left blank.
    @discardableResult
    static func save(_ typed: String) -> Bool {
        guard let first = boardNamesParse(typed, logins: true).first else { return false }
        UserDefaults.standard.set(first, forKey: key)
        return true
    }
}

/// What an edit is asking for: a sheet for the title and description, the labels or the assignees, or the login alert
/// (`assignAfterLogin` assigns the user once it is saved).
enum ItemEdit: String, Identifiable {
    case details, labels, assignees, login, assignAfterLogin
    var id: String { rawValue }
    fileprivate var isSheet: Bool { self == .details || self == .labels || self == .assignees }
}

/// The pull request or issue an edit starts from: `what` is "issue" or "pull request", `body` nil until it is read.
struct ItemEditTarget {
    var what: String
    var number: Int
    var title: String
    var body: String?
    var labels: [PullLabel]
    var assignees: [String]
}

/// Strings as the `labels` or `assignees` an edit sends.
func itemEditList(_ names: [String]) -> JSON { .array(names.map { .string($0) }) }

extension View {
    /// The sheets and the login alert `edit` opens; `send` takes the fields that changed, as `update_pull` or
    /// `update_issue` takes them (a list replaces the old one whole).
    func itemEdits(_ edit: Binding<ItemEdit?>, target: ItemEditTarget, send: @escaping (JSON) -> Void) -> some View {
        modifier(ItemEditPrompts(edit: edit, target: target, send: send))
    }
}

/// The assignees' menu items: assign or unassign the user, edit the list, or change which login is the user's.
struct AssigneesMenuItems: View {
    let assignees: [String]
    @Binding var edit: ItemEdit?
    let send: (JSON) -> Void

    var body: some View {
        let me = GitHubLogin.current
        Button {
            if let me { send(["assignees": itemEditList(boardAssigneesToggle(assignees, login: me).assignees)]) } else { edit = .assignAfterLogin }
        } label: {
            let label = assignMeLabel(assignees, me: me)
            Label(label, systemImage: label == "Assign me" ? "person.badge.plus" : "person.badge.minus")
        }
        Button { edit = .assignees } label: { Label("Edit assignees…", systemImage: "person.2") }
        Section {
            Button { edit = .login } label: {
                Label(me.map { "Change my GitHub login (\($0))…" } ?? "Set my GitHub login…", systemImage: "person.crop.circle")
            }
        }
    }
}

private struct ItemEditPrompts: ViewModifier {
    @Binding var edit: ItemEdit?
    let target: ItemEditTarget
    let send: (JSON) -> Void
    @State private var login = ""
    /// The login alert was opened by Assign me, which goes on once the login is saved.
    @State private var assignAfter = false

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { edit?.isSheet == true ? edit : nil }, set: { if $0 == nil { edit = nil } })) { e in
                Group {
                    switch e {
                    case .details:
                        EditDetailsSheet(caption: "Edit \(target.what) #\(target.number)", title: target.title, body: target.body ?? "") { title, body in
                            if let fields = detailsEdited(title: target.title, body: target.body, newTitle: title, newBody: body) { send(fields) }
                        }
                    case .labels:
                        EditNamesSheet(caption: "Labels of #\(target.number)", hint: "Label names, comma separated. A name with a comma goes in double quotes.",
                                       text: boardLabelNamesJoin(target.labels)) { typed in
                            send(["labels": itemEditList(boardNamesParse(typed, logins: false))])
                        }
                    default:
                        EditNamesSheet(caption: "Assignees of #\(target.number)", hint: "GitHub logins, comma separated (ten at most).",
                                       text: boardNamesJoin(target.assignees)) { typed in
                            send(["assignees": itemEditList(boardNamesParse(typed, logins: true))])
                        }
                    }
                }
                .presentationDetents(e == .details ? [.large] : [.medium, .large])
            }
            .alert("Your GitHub login", isPresented: Binding(get: { edit == .login || edit == .assignAfterLogin }, set: { if !$0 { edit = nil } })) {
                TextField("Login", text: $login).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save") {
                    guard GitHubLogin.save(login), assignAfter else { return }
                    send(["assignees": itemEditList(boardAssigneesToggle(target.assignees, login: GitHubLogin.current).assignees)])
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The GitHub user \u{201C}Assign me\u{201D} adds. It is kept on this device.")
            }
            .onChange(of: edit) { _, e in
                guard e == .login || e == .assignAfterLogin else { return }
                login = GitHubLogin.current ?? ""
                assignAfter = e == .assignAfterLogin
            }
    }
}

/// An issue's or pull request's title and description: the title in a field, the Markdown description in a box under it,
/// and Save, which a blank title keeps off. Hands back the title trimmed and the description as typed.
private struct EditDetailsSheet: View {
    let caption: String
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @FocusState private var focused: Bool
    /// GitHub takes a description of up to 65,536 characters.
    private static let bodyLimit = 65_536

    init(caption: String, title: String, body: String, save: @escaping (String, String) -> Void) {
        self.caption = caption; self.save = save
        _title = State(initialValue: title)
        // GitHub keeps a body as it was typed, often with CRLF; the box shows plain line breaks.
        _text = State(initialValue: body.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") { TextField("Title", text: $title, axis: .vertical).lineLimit(1...4).focused($focused) }
                    .listRowBackground(Theme.row)
                Section("Description (Markdown)") {
                    TextEditor(text: $text).font(.callout.monospaced()).frame(minHeight: 260)
                        .onChange(of: text) { _, v in if v.count > Self.bodyLimit { text = String(v.prefix(Self.bodyLimit)) } }
                }
                .listRowBackground(Theme.row)
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(caption).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { dismiss(); save(title.cTrimmed, text) }.bold().disabled(title.cTrimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

/// A list of labels or logins as one comma-separated box, the current ones in it; an empty box clears them.
private struct EditNamesSheet: View {
    let caption: String
    let hint: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(caption: String, hint: String, text: String, save: @escaping (String) -> Void) {
        self.caption = caption; self.hint = hint; self.save = save
        _text = State(initialValue: text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("None", text: $text, axis: .vertical).lineLimit(3...10).focused($focused)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text(hint + " Saving replaces the whole list on GitHub.")
                }
                .listRowBackground(Theme.row)
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(caption).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { dismiss(); save(text) }.bold() }
            }
            .onAppear { focused = true }
        }
    }
}
