// A session's ⚡ Webhook, as the Mac's screen (WebhookScreen.swift) on a phone: whether an outside system may post to
// wake the session, the caps the turns it starts run under, the second webhook that takes the operator's own
// instructions, and the URLs and keys a sender needs, with Rotate Keys to end the old ones. An admin token's, read and
// written through /sessions/{id}/webhook; pushed from the conversation's menu.
import SwiftUI

/// The two caps, each a whole number in its range.
private enum WebhookField: Hashable, CaseIterable {
    case perHour, maxTurns
    var key: String { self == .perHour ? "perHour" : "maxTurns" }
    var label: String { self == .perHour ? "Deliveries an hour" : "Turns in a row" }
    var hint: String {
        self == .perHour ? "Past it a sender is answered 429 with Retry-After. From 1 to 600."
            : "Turns deliveries may start with no word from you; past it the webhook pauses until you say anything in the conversation (or save this form). From 1 to 1000."
    }
    var range: ClosedRange<Int> { self == .perHour ? 1...600 : 1...1000 }
    var fallback: Int { self == .perHour ? 30 : 10 }
    var def: SettingsField { SettingsField(key: key, kind: .number, label: label, hint: hint) }
}

/// The three switches, by the key they are sent under.
private enum WebhookToggle: String, CaseIterable {
    case armed, instructions, sshUnattended
    var label: String {
        switch self {
        case .armed: return "Take deliveries"
        case .instructions: return "Take instructions too"
        case .sshUnattended: return "SSH unattended"
        }
    }
    var detail: String {
        switch self {
        case .armed: return "An outside system may post to wake the session."
        case .instructions: return "A second URL and key whose messages reach the agent as your word."
        case .sshUnattended: return "An SSH server in allow mode runs commands unapproved in a turn a delivery started."
        }
    }
}

/// What Copy and Show are about.
private enum WebhookValue: String { case url, key, instructionsUrl, instructionsKey }

@MainActor
private final class WebhookModel: ObservableObject {
    let session: Session
    /// The server's last answer, a Webhook.
    @Published private(set) var hook: JSON?
    @Published var toggles: [WebhookToggle: Bool] = [:]
    @Published var texts: [WebhookField: String] = [:]
    @Published var shownKeys: Set<WebhookValue> = []
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var dirty = false
    /// The read failed.
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    @Published private(set) var messageOK = false
    @Published var scrollToken = 0

    init(session: Session) { self.session = session }

    func string(_ key: String) -> String? { hook?[key].nonEmpty }
    var armed: Bool { hook?["armed"].is(true) ?? false }
    func on(_ t: WebhookToggle) -> Bool { toggles[t] ?? false }

    /// The form shows what the server answered, dropping anything unsaved.
    private func fill() {
        guard let hook else { return }
        for t in WebhookToggle.allCases { toggles[t] = hook[t.rawValue].is(true) }
        for f in WebhookField.allCases { texts[f] = String(hook[f.key].int ?? f.fallback) }
        dirty = false
    }

    func binding(_ f: WebhookField) -> Binding<String> {
        Binding(get: { self.texts[f] ?? "" }, set: { v in
            // Digits only, as the C client's ES_NUMBER edits take.
            let value = v.filter { $0.isASCII && $0.isNumber }
            guard value != self.texts[f] else { return }
            self.texts[f] = value
            self.dirty = true
        })
    }
    func toggle(_ t: WebhookToggle) -> Binding<Bool> {
        Binding(get: { self.on(t) }, set: { v in
            guard !self.busy, v != self.on(t) else { return }
            self.toggles[t] = v
            // Instructions ride on the webhook: turning it off turns them off with it.
            if t == .armed && !v { self.toggles[.instructions] = false }
            self.dirty = true
        })
    }

    // MARK: Reading and writing

