// One conversation (screen_conversation.c): its transcript, read a little at a time after the saved part; the composer;
// and the actions on the session. The column beside it is the session's panel.
import AppKit
import SwiftUI

// MARK: - The composer's own state

/// What is typed, kept apart from the conversation so a keystroke does not lay the transcript out again.
@MainActor
final class ComposerState: ObservableObject {
    @Published var text = ""
    @Published var lines = 1
    @Published var focused = false
    @Published var focus = FocusRequest()
    var trimmedEmpty: Bool { text.cTrimmed.isEmpty }
    func focusNow() { focus.tick += 1 }
}

/// Text typed into a conversation that was left for a screen pushed over it, until it comes back.
@MainActor
enum ConversationDrafts { static var text: [String: String] = [:] }

// MARK: - The model

@MainActor
final class ConversationModel: ObservableObject {
    let id: String
    let initial: Session
    @Published private(set) var snapshot: Session?
    var session: Session { snapshot ?? initial }

    @Published private(set) var transcript = Transcript()
    @Published private(set) var blocks: [TranscriptBlock] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?
    @Published private(set) var writeError: String?
    /// Tool and preparation blocks opened, by their first event's sequence.
    @Published var expanded: Set<Int> = []
    /// Verdicts picked here for the held round, by finding key.
    @Published var decisions: [String: String] = [:]
    @Published var triageNote = ""
    /// Bumped to scroll the transcript to its end and keep it there.
    @Published private(set) var scrollToEnd = 0
    /// The find bar (⌘F) while open, its query and its matches; `findTick` is bumped to bring the current one into view.
    @Published private(set) var finding = false
    @Published var findQuery = "" { didSet { if findQuery != oldValue { findSearch() } } }
    @Published private(set) var find = TranscriptFind()
    @Published private(set) var findTick = 0

    private var restored = false, unsaved = false, retimed = false, pendingFull = false
    var dialogOpen = false

    let composer = ComposerState()
    /// The transcript's text selection, across its messages.
    let selection = TextSelectionGroup()
    let files = Attachments(call: "message")
    let voice = VoiceNote()

    /// The window's navigator it opened in (a page popped out has its own), which its polling and its delete act on
    /// whichever window is in front.
    let navigator = Navigator.shared

    init(id: String, initial: JSON?) {
        self.id = id
        self.initial = initial.flatMap(Session.init) ?? Session(raw: ["id": .string(id), "status": ""])
        composer.text = ConversationDrafts.text[id] ?? ""
        voice.onText = { [weak self] text in
            guard let self else { return }
            self.composer.text = appendDictation(self.composer.text, text)
        }
    }

    private var cacheKey: String { "transcript:\(id)" }
    var screenID: String { "conversation:\(id)" }
    var canMessage: Bool { Store.shared.supports("message") && session.status != "closed" }
    /// Nothing is in flight and no earlier write left its outcome unknown.
    var can: Bool { !busy && !uncertain }

    // MARK: Reading

    /// Reads what happened since the cursor, or the whole transcript; a read already under way keeps a full one for after.
    @discardableResult
    func refresh(full requested: Bool) async -> APIError? {
        if loading { if requested { pendingFull = true }; return nil }
        loading = true
        var full = requested
        if !restored {
            // Saved events show at once and move the cursor, so only what happened since is downloaded.
            restored = true
            let saved = Store.shared.cache.lines(cacheKey)
            if !saved.isEmpty { transcript.append(.array(saved)); rebuild() }
        }
        // A transcript saved before messages showed their time has none; it is read again once to get them.
        if !retimed && transcriptNeedsRetime(transcript.events) { full = true }
        retimed = true
        var failure: APIError?
        do {
            let answer = try await Store.shared.call("session", ["sessionId": .string(id), "since": JSON(full ? 0 : transcript.cursor)])
            loading = false
            if let next = Session(answer["session"]) { snapshot = next }
            let events = answer["events"]
            if full { transcript = Transcript() }
            transcript.append(events)
            error = nil; loaded = true
            let cache = Store.shared.cache
            if full || unsaved { unsaved = !cache.replace(transcript.json.items, cacheKey) }
            else if events.count > 0 { unsaved = !cache.append(events.items, cacheKey) }
            rebuild()
            showPanel()
        } catch {
            loading = false
            if error.isCancellation { return APIError(.cancelled) }
            self.error = errorText(error); loaded = true
            failure = error as? APIError ?? APIError(.network, message: errorText(error))
        }
        if pendingFull { pendingFull = false; Task { await self.refresh(full: true) } }
        return failure
    }
    private func rebuild() {
        let next = transcriptBlocks(transcript.events)
        if next != blocks { blocks = next }
    }

