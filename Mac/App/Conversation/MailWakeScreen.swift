// A session's ✉ Mail wake (core #159), beside its ⚡ Webhook: the rules under which new inbox mail in a connected mailbox
// wakes the session with a turn of its own, and the caps those turns run under. An admin token's, read and written
// through /sessions/{id}/mail-wake (MailWakeModel.swift); pushed over the conversation from its header.
import SwiftUI

/// What a box on this screen is: a cap, or one rule's filter.
enum MailWakeFocus: Hashable {
    case cap(MailWakeCap)
    case filter(UUID, MailWakeFilter)
}

struct MailWakeScreen: View {
    @StateObject private var model: MailWakeModel
    @FocusState private var focus: MailWakeFocus?

    init(session: JSON) {
        _model = StateObject(wrappedValue: MailWakeModel(session: Session(raw: session)))
    }

    var body: some View {
        SettingsPage(header: header, unavailable: nil, scrollToken: model.scrollToken) {
            Color.clear.frame(height: 8)
            if let message = model.message {
                if model.messageOK {
                    Label(message, systemImage: Glyph.symbol(0xE73E)).font(Theme.footnote).foregroundStyle(Theme.ok).padding(.bottom, 14)
                } else {
                    NoticeBox(message: message).padding(.bottom, 14)
                }
            }
            if model.wake != nil { form } else if let error = model.error {
                NoticeBox(message: error).padding(.bottom, 10)
                Button("Try again") { model.retry() }.dashButton().disabled(model.loading)
            } else {
                LoadingNote(text: "Reading the mail wake rules…")
            }
        }
        .task { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in save() }
    }

    private func save() {
        guard let problem = model.save() else { return }
        switch problem {
        case .cap(let c): focus = .cap(c)
        case .notAddress(let r, let f), .tooLong(let r, let f):
            if model.rows.indices.contains(r) { focus = .filter(model.rows[r].id, f) }
        default: break
        }
    }

    private var header: PaneHeader {
        let on = model.rows.contains { $0.rule.enabled }
        let state = model.wake == nil ? (model.error != nil ? "could not be read" : "reading…") : on ? "on" : "off"
        let button = HeaderButton(glyph: Glyph.symbol(0xE74E), label: "Save", tip: "Save (⌘S)",
                                  enabled: model.canEdit && model.dirty, prominent: true) { save() }
        return PaneHeader(title: "\u{2709} Mail wake", subtitle: "\(model.session.displayTitle) · \(state)", buttons: [button])
    }

    @ViewBuilder private var form: some View {
        SettingsNote(text: "New mail arriving in a connected mailbox's inbox wakes this session when it matches every filter of a rule that is on. What arrives is information, never your word: it waits for the turn under way and any question to end, and a closed session is not reopened for it. Mail the mailbox sends itself never wakes it.")
        if model.mailTools == false {
            NoticeBox(message: MailWakeProblem.mailToolsOff.message).padding(.bottom, 14)
        }
        if model.accounts != nil && model.mailboxes.isEmpty {
            NoticeBox(message: "No mailbox is connected and turned on. Connect one under Settings › Mail first.").padding(.bottom, 14)
        }
        SettingsPair { capField(.perHour) } right: { capField(.maxTurns) }

        Text("Rules").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).padding(.top, 4).padding(.bottom, 8)
        if model.rows.isEmpty {
            EmptyNote(title: "No rules: mail does not wake this session.").padding(.bottom, 8)
        }
        ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
            MailWakeRuleBox(model: model, row: row, number: i + 1, focus: $focus, onSubmit: save)
        }
        Button("Add rule") { model.add() }.dashButton().disabled(!model.canAdd)
            .help(model.rows.count >= mailWakeRuleLimit ? "A session keeps at most \(mailWakeRuleLimit) rules." : "")
    }

    private func capField(_ c: MailWakeCap) -> some View {
        SettingsFieldBox(def: c.def(), text: model.binding(c), enabled: model.canEdit, focus: $focus, key: .cap(c)) { save() }
    }
}

/// One rule: whether it is on and Remove, its mailbox, then the To, From and Subject filters.
private struct MailWakeRuleBox: View {
    @ObservedObject var model: MailWakeModel
    var row: MailWakeModel.Row
    var number: Int
    var focus: FocusState<MailWakeFocus?>.Binding
    var onSubmit: () -> Void

    var body: some View {
        let editable = model.canEdit
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SettingsCheck(label: "Rule \(number) is on", on: row.rule.enabled) { model.toggle(row.id) }
                        .disabled(!editable || (!row.rule.enabled && model.mailTools == false))
                    Button("Remove") { model.remove(row.id) }.dashButton(.plain).disabled(!editable).fixedSize()
                }
                .padding(.bottom, 8)
                SettingsLabeledSelect(label: "Mailbox", text: model.mailboxTitle(row.rule.account), enabled: editable,
                                      hint: "A connected mailbox whose new inbox mail this rule watches.") { pickMailbox() }
                SettingsPair { filter(.to) } right: { filter(.from) }
                filter(.subject)
            }
        }
        .padding(.bottom, 12)
    }

    private func pickMailbox() {
        let boxes = model.mailboxes
        guard !boxes.isEmpty else { return }
        let items = boxes.map { PopupMenu.Item(title: $0.title, checked: $0.id == row.rule.account) }
        if let i = PopupMenu.choose(items) { model.pickMailbox(row.id, boxes[i].id) }
    }

    private func filter(_ f: MailWakeFilter) -> some View {
        SettingsFieldBox(def: f.def(), text: model.binding(row.id, f), enabled: model.canEdit, focus: focus,
                         key: .filter(row.id, f), onSubmit: onSubmit)
    }
}
