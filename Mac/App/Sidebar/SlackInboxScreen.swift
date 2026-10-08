// The operator's Slack inbox (core #121; the Windows client's screen_slack.c, #135), on a server that has it for an Admin
// token: a workspace's channels, private channels, direct messages and groups; a conversation's history, older pages as
// asked for, and its threads beside it; and messages written here sent as the operator at once. Read marks follow what was
// on screen. Drafts are kept per conversation and thread while the app runs, and a send whose outcome is unknown is not
// sent again until the conversation has been checked. Nothing here is saved to disk.
import AppKit
import SwiftUI

@MainActor
final class SlackInboxModel: ObservableObject {
    static let shared = SlackInboxModel()

    static var offered: Bool {
        let s = Store.shared
        return s.isAdmin && s.supports("slack_workspaces") && s.supports("slack_conversations") && s.supports("slack_history")
    }

    @Published private(set) var workspaces: [JSON] = []
    @Published private(set) var workspace: String?
    @Published private(set) var conversations: [JSON] = []
    @Published private(set) var people: [String: JSON] = [:]
    @Published private(set) var loadingConversations = false
    @Published private(set) var error: String?
    @Published var search = ""
    /// The conversation open, its messages and where its older history starts.
    @Published private(set) var channel: String?
    @Published private(set) var messages = SlackMessages()
    @Published private(set) var page = SlackPage()
    @Published private(set) var loadingHistory = false
    @Published private(set) var historyError: String?
    /// The thread open beside it, by its parent's ts.
    @Published private(set) var thread: String?
    @Published private(set) var threadMessages = SlackMessages()
    @Published private(set) var threadPage = SlackPage()
    @Published private(set) var loadingThread = false
    /// Drafts by "channel|thread".
    @Published var drafts: [String: SlackDraft] = [:]
    @Published private(set) var sendError: String?
    @Published private(set) var retryUntil: Date?
    /// Bumped when the conversation's newest messages arrive, to scroll to them.
    @Published private(set) var scrollTick = 0
    private var marked: [String: String] = [:]
    private var generation = 0

    var coolingDown: Bool { retryUntil.map { $0 > Date() } ?? false }
    var conversation: JSON? { conversations.first { $0["id"].string == channel } }
    func name(_ row: JSON) -> String { SlackNames.conversation(row, people: people) }
    func author(_ m: SlackMessage) -> String {
        if m.raw["user"].nonEmpty == nil, let bot = m.raw["username"].nonEmpty ?? m.raw["bot_profile"]["name"].nonEmpty { return bot }
        return SlackNames.person(m.user, people: people)
    }
    func text(_ m: SlackMessage) -> String { SlackText.message(m.raw, people: people) }

    private func failed(_ e: APIError, into slot: ReferenceWritableKeyPath<SlackInboxModel, String?>) {
        if e.kind == .cancelled { return }
        if e.status == 429 { retryUntil = Date().addingTimeInterval(max(e.retryAfter ?? 30, 5)) }
        if e.status == 403 || e.status == 404 { clearPrivate() }
        self[keyPath: slot] = e.status == 429 ? "Slack is rate limiting the inbox. It is asked again after \(formatEventTime(retryUntil ?? Date()))."
            : e.status == 502 ? "Slack refused: \(e.message ?? "check the workspace's token and its scopes in Settings.")"
            : e.description
    }
    /// The workspace went away or this token may no longer read it: nothing of it is kept.
    private func clearPrivate() {
        generation += 1
        conversations = []; people = [:]; channel = nil; messages = SlackMessages(); page = SlackPage()
        thread = nil; threadMessages = SlackMessages(); threadPage = SlackPage()
    }

    // MARK: Workspaces and conversations