    /// Whether the session's event stream is flowing, so polling only checks in now and then.
    @Published private(set) var live = false

    /// Follows the session's event stream while the screen is up: each transcript line lands as it is written, and the
    /// record on each change. It starts after the lines already read; a dropped stream comes back after 2 s doubling to a
    /// minute, and polling carries on meanwhile.
    func follow() async {
        guard Store.shared.supports("session_events") else { return }
        var failures = 0
        while !Task.isCancelled {
            while (!Store.shared.active || !loaded) && !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard let client = Store.shared.client, !Task.isCancelled else { return }
            do {
                try await client.stream("session_events", ["sessionId": .string(id), "since": JSON(transcript.cursor)],
                                        opened: { [weak self] in Task { @MainActor in self?.live = true } }) { [weak self] event, data in
                    guard let j = JSON.parse(data) else { return }
                    Task { @MainActor in self?.applyLive(event, j) }
                }
                failures = 0
            } catch {
                live = false
                if Task.isCancelled || (error as? APIError)?.kind == .cancelled { return }
                if let s = (error as? APIError)?.status, s == 404 || s == 403 { return }
                failures = min(failures + 1, 6)
            }
            live = false
            try? await Task.sleep(nanoseconds: UInt64(min(pow(2, Double(failures)), 60) * 1_000_000_000))
        }
    }
    private func applyLive(_ event: String, _ j: JSON) {
        live = true
        if event == "session" {
            if let next = Session(j["session"].isObject ? j["session"] : j) { snapshot = next; showPanel() }
            return
        }
        // A transcript line, unnamed; one already held (read by a poll meanwhile) adds nothing.
        guard j["seq"].truncatedInt != nil else { return }
        let before = transcript.events.count
        transcript.append(.array([j]))
        guard transcript.events.count != before else { return }
        if !unsaved { unsaved = !Store.shared.cache.append([j], cacheKey) }
        rebuild()
    }

