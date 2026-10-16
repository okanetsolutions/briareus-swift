// The mail inbox (the Windows client's screen_mail_inbox.c, core #120): the mail the server keeps synced from every
// connected mailbox or one, newest first, 50 to a page, with a search, a label or folder, a thread and read, inbox and star
// filters; a message opens beside the list as plain, selectable text (MailReader.swift), Reply answers it and Move to
// Trash moves it to the provider's trash.
// Reading here marks nothing read, and no HTML, image or link of a message is loaded. An Admin token's.
import AppKit
import SwiftUI

@MainActor
final class MailInboxModel: ObservableObject {
    @Published private(set) var accounts = MailAccounts()
    @Published private(set) var accountsLoaded = false
    @Published private(set) var messages: [MailMessage] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var loaded = false
    @Published private(set) var listing = false
    @Published private(set) var listError: String?
    @Published private(set) var accountError: String?
    @Published var filter = MailFilter()
    /// The message open beside the list, by key, and its body once read.
    @Published private(set) var selected: String?
    @Published private(set) var body: MailMessage?
    @Published private(set) var bodyError: String?
    @Published private(set) var readingBody = false
    /// The message being moved to the trash, by key: its button waits, and another cannot be moved meanwhile.
    @Published private(set) var trashing: String?
    /// The message whose body is being read: opening another while one loads reads the new one, and the old answer is dropped.
    private var readingKey: String?
    @Published private(set) var notice: String?
    /// While the server rate limits or fails, nothing is asked until then.
    @Published private(set) var retryUntil: Date?
    private var failures = 0
    /// Which filter a page or a body answers: an answer for an older one is dropped.
    private var generation = 0
    /// The reply being written to the open message.
    let reply = MailReplyModel()

    static var offered: Bool { Store.shared.isAdmin && Store.shared.supports("settings_mail_accounts") && Store.shared.supports("mail_messages") }
    var coolingDown: Bool { retryUntil.map { $0 > Date() } ?? false }

    private func failed(_ e: APIError, into slot: ReferenceWritableKeyPath<MailInboxModel, String?>, detail: Bool) {
        self[keyPath: slot] = mailReadError(status: e.status, detail: detail)
        if e.status == 429 || e.status == 503 || e.status >= 500 || e.kind == .network {
            failures = min(failures + 1, 4)
            let until = Date().addingTimeInterval(mailRetryDelay(failures: failures, retryAfter: e.retryAfter))
            if retryUntil.map({ until > $0 }) ?? true { retryUntil = until }
        }
    }

    /// The filters changed, or the mailboxes did: back to the newest page, nothing open.
    private func restart() {
        generation += 1
        messages = []; nextCursor = nil; loaded = false; listError = nil; notice = nil
        close()
    }

    // MARK: Reading

    /// The accounts first (which mailboxes may be read), then the first page if there is none yet.
    func loadAccounts() async {
        guard Self.offered, !coolingDown else { return }
        let r = await boardCall("settings_mail_accounts")
        switch r {
        case .failure(let e):
            if e.kind == .cancelled { return }
            failed(e, into: \.accountError, detail: false)
        case .success(let v):
            guard let fresh = MailAccounts(v) else { accountError = "The server returned an unexpected account list."; return }
            accountError = nil
            // A mailbox gone, or newly readable, changes which messages may show: start over from the newest page.
            let changed = accounts.readable != fresh.readable && accountsLoaded
            accounts = fresh; accountsLoaded = true
            if let a = filter.account, !fresh.readable.contains(a) { filter.account = nil; restart() }
            else if changed { restart() }
            if !loaded { await loadPage() }
        }
    }
    func loadPage() async {
        guard Self.offered, accountsLoaded, !listing, !coolingDown, !(loaded && nextCursor == nil) else { return }
        if let a = filter.account, !accounts.readable.contains(a) { return }
        listing = true
        let gen = generation
        let cursor = loaded ? nextCursor : nil
        let r = await boardCall("mail_messages", filter.arguments(cursor: cursor))
        listing = false
        guard gen == generation else { return }
        switch r {
        case .failure(let e):
            if e.kind == .cancelled { return }
            failed(e, into: \.listError, detail: false)
        case .success(let v):
            guard let page = MailPage(v), page.nextCursor == nil || page.nextCursor != cursor else {
                listError = "The server returned an unexpected message list. Refresh to try again."; return
            }
            messages = mailMerge(messages, page.messages, readable: accounts.readable)
            nextCursor = page.nextCursor
            loaded = true; failures = 0; listError = nil
        }
    }
    func refresh() {
        guard !coolingDown else { return }
        restart()
        Task { await loadAccounts() }
    }
    func setFilter(_ change: (inout MailFilter) -> Void) {
        var f = filter
        change(&f)
        guard f != filter else { return }
        filter = f
        restart()
        Task { await loadPage() }
    }