    func start() async {
        guard Self.offered, !coolingDown else { return }
        let r = await boardCall("slack_workspaces")
        switch r {
        case .failure(let e): failed(e, into: \.error)
        case .success(let v):
            let list = v["workspaces"].items.filter { $0["id"].number != nil }
            workspaces = list
            error = nil
            let ids = list.compactMap(Self.id)
            if workspace == nil || !ids.contains(workspace!) { pickWorkspace(ids.first) }
            else if conversations.isEmpty { await loadConversations() }
        }
    }
    static func id(_ row: JSON) -> String? {
        guard let n = row["id"].number, n.isFinite, n >= 1, n == n.rounded() else { return nil }
        return String(Int64(n))
    }
    func pickWorkspace(_ id: String?) {
        guard id != workspace || conversations.isEmpty else { return }
        clearPrivate()
        workspace = id
        guard id != nil else { return }
        Task { await loadConversations(); await loadPeople() }
    }
    func loadConversations() async {
        guard let ws = workspace, !loadingConversations, !coolingDown else { return }
        loadingConversations = true
        let gen = generation
        var rows: [JSON] = []
        var cursor = ""
        repeat {
            var args: JSON = ["id": .string(ws), "limit": 200]
            if !cursor.isEmpty { args["cursor"] = .string(cursor) }
            let r = await boardCall("slack_conversations", args)
            guard gen == generation else { loadingConversations = false; return }
            guard let v = r.value else { loadingConversations = false; if let e = r.error { failed(e, into: \.error) }; return }
            rows += v["conversations"].items.filter { !$0["is_archived"].is(true) }
            let next = v["nextCursor"].string ?? ""
            if next == cursor { break }
            cursor = next
        } while !cursor.isEmpty && rows.count < 2000
        loadingConversations = false
        conversations = rows
        error = nil
    }
    /// The directory, for authors' names and new direct messages.
    func loadPeople() async {
        guard let ws = workspace, Store.shared.supports("slack_people") else { return }
        let gen = generation
        var all: [String: JSON] = [:]
        var cursor = ""
        repeat {
            var args: JSON = ["id": .string(ws), "limit": 200]
            if !cursor.isEmpty { args["cursor"] = .string(cursor) }
            guard let v = await boardCall("slack_people", args).value, gen == generation else { return }
            for p in v["people"].items { if let id = p["id"].nonEmpty { all[id] = p } }
            let next = v["nextCursor"].string ?? ""
            if next == cursor { break }
            cursor = next
        } while !cursor.isEmpty && all.count < 5000
        people = all
    }
    var directory: [JSON] {
        people.values.filter { !$0["deleted"].is(true) && !$0["is_bot"].is(true) && $0["id"].string != "USLACKBOT" }
            .sorted { SlackNames.person($0["id"].string, people: people).lowercased() < SlackNames.person($1["id"].string, people: people).lowercased() }
    }

    // MARK: Live

    /// Whether the workspace's events are flowing (`ready` received), so polling can wait.
    @Published private(set) var live = false
    /// Follows the workspace's events until cancelled, reconnecting with a growing pause; on each `ready` (the stream does
    /// not replay what it missed) the open conversation is read again.
    func follow() async {
        guard Store.shared.supports("slack_events") else { return }
        var failures = 0
        while !Task.isCancelled {
            guard let ws = workspace, let client = Store.shared.client else { try? await Task.sleep(nanoseconds: 2_000_000_000); continue }
            do {
                try await client.stream("slack_events", ["id": .string(ws)]) { event, data in
                    guard let j = JSON.parse(data) else { return }
                    Task { @MainActor in self.apply(event, j, workspace: ws) }
                }
                failures = 0
            } catch {
                if (error as? APIError)?.kind == .cancelled || Task.isCancelled { live = false; return }
                // 409: no signing secret, so no events; polling carries on alone.
                if (error as? APIError)?.status == 409 { live = false; return }
                failures = min(failures + 1, 6)
            }
            live = false
            try? await Task.sleep(nanoseconds: UInt64(min(pow(2, Double(failures)), 60) * 1_000_000_000))
        }
        live = false
    }
    private func apply(_ event: String, _ j: JSON, workspace ws: String) {
        guard ws == workspace else { return }
        switch event {
        case "ready":
            live = true
            Task { await loadHistory(older: false) }
        case "message", "message.changed":
            let e = j["event"]
            // An edit carries the new copy as `message`; a reply's parent update arrives the same way.
            let m = e["message"].isObject ? e["message"] : e
            guard let ch = e["channel"].string ?? j["channel"].string, ch == channel else { return }
            if let parent = m["thread_ts"].nonEmpty, parent != m["ts"].string {
                if thread == parent { threadMessages.merge(m) }
                if m["subtype"].string == "thread_broadcast" { messages.merge(m); scrollTick += 1 }
            } else {
                messages.merge(m)
                scrollTick += 1
            }
        case "message.deleted":
            let e = j["event"]
            guard let ch = e["channel"].string, ch == channel, let ts = e["deleted_ts"].string ?? e["ts"].string else { return }
            messages.remove(ts); threadMessages.remove(ts)
        case "workspace.changed", "workspace.removed":
            live = false
            Task { await start() }
        default: break
        }
    }