    /// Polls while the screen is up: every 2 seconds while the agent works, every 7 otherwise, with the Windows client's
    /// backoff; every 30 while the event stream brings the lines.
    func run() async {
        var failures = 0
        while !Task.isCancelled {
            while !Store.shared.active && !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            if Task.isCancelled { return }
            var failure: APIError?
            if !busy && !dialogOpen && !loading { failure = await refresh(full: false) }
            if Task.isCancelled { return }
            if let failure, failure.kind != .cancelled { failures += 1 } else { failures = 0 }
            let delay = pollDelay(base: live ? 30 : session.isActive ? 2 : 7, failures: failures, retryAfter: failure?.retryAfter)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// The column at the right: the session's pull request and context usage, while this conversation is the page itself
    /// (not one pushed over a pull request) and the session has any of them. An open panel takes the latest record.
    func showPanel() {
        let nav = navigator
        guard nav.top.id == screenID else { return }
        if nav.stack.count == 1 && SessionPanel.wanted(session) {
            if nav.panelSession != session.raw { nav.panelSession = session.raw }
        } else if nav.panelSession != nil {
            nav.panelSession = nil
        }
    }
    /// The screen went away: a pull request pushed over the conversation fills the window, and the column returns with it.
    func hidden() {
        voice.drop()
        let draft = composer.text
        ConversationDrafts.text[id] = draft.isEmpty ? nil : draft
        files.clear()
        let nav = navigator
        if nav.panelSession?["id"].string == id { nav.panelSession = nil }
    }

    // MARK: Find in the conversation

    private var findBlocks: [(seq: Int, pieces: [String])] {
        blocks.map { ($0.seq, transcriptFindPieces($0, open: expanded.contains($0.seq))) }
    }
    func openFind() { finding = true; findFocus += 1 }
    /// Focus for the find field: bumped by ⌘F, also while it is open.
    @Published private(set) var findFocus = 0
    func closeFind() {
        finding = false
        findQuery = ""
        find = TranscriptFind()
        selection.find = nil
    }
    private func findSearch() {
        find.search(findQuery, in: findBlocks)
        findShow()
    }
    func findStep(backward: Bool) {
        guard !find.matches.isEmpty else { return }
        find.step(backward: backward)
        findShow()
    }
    /// The transcript changed under an open find bar: the matches again, the current one kept where it was.
    func findRefresh() {
        guard finding, !findQuery.isEmpty else { return }
        let before = find.currentMatch
        find.rebuild(findBlocks)
        selection.find = (findQuery, find.currentMatch?.block, find.currentInBlock ?? 0)
        if find.currentMatch != before { findTick += 1 }
    }
    private func findShow() {
        selection.find = findQuery.isEmpty ? nil : (findQuery, find.currentMatch?.block, find.currentInBlock ?? 0)
        if find.currentMatch != nil { findTick += 1 }
    }

    // MARK: Writing

    func mutate(_ name: String, _ extra: JSON = [:]) {
        if busy || uncertain { return }
        busy = true; writeError = nil
        var args: JSON = ["sessionId": .string(id)]
        args.merge(extra)
        Task {
            do { _ = try await Store.shared.call(name, args) } catch {
                busy = false
                writeError = errorText(error)
                uncertain = true
                return
            }
            busy = false
            let repo = session.repo ?? initial.repo
            switch name {
            case "message":
                if composer.text == args["text"].string {
                    composer.text = ""
                    ConversationDrafts.text[id] = nil
                    scrollToEnd += 1
                }
                // The files that went with it; one attached since stays for the next message.
                files.sent(args["attachments"].isNull ? nil : args["attachments"])
            case "delete":
                // The sidebar drops the row now instead of at its next poll; the transcript goes with it.
                Store.shared.cache.remove(cacheKey)
                ConversationDrafts.text[id] = nil
                var info: [String: Any] = ["id": id]
                if let repo { info["repo"] = repo }
                post(.sessionForgotten, info)
                // Beside the list there is nothing to go back to: the right-hand side empties instead.
                let nav = navigator
                if nav.top.id == screenID { if nav.stack.count > 1 { nav.pop() } else { nav.clear() } }
                return
            case "complete_findings":
                decisions = [:]; triageNote = ""
            default: break
            }
            post(.sessionsChanged, repo.map { ["repo": $0] } ?? [:])
            // A Clear or a compaction hides lines already on screen, so the transcript is read again whole.
            await refresh(full: name == "clear" || name == "compact")
        }
    }

    func confirmAndMutate(_ action: String) {
        let title: String
        switch action {
        case "delete": title = "Permanently delete this conversation and its transcript?"
        case "cancel": title = "Stop the running agent?"
        case "close": title = "Close this conversation?"
        default: title = "Reopen this conversation?"
        }
        dialogOpen = true
        let ok = Dialogs.confirm(title, nil, continueLabel: "Confirm", destructive: action == "delete" || action == "cancel")
        dialogOpen = false
        guard ok else { return }
        mutate(action)
    }

    func send() {
        guard !busy, !uncertain, !composer.trimmedEmpty, canMessage, !files.uploading else { return }
        var extra: JSON = ["text": .string(composer.text)]
        if let ids = files.ids { extra["attachments"] = ids }
        mutate("message", extra)
    }

    func rename() {
        dialogOpen = true
        let title = Dialogs.text("Rename conversation", label: "Title", okLabel: "Save", current: session.displayTitle)
        dialogOpen = false
        if let title, !title.cTrimmed.isEmpty { mutate("rename", ["title": .string(title)]) }
    }

    func toggleLoop() {
        mutate("review_loop", ["on": .bool(!session.reviewLoopOn)])
    }

    func answer(_ label: String) {
        composer.text = label
        composer.focusNow()
    }

    func refreshOutcome() {
        uncertain = false; writeError = nil
        Task { await refresh(full: false) }
    }

    // MARK: Held findings

    func pick(_ finding: JSON, decision index: Int) {
        guard let key = finding["key"].string, index >= 0, index < findingDecisionIds.count else { return }
        decisions[key] = findingDecisionIds[index]
    }
    func editNote() {
        dialogOpen = true
        let note = Dialogs.text("Note", label: "A note for the pull request and the fix session (optional)", okLabel: "Save", current: triageNote)
        dialogOpen = false
        if let note { triageNote = note }
    }
    func completeTriage(fixes: Int) {
        guard let triage = session.heldTriage else { return }
        let takes = triageTakesVerdicts(triage)
        dialogOpen = true
        let ok = Dialogs.confirm(triageConfirmTitle(takesVerdicts: takes, fixes: fixes), nil, continueLabel: "Complete")
        dialogOpen = false
        guard ok else { return }
        mutate("complete_findings", triageCompletion(triage, picked: decisions, note: triageNote))
    }
}

// MARK: - The screen

struct ConversationScreen: View {
    var sessionID: String
    var initial: JSON?
    @StateObject private var model: ConversationModel
    @ObservedObject private var store = Store.shared
    @State private var atBottom = true
    @State private var stick = true
    /// The user scrolled since the transcript last kept to its end: only then does it stop following new lines.
    @State private var userScrolled = false
    /// A scroll to the end under way, which the user scrolling the transcript cancels.
    @State private var scrolling: Task<Void, Never>?

    init(sessionID: String, initial: JSON?) {
        self.sessionID = sessionID
        self.initial = initial
        _model = StateObject(wrappedValue: ConversationModel(id: sessionID, initial: initial))
    }

    private var headerButtons: [HeaderButton] {
        let s = model.session
        let can = model.can
        let closed = s.status == "closed"
        var out: [HeaderButton] = []
        if store.supports("browser") {
            let browser = BrowserState.sessionOn(s.raw)
            out.append(HeaderButton(glyph: Glyph.symbol(0xE774), label: browser.on && browser.running ? "\u{1F310} Browser \u{25CF}" : "\u{1F310} Browser",
                                    tip: "The session's shared browser") { BrowserDock.open(s) })
        }
        // An admin token's; the session record carries the settings, so the button says when deliveries are on.
        if store.supports("session_webhook") {
            let armed = s.raw["webhook"]["armed"].is(true)
            out.append(HeaderButton(glyph: "bolt", label: armed ? "\u{26A1} Webhook \u{25CF}" : "\u{26A1} Webhook",
                                    tip: armed ? "Webhook (on)" : "Webhook") { Navigator.shared.push(.webhook(session: s.raw)) })
        }
        if store.supports("cancel") && s.isActive {
            out.append(HeaderButton(glyph: Glyph.symbol(0xE71A), label: "\u{23F9} Stop", tip: "Stop", enabled: can) { model.confirmAndMutate("cancel") })
        }
        if store.supports("reopen") && closed {
            out.append(HeaderButton(glyph: Glyph.symbol(0xE7A7), label: "\u{27F3} Reopen", tip: "Reopen", enabled: can) { model.confirmAndMutate("reopen") })
        }
        if store.supports("close") && !closed {
            out.append(HeaderButton(glyph: Glyph.symbol(0xE8BB), label: "Close", tip: "Close", enabled: can) { model.confirmAndMutate("close") })
        }
        if store.supports("delete") {
            out.append(HeaderButton(glyph: Glyph.symbol(0xE74D), label: "\u{1F5D1} Delete", tip: "Delete", enabled: can, destructive: true) { model.confirmAndMutate("delete") })
        }
        return out
    }

    /// What changes the transcript's height at its end: new events, the queue, the held round, the working line, errors.
    private var contentMark: [Int] {
        let s = model.session
        return [model.transcript.events.count, model.transcript.cursor, s.queued.count, s.isActive ? 1 : 0,
                s.heldTriage?["findings"].count ?? -1, model.error == nil ? 0 : 1, model.writeError == nil ? 0 : 1,
                s.raw["error"].nonEmpty == nil ? 0 : 1, model.loaded ? 1 : 0]
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: model.session.displayTitle, subtitle: (model.live ? "● live · " : "") + conversationStatusLine(model.session), buttons: headerButtons,
                       titleAction: store.supports("rename") ? { model.rename() } : nil)
            if model.finding { FindBar(model: model) }
            transcript
            if RecoveryReport.offered(status: model.session.status) && store.isAdmin && store.supports("session_recovery") {
                RecoveryBox(sessionID: model.id) { Task { await model.refresh(full: true) } }.id(model.id)
            }
            ConversationFooter(model: model, composer: model.composer, files: model.files, voice: model.voice)
        }
        // ⌘F: find in the conversation (the Windows client's Ctrl+F).
        .background(Button("") { model.openFind() }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0))
        .onChange(of: model.blocks) { _, _ in model.findRefresh() }
        .onChange(of: model.expanded) { _, _ in model.findRefresh() }
        .task(id: store.active) { await model.run() }
        .task { await model.follow() }
        .onAppear {
            model.showPanel()
            stick = true
        }
        .onDisappear {
            scrolling?.cancel(); scrolling = nil
            model.hidden()
        }
        .onChange(of: store.active) { _, active in
            // Recording cannot go on in the background: what was said until then is transcribed, as if stopped.
            if !active && model.voice.state == .recording { model.voice.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in
            Task { await model.refresh(full: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationSessionOperation)) { note in
            guard let info = note.userInfo, info["id"] as? String == sessionID, let operation = info["operation"] as? String else { return }
            model.mutate(operation, (info["extra"] as? JSON) ?? [:])
        }
    }

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        TranscriptColumn(model: model, blocks: model.blocks, session: model.session, expanded: model.expanded,
                                         decisions: model.decisions, triageNote: model.triageNote, loaded: model.loaded,
                                         error: model.error, writeError: model.writeError, busy: model.busy, loading: model.loading,
                                         uncertain: model.uncertain, canMessage: model.canMessage)
                            .equatable()
                            .textSelectionScope(model.selection)
                        Color.clear.frame(height: 1).id("end")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TranscriptEndKey.self, value: g.frame(in: .named("transcript")).maxY)
                            })
                    }
                    .background(UserScrollWatcher { scrolling?.cancel(); scrolling = nil; userScrolled = true })
                    .padding(.top, 18).padding(.bottom, 30)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "transcript")
                .onPreferenceChange(TranscriptEndKey.self) { maxY in
                    let bottom = maxY <= outer.size.height + 4
                    if atBottom != bottom { atBottom = bottom }
                    // Content growing under the end is not the user leaving it: only their own scroll unsticks it.
                    if bottom { if !stick { stick = true }; userScrolled = false }
                    else if scrolling == nil && userScrolled && stick { stick = false }
                }
                .overlay(alignment: .bottom) {
                    // The "latest" button: back to the end, which the transcript then keeps to.
                    if !atBottom && !model.blocks.isEmpty {
                        Button {
                            stick = true
                            scrollToEnd(proxy, animated: true)
                        } label: { Image(systemName: Glyph.symbol(0xE74B)) }
                            .buttonStyle(IconButtonStyle())
                            .help("Latest")
                            .padding(.bottom, 10)
                    }
                }
                .onChange(of: contentMark) { _, _ in if stick { scrollToEnd(proxy) } }
                .onChange(of: model.scrollToEnd) { _, _ in stick = true; scrollToEnd(proxy) }
                .onChange(of: model.findTick) { _, _ in revealFind(proxy) }
                // The bar takes height from the transcript: one kept at its end stays there.
                .onChange(of: model.finding) { _, _ in if stick { scrollToEnd(proxy) } }
                .onAppear { scrollToEnd(proxy) }
            }
        }
    }

    /// Brings find's current match into view: its block first, which the lazy column may not have made yet, then the match
    /// itself once its text is there.
    private func revealFind(_ proxy: ScrollViewProxy) {
        guard model.find.currentMatch != nil else { return }
        scrolling?.cancel()
        stick = false
        scrolling = Task { @MainActor in
            defer { scrolling = nil }
            for _ in 0..<80 {
                await Task.yield()
                if Task.isCancelled || model.selection.revealStep(window: NSApp.keyWindow) { return }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    /// The lazy column guesses the height of messages it has not made yet, so the first scroll can stop short of the end;
    /// it scrolls again until the end is in view. A new one replaces the one under way; the first try eases there when
    /// animated.
    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = false) {
        scrolling?.cancel()
        scrolling = Task { @MainActor in
            for attempt in 0..<6 {
                await Task.yield()
                if Task.isCancelled { return }
                if animated && attempt == 0 {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                } else {
                    proxy.scrollTo("end", anchor: .bottom)
                }
                try? await Task.sleep(nanoseconds: animated && attempt == 0 ? 250_000_000 : 80_000_000)
                if Task.isCancelled { return }
                if atBottom { break }
            }
            scrolling = nil
        }
    }
}

/// Calls back when the user scrolls the scroll view it sits in: the wheel or trackpad over it, or a drag of its scroller.
/// A scroll elsewhere in the app, or one made by the code, does not count.
private struct UserScrollWatcher: NSViewRepresentable {
    var onScroll: () -> Void
    func makeNSView(context: Context) -> WatchView { let v = WatchView(); v.onScroll = onScroll; return v }
    func updateNSView(_ v: WatchView, context: Context) { v.onScroll = onScroll }

    final class WatchView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?
        private var live: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            if let l = live { NotificationCenter.default.removeObserver(l); live = nil }
            guard window != nil, let scroll = enclosingScrollView else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak scroll] event in
                MainActor.assumeIsolated {
                    guard let self, let scroll, event.window === self.window,
                          scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return }
                    self.onScroll?()
                }
                return event
            }
            live = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onScroll?() }
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct TranscriptEndKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Footer