    // MARK: A message

    func open(_ m: MailMessage) {
        guard Store.shared.supports("mail_message"), accounts.readable.contains(m.accountID) else { return }
        if selected != m.key { reply.cancel() }
        selected = m.key; body = nil; bodyError = nil
        Task { await loadBody(m) }
    }
    func close() { selected = nil; body = nil; bodyError = nil; reply.cancel() }
    func loadBody(_ m: MailMessage) async {
        guard selected == m.key, readingKey != m.key, !coolingDown else { return }
        readingKey = m.key; readingBody = true
        let gen = generation
        let r = await boardCall("mail_message", ["account": JSON(m.accountID), "id": .string(m.id)])
        if readingKey == m.key { readingKey = nil; readingBody = false }
        guard gen == generation, selected == m.key else { return }
        switch r {
        case .failure(let e):
            if e.kind == .cancelled { return }
            if e.status == 404 {
                // Deleted or moved to the trash since: the list is read again.
                restart()
                notice = mailReadError(status: 404, detail: true)
                await loadAccounts()
                return
            }
            failed(e, into: \.bodyError, detail: true)
        case .success(let v):
            guard let full = MailMessage(v["message"]), full.key == m.key else {
                bodyError = "The server returned a different message; refresh the list."; return
            }
            body = full; failures = 0
        }
    }
    var selectedSummary: MailMessage? { messages.first { $0.key == selected } }

    // MARK: Moving to the trash

    /// Whether a message's mailbox may move it to the trash: the server has the route and the mailbox was not connected
    /// read-only.
    func canTrash(_ m: MailMessage) -> Bool { Store.shared.supports("delete_mail_message") && accounts.writable(m.accountID) }
    /// Whether a message may be answered: the server has the route and its mailbox may send.
    func canReply(_ m: MailMessage) -> Bool { Store.shared.supports("reply_mail_message") && accounts.writable(m.accountID) }
    /// Moves the message, not its thread, to Gmail's Trash or Outlook's Deleted Items once confirmed; the provider keeps
    /// it there, so it is not erased. Gone from the list once the server says so.
    func trash(_ m: MailMessage) {
        guard canTrash(m), trashing == nil else { return }
        let account = accounts.find(m.accountID)
        let bin = account?.provider == "outlook" ? "Deleted Items" : "the Trash"
        guard Dialogs.confirm("Move “\(m.shownSubject)” to \(bin)?",
                              "Only this message moves, not its thread. It stays in \(bin) at \(account?.providerName ?? "the provider") until emptied there.",
                              continueLabel: "Move to Trash", destructive: true) else { return }
        trashing = m.key
        Task {
            let r = await boardCall("delete_mail_message", ["account": JSON(m.accountID), "id": .string(m.id)])
            trashing = nil
            if case .failure(let e) = r, e.status != 404 {
                if e.kind != .cancelled { Dialogs.alert("The message was not moved to the trash", mailTrashError(e)) }
                return
            }
            // Gone either way: a 404 means the synced copy was already removed.
            messages.removeAll { $0.key == m.key }
            if selected == m.key { close() }
        }
    }
}