    // MARK: A conversation

    func open(_ id: String) {
        guard id != channel else { return }
        generation += 1
        channel = id; messages = SlackMessages(); page = SlackPage(); historyError = nil
        thread = nil; threadMessages = SlackMessages(); threadPage = SlackPage(); sendError = nil
        Task { await loadHistory(older: false) }
    }
    /// The newest page (which also brings what arrived since), or the next older one.
    func loadHistory(older: Bool) async {
        guard let ws = workspace, let ch = channel, !loadingHistory, !coolingDown else { return }
        if older && !page.more { return }
        loadingHistory = true
        let gen = generation
        var args: JSON = ["id": .string(ws), "channel": .string(ch), "limit": 30]
        if older { args.merge(page.arguments) }
        let r = await boardCall("slack_history", args)
        loadingHistory = false
        guard gen == generation else { return }
        switch r {
        case .failure(let e): failed(e, into: \.historyError)
        case .success(let v):
            var m = messages
            if older {
                var p = page
                guard p.merge(v, into: &m, thread: false) else { historyError = "Slack sent an unexpected page."; return }
                page = p
            } else {
                // The newest page: what it holds merges in; where older pages start is kept once set.
                var fresh = SlackPage()
                guard fresh.merge(v, into: &m, thread: false) else { historyError = "Slack sent an unexpected page."; return }
                if messages.list.isEmpty { page = fresh }
                scrollTick += 1
            }
            messages = m
            historyError = nil
        }
    }
    func openThread(_ ts: String) {
        guard Store.shared.supports("slack_thread") else { return }
        thread = ts; threadMessages = SlackMessages(); threadPage = SlackPage()
        Task { await loadThread() }
    }
    func closeThread() { thread = nil }
    func loadThread() async {
        guard let ws = workspace, let ch = channel, let t = thread, !loadingThread, !coolingDown, threadPage.more else { return }
        loadingThread = true
        let gen = generation
        var args: JSON = ["id": .string(ws), "channel": .string(ch), "ts": .string(t), "limit": 50]
        args.merge(threadPage.arguments)
        let r = await boardCall("slack_thread", args)
        loadingThread = false
        guard gen == generation, thread == t else { return }
        switch r {
        case .failure(let e): failed(e, into: \.historyError)
        case .success(let v):
            var m = threadMessages, p = threadPage
            if p.merge(v, into: &m, thread: true) { threadMessages = m; threadPage = p }
        }
    }

    /// The conversation was on screen with its newest message: marked read through it, once a second at most.
    func markRead() {
        guard let ws = workspace, let ch = channel, let ts = messages.newest?.ts, Store.shared.supports("slack_read"), !coolingDown else { return }
        if let done = marked[ch], SlackTS.compare(ts, done) <= 0 { return }
        marked[ch] = ts
        Task { _ = await boardCall("slack_read", ["id": .string(ws), "channel": .string(ch), "ts": .string(ts)]) }
    }

    // MARK: Writing

    static func key(_ channel: String, _ thread: String?) -> String { "\(channel)|\(thread ?? "")" }
    func draft(thread: String?) -> Binding<String> {
        let key = Self.key(channel ?? "", thread)
        return Binding(get: { self.drafts[key]?.text ?? "" }, set: { self.drafts[key, default: SlackDraft()].text = String($0.prefix(SlackText.limit * 2)) })
    }
    func draftState(thread: String?) -> SlackDraft { drafts[Self.key(channel ?? "", thread)] ?? SlackDraft() }

