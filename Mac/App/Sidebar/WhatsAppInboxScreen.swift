// The operator's WhatsApp inbox through the server's WAHA (core #130), on a server that has it set up, for an Admin
// token: the linked phone (linked from here with its QR code), the chats newest first with their unread counts, a chat's
// history with older pages on request, and messages and quoted replies sent from here as the operator. The account, the
// chats and the open chat are read again every 5 seconds while on show, as the server asks. Nothing is kept on disk, and a
// send whose outcome is unknown is not sent again until the chat has been checked.
import AppKit
import SwiftUI

@MainActor
final class WhatsAppInboxModel: ObservableObject {
    static let shared = WhatsAppInboxModel()

    /// The server lists the routes for this token; whether WAHA is set up is asked once (`configured`).
    static var routes: Bool {
        let s = Store.shared
        return s.isAdmin && s.supports("whatsapp_accounts") && s.supports("whatsapp_conversations") && s.supports("whatsapp_messages")
    }
    /// Set up on the server, as its first answer says; nil until asked.
    @Published private(set) var configured: Bool?
    static var offered: Bool { routes && shared.configured != false }

    @Published private(set) var account: WhatsAppAccount?
    @Published private(set) var qr: NSImage?
    @Published private(set) var chats: [WhatsAppChat] = []
    @Published private(set) var error: String?
    @Published var search = ""
    @Published private(set) var chat: String?
    @Published private(set) var messages = WhatsAppMessages()
    @Published private(set) var nextOffset: Int?
    @Published private(set) var loadingOlder = false
    @Published private(set) var historyError: String?
    @Published var draft = ""
    @Published private(set) var sending = false
    @Published private(set) var uncertain = false
    @Published private(set) var sendError: String?
    /// The message a reply quotes.
    @Published var replyTo: WhatsAppMessage?
    @Published private(set) var scrollTick = 0
    @Published private(set) var busy = false
    private var marked: [String: String] = [:]
    private var generation = 0

    var openChat: WhatsAppChat? { chats.first { $0.id == chat } }
    var accountID: String { account?.id ?? "default" }

    private func failed(_ e: APIError, into slot: ReferenceWritableKeyPath<WhatsAppInboxModel, String?>) {
        if e.kind == .cancelled { return }
        self[keyPath: slot] = e.status == 503 ? "WhatsApp is not set up on the server (WAHA)."
            : e.status == 502 ? "The server could not reach WAHA, or WAHA refused its key."
            : e.status == 409 ? "The phone is not linked or not ready: \(e.message ?? "")"
            : e.description
    }

    /// Asks once whether WAHA is set up, so the sidebar's button knows which WhatsApp to open.
    func probe() async {
        guard Self.routes, configured == nil else { return }
        if let v = await boardCall("whatsapp_accounts").value { configured = v["configured"].is(true) }
    }

    /// The account, then its pairing code or its chats, then the open chat's newest messages.
    func tick() async {
        guard Self.routes else { return }
        let r = await boardCall("whatsapp_accounts")
        switch r {
        case .failure(let e):
            failed(e, into: \.error)
            return
        case .success(let v):
            configured = v["configured"].is(true)
            guard configured == true else { account = nil; return }
            account = v["accounts"].items.compactMap(WhatsAppAccount.init).first
            error = nil
        }
        guard let account else { return }
        if account.pairing && Store.shared.supports("whatsapp_qr") {
            if let v = await boardCall("whatsapp_qr", ["id": .string(account.id)]).value, let data = WhatsAppText.qrImage(v) { qr = NSImage(data: data) }
        } else { qr = nil }
        guard account.working else { return }
        await loadChats()
        if chat != nil { await loadNewest() }
    }
    func loadChats() async {
        let gen = generation
        let r = await boardCall("whatsapp_conversations", ["id": .string(accountID), "limit": 100])
        guard gen == generation else { return }
        switch r {
        case .failure(let e): failed(e, into: \.error)
        case .success(let v):
            chats = v["conversations"].items.compactMap(WhatsAppChat.init)
            error = nil
        }
    }

    // MARK: The phone

