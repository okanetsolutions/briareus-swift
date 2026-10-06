// A session's ⚡ Webhook (screen_webhook.c), as the dashboard's dialog: whether an outside system may post to wake the
// session, the caps the turns it starts run under, the second webhook that takes the operator's own instructions, and the
// URLs and keys a sender needs, with Rotate key to end the old ones. An admin token's, read and written through
// /sessions/{id}/webhook; pushed over the conversation from its header.
import SwiftUI

/// The two caps, each a whole number in its range.
enum WebhookField: Int, CaseIterable, Hashable {
    case perHour, maxTurns
    var key: String { self == .perHour ? "perHour" : "maxTurns" }
    var label: String { self == .perHour ? "Deliveries an hour" : "Turns in a row" }
    var hint: String {
        self == .perHour ? "Past it a sender is answered 429 with Retry-After. From 1 to 600."
            : "Turns deliveries may start with no word from you; past it the webhook pauses until you say anything here (or save this form). From 1 to 1000."
    }
    var range: ClosedRange<Int> { self == .perHour ? 1...600 : 1...1000 }
    var fallback: Int { self == .perHour ? 30 : 10 }
    var def: SettingsField { SettingsField(key: key, kind: .text, label: label, hint: hint) }
}

/// The three switches, by the key they are sent under.
enum WebhookToggle: String, CaseIterable {
    case armed, instructions, sshUnattended
    var label: String {
        switch self {
        case .armed: return "Take deliveries"
        case .instructions: return "Take instructions too: a second URL and key whose messages reach the agent as your word"
        case .sshUnattended: return "Let an SSH server in allow mode run commands unapproved in a turn a delivery started"
        }
    }
}

/// What Copy and Show are about.
enum WebhookValue: String { case url, key, instructionsUrl, instructionsKey }

@MainActor
final class WebhookModel: ObservableObject {
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

    private func changed() {
        if !dirty { dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard dirty else { return true }
        let leave = confirmDiscard("The webhook's settings have not been saved.")
        if leave { dirty = false }
        return leave
    }

    func binding(_ f: WebhookField) -> Binding<String> {
        Binding(get: { self.texts[f] ?? "" }, set: { v in
            // Digits only, as the C client's ES_NUMBER edits take.
            let value = v.filter { $0.isASCII && $0.isNumber }
            guard value != self.texts[f] else { return }
            self.texts[f] = value
            self.changed()
        })
    }
    func toggle(_ t: WebhookToggle) {
        guard !busy else { return }
        toggles[t] = !on(t)
        // Instructions ride on the webhook: turning it off turns them off with it.
        if t == .armed && !on(.armed) { toggles[.instructions] = false }
        changed()
    }

    // MARK: Reading and writing

    /// A pause or a held delivery may have come meanwhile; what is being typed is kept.
    func load() {
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let answer = try await Store.shared.call("session_webhook", ["sessionId": .string(session.id)])
                error = nil
                hook = answer
                if !dirty { fill() }
            } catch {
                if !error.isCancellation { self.error = errorText(error) }
            }
        }
    }
    func retry() { error = nil; load() }

    private func show(_ text: String?, ok: Bool) { message = text; messageOK = ok }

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
                post(.sessionsChanged, session.repo.map { ["repo": $0] } ?? [:])
            } catch {
                if !error.isCancellation { show(errorText(error), ok: false) }
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
    func rotate() {
        guard !busy, Dialogs.confirm("Rotate the webhook keys?",
                                     "New keys replace both of this session's webhook keys. A sender holding an old key is refused until it is given the new one.",
                                     continueLabel: "Rotate", destructive: true) else { return }
        submit("rotate_session_webhook")
    }
    func copy(_ v: WebhookValue) {
        guard let value = string(v.rawValue) else { return }
        Clipboard.copy(value)
        show(v == .key || v == .instructionsKey ? "Key copied." : "URL copied.", ok: true)
    }
}

struct WebhookScreen: View {
    @StateObject private var model: WebhookModel
    @FocusState private var focus: WebhookField?

    init(session: JSON) {
        _model = StateObject(wrappedValue: WebhookModel(session: Session(raw: session)))
    }

    var body: some View {
        SettingsPage(header: header, unavailable: nil, scrollToken: 0) {
            Color.clear.frame(height: 8)
            if let message = model.message {
                if model.messageOK {
                    Label(message, systemImage: Glyph.symbol(0xE73E)).font(Theme.footnote).foregroundStyle(Theme.ok).padding(.bottom, 14)
                } else {
                    NoticeBox(message: message).padding(.bottom, 14)
                }
            }
            if model.hook != nil { form } else if let error = model.error {
                NoticeBox(message: error).padding(.bottom, 10)
                Button("Try again") { model.retry() }.dashButton().disabled(model.loading)
            } else {
                LoadingNote(text: "Reading the webhook…")
            }
        }
        .task { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in save() }
    }

    private func save() { if let f = model.save() { focus = f } }