    /// Sends the draft to the conversation, or as a reply in the thread, as the operator. Never sent again by itself.
    func send(thread: String?) {
        guard let ws = workspace, let ch = channel, Store.shared.supports("slack_send"), !coolingDown else { return }
        let key = Self.key(ch, thread)
        var d = drafts[key] ?? SlackDraft()
        guard d.begin() else { return }
        drafts[key] = d
        var body: JSON = ["id": .string(ws), "channel": .string(ch), "text": .string(d.text)]
        if let thread { body["threadTs"] = .string(thread) }
        sendError = nil
        Task {
            let r = await boardCall("slack_send", body)
            var d = drafts[key] ?? SlackDraft()
            switch r {
            case .success(let v):
                switch d.finish(ok: true, refusal: false, receipt: v, channel: ch) {
                case .confirmed:
                    if v["message"].isObject {
                        if thread != nil, self.thread == thread { threadMessages.merge(v["message"]) }
                        if thread == nil, channel == ch { messages.merge(v["message"]); scrollTick += 1 }
                    }
                case .workspaceChanged:
                    sendError = "Sent. The workspace changed meanwhile; it is read again."
                    drafts[key] = d
                    Task { await start() }
                    return
                default:
                    sendError = "The server's answer did not confirm the send. Check the conversation before sending again."
                }
            case .failure(let e):
                if e.kind == .cancelled { d.sending = false; d.uncertain = true; drafts[key] = d; return }
                let refusal = e.status >= 400 && e.status < 500 && e.status != 408
                _ = d.finish(ok: false, refusal: refusal, receipt: .null, channel: ch)
                failed(e, into: \.sendError)
                if d.uncertain { sendError = "\(sendError ?? "The send failed.") It may have gone through: check the conversation before sending again." }
            }
            drafts[key] = d
        }
    }
    /// The conversation has been checked after an unknown outcome: the draft may be sent again.
    func recover(thread: String?) {
        let key = Self.key(channel ?? "", thread)
        drafts[key]?.recover()
        sendError = nil
        Task { await loadHistory(older: false) }
    }

    /// A direct message with someone from the directory, opened and shown.
    func openDirectMessage(_ userID: String) {
        guard let ws = workspace, Store.shared.supports("slack_open_dm") else { return }
        Task {
            let r = await boardCall("slack_open_dm", ["id": .string(ws), "userId": .string(userID)])
            guard let row = r.value?["conversation"], let id = row["id"].nonEmpty else { if let e = r.error { failed(e, into: \.error) }; return }
            if !conversations.contains(where: { $0["id"].string == id }) {
                var full = row
                if full["user"].isNull { full["user"] = .string(userID) }
                if full["is_im"].isNull { full["is_im"] = true }
                conversations.insert(full, at: 0)
            }
            open(id)
        }
    }
}

struct SlackInboxScreen: View {
    @ObservedObject private var model = SlackInboxModel.shared
    @ObservedObject private var store = Store.shared
    @State private var pickingPerson = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Slack", subtitle: subtitle, buttons: headerButtons)
            if !SlackInboxModel.offered {
                NoticeBox(message: "The Slack inbox needs an Admin token on a server that has it.").padding(Theme.paneMargin)
                Spacer()
            } else if model.workspaces.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let e = model.error { NoticeBox(message: e) }
                    else { Text("No Slack workspaces yet. Add one in Settings › Slack workspaces.").font(Theme.body).foregroundStyle(Theme.muted) }
                }
                .padding(Theme.paneMargin)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    SlackConversationList(model: model, pickingPerson: $pickingPerson).frame(width: 260)
                    Rectangle().fill(Theme.line).frame(width: 1)
                    SlackConversationView(model: model).frame(maxWidth: .infinity)
                    if model.thread != nil {
                        Rectangle().fill(Theme.line).frame(width: 1)
                        SlackThreadView(model: model).frame(width: 340)
                    }
                }
            }
        }
        .task { await model.start() }
        .task(id: model.workspace) { await model.follow() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in
            Task { await model.start(); await model.loadConversations(); await model.loadHistory(older: false) }
        }
        .sheet(isPresented: $pickingPerson) { SlackPeoplePicker(model: model, shown: $pickingPerson) }
    }

    private var subtitle: String {
        guard let ws = model.workspaces.first(where: { SlackInboxModel.id($0) == model.workspace }) else { return "Your Slack, read and written as you" }
        var s = ws["label"].nonEmpty ?? ws["team"].nonEmpty ?? "Workspace"
        if let user = ws["user"].nonEmpty { s += " · as \(user)" }
        s += model.live ? " · live" : ""
        return s
    }

    private var headerButtons: [HeaderButton] {
        var out: [HeaderButton] = []
        if model.workspaces.count > 1 {
            out.append(HeaderButton(glyph: "building.2", label: "Workspace ▾", tip: "Another workspace") {
                let rows = model.workspaces.map { MenuRow(title: $0["label"].nonEmpty ?? $0["team"].nonEmpty ?? "Workspace", checked: SlackInboxModel.id($0) == model.workspace) }
                if let i = popUpMenu(rows) { model.pickWorkspace(SlackInboxModel.id(model.workspaces[i])) }
            })
        }
        out.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the conversations and this one's newest messages again", enabled: !model.coolingDown) {
            Task { await model.loadConversations(); await model.loadHistory(older: false) }
        })
        return out
    }
}