    func start() {
        guard Store.shared.supports("whatsapp_start"), !busy else { return }
        busy = true
        Task {
            let r = await boardCall("whatsapp_start", ["id": .string(accountID)])
            busy = false
            if let e = r.error { failed(e, into: \.error) }
            await tick()
        }
    }
    func logout() {
        guard Store.shared.supports("whatsapp_logout"), !busy,
              Dialogs.confirm("Unlink this phone?", "The server stops reading and sending WhatsApp messages until the phone is linked again with its QR code.",
                              continueLabel: "Unlink", destructive: true) else { return }
        busy = true
        Task {
            let r = await boardCall("whatsapp_logout", ["id": .string(accountID)])
            busy = false
            if let e = r.error { failed(e, into: \.error) }
            generation += 1
            chats = []; chat = nil; messages = WhatsAppMessages()
            await tick()
        }
    }

    // MARK: A chat

    func open(_ id: String) {
        guard id != chat else { return }
        generation += 1
        chat = id; messages = WhatsAppMessages(); nextOffset = nil; historyError = nil
        draft = ""; replyTo = nil; uncertain = false; sendError = nil
        Task { await loadNewest() }
    }
    func loadNewest() async {
        guard let id = chat else { return }
        let gen = generation
        let r = await boardCall("whatsapp_messages", ["id": .string(accountID), "chat": .string(id), "limit": 50])
        guard gen == generation, chat == id else { return }
        switch r {
        case .failure(let e): failed(e, into: \.historyError)
        case .success(let v):
            let first = messages.list.isEmpty
            let before = messages.list.last?.id
            messages.merge(v["messages"].items.compactMap(WhatsAppMessage.init))
            if first { nextOffset = v["nextOffset"].int32.map { Int($0) } }
            if first || messages.list.last?.id != before { scrollTick += 1 }
            historyError = nil
        }
    }
    func loadOlder() async {
        guard let id = chat, let offset = nextOffset, !loadingOlder else { return }
        loadingOlder = true
        let gen = generation
        let r = await boardCall("whatsapp_messages", ["id": .string(accountID), "chat": .string(id), "limit": 50, "offset": JSON(offset)])
        loadingOlder = false
        guard gen == generation else { return }
        switch r {
        case .failure(let e): failed(e, into: \.historyError)
        case .success(let v):
            messages.merge(v["messages"].items.compactMap(WhatsAppMessage.init))
            nextOffset = v["nextOffset"].int32.map { Int($0) }
        }
    }
    /// The chat was on screen with its newest message: its unread ones are marked read, once per newest message.
    func markRead() {
        guard let id = chat, let newest = messages.list.last?.id, marked[id] != newest, Store.shared.supports("whatsapp_read"),
              (openChat?.unread ?? 0) > 0 else { return }
        marked[id] = newest
        Task {
            _ = await boardCall("whatsapp_read", ["id": .string(accountID), "chat": .string(id)])
            await loadChats()
        }
    }

    // MARK: Writing

    func send() {
        guard let id = chat, Store.shared.supports("whatsapp_send"), !sending, !uncertain, WhatsAppText.valid(draft) else { return }
        let text = draft
        var body: JSON = ["id": .string(accountID), "chat": .string(id), "text": .string(text)]
        if let replyTo { body["replyTo"] = .string(replyTo.id) }
        sending = true; sendError = nil
        Task {
            let r = await boardCall("whatsapp_send", body)
            sending = false
            switch r {
            case .success(let v):
                if let m = WhatsAppMessage(v["message"]), chat == id { messages.merge([m]); scrollTick += 1 }
                if draft == text { draft = "" }
                replyTo = nil
            case .failure(let e):
                if e.kind == .cancelled { uncertain = true; return }
                failed(e, into: \.sendError)
                // A refusal (a 4xx but a timeout) is known not to have gone; anything else may have.
                if !(e.status >= 400 && e.status < 500 && e.status != 408) {
                    uncertain = true
                    sendError = "\(sendError ?? "The send failed.") It may have gone through: check the chat before sending again."
                }
            }
        }
    }
    func recover() { uncertain = false; sendError = nil; Task { await loadNewest() } }

    /// An attachment, downloaded through the server (WAHA's own storage), quarantined, and opened with its app when it is a
    /// safe kind; anything else is shown in Finder.
    @Published private(set) var downloading: String?
    func openMedia(_ m: WhatsAppMessage) {
        guard let id = chat, downloading == nil, let client = Store.shared.client else { return }
        let url = client.address.baseURL + "whatsapp/accounts/\(APIClient.encode(accountID))/conversations/\(APIClient.encode(id))/messages/\(APIClient.encode(m.id))/media"
        downloading = m.id
        Task {
            defer { downloading = nil }
            do {
                guard let data = try await client.serverFile(url, under: "whatsapp/accounts/", limit: 100 * 1024 * 1024) else { return }
                let safe = ReceivedFile.safeName(m.mediaName)
                let ext = (safe as NSString).pathExtension.isEmpty ? WhatsAppText.fileExtension(m.mediaType) : ""
                try openReceivedFile(data, named: safe + ext, prefix: String(abs(m.id.hashValue)), in: "briareus-whatsapp")
            } catch {
                historyError = errorText(error)
            }
        }
    }
}