    /// A pause or a held delivery may have come meanwhile; what is being typed is kept.
    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let answer = try await Store.shared.call("session_webhook", ["sessionId": .string(session.id)])
            error = nil
            hook = answer
            if !dirty { fill() }
        } catch {
            if let text = failure(error) { self.error = text }
        }
    }

    private func show(_ text: String?, ok: Bool) {
        message = text; messageOK = ok
        if !ok { scrollToken += 1 }
    }

    private func submit(_ operation: String, _ body: JSON = [:]) {
        busy = true; message = nil
        var args = body
        args["sessionId"] = .string(session.id)
        Task {
            defer { busy = false }
            do {
                let answer = try await Store.shared.call(operation, args)
                hook = answer
                fill()
                shownKeys = []
                show(operation == "rotate_session_webhook" ? "Keys rotated. A sender holding the old key is refused until it is given the new one." : "Saved.", ok: true)
                // The conversation's menu says whether deliveries are on, from the session record.
                if let repo = session.repo { Task { try? await Store.shared.feed(repo).loadSessions(fresh: true) } }
            } catch {
                if let text = failure(error) { show(text, ok: false) }
            }
        }
    }

    /// The field at fault when the form cannot be sent, after saying why.
    @discardableResult
    func save() -> WebhookField? {
        guard !busy, hook != nil else { return nil }
        var body: JSON = [:]
        for t in WebhookToggle.allCases { body[t.rawValue] = .bool(on(t)) }
        for f in WebhookField.allCases {
            guard let n = Int((texts[f] ?? "").cTrimmed), f.range.contains(n) else {
                show("\(f.label) must be a whole number from \(f.range.lowerBound) to \(f.range.upperBound).", ok: false)
                return f
            }
            body[f.key] = JSON(n)
        }
        submit("set_session_webhook", body)
        return nil
    }
    func rotate() { if !busy { submit("rotate_session_webhook") } }

    func copy(_ v: WebhookValue) {
        guard let value = string(v.rawValue) else { return }
        Pasteboard.copy(value)
        show(v == .key || v == .instructionsKey ? "Key copied." : "URL copied.", ok: true)
    }
}

struct WebhookScreen: View {
    @StateObject private var model: WebhookModel
    @FocusState private var focus: WebhookField?
    @EnvironmentObject private var store: Store
    @State private var confirmRotate = false

    init(session: JSON) {
        _model = StateObject(wrappedValue: WebhookModel(session: Session(raw: session)))
    }

    var body: some View {
        if let why = settingsUnavailableReason("session_webhook", path: "/webhook", what: "A session's webhook", manage: "it") {
            SettingsUnavailableView(text: why).navigationTitle("\u{26A1} Webhook")
        } else {
            screen
        }
    }

    private var paused: String? { model.string("paused") }