/// `#composer-wrap`: the chips, the box with the files, the text and the buttons, and the note under it; or, on a closed
/// or read-only conversation, a box that says so with ⟳ Reopen.
private struct ConversationFooter: View {
    @ObservedObject var model: ConversationModel
    @ObservedObject var composer: ComposerState
    @ObservedObject var files: Attachments
    @ObservedObject var voice: VoiceNote
    @ObservedObject private var store = Store.shared

    private func chipShown(_ chip: ComposerChip) -> Bool {
        if chip == .loop { return store.supports("review_loop") && model.session.canReviewLoop }
        return !conversationChipText(model.session, chip).isEmpty
    }

    var body: some View {
        let s = model.session
        let can = model.can
        FooterColumn {
            VStack(alignment: .leading, spacing: 0) {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(ComposerChip.allCases.filter(chipShown), id: \.self) { chip in
                        let live = chip == .loop
                        ComposerChipView(label: conversationChipText(s, chip), on: live && s.reviewLoopOn, live: live && can,
                                         action: live && can ? { model.toggleLoop() } : nil)
                    }
                }
                .padding(.top, 8).padding(.bottom, 8)
                if model.canMessage { box } else { closedBox }
            }
        }
        .background(Theme.canvas)
    }

    private var box: some View {
        let s = model.session
        let can = model.can
        let empty = composer.trimmedEmpty
        let uploading = files.uploading
        let active = s.isActive
        let stop = active && store.supports("cancel") && empty
        return VStack(spacing: 0) {
            ComposerBox(files: files, text: $composer.text, lines: $composer.lines, focused: $composer.focused, placeholder: (model.session.provider ?? "").lowercased().contains("claude") ? "Reply\u{2026}  (/btw asks a side question the agent never sees)" : "Reply\u{2026}",
                        focus: composer.focus,
                        onSubmit: { model.send() },
                        onPaste: { files.paste($0) },
                        onDrop: { files.drop($0) },
                        onTap: { composer.focusNow() }) {
                if files.supported {
                    AttachButton(enabled: files.count < attachmentsMax) { files.pick() }
                }
                if SavedPrompts.offered {
                    PromptsButton(repo: model.session.repo, text: composer.text) { body in
                        composer.text = composer.text.cTrimmed.isEmpty ? body : composer.text + "\n\n" + body
                        composer.focusNow()
                    }
                }
                if store.canTranscribe {
                    MicButton(voice: voice)
                    if voice.state == .recording || voice.state == .transcribing {
                        ComposerSquareButton(glyph: "\u{2715}", tip: "Discard the voice note") { voice.drop() }
                        VoiceClock(voice: voice)
                    }
                }
            } trailing: {
                if stop {
                    ComposerSquareButton(glyph: "\u{25A0}", color: Theme.ink, tip: "Stop") { if can { model.confirmAndMutate("cancel") } }
                } else {
                    SendButton(filled: (can && !empty && !uploading) || model.busy) { model.send() }
                }
            }
            Text(conversationComposerNote(active: active, liveInput: s.liveInput, uploading: uploading, files: files.count, empty: empty))
                .font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity).frame(height: 16)
                .padding(.top, 6).padding(.bottom, 14)
        }
    }

    private var closedBox: some View {
        let reopen = store.supports("reopen") && model.session.status == "closed"
        let can = model.can
        return HStack(spacing: 12) {
            Text(store.canManage ? "This session is closed." : "Read-only access")
                .font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if reopen {
                Button { if can { model.confirmAndMutate("reopen") } } label: { Text("\u{27F3} Reopen") }
                    .dashButton(.bordered)
                    .disabled(!can)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.bottom, 36)
    }
}