/// The workspace's conversations: a search, ＋ New message, then channels, direct messages and groups.
private struct SlackConversationList: View {
    @ObservedObject var model: SlackInboxModel
    @Binding var pickingPerson: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    TextField("Find a conversation", text: $model.search).textFieldStyle(.plain).font(Theme.footnote)
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                if Store.shared.supports("slack_open_dm") {
                    Button { pickingPerson = true } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(IconButtonStyle()).help("New direct message")
                }
            }
            .padding(10)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let e = model.error { Notice(message: e).padding(10) }
                    if model.loadingConversations && model.conversations.isEmpty { LoadingNote(text: "Loading conversations…") }
                    section("Channels") { !$0["is_im"].is(true) && !$0["is_mpim"].is(true) }
                    section("Direct messages") { $0["is_im"].is(true) }
                    section("Groups") { $0["is_mpim"].is(true) }
                }
                .padding(.bottom, 10)
            }
        }
        .background(Theme.sidebar)
    }

    @ViewBuilder private func section(_ title: String, _ include: (JSON) -> Bool) -> some View {
        let q = model.search.cTrimmed.lowercased()
        let rows = model.conversations.filter(include).filter { q.isEmpty || model.name($0).lowercased().contains(q) }
            .sorted { model.name($0).lowercased() < model.name($1).lowercased() }
        if !rows.isEmpty {
            Text(title).font(Theme.caption).foregroundStyle(Theme.muted).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            ForEach(rows, id: \.self) { row in
                let id = row["id"].string ?? ""
                let selected = model.channel == id
                Button { model.open(id) } label: {
                    HStack(spacing: 6) {
                        Text(SlackNames.glyph(row)).font(Theme.footnote).foregroundStyle(Theme.muted).frame(width: 16)
                        Text(model.name(row)).font(Theme.footnote).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.raise : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
        }
    }
}

/// One message: its author and time, what it says, and its thread's replies.
private struct SlackMessageRow: View {
    @ObservedObject var model: SlackInboxModel
    var message: SlackMessage
    var inThread = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(model.author(message)).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                if let at = SlackTS.date(message.ts) { Text(formatEventTime(at)).font(Theme.caption).foregroundStyle(Theme.muted) }
                if message.raw["edited"].isObject { Text("(edited)").font(Theme.caption).foregroundStyle(Theme.muted) }
            }
            MarkdownView(source: model.text(message))
            if !inThread && message.replyCount > 0 && Store.shared.supports("slack_thread") {
                Button("\(message.replyCount) repl\(message.replyCount == 1 ? "y" : "ies") ›") { model.openThread(message.ts) }
                    .buttonStyle(.plain).font(Theme.footnote).foregroundStyle(Theme.accent).padding(.top, 2)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !inThread && Store.shared.supports("slack_thread") { Button("Reply in thread") { model.openThread(message.ts) } }
            Button("Copy text") { Clipboard.copy(message.raw["text"].string ?? "") }
        }
    }
}