    private var screen: some View {
        ScrollViewReader { proxy in
            Form {
                Section { EmptyView() } footer: { Text("\(model.session.displayTitle) \u{00B7} \(state)") }
                if let message = model.message {
                    if model.messageOK {
                        Section { SettingsVerdict(text: message, ok: true) }.listRowBackground(Theme.row)
                    } else {
                        SettingsErrorSection(error: message)
                    }
                }
                if model.hook != nil {
                    form
                } else if let error = model.error {
                    SettingsErrorSection(error: error)
                    Section { Button("Try Again") { Task { await model.load() } }.disabled(model.loading) }.listRowBackground(Theme.row)
                } else {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }.listRowBackground(Color.clear)
                }
            }
            .onChange(of: model.scrollToken) { _, _ in withAnimation { proxy.scrollTo(settingsErrorID, anchor: .top) } }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .modifier(SettingsFormChrome(
            title: "\u{26A1} Webhook", dirty: model.dirty, discardMessage: "The webhook's settings have not been saved.",
            saveTitle: "Save", canSave: model.hook != nil && !model.busy && (model.dirty || paused != nil) && store.supports("set_session_webhook"),
            saving: model.busy, onSave: save))
        .alert("Rotate the webhook keys?", isPresented: $confirmRotate) {
            Button("Rotate", role: .destructive) { model.rotate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New keys replace both of this session's webhook keys. A sender holding an old key is refused until it is given the new one.")
        }
    }

    private var state: String {
        model.hook == nil ? (model.error != nil ? "could not be read" : "reading\u{2026}")
            : paused != nil ? "paused" : model.armed ? "on" : "off"
    }

    private func save() {
        focus = nil
        if let f = model.save() { focus = f }
    }

    @ViewBuilder private var form: some View {
        let unfit = model.string("unfit")
        let editable = !model.busy && store.supports("set_session_webhook")
        let held = model.hook?["held"].int ?? 0
        if (unfit != nil && !model.armed) || paused != nil || held > 0 {
            Section {
                if let unfit, !model.armed { notice(unfit, "exclamationmark.triangle.fill", Theme.danger) }
                if let paused { notice("Paused. \(paused) Saving this form lifts the pause.", "pause.circle.fill", Theme.warning) }
                if held > 0 {
                    notice(held == 1 ? "1 delivery is waiting for the turn under way, or for your answer."
                           : "\(held) deliveries are waiting for the turn under way, or for your answer.", "tray.full", Theme.warning)
                }
            }
            .listRowBackground(Theme.row)
        }
        Section {
            check(.armed, enabled: editable && (unfit == nil || model.on(.armed)))
            ForEach(WebhookField.allCases, id: \.self) { f in
                SettingsTextRow(def: f.def, text: model.binding(f), enabled: editable, focus: $focus, key: f, onSubmit: save)
            }
            check(.sshUnattended, enabled: editable)
            check(.instructions, enabled: editable && model.on(.armed))
        } footer: {
            Text("An outside system (a support platform relaying what a customer wrote, an alert, a CI) posts to the URL to wake the session with a message. What arrives is information, never your word: it answers no question, waits for the turn under way to end, and everything held goes to the agent as one turn of its own. A closed session is woken for it.\n\nInstructions are for a bridge that sorts messages by who wrote them (a WhatsApp relay sending your own number's messages there and everybody else's to the first URL): they answer the question the agent stands on and queue behind a turn like a message typed here. Each URL has a key of its own; neither opens the other.")
        }
        .listRowBackground(Theme.row)

        let url = model.string("url"), key = model.string("key")
        Section {
            if let url { valueRow("URL", value: url, which: .url) }
            if let key { valueRow("Key", value: key, which: .key, secret: true) }
            if url == nil && key == nil {
                Text(model.on(.armed) ? "Save to get the URL and the key a sender signs with." : "The URL and key are handed out once the webhook is on.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Deliveries")
        } footer: {
            if url != nil {
                Text("Send the key as Authorization: Bearer, or sign with it (X-Briareus-Signature-256 over the time sent and the body) so it never travels. The /webhooks/ paths must bypass Cloudflare Access.")
            }
        }
        .listRowBackground(Theme.row)

        if model.armed && model.hook?["instructions"].is(true) == true {
            Section {
                if let u = model.string("instructionsUrl") { valueRow("URL", value: u, which: .instructionsUrl) }
                if let k = model.string("instructionsKey") { valueRow("Key", value: k, which: .instructionsKey, secret: true) }
            } header: {
                Text("Instructions")
            } footer: {
                Text("Where your own instructions are posted, with the instructions webhook's own key; the deliveries key does not open it.")
            }
            .listRowBackground(Theme.row)
        } else if model.on(.instructions) {
            Section("Instructions") { Text("Save to get the instructions URL and key.").foregroundStyle(.secondary) }
                .listRowBackground(Theme.row)
        }

        if let url, key != nil {
            Section {
                CodeBlock(language: "sh", text: "curl -X POST \"\(url)\" -H \"Authorization: Bearer $KEY\" -H 'Content-Type: application/json' \\\n  -d '{\"text\":\"The nightly build failed\",\"source\":\"ci\",\"id\":\"run-4711\"}'")
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("Sending")
            } footer: {
                Text("JSON {\"text\", \"source\", \"id\"}, plain text, or any other JSON, up to 20,000 characters. source is a label the transcript shows; id names the delivery, so a retry is answered as a duplicate instead of running the agent twice.")
            }
            .listRowBackground(Color.clear)
        }

        if model.armed && store.supports("rotate_session_webhook") {
            Section {
                Button("Rotate Keys", systemImage: "arrow.triangle.2.circlepath", role: .destructive) { confirmRotate = true }
                    .disabled(model.busy)
            } footer: {
                Text("Replaces the keys; the old ones stop working.")
            }
            .listRowBackground(Theme.row)
        }
    }

    private func notice(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol).font(.callout).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func check(_ t: WebhookToggle, enabled: Bool) -> some View {
        Toggle(isOn: model.toggle(t)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.label)
                Text(t.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.accent)
        .disabled(!enabled)
    }

    /// A URL or key with Copy, and Show for a key, which is dotted until then.
    private func valueRow(_ label: String, value: String, which: WebhookValue, secret: Bool = false) -> some View {
        let hidden = secret && !model.shownKeys.contains(which)
        return VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.medium))
            Text(verbatim: hidden ? String(repeating: "\u{2022}", count: 12) : value)
                .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                if secret {
                    Button(hidden ? "Show" : "Hide", systemImage: hidden ? "eye" : "eye.slash") {
                        if hidden { model.shownKeys.insert(which) } else { model.shownKeys.remove(which) }
                    }
                }
                Button("Copy", systemImage: "doc.on.doc") { model.copy(which) }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless).font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
