// Mail account settings (the Windows client's screen_mail.c, core #120): the Gmail and Outlook mailboxes the server keeps
// synced, connected with the provider's own sign-in in the browser, each with its label, switch, sync window, a sync now,
// a sign-in again and a disconnect. An Admin token's.
import AppKit
import SwiftUI

@MainActor
final class MailSettingsModel: ObservableObject {
    @Published private(set) var accounts = MailAccounts()
    @Published private(set) var loaded = false
    @Published private(set) var reading = false
    @Published private(set) var writing = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    /// A sign-in under way: the browser is at the provider, and the server or the pasted address finishes it.
    @Published private(set) var signIn: MailSignIn?
    /// Refused for good: the token or the route is gone.
    @Published private(set) var blocked = false
    /// While the server rate limits, nothing is asked until then.
    @Published private(set) var retryUntil: Date?
    private var failures = 0
    private var readError = false

    static var offered: Bool { Store.shared.isAdmin && Store.shared.supports("settings_mail_accounts") }

    func can(_ op: String) -> Bool {
        !blocked && !writing && !reading && signIn == nil && (retryUntil.map { $0 <= Date() } ?? true) && Store.shared.supports(op)
    }
    /// How long until the list is read again: every 10 s while a sign-in or a sync is under way, never otherwise.
    var pollDelay: TimeInterval? {
        if blocked { return nil }
        if let retryUntil, retryUntil > Date() { return retryUntil.timeIntervalSinceNow }
        if failures > 0 && readError { return mailRetryDelay(failures: failures, retryAfter: nil) }
        return signIn != nil || accounts.syncing ? 10 : nil
    }

    private func failed(_ e: APIError, finishing: Bool, read: Bool) {
        error = mailErrorMessage(status: e.status, finishing: finishing, detail: e.message)
        readError = read
        if e.status == 401 || e.status == 403 || (e.status == 404 && read) { blocked = true }
        if e.status == 429 || read {
            failures += 1
            retryUntil = Date().addingTimeInterval(mailRetryDelay(failures: failures, retryAfter: e.retryAfter))
        }
    }

    func load() async {
        guard Self.offered, !blocked, !reading, !writing else { return }
        if let retryUntil, retryUntil > Date() { return }
        reading = true
        let r = await boardCall("settings_mail_accounts")
        reading = false
        switch r {
        case .failure(let e):
            if e.kind == .cancelled { return }
            failed(e, finishing: false, read: true)
        case .success(let v):
            guard let fresh = MailAccounts(v) else {
                error = "The server returned an unexpected mail account list."; blocked = true; return
            }
            if readError { error = nil; readError = false }
            loaded = true; failures = 0; retryUntil = nil
            if let s = signIn {
                if s.completed(by: fresh) { signIn = nil; notice = "The account list now reflects a connected mailbox." }
                else if s.expiresAt <= Date() {
                    signIn = nil; notice = nil
                    error = "Sign-in waiting expired. Check the browser result and refresh before starting again."
                }
            }
            accounts = fresh
        }
    }
    func refresh() {
        guard !writing, retryUntil.map({ $0 <= Date() }) ?? true else { return }
        blocked = false; error = nil
        Task { await load() }
    }

    // MARK: Connecting

    /// Starts a sign-in at the provider in the browser: a new mailbox, or `account` again. Its settings stay as they are;
    /// only a new mailbox takes the server's defaults.
    func connect(_ provider: String, account: Int? = nil) {
        guard loaded, can("connect_mail_account"), accounts.available(provider) else { return }
        var body: JSON = ["provider": .string(provider)]
        if let account { body["accountId"] = JSON(account) }
        error = nil; notice = nil
        writing = true
        let before = accounts
        Task {
            let r = await boardCall("connect_mail_account", body)
            writing = false
            switch r {
            case .failure(let e):
                if e.kind == .cancelled { return }
                failed(e, finishing: false, read: false)
                if e.status == 404 { await load() }
            case .success(let v):
                guard let s = MailSignIn(v, provider: provider, accountID: account, accounts: before), s.expiresAt > Date(),
                      s.finishesOnServer || Store.shared.supports("finish_mail_account") else {
                    error = "The server returned an invalid or expired sign-in. Start again."
                    return
                }
                signIn = s
                notice = s.finishesOnServer
                    ? "Finish signing in in your browser. This page checks every 10 seconds. The browser reports errors, including a different mailbox (409). For a mailbox already connected, check the browser's result, then click Browser finished."
                    : "Finish signing in in your browser, then paste the whole address it ends on here at once: Microsoft's codes can expire within a minute."
                if let u = URL(string: s.url) { NSWorkspace.shared.open(u) }
            }
        }
    }
    /// The address the sign-in ended on, pasted: checked against the sign-in, then sent once. An exchange is single use,
    /// refused or not.
    func pasteCallback() {
        guard let s = signIn, !s.finishesOnServer, !writing, Store.shared.supports("finish_mail_account") else { return }
        guard let pasted = Dialogs.text("Finish mail sign-in", label: "Paste the whole address the sign-in ended on, at once.", okLabel: "Finish") else { return }
        guard let current = signIn, current == s else { return }
        guard let body = s.finishBody(pasted: pasted.cTrimmed) else {
            error = "That address does not match this sign-in, carries an error, or the sign-in expired. Check the address or start again."
            return
        }
        writing = true; error = nil
        Task {
            let r = await boardCall("finish_mail_account", body)
            writing = false
            signIn = nil
            switch r {
            case .failure(let e):
                notice = nil
                if e.kind != .cancelled { failed(e, finishing: true, read: false) }
            case .success(let v):
                if let a = MailAccount(v["account"]), s.accountID == nil || a.id == s.accountID { notice = "Mailbox connected; refreshing its status." }
                else { error = "The server returned an unexpected mail response. Refresh before trying again." }
            }
            await load()
        }
    }
    /// The browser said it finished (or failed): stop waiting and read the list.
    func browserFinished() {
        guard signIn != nil, !writing else { return }
        signIn = nil
        notice = "Check the browser's result for success or a wrong-mailbox error; refreshing the accounts."
        Task { await load() }
    }
    func cancelWaiting() {
        guard signIn != nil, !writing else { return }
        signIn = nil
        notice = "Stopped waiting here. You can start a new sign-in."
    }