/// The conversation: older history on demand at the top, the messages, and the composer.
private struct SlackConversationView: View {
    @ObservedObject var model: SlackInboxModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        if let row = model.conversation {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("\(SlackNames.glyph(row)) \(model.name(row))").font(Theme.bodySemibold).foregroundStyle(Theme.ink)
                    if let topic = row["topic"]["value"].nonEmpty {
                        Text(topic).font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).frame(height: 40)
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if model.page.more {
                                Button(model.loadingHistory ? "Loading…" : "Load older messages") { Task { await model.loadHistory(older: true) } }
                                    .dashButton(.bordered).disabled(model.loadingHistory || model.coolingDown).padding(12)
                            } else if model.page.stalled {
                                Text("Slack stopped paging this conversation.").font(Theme.footnote).foregroundStyle(Theme.muted).padding(12)
                            }
                            if let e = model.historyError { Notice(message: e).padding(.horizontal, 16) }
                            if model.loadingHistory && model.messages.list.isEmpty { LoadingNote(text: "Loading messages…") }
                            ForEach(model.messages.list.filter(\.inChannel), id: \.ts) { m in SlackMessageRow(model: model, message: m) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: model.scrollTick) { _, _ in
                        DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                        // The newest message is on screen: read through it, after a moment.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if store.active { model.markRead() } }
                    }
                }
                SlackComposer(model: model, thread: nil, placeholder: "Message \(SlackNames.glyph(row))\(model.name(row))")
            }
            // What arrived since, every 30 seconds while on show, unless the workspace's events bring it as it happens.
            .task(id: model.channel) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if Task.isCancelled { return }
                    if store.active && !model.live { await model.loadHistory(older: false) }
                }
            }
        } else {
            VStack(spacing: 6) {
                Text("Pick a conversation").font(Theme.title3).foregroundStyle(Theme.ink)
                Text("Messages you write here go out as you, at once.").font(Theme.footnote).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A thread beside the conversation: its parent and replies, and a reply box.
private struct SlackThreadView: View {
    @ObservedObject var model: SlackInboxModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Thread").font(Theme.bodySemibold).foregroundStyle(Theme.ink)
                Spacer()
                Button { model.closeThread() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("Close the thread")
            }
            .padding(.horizontal, 12).frame(height: 40)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.loadingThread && model.threadMessages.list.isEmpty { LoadingNote(text: "Loading the thread…") }
                    ForEach(model.threadMessages.list, id: \.ts) { m in SlackMessageRow(model: model, message: m, inThread: true) }
                    if model.threadPage.more && !model.threadMessages.list.isEmpty {
                        Button(model.loadingThread ? "Loading…" : "Load more replies") { Task { await model.loadThread() } }
                            .dashButton(.bordered).disabled(model.loadingThread).padding(12)
                    }
                }
                .padding(.vertical, 8)
            }
            SlackComposer(model: model, thread: model.thread, placeholder: "Reply in thread")
        }
        .background(Theme.canvas)
    }
}

/// The message box for a conversation or a thread: Enter sends, Shift+Enter breaks the line; it names where it sends.
private struct SlackComposer: View {
    @ObservedObject var model: SlackInboxModel
    var thread: String?
    var placeholder: String
    @ObservedObject private var store = Store.shared

    var body: some View {
        let d = model.draftState(thread: thread)
        VStack(alignment: .leading, spacing: 6) {
            if let e = model.sendError, (d.uncertain || thread == nil) { Notice(message: e) }
            if d.uncertain {
                Button("I checked: allow sending again") { model.recover(thread: thread) }.dashButton(.bordered)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: model.draft(thread: thread), axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.body).lineLimit(1...8)
                    .onSubmit { model.send(thread: thread) }
                    .disabled(d.sending || !store.supports("slack_send"))
                Button { model.send(thread: thread) } label: { Image(systemName: "paperplane.fill") }
                    .buttonStyle(IconButtonStyle(prominent: SlackText.valid(d.text) && !d.sending && !d.uncertain))
                    .disabled(!SlackText.valid(d.text) || d.sending || d.uncertain || model.coolingDown)
                    .help("Send as you (Enter)")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
            if d.text.utf16.count > SlackText.limit {
                Text("\(d.text.utf16.count) / \(SlackText.limit) characters: too long for Slack.").font(Theme.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(12)
    }
}

/// ＋ New direct message: someone from the workspace's directory.
private struct SlackPeoplePicker: View {
    @ObservedObject var model: SlackInboxModel
    @Binding var shown: Bool
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New direct message").font(Theme.title3).foregroundStyle(Theme.ink)
            TextField("Find someone", text: $query).textFieldStyle(.roundedBorder)
            let q = query.cTrimmed.lowercased()
            let people = model.directory.filter { p in
                q.isEmpty || SlackNames.person(p["id"].string, people: model.people).lowercased().contains(q) || (p["real_name"].string ?? "").lowercased().contains(q)
            }
            List(people.prefix(200), id: \.self) { p in
                Button {
                    shown = false
                    if let id = p["id"].nonEmpty { model.openDirectMessage(id) }
                } label: {
                    HStack {
                        Text(SlackNames.person(p["id"].string, people: model.people)).foregroundStyle(Theme.ink)
                        if let real = p["real_name"].nonEmpty, real != SlackNames.person(p["id"].string, people: model.people) {
                            Text(real).foregroundStyle(Theme.muted)
                        }
                    }
                    .font(Theme.footnote)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 280)
            HStack { Spacer(); Button("Cancel") { shown = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(18)
        .frame(width: 420, height: 440)
    }
}
