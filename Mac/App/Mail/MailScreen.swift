// The mail inbox (the Windows client's screen_mail_inbox.c, core #120): the mail the server keeps synced from every
// connected mailbox or one, newest first, 50 to a page, with a search, a label or folder, a thread and read, inbox and star
// filters; a message opens beside the list as plain, selectable text. It only reads the server's copy: reading here marks
// nothing read, and no HTML, image or link of a message is loaded. An Admin token's.
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
    @Published private(set) var notice: String?
    /// While the server rate limits or fails, nothing is asked until then.
    @Published private(set) var retryUntil: Date?
    private var failures = 0
    /// Which filter a page or a body answers: an answer for an older one is dropped.
    private var generation = 0

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
        selected = m.key; body = nil; bodyError = nil
        Task { await loadBody(m) }
    }
    func close() { selected = nil; body = nil; bodyError = nil }
    func loadBody(_ m: MailMessage) async {
        guard selected == m.key, !readingBody, !coolingDown else { return }
        readingBody = true
        let gen = generation
        let r = await boardCall("mail_message", ["account": JSON(m.accountID), "id": .string(m.id)])
        readingBody = false
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
            out.append(HeaderButton(glyph: "gearshape", label: "Mail accounts", tip: "The mailboxes the server syncs") { Navigator.shared.push(.mailSettings) })
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

/// The open message: its subject and people, its labels, Open at the provider, its text and its attachments, described.
private struct MailReader: View {
    @ObservedObject var model: MailInboxModel

    var body: some View {
        let m = model.body ?? model.selectedSummary
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                if let url = model.body?.webURL {
                    Button("Open at \(model.accounts.find(m?.accountID ?? 0)?.providerName ?? "the provider") ↗") { openWebURL(url) }.dashButton(.bordered)
                }
                Button { model.close() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("Close the message")
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let m {
                        Text(m.shownSubject).font(Theme.title3).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        people(m)
                        if !m.labels.isEmpty {
                            FlowLayout(spacing: 4, lineSpacing: 4) {
                                ForEach(m.labels, id: \.self) { l in
                                    Text(l).font(Theme.caption2).foregroundStyle(Theme.muted).padding(.horizontal, 6).frame(height: 18)
                                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 1))
                                }
                            }
                        }
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 6)
                    }
                    if let e = model.bodyError {
                        Notice(message: e)
                        if let s = model.selectedSummary {
                            Button("Try again") { Task { await model.loadBody(s) } }.dashButton(.bordered).disabled(model.readingBody || model.coolingDown)
                        }
                    }
                    if model.readingBody { LoadingNote(text: "Loading the message…") }
                    if let b = model.body {
                        if b.truncated { Notice(message: "The server cut this message short. Open it at the provider to read all of it.") }
                        // Its text as text: no HTML, images, scripts or live links.
                        SelectableText(expandTabs(b.text?.isEmpty == false ? b.text! : "This message has no text in the synced copy."),
                                       font: SelectableFont.system(14), color: b.text?.isEmpty == false ? Theme.ink : Theme.muted)
                        if !b.attachments.isEmpty {
                            Text("Attachments (described only; their content is not synced)").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).padding(.top, 14)
                            ForEach(Array(b.attachments.enumerated()), id: \.offset) { _, a in
                                HStack(spacing: 6) {
                                    Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                    Text("\(a.name) · \(a.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))")
                                        .font(Theme.footnote).foregroundStyle(Theme.muted).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func people(_ m: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            line("From", m.sender)
            if !m.to.isEmpty { line("To", m.to) }
            if !m.cc.isEmpty { line("Cc", m.cc) }
            if !m.replyTo.isEmpty { line("Reply-To", m.replyTo) }
            line("Received", m.receivedAt.map { formatEventTime($0) } ?? "unknown")
            if let a = model.accounts.find(m.accountID) { line("Mailbox", a.title) }
        }
    }
    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Theme.footnote).foregroundStyle(Theme.muted).frame(width: 70, alignment: .leading)
            Text(value).font(Theme.footnote).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