    // MARK: A mailbox's settings

    private func write(_ op: String, _ body: JSON, id: Int, done: String) {
        guard can(op), accounts.find(id) != nil else { return }
        writing = true; error = nil
        Task {
            let r = await boardCall(op, body)
            writing = false
            switch r {
            case .failure(let e):
                if e.kind != .cancelled { failed(e, finishing: false, read: false) }
            case .success(let v):
                let ok = op == "delete_mail_account" ? v["ok"].is(true) : MailAccount(v["account"])?.id == id
                if ok { notice = done } else { error = "The server returned an unexpected mail response. Refresh before trying again." }
            }
            await load()
        }
    }
    /// Only the field edited is sent: another client may have changed the others meanwhile.
    func editLabel(_ a: MailAccount) {
        guard can("update_mail_account"), let v = Dialogs.text("Mailbox label", label: "A name to show; empty for none.", okLabel: "Save", current: a.label) else { return }
        write("update_mail_account", ["id": JSON(a.id), "label": .string(v.cTrimmed)], id: a.id, done: "Label saved; refreshing the accounts.")
    }
    func toggle(_ a: MailAccount) {
        write("update_mail_account", ["id": JSON(a.id), "enabled": .bool(!a.enabled)], id: a.id,
              done: a.enabled ? "Disabled: the periodic sync leaves it out." : "Enabled: the periodic sync includes it.")
    }
    func editDays(_ a: MailAccount) {
        guard can("update_mail_account"),
              let v = Dialogs.text("Mail sync window", label: "Days to keep, 1–365. Changing it starts its sync over.", okLabel: "Save", current: String(a.syncDays)) else { return }
        guard let days = mailSyncDays(v) else { error = "Enter a whole number of days from 1 to 365."; return }
        write("update_mail_account", ["id": JSON(a.id), "syncDays": JSON(days)], id: a.id, done: "Sync window saved; its sync starts over.")
    }
    func sync(_ a: MailAccount) {
        write("sync_mail_account", ["id": JSON(a.id)], id: a.id, done: "Sync started; the accounts are read until it finishes.")
    }
    func disconnect(_ a: MailAccount) {
        guard can("delete_mail_account"),
              Dialogs.confirm("Disconnect \(a.email)?", "The server deletes its synced copy of the mail and the saved sign-in. The mailbox itself is kept. To take the app's access away too, remove it in your Google or Microsoft account settings.",
                              continueLabel: "Disconnect", destructive: true) else { return }
        write("delete_mail_account", ["id": JSON(a.id)], id: a.id,
              done: "Disconnected. Google or Microsoft may still list the app as having access until you remove it there.")
    }
}