    private var header: PaneHeader {
        let state = model.hook == nil ? (model.error != nil ? "could not be read" : "reading…")
            : model.string("paused") != nil ? "paused" : model.armed ? "on" : "off"
        var buttons = [HeaderButton(glyph: Glyph.symbol(0xE74E), label: "Save", tip: "Save (⌘S)",
                                    enabled: model.hook != nil && !model.busy && (model.dirty || model.string("paused") != nil),
                                    prominent: true) { save() }]
        if model.armed {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), label: "Rotate key", tip: "Replace the keys; the old ones stop working",
                                        enabled: !model.busy) { model.rotate() })
        }
        return PaneHeader(title: "\u{26A1} Webhook", subtitle: "\(model.session.displayTitle) · \(state)", buttons: buttons)
    }

    @ViewBuilder private var form: some View {
        let unfit = model.string("unfit"), paused = model.string("paused")
        let editable = !model.busy
        note("An outside system (a support platform relaying what a customer wrote, an alert, a CI) posts to this URL to wake the session with a message. What arrives is information, never your word: it answers no question, waits for the turn under way to end, and everything held goes to the agent as one turn of its own. A closed session is woken for it.")
        if let unfit, !model.armed { NoticeBox(message: unfit).padding(.bottom, 14) }
        if let paused { NoticeBox(message: "Paused. \(paused) Saving this form lifts the pause.").padding(.bottom, 14) }
        let held = model.hook?["held"].int ?? 0
        if held > 0 {
            Label(held == 1 ? "1 delivery is waiting for the turn under way, or for your answer." : "\(held) deliveries are waiting for the turn under way, or for your answer.",
                  systemImage: Glyph.symbol(0xE823))
                .font(Theme.footnote).foregroundStyle(Theme.warn).padding(.bottom, 12)
        }
        check(.armed, enabled: editable && (unfit == nil || model.on(.armed)))
        Color.clear.frame(height: 8)
        SettingsPair { field(.perHour) } right: { field(.maxTurns) }
        check(.sshUnattended, enabled: editable)
        check(.instructions, enabled: editable && model.on(.armed))
        note("Instructions are for a bridge that sorts messages by who wrote them (a WhatsApp relay sending your own number's messages there and everybody else's to the first URL): they answer the question the agent stands on and queue behind a turn like a message typed here. Each URL has a key of its own; neither opens the other.")

        heading("Deliveries")
        let url = model.string("url"), key = model.string("key")
        if let url { valueRow("URL", help: "Where a sender posts. The /webhooks/ paths must bypass Cloudflare Access.", value: url, which: .url) }
        if let key {
            valueRow("Key", help: "Send it as Authorization: Bearer, or sign with it (X-Briareus-Signature-256 over the time sent and the body) so it never travels. Rotate key ends it.",
                     value: key, which: .key, secret: true)
        } else {
            note(model.on(.armed) ? "Save to get the key a sender signs with." : "The key is handed out once the webhook is on.")
        }
        if model.armed && model.hook?["instructions"].is(true) == true {
            heading("Instructions")
            if let u = model.string("instructionsUrl") { valueRow("URL", help: "Where your own instructions are posted.", value: u, which: .instructionsUrl) }
            if let k = model.string("instructionsKey") {
                valueRow("Key", help: "The instructions webhook's own key; the deliveries key does not open it.", value: k, which: .instructionsKey, secret: true)
            }
        } else if model.on(.instructions) {
            note("Save to get the instructions URL and key.")
        }
        if let url, key != nil {
            heading("Sending")
            note("JSON {\"text\", \"source\", \"id\"}, plain text, or any other JSON, up to 20,000 characters. source is a label the transcript shows; id names the delivery, so a retry is answered as a duplicate instead of running the agent twice.")
            MarkdownView(source: "```sh\ncurl -X POST \"\(url)\" -H \"Authorization: Bearer $KEY\" -H 'Content-Type: application/json' \\\n  -d '{\"text\":\"The nightly build failed\",\"source\":\"ci\",\"id\":\"run-4711\"}'\n```",
                         size: .footnote)
        }
    }

    private func note(_ text: String) -> some View { SettingsNote(text: text) }
    private func heading(_ text: String) -> some View {
        Text(text).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1).padding(.top, 12).padding(.bottom, 8)
    }
    private func check(_ t: WebhookToggle, enabled: Bool) -> some View {
        SettingsCheck(label: t.label, on: model.on(t)) { if enabled { model.toggle(t) } }
            .opacity(enabled ? 1 : 0.6)
            .disabled(!enabled)
            .padding(.bottom, 6)
    }
    private func field(_ f: WebhookField) -> some View {
        SettingsFieldBox(def: f.def, text: model.binding(f), enabled: !model.busy, focus: $focus, key: f) { save() }
    }

    /// A URL or key on one line with Copy after it, and Show for a key, which is dotted until then.
    private func valueRow(_ label: String, help: String, value: String, which: WebhookValue, secret: Bool = false) -> some View {
        let hidden = secret && !model.shownKeys.contains(which)
        return VStack(alignment: .leading, spacing: 0) {
            SettingsFieldLabel(label: label, hint: help)
            HStack(spacing: 14) {
                Text(verbatim: hidden ? String(repeating: "\u{2022}", count: 12) : value)
                    .font(Theme.mono).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if secret {
                        Button(hidden ? "Show" : "Hide") {
                            if hidden { model.shownKeys.insert(which) } else { model.shownKeys.remove(which) }
                        }
                        .dashButton(.plain)
                    }
                    Button("Copy") { model.copy(which) }.dashButton(.plain)
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 14)
    }
}