// MARK: - Recovery

/// A session that stopped mid-work (the server restarted, or it failed): what it left in its workspace, read on request,
/// and Resume from that, which picks the conversation up where it was with its commits and files.
private struct RecoveryBox: View {
    var sessionID: String
    var resumed: () -> Void
    @State private var report: RecoveryReport?
    @State private var reading = false
    @State private var resuming = false
    @State private var error: String?
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("This session stopped before finishing.").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                Spacer()
                Button(reading ? "Checking…" : report == nil ? "Check what it left" : "Check again") { Task { await read() } }
                    .dashButton(.bordered).disabled(reading || resuming)
                if let r = report, r.canResume, store.supports("resume_session") {
                    Button(resuming ? "Resuming…" : "Resume") { Task { await resume(r) } }.dashButton(.prominent).disabled(reading || resuming)
                }
            }
            if let e = error { Notice(message: e) }
            if let r = report {
                Text(r.reason).font(Theme.footnote).foregroundStyle(r.canResume ? Theme.muted : Theme.danger).fixedSize(horizontal: false, vertical: true)
                if r.available {
                    let branch = r.branch ?? "no branch"
                    let expected = r.expectedBranch.map { $0 == r.branch ? "" : " (expected \($0))" } ?? ""
                    Text("Branch \(branch)\(expected)\(r.shortHead.map { " at \($0)" } ?? "") · \(r.changeCount == 0 ? "no uncommitted changes" : "\(r.changeCount) file\(r.changeCount == 1 ? "" : "s") changed")")
                        .font(Theme.caption).foregroundStyle(Theme.muted)
                    if !r.changes.isEmpty {
                        ScrollView {
                            Text(r.changes).font(Theme.monoSmall).foregroundStyle(Theme.ink).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accentDim, lineWidth: 1))
        .padding(.horizontal, 24).padding(.bottom, 6)
        .frame(maxWidth: 860)
    }

    private func read() async {
        reading = true; error = nil
        let r = await boardCall("session_recovery", ["sessionId": .string(sessionID)])
        reading = false
        switch r {
        case .success(let v): report = RecoveryReport(v); if report == nil { error = "The server sent an unexpected report." }
        case .failure(let e): if e.kind != .cancelled { error = e.description }
        }
    }
    /// Resumes from the report just read: the server refuses it when the workspace changed since.
    private func resume(_ r: RecoveryReport) async {
        resuming = true; error = nil
        let result = await boardCall("resume_session", ["sessionId": .string(sessionID), "fingerprint": .string(r.fingerprint)])
        resuming = false
        switch result {
        case .success:
            report = nil
            post(.sessionsChanged, [:])
            resumed()
        case .failure(let e):
            if e.kind != .cancelled { error = e.status == 409 ? "The workspace changed since it was checked: check again before resuming." : e.description }
        }
    }
}
/// The find bar under the header (the Windows client's pane find bar): the query, where the current match is of how
/// many, Previous and Next (⇧⌘G and ⌘G, or ⇧Enter and Enter in the field) and Close (Esc in the field).
private struct FindBar: View {
    @ObservedObject var model: ConversationModel
    @FocusState private var focused: Bool