struct MailSettingsScreen: View {
    @StateObject private var model = MailSettingsModel()
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Mail accounts", subtitle: "Gmail and Outlook mailboxes the server keeps synced; it can only read them", buttons: [
                HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the accounts again", enabled: !model.reading && !model.writing) { model.refresh() },
            ])
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, Theme.paneMargin).padding(.top, 16).padding(.bottom, 24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await model.load() }
        // While a sign-in or a sync is under way, the accounts are read every 10 seconds.
        .task(id: "\(model.signIn?.state ?? "")|\(model.accounts.syncing)|\(model.loaded)|\(model.retryUntil?.timeIntervalSince1970 ?? 0)") {
            while !Task.isCancelled, let delay = model.pollDelay {
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 1) * 1_000_000_000))
                if Task.isCancelled || !store.active { return }
                await model.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
    }

    @ViewBuilder private var content: some View {
        if !MailSettingsModel.offered {
            NoticeBox(message: "Mail settings need an Admin token on a server with mail accounts.")
        } else {
            if let e = model.error { NoticeBox(message: e).padding(.bottom, 10) }
            if let n = model.notice {
                Text(n).font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            }
            if !model.loaded {
                if !model.blocked { LoadingNote(text: "Loading mail accounts…") }
            } else {
                if let s = model.signIn { waiting(s) }
                connect
                ForEach(model.accounts.accounts, id: \.id) { a in AccountRow(model: model, account: a).padding(.bottom, 12) }
                if model.accounts.accounts.isEmpty {
                    Text("No mailboxes connected yet.").font(Theme.footnote).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func waiting(_ s: MailSignIn) -> some View {
        HStack(spacing: 8) {
            if s.finishesOnServer {
                Button("Browser finished") { model.browserFinished() }.dashButton(.prominent).disabled(model.writing)
            } else {
                Button("Paste the address it ended on…") { model.pasteCallback() }.dashButton(.prominent)
                    .disabled(model.writing || !store.supports("finish_mail_account"))
            }
            Button("Stop waiting") { model.cancelWaiting() }.dashButton(.bordered).disabled(model.writing)
            Text("Waiting for \(mailProviderName(s.provider)) until \(formatEventTime(s.expiresAt))").font(Theme.footnote).foregroundStyle(Theme.muted)
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder private var connect: some View {
        let a = model.accounts
        if store.supports("connect_mail_account") && (a.gmail || a.outlook) {
            HStack(spacing: 8) {
                if a.gmail { Button("Connect Gmail") { model.connect("gmail") }.dashButton(.prominent).disabled(!model.can("connect_mail_account")) }
                if a.outlook { Button("Connect Outlook") { model.connect("outlook") }.dashButton(.prominent).disabled(!model.can("connect_mail_account")) }
            }
            .padding(.bottom, 18)
        } else if !a.gmail && !a.outlook {
            Text("This server has no mail providers set up (Google or Microsoft OAuth).").font(Theme.footnote).foregroundStyle(Theme.muted).padding(.bottom, 18)
        }
    }
}

/// A mailbox: its name and address, what it is and how its sync stands, then its buttons.
private struct AccountRow: View {
    @ObservedObject var model: MailSettingsModel
    var account: MailAccount
    @ObservedObject private var store = Store.shared

    var body: some View {
        let a = account
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(a.needsSignIn ? Theme.danger : a.enabled ? Theme.ok : Theme.muted).frame(width: 7, height: 7)
                Text(a.title).font(Theme.bodySemibold).foregroundStyle(Theme.ink).textSelection(.enabled)
            }
            Text(statusLine(a)).font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let e = a.lastSyncError { Notice(message: e) }
            if a.needsSignIn { Notice(message: "The provider stopped honouring its sign-in (revoked or expired). Sign in again with this mailbox.") }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if store.supports("update_mail_account") {
                    Button("Label…") { model.editLabel(a) }.dashButton(.bordered).disabled(!model.can("update_mail_account"))
                    Button(a.enabled ? "Disable" : "Enable") { model.toggle(a) }.dashButton(.bordered).disabled(!model.can("update_mail_account"))
                    Button("Sync window…") { model.editDays(a) }.dashButton(.bordered).disabled(!model.can("update_mail_account"))
                }
                if store.supports("connect_mail_account") {
                    Button("Sign in again") { model.connect(a.provider, account: a.id) }.dashButton(a.needsSignIn ? .prominent : .bordered)
                        .disabled(!model.can("connect_mail_account") || !model.accounts.available(a.provider))
                }
                if store.supports("sync_mail_account") {
                    Button("Sync now") { model.sync(a) }.dashButton(.bordered)
                        .disabled(!model.can("sync_mail_account") || a.syncing || a.status != "connected")
                }
                if store.supports("delete_mail_account") {
                    Button("Disconnect") { model.disconnect(a) }.dashButton(.destructive).disabled(!model.can("delete_mail_account"))
                }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func statusLine(_ a: MailAccount) -> String {
        var parts = [a.providerName, a.needsSignIn ? "needs sign-in" : a.status, a.enabled ? "enabled" : "disabled",
                     "\(a.syncDays) day\(a.syncDays == 1 ? "" : "s")",
                     "\(a.messages) message\(a.messages == 1 ? "" : "s"), \(a.unread) unread",
                     "last sync \(a.lastSyncAt.map { formatRelative($0) } ?? "never")"]
        if a.syncing { parts.append("syncing…") }
        return parts.joined(separator: " · ")
    }
}