struct WhatsAppInboxScreen: View {
    @ObservedObject private var model = WhatsAppInboxModel.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "WhatsApp", subtitle: subtitle, buttons: headerButtons)
            content
        }
        .task {
            // As the server asks: the account, the chats and the open chat every 5 seconds while on show.
            while !Task.isCancelled {
                if store.active { await model.tick() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private var subtitle: String {
        guard let a = model.account else { return "Your WhatsApp, through the server" }
        return "\(a.me ?? "phone") · \(a.statusText)"
    }
    private var headerButtons: [HeaderButton] {
        var out: [HeaderButton] = []
        out.append(HeaderButton(glyph: "globe", label: "WhatsApp Web", tip: "WhatsApp's own web app") { Navigator.shared.push(.webApp(.whatsapp)) })
        if model.account?.working == true && store.supports("whatsapp_logout") {
            out.append(HeaderButton(glyph: "iphone.slash", tip: "Unlink the phone", enabled: !model.busy, destructive: true) { model.logout() })
        }
        return out
    }

    @ViewBuilder private var content: some View {
        if model.configured == false {
            message("WhatsApp is not set up on this server (WAHA). WhatsApp Web, in the header, still works.")
        } else if let a = model.account, !a.working {
            pairing(a)
        } else if model.account == nil {
            VStack(alignment: .leading, spacing: 10) {
                if let e = model.error { NoticeBox(message: e) } else { LoadingNote(text: "Reading the phone's link…") }
                if store.supports("whatsapp_start") { Button("Link a phone") { model.start() }.dashButton(.prominent).disabled(model.busy) }
            }
            .padding(Theme.paneMargin)
            Spacer()
        } else {
            HStack(spacing: 0) {
                WhatsAppChatList(model: model).frame(width: 280)
                Rectangle().fill(Theme.line).frame(width: 1)
                WhatsAppChatView(model: model).frame(maxWidth: .infinity)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(Theme.body).foregroundStyle(Theme.muted).padding(Theme.paneMargin).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The phone is not linked: its QR code to scan, or Start.
    private func pairing(_ a: WhatsAppAccount) -> some View {
        VStack(spacing: 14) {
            Text(a.pairing ? "Link your phone" : "The phone's link is \(a.statusText)").font(Theme.title3).foregroundStyle(Theme.ink)
            if a.pairing {
                Text("On the phone: WhatsApp › Linked devices › Link a device, then scan this.").font(Theme.footnote).foregroundStyle(Theme.muted)
                if let qr = model.qr {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 264, height: 264)
                        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                } else { LoadingNote(text: "Reading the code…").frame(width: 200) }
            } else if store.supports("whatsapp_start") {
                Button(a.status == "STARTING" ? "Starting…" : "Start") { model.start() }.dashButton(.prominent).disabled(model.busy || a.status == "STARTING")
            }
            if let e = model.error { Notice(message: e) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The chats, newest activity first, with a search: each with its last message and unread count.
private struct WhatsAppChatList: View {
    @ObservedObject var model: WhatsAppInboxModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.muted)
                TextField("Find a chat", text: $model.search).textFieldStyle(.plain).font(Theme.footnote)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
            .padding(10)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let e = model.error { Notice(message: e).padding(10) }
                    let q = model.search.cTrimmed.lowercased()
                    ForEach(model.chats.filter { q.isEmpty || $0.name.lowercased().contains(q) }, id: \.id) { c in row(c) }
                }
            }
        }
        .background(Theme.sidebar)
    }

    private func row(_ c: WhatsAppChat) -> some View {
        Button { model.open(c.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.isGroup ? "👥" : "👤").font(.system(size: 11))
                    Text(c.name).font(c.unread > 0 ? Theme.footnoteSemibold : Theme.footnote).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if let at = c.last?.date { Text(formatRelative(at)).font(Theme.caption2).foregroundStyle(Theme.muted) }
                }
                HStack(spacing: 6) {
                    Text(c.last.map(preview) ?? "").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    if c.unread > 0 {
                        Text("\(c.unread)").font(Theme.caption2).foregroundStyle(Theme.onAccent).padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Theme.ok))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(model.chat == c.id ? Theme.raise : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    private func preview(_ m: WhatsAppMessage) -> String {
        let body = m.text.isEmpty ? (m.hasMedia ? "📎 \(m.mediaName ?? "Attachment")" : "") : m.text
        return (m.fromMe ? "You: " : "") + body
    }
}

/// The open chat: older pages on request, the messages as bubbles, and the composer.
private struct WhatsAppChatView: View {
    @ObservedObject var model: WhatsAppInboxModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        if let c = model.openChat {
            VStack(spacing: 0) {
                HStack {
                    Text(c.name).font(Theme.bodySemibold).foregroundStyle(Theme.ink)
                    Text(c.isGroup ? "group" : WhatsAppText.phone(c.id)).font(Theme.footnote).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 16).frame(height: 40)
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            if model.nextOffset != nil {
                                Button(model.loadingOlder ? "Loading…" : "Load older messages") { Task { await model.loadOlder() } }
                                    .dashButton(.bordered).disabled(model.loadingOlder).padding(8)
                            }
                            if let e = model.historyError { Notice(message: e) }
                            ForEach(model.messages.list, id: \.id) { m in bubble(m, group: c.isGroup) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .onChange(of: model.scrollTick) { _, _ in
                        DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if store.active { model.markRead() } }
                    }
                }
                composer
            }
        } else {
            Text("Pick a chat").font(Theme.title3).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bubble(_ m: WhatsAppMessage, group: Bool) -> some View {
        HStack {
            if m.fromMe { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 3) {
                if group && !m.fromMe, let p = m.participant {
                    Text(WhatsAppText.phone(p)).font(Theme.caption2).foregroundStyle(Theme.accent)
                }
                if let q = m.quoteText {
                    VStack(alignment: .leading, spacing: 1) {
                        if let a = m.quoteAuthor { Text(WhatsAppText.phone(a)).font(Theme.caption2).foregroundStyle(Theme.accent) }
                        Text(q).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(3)
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
                }
                if m.hasMedia {
                    let can = store.supports("whatsapp_media")
                    HStack(spacing: 4) {
                        Text("📎 \(m.mediaName ?? "Attachment")\(m.mediaType.map { " · \($0)" } ?? "")")
                        if model.downloading == m.id { Text("downloading…") }
                    }
                    .font(Theme.footnote).foregroundStyle(can ? Theme.accent : Theme.muted)
                    .contentShape(Rectangle())
                    .onTapGesture { if can { model.openMedia(m) } }
                    .onHover { if can { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() } }
                    .help("Download it through the server and open it")
                }
                if !m.text.isEmpty {
                    Text(m.text).font(Theme.body).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if !m.hasMedia {
                    // A sticker, a reaction or a call: nothing WAHA gives as text.
                    Text("A message with no text (a sticker, reaction or call); open WhatsApp to see it").font(Theme.footnote).italic().foregroundStyle(Theme.muted)
                }
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(formatEventTime(m.date)).font(Theme.caption2).foregroundStyle(Theme.muted)
                    if let t = m.ticks { Text(t).font(Theme.caption2).foregroundStyle(m.read ? Color.blue : Theme.muted) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(m.fromMe ? Theme.ok.opacity(0.22) : Theme.raise))
            .frame(maxWidth: 520, alignment: m.fromMe ? .trailing : .leading)
            .contextMenu {
                if store.supports("whatsapp_send") { Button("Reply") { model.replyTo = m } }
                Button("Copy text") { Clipboard.copy(m.text) }
            }
            if !m.fromMe { Spacer(minLength: 60) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = model.sendError { Notice(message: e) }
            if model.uncertain { Button("I checked: allow sending again") { model.recover() }.dashButton(.bordered) }
            if let q = model.replyTo {
                HStack {
                    Text("Replying to: \(q.text.isEmpty ? "📎 Attachment" : q.text)").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer()
                    Button { model.replyTo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.body).lineLimit(1...8)
                    .onSubmit { model.send() }
                    .disabled(model.sending || !store.supports("whatsapp_send"))
                Button { model.send() } label: { Image(systemName: "paperplane.fill") }
                    .buttonStyle(IconButtonStyle(prominent: WhatsAppText.valid(model.draft) && !model.sending && !model.uncertain))
                    .disabled(!WhatsAppText.valid(model.draft) || model.sending || model.uncertain)
                    .help("Send as you (Enter)")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
        }
        .padding(12)
    }
}