    var body: some View {
        let none = model.find.matches.isEmpty
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.muted)
                TextField("Find in conversation", text: $model.findQuery)
                    .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit {
                        model.findStep(backward: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
                        focused = true
                    }
                    .onExitCommand { model.closeFind() }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accentDim : Theme.line, lineWidth: 1))
            .frame(maxWidth: 420)
            Text(model.find.status).font(Theme.footnote).monospacedDigit()
                .foregroundStyle(none && !model.findQuery.isEmpty ? Theme.danger : Theme.muted)
                .frame(minWidth: 72)
            Button("Previous") { model.findStep(backward: true) }
                .dashButton(.bordered).disabled(none).keyboardShortcut("g", modifiers: [.command, .shift]).help("Previous match (⇧⌘G)")
            Button("Next") { model.findStep(backward: false) }
                .dashButton(.bordered).disabled(none).keyboardShortcut("g", modifiers: .command).help("Next match (⌘G)")
            Spacer(minLength: 0)
            Button("Close") { model.closeFind() }.dashButton(.bordered).help("Close (Esc)")
        }
        .padding(.horizontal, 18).frame(height: 40)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onAppear { focus() }
        .onChange(of: model.findFocus) { _, _ in focus() }
    }

    /// ⌘F with the bar open takes the field again, its query selected, so typing replaces it. A bar just shown is not in
    /// the window yet, and the composer keeps the keys until the field can take them: it asks again until it has them,
    /// and selects only its own text.
    private func focus(_ tries: Int = 8) {
        focused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            if focused, NSApp.keyWindow?.firstResponder is NSText, !(NSApp.keyWindow?.firstResponder is ComposerNSTextView) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            } else if tries > 0 {
                focus(tries - 1)
            }
        }
    }
}