/// What a refused move to the trash means, in words.
func mailTrashError(_ e: APIError) -> String {
    switch e.status {
    case 409: return "This mailbox was connected read-only. Connect it again in Mail accounts with access to manage mail, then try again."
    case 401, 403, 429, 503: return mailReadError(status: e.status, detail: true)
    case 502: return "The provider did not answer clearly, so the server kept its copy. Refresh before trying again: it may already be in the trash."
    default: return e.description
    }
}

/// What a refused read means, in words (`detail`: one message's).
func mailReadError(status: Int, detail: Bool) -> String {
    switch status {
    case 401: return "This token expired or was revoked. Reconnect to the server."
    case 403: return "Mail needs an Admin token."
    case 404: return detail ? "That message is no longer in the synced copy (deleted or moved to the trash). The list was read again." : "This mail route or mailbox is no longer available. Refresh."
    case 409: return "A mailbox needs signing in again. Open Mail accounts."
    case 429: return "The server is rate limiting mail requests. It is asked again after a pause."
    case 503: return "Mail is unavailable on the server right now."
    case 400: return "The server refused these filters. Reset them and try again."
    default: return "The mail could not be read. Refresh to try again."
    }
}

struct MailScreen: View {
    @StateObject private var model = MailInboxModel()
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "✉ Mail", subtitle: "The server's synced copy, newest first; reading here marks nothing read", buttons: headerButtons)
            if !MailInboxModel.offered {
                NoticeBox(message: "Mail needs an Admin token on a server with mail.").padding(Theme.paneMargin)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    MailList(model: model)
                        .frame(minWidth: 320, idealWidth: 420, maxWidth: model.selected == nil ? .infinity : 460)
                    if model.selected != nil {
                        Rectangle().fill(Theme.line).frame(width: 1)
                        MailReader(model: model).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .task {
            // The mailboxes again every 30 seconds while on show (a removed or signed-out one leaves the list), the first
            // page once they are read.
            while !Task.isCancelled {
                if store.active { await model.loadAccounts() }
                let wait = model.retryUntil.map { max($0.timeIntervalSinceNow, 1) } ?? 30
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
    }

    private var headerButtons: [HeaderButton] {
        var out: [HeaderButton] = []
        if MailSettingsModel.offered {
            // The mailboxes' setup lives in Settings › Mail (Windows #141).
            out.append(HeaderButton(glyph: "gearshape", label: "Mail accounts", tip: "The mailboxes the server syncs, in Settings") {
                let nav = Navigator.shared
                nav.sidebarMode = .settings
                nav.show(.mailSettings(id: nil))
            })
        }
        out.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the mailboxes and the newest messages again",
                                enabled: !model.listing && !model.coolingDown) { model.refresh() })
        return out
    }
}

