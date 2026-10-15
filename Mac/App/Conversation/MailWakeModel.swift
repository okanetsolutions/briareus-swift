// The state behind a session's ✉ Mail wake screen (MailWakeScreen.swift): the rules and caps being edited, the mailboxes
// a rule can name, whether the project lets mail wake its sessions, and Save. An admin token's, read and written through
// /sessions/{id}/mail-wake; the rules' checks and the body are Core's (MailWakeLogic.swift).
import SwiftUI

@MainActor
final class MailWakeModel: ObservableObject {
    /// One rule as edited, with an identity of its own for the list and the focus.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var rule: MailWakeRule
    }

    let session: Session
    /// The server's last answer, a mail-wake record.
    @Published private(set) var wake: JSON?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var caps: [MailWakeCap: String] = [:]
    /// The mailboxes, nil until read (or when they could not be).
    @Published private(set) var accounts: MailAccounts?
    /// Whether the project's mail tools are on; nil when the projects' settings did not say.
    @Published private(set) var mailTools: Bool?
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var dirty = false
    /// The read failed.
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    @Published private(set) var messageOK = false
    @Published private(set) var scrollToken = 0

    init(session: Session) { self.session = session }

    var canEdit: Bool { wake != nil && !busy && Store.shared.supports("set_session_mail_wake") }
    var canAdd: Bool { canEdit && rows.count < mailWakeRuleLimit && mailTools != false && !mailboxes.isEmpty }
    /// What a rule may pick from.
    var mailboxes: [MailAccount] { accounts.map(mailWakeMailboxes) ?? [] }
    /// How a rule's mailbox reads: its title, or its id when the server no longer lists it.
    func mailboxTitle(_ id: Int?) -> String {
        guard let id else { return "Choose a mailbox" }
        return accounts?.find(id)?.title ?? "Mailbox \(id)"
    }

    /// The form shows what the server answered, dropping anything unsaved.
    private func fill() {
        guard let wake else { return }
        rows = mailWakeRules(wake).map { Row(rule: $0) }
        for c in MailWakeCap.allCases { caps[c] = c.text(wake) }
        dirty = false
    }

    private func changed() {
        if !dirty { dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard dirty else { return true }
        let leave = confirmDiscard("The mail wake rules have not been saved.")
        if leave { dirty = false }
        return leave
    }

    // MARK: Editing

    func binding(_ c: MailWakeCap) -> Binding<String> {
        Binding(get: { self.caps[c] ?? "" }, set: { v in
            let value = v.filter { $0.isASCII && $0.isNumber }
            guard value != self.caps[c] else { return }
            self.caps[c] = value
            self.changed()
        })
    }
    func binding(_ row: Row.ID, _ f: MailWakeFilter) -> Binding<String> {
        Binding(get: { self.rows.first { $0.id == row }?.rule[f] ?? "" }, set: { v in
            self.edit(row) { $0[f] = v }
        })
    }
    private func edit(_ row: Row.ID, _ change: (inout MailWakeRule) -> Void) {
        guard canEdit, let i = rows.firstIndex(where: { $0.id == row }) else { return }
        var rule = rows[i].rule
        change(&rule)
        guard rule != rows[i].rule else { return }
        rows[i].rule = rule
        changed()
    }
    func toggle(_ row: Row.ID) { edit(row) { $0.enabled.toggle() } }
    func pickMailbox(_ row: Row.ID, _ account: Int) { edit(row) { $0.account = account } }
    func remove(_ row: Row.ID) {
        guard canEdit else { return }
        rows.removeAll { $0.id == row }
        changed()
    }
    /// A new rule on the only mailbox when there is one.
    func add() {
        guard canAdd else { return }
        rows.append(Row(rule: MailWakeRule(account: mailboxes.count == 1 ? mailboxes[0].id : nil)))
        changed()
    }

    // MARK: Reading and writing

    /// The rules, with the mailboxes and the project's mail tools beside them; what is being typed is kept.
    func load() {
        guard !loading else { return }
        loading = true
        let args: JSON = ["sessionId": .string(session.id)]
        Task {
            defer { loading = false }
            async let mailboxes = try? Store.shared.call("settings_mail_accounts")
            async let projects = Store.shared.supports("settings_projects") ? try? Store.shared.call("settings_projects") : nil
            do {
                let answer = try await Store.shared.call("session_mail_wake", args)
                error = nil
                wake = answer
                if !dirty { fill() }
            } catch {
                if !error.isCancellation { self.error = errorText(error) }
            }
            if let read = await mailboxes { accounts = MailAccounts(read) }
            if let read = await projects, let repo = session.repo { mailTools = mailToolsEnabled(read, repo: repo) }
        }
    }
    func retry() { error = nil; load() }

    private func show(_ text: String?, ok: Bool) {
        message = text; messageOK = ok
        if !ok { scrollToken += 1 }
    }

    /// The rule at fault when the form cannot be sent, after saying why.
    @discardableResult
    func save() -> MailWakeProblem? {
        guard canEdit else { return nil }
        let usable = accounts.map { Set(mailWakeMailboxes($0).map(\.id)) }
        switch mailWakeSave(rules: rows.map(\.rule), caps: caps, usable: usable, mailTools: mailTools) {
        case .invalid(let problem):
            show(problem.message, ok: false)
            return problem
        case .body(var body):
            body["sessionId"] = .string(session.id)
            submit(body)
            return nil
        }
    }

    private func submit(_ body: JSON) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                wake = try await Store.shared.call("set_session_mail_wake", body)
                fill()
                show("Saved.", ok: true)
                // The conversation's header marks the button from the session record's mailWake.
                post(.sessionsChanged, session.repo.map { ["repo": $0] } ?? [:])
            } catch {
                if !error.isCancellation { show(errorText(error), ok: false) }
            }
        }
    }
}