/// The filters over the messages, and the messages.
private struct MailList: View {
    @ObservedObject var model: MailInboxModel
    @State private var query = ""
    @State private var label = ""
    @State private var thread = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filters.padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let n = model.notice { Notice(message: n).padding(.horizontal, 14).padding(.top, 10) }
                    if model.coolingDown { Notice(message: "Paused while the server rate limits mail; it is asked again after a moment.").padding(.horizontal, 14).padding(.top, 10) }
                    if let e = model.accountError { Notice(message: e).padding(.horizontal, 14).padding(.top, 10) }
                    if let e = model.listError { Notice(message: e).padding(.horizontal, 14).padding(.top, 10) }
                    if !model.accountsLoaded || (!model.loaded && model.listing) {
                        LoadingNote(text: !model.accountsLoaded ? "Loading the mailboxes…" : "Loading messages…").padding(.horizontal, 6)
                    } else if model.loaded && model.messages.isEmpty {
                        EmptyNote(title: model.nextCursor != nil ? "No readable messages on the pages read." : "No synced messages match these filters.",
                                  detail: model.filter.isDefault ? nil : "Reset the filters to see everything.").padding(.horizontal, 6)
                    }
                    ForEach(model.messages, id: \.key) { m in
                        MailRow(message: m, account: model.accounts.find(m.accountID), selected: model.selected == m.key) { model.open(m) }
                    }
                    if model.nextCursor != nil {
                        Button(model.listing ? "Loading…" : "Load older messages") { Task { await model.loadPage() } }
                            .dashButton(.bordered).disabled(model.listing || model.coolingDown).padding(14)
                    }
                }
            }
        }
    }

    private var filters: some View {
        let f = model.filter
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                FilterField(icon: "magnifyingglass", placeholder: "Search sender, subject or preview", text: $query) { v in model.setFilter { $0.query = v } }
                Menu {
                    Button { model.setFilter { $0.account = nil } } label: { Label("All mailboxes", systemImage: f.account == nil ? "checkmark" : "") }
                    Divider()
                    ForEach(model.accounts.accounts, id: \.id) { a in
                        Button { model.setFilter { $0.account = a.id } } label: {
                            Label(a.needsSignIn ? "\(a.title) (needs sign-in)" : a.title, systemImage: f.account == a.id ? "checkmark" : "")
                        }
                        .disabled(a.needsSignIn)
                    }
                } label: {
                    Text(f.account.flatMap { model.accounts.find($0)?.email } ?? "All mailboxes").font(Theme.footnote).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 6) {
                TriChip(title: "Unread", value: f.unread) { v in model.setFilter { $0.unread = v } }
                TriChip(title: "Inbox", value: f.inbox) { v in model.setFilter { $0.inbox = v } }
                TriChip(title: "Starred", value: f.starred) { v in model.setFilter { $0.starred = v } }
                Spacer(minLength: 0)
                if !f.isDefault {
                    Button("Reset") {
                        query = ""; label = ""; thread = ""
                        model.setFilter { let a = $0.account; $0 = MailFilter(); $0.account = a }
                    }
                    .buttonStyle(.plain).font(Theme.footnote).foregroundStyle(Theme.accent)
                }
            }
            HStack(spacing: 6) {
                FilterField(icon: "tag", placeholder: "Exact label or folder", text: $label) { v in model.setFilter { $0.label = v } }
                FilterField(icon: "bubble.left.and.bubble.right", placeholder: "Thread id", text: $thread) { v in model.setFilter { $0.thread = v } }
            }
        }
    }
}

/// A filter's text field: applied on Enter, and when cleared.
private struct FilterField: View {
    var icon: String
    var placeholder: String
    @Binding var text: String
    var apply: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.muted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(Theme.footnote).foregroundStyle(Theme.ink)
                .onSubmit { apply(text.cTrimmed) }
                .onChange(of: text) { _, v in if v.isEmpty { apply("") } }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Any, yes or no, a click going around: "Unread", "Unread ✓", "Unread ✗".
private struct TriChip: View {
    var title: String
    var value: Bool?
    var set: (Bool?) -> Void

    var body: some View {
        let text = value == nil ? title : value! ? "\(title) ✓" : "Not \(title.lowercased())"
        Button(text) { set(value == nil ? true : value! ? false : nil) }
            .buttonStyle(.plain).font(Theme.footnote)
            .foregroundStyle(value == nil ? Theme.muted : Theme.ink)
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 11).fill(value == nil ? Color.clear : Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(value == nil ? Theme.line : Theme.accentDim, lineWidth: 1))
            .help("Any, then only \(title.lowercased()), then only not \(title.lowercased())")
    }
}

/// A message in the list: the unread dot, who from, when, the subject, its preview, and its mailbox.
private struct MailRow: View {
    var message: MailMessage
    var account: MailAccount?
    var selected: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        let m = message
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(m.isRead ? Color.clear : Theme.accent).frame(width: 6, height: 6)
                    Text(m.sender).font(m.isRead ? Theme.footnote : Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if m.isStarred { Text("★").font(Theme.caption).foregroundStyle(Theme.warn) }
                    if !m.attachments.isEmpty { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                    Text(m.receivedAt.map { formatRelative($0) } ?? "").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Text(m.shownSubject).font(m.isRead ? Theme.footnote : Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1).padding(.leading, 12)
                Text(m.snippet).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(2).padding(.leading, 12)
                if let account { Text(account.email).font(Theme.caption2).foregroundStyle(Theme.muted).lineLimit(1).padding(.leading, 12) }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.raise : hovered ? Theme.raise.opacity(0.5) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
