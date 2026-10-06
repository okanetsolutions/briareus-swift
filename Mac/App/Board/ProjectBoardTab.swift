// A project's Board tab, after Issues (project_board.c): the GitHub Projects board named in the project's settings,
// filtered and grouped the way its view is on GitHub (`project_board`). Columns run side by side, each with its count and
// its number fields totalled (Story Points). The columns reach the view's bottom and each scrolls on its own; a wide board
// scrolls sideways with the bar at the bottom. An assignee picker narrows the cards, as GitHub's filter bar does. Only
// this project's cards are shown, so a board shared by several repositories reads as this one's. A card opens its issue
// or pull request on the app's own screens; the Windows client's side panel over the board is the detail pane's stack
// here, ‹ coming back to the board. An issue card lists the pull requests that close it, from the board's `pulls` read;
// this project's open the same way, others on GitHub. A card dragged to another column moves there at once and on GitHub
// through `project_board_move`, as dragging it on GitHub's board does; a refusal puts the board back as GitHub has it.
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProjectBoardModel: ObservableObject {
    let repo: String
    /// The board shown, the saved one or the server's; nil until there is one.
    @Published private(set) var board: ProjectBoard?
    /// The server answered since the tab was first opened.
    @Published private(set) var loaded = false
    /// The request's own failure; GitHub's refusal is `board.error`.
    @Published private(set) var error: String?
    /// The picked assignee (a login or `projectNoAssignee`); nil for everyone.
    @Published private(set) var assignee: String?
    /// Why the last move failed.
    @Published private(set) var moveError: String?
    @Published private(set) var moving = false
    @Published private(set) var reading = false
    /// The column a carried card is over, lit while it would land there, and the column it was picked up from.
    @Published var dropColumn: Int?
    var carriedFrom: Int?
    /// The card the last move carried and where it was, until a board read shows it as GitHub has it.
    private var moved: (id: String, from: Int, at: Int)?
    private var readGen = 0

    init(repo: String) {
        self.repo = repo
        filterRestore()
    }

    /// Whether the project names a board and the server can read it.
    static func offered(_ repo: String) -> Bool {
        projectHasBoard(ProjectsModel.shared.raw, repo: repo) && Store.shared.supports("project_board")
    }

    private var cacheKey: String { "project-board:\(repo)" }

    // MARK: Filter, kept on disk per repository as the other tabs' pickers are

    private var filterKey: String { "project-board-filter:\(repo)" }
    private func filterSave() {
        var saved: JSON = [:]
        if let assignee, !assignee.isEmpty { saved["assignee"] = .string(assignee) }
        Store.shared.cache.store(saved, filterKey)
    }
    private func filterRestore() { assignee = Store.shared.cache.value(filterKey)?["assignee"].nonEmpty }
    func setAssignee(_ value: String?) {
        assignee = (value ?? "").isEmpty ? nil : value
        filterSave()
    }
    /// The picker's menu: everyone, then each assignee with how many cards they have.
    func pickAssignee() {
        guard let board else { return }
        let options = board.assignees(pick: assignee)
        var items = [BoardPopupMenu.Item(title: "All assignees", checked: assignee == nil)]
        for o in options { items.append(BoardPopupMenu.Item(title: "\(o.text) (\(o.count))", checked: assignee.map { foldEqual($0, o.value) } ?? false)) }
        guard let chosen = BoardPopupMenu.show(items, rightAligned: true) else { return }
        setAssignee(chosen == 0 ? nil : options[chosen - 1].value)
    }
    var pickLabel: String { assignee == nil ? "All assignees" : assignee == projectNoAssignee ? "No assignee" : assignee! }

    // MARK: Reading

    private func show(_ answer: JSON) {
        guard var b = ProjectBoard(answer) else { return }
        b.keepRepo(repo)
        board = b
    }
    /// Reads the board the first time the tab is shown, the saved copy first. While a card is moving, the read after the
    /// move is the first.
    func open() { if !loaded && !reading && !moving { Task { await load(fresh: false) } } }
    /// Reads it past the server's cache.
    func refresh() { moveError = nil; Task { await load(fresh: true) } }

    func load(fresh: Bool) async {
        guard Self.offered(repo) else { return }
        if board == nil, let saved = Store.shared.cache.value(cacheKey) { show(saved) }
        readGen += 1
        let gen = readGen
        reading = true
        var args: JSON = ["repo": .string(repo)]
        if fresh { args["fresh"] = "1" }
        let r = await boardCall("project_board", args)
        guard gen == readGen else { return }
        reading = false
        loaded = true
        switch r {
        case .success(let v):
            if !moving { moved = nil }
            error = nil
            // A card carried meanwhile is named by its id, so the new board landing under it moves the right one.
            show(v)
            // A refusal is not saved: the board last read stays the one shown the next time.
            if board != nil && board?.error == nil { Store.shared.cache.store(v, cacheKey) }
        case .failure(let e):
            if e.kind == .cancelled { return }
            // A move GitHub refused and no board to show instead: the card goes back by hand.
            if !moving { undoMove() }
            error = e.description
        }
    }

    // MARK: Moving cards

    /// Whether the card can be dragged to another column: the server moves cards, none is on its way already, and no
    /// failed move waits for the read that puts its card back (a second move would cancel that read).
    func movable(_ card: ProjectBoardCard) -> Bool {
        !moving && moved == nil && !(card.id ?? "").isEmpty && card.type != "redacted" && Store.shared.supports("project_board_move")
    }
    /// The card shows in its new column at once, at its end; the board read after the server answers puts it in its place.
    func move(cardID: String, to: Int) {
        guard var b = board, b.columns.indices.contains(to) else { return }
        guard let from = b.columns.firstIndex(where: { $0.cards.contains { $0.id == cardID } }), from != to,
              let at = b.columns[from].cards.firstIndex(where: { $0.id == cardID }), movable(b.columns[from].cards[at]) else { return }
        let args: JSON = ["repo": .string(repo), "itemId": .string(cardID), "columnId": JSON(b.columns[to].id)]
        guard b.move(from: from, card: at, to: to) else { return }
        board = b
        moved = (cardID, from, at)
        moveError = nil
        moving = true
        // A read on its way would show the card back where it was; the one after the move replaces it.
        readGen += 1
        reading = false
        Task {
            let r = await boardCall("project_board_move", args)
            moving = false
            // Moved or not, the board is read again as GitHub has it now: the server has dropped its saved copy.
            if let e = r.error { moveError = e.description } else { moved = nil }
            await load(fresh: r.error != nil)
        }
    }
    /// Puts the card a failed move carried back where it was, when no board read has replaced the guess.
    private func undoMove() {
        defer { moved = nil }
        guard let m = moved, var b = board, b.columns.indices.contains(m.from) else { return }
        for k in b.columns.indices where k != m.from {
            guard let i = b.columns[k].cards.firstIndex(where: { $0.id == m.id }), b.move(from: k, card: i, to: m.from) else { continue }
            let card = b.columns[m.from].cards.removeLast()
            b.columns[m.from].cards.insert(card, at: min(m.at, b.columns[m.from].cards.count))
            board = b
            return
        }
    }

    // MARK: Opening

    /// A card of this repository opens its issue or pull request on the app's own screens; any other on GitHub.
    func open(_ card: ProjectBoardCard, pulls: [PullSummary]) {
        let here = card.repo.map { foldEqual($0, repo) } ?? false
        if here && card.type == "issue" && card.number > 0 && Store.shared.supports("pulls") {
            // The issue screen reads the rest from the board; the card gives it what to show until it has.
            Navigator.shared.push(.issue(repo: repo, issue: card.issueJSON))
            return
        }
        if here && card.type == "pull" && card.number > 0 && Store.shared.supports("pull") {
            Navigator.shared.push(.pull(repo: repo, number: card.number, stack: nil, summary: pullsFind(pulls, card.number)?.raw))
            return
        }
        if safeWebURL(card.url) { openWebURL(card.url) }
    }
    /// A pull request of this project opens on its screen, as its card would; any other on GitHub.
    func openPull(_ link: BoardLink, pulls: [PullSummary]) {
        if !link.isForeign(repo) && Store.shared.supports("pull") {
            Navigator.shared.push(.pull(repo: repo, number: link.number, stack: nil, summary: pullsFind(pulls, link.number)?.raw))
        } else if safeWebURL(link.url) { openWebURL(link.url) }
    }
    func openOnGitHub() { if let url = board?.webURL, safeWebURL(url) { openWebURL(url) } }
}

// MARK: - Header

/// The pane's header on the Board tab: the board and view in the line under the title with how many cards it shows, the
/// assignee picker, ↗ to open the view on GitHub and ⟳.
struct ProjectBoardHeader: View {
    @ObservedObject var model: ProjectBoardModel
    var title: String

    var body: some View {
        var sub = model.repo
        if let b = model.board, b.title != nil || b.viewName != nil {
            let items = b.items(model.assignee)
            sub = [b.title ?? "Project", b.viewName].compactMap { $0 }.joined(separator: " · ") + " · \(items) item\(items == 1 ? "" : "s")"
        }
        var buttons: [HeaderButton] = []
        if let b = model.board, !b.columns.isEmpty {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE716), label: "\(model.pickLabel) ▾", tip: "Show the cards of one assignee") { model.pickAssignee() })
        }
        if safeWebURL(model.board?.webURL) {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE8A7), tip: "Open the board on GitHub") { model.openOnGitHub() })
        }
        buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the board from GitHub again", enabled: !model.reading && !model.moving) { model.refresh() })
        return PaneHeader(title: title, subtitle: sub, buttons: buttons)
    }
}

// MARK: - The tab

/// The tab under the project's tabs, down to the pane's bottom. `issues` and `pulls` are the board's `pulls` read, which
/// names the pull requests closing each issue card.
struct ProjectBoardTab: View {
    @ObservedObject var model: ProjectBoardModel
    var issues: [IssueSummary]
    var pulls: [PullSummary]

    private static let columnWidth: CGFloat = 300, columnMaxWidth: CGFloat = 380, gap: CGFloat = 12, minHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.error { Notice(message: e).padding(.bottom, 10) }
            if let e = model.moveError { Notice(message: e).padding(.bottom, 10) }
            if let b = model.board {
                notes(b)
                if b.columns.isEmpty {
                    if b.error == nil { EmptyNote(title: "Nothing on the board", detail: "No item on this board matches its view's filter.") }
                    Spacer(minLength: 0)
                } else {
                    columns(b)
                }
            } else {
                if model.error == nil { LoadingNote(text: "Loading the board…").padding(.horizontal, -8) }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.open() }
    }

    /// What stands above the columns: GitHub's refusal, the view's filter, a cut-off board, and the assignee's share.
    @ViewBuilder private func notes(_ b: ProjectBoard) -> some View {
        if let refused = b.error {
            NoticeBox(message: refused)
            Text("Reading a board needs Projects: read on the server's GitHub token (read:project on a classic token), and a project and view GitHub can find. The board is named in ⚙ Settings → Projects.")
                .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6).padding(.bottom, 10)
        }
        if let filter = b.filter, !filter.isEmpty {
            Text(verbatim: "Filtered by \(filter)").font(Theme.monoCaption2).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
        }
        if b.truncated {
            Text("Only the board's first 2,000 items are shown.").font(Theme.caption).foregroundStyle(Theme.warn).padding(.bottom, 8)
        }
        if model.assignee != nil && !b.columns.isEmpty {
            HStack {
                Text(verbatim: "Showing \(b.items(model.assignee)) of \(b.items(nil))").font(Theme.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button("Clear filter") { model.setAssignee(nil) }.buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.accent).handCursor()
            }
            .frame(height: 20).padding(.bottom, 8)
        }
    }

    /// The columns share the width when they fit, and keep a readable width and scroll sideways when they do not. They reach
    /// down to the pane's bottom, above the sideways bar, so the board itself stays put.
    private func columns(_ b: ProjectBoard) -> some View {
        GeometryReader { geo in
            let n = CGFloat(b.columns.count)
            let fit = ((geo.size.width - Self.gap * (n - 1)) / n).rounded(.down)
            let width = fit > Self.columnWidth ? min(fit, Self.columnMaxWidth) : Self.columnWidth
            let height = max(geo.size.height - 16, Self.minHeight)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(Array(b.columns.enumerated()), id: \.offset) { i, column in
                        BoardColumnView(model: model, column: column, index: i, repo: model.repo, issues: issues, pulls: pulls)
                            .frame(width: width, height: height)
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }
}

/// A column: its heading stays put and its cards scroll beneath it on their own. A card carried over it from another
/// column lights it up and lands there on drop.
private struct BoardColumnView: View {
    @ObservedObject var model: ProjectBoardModel
    var column: ProjectBoardColumn
    var index: Int
    var repo: String
    var issues: [IssueSummary]
    var pulls: [PullSummary]

    var body: some View {
        // Filtered, the count and the totals are the shown cards', as GitHub's are.
        let m = model.assignee == nil ? (count: column.count, sums: column.sums.map(\.value)) : column.matching(model.assignee)
        let lit = model.dropColumn == index && model.carriedFrom != index
        VStack(alignment: .leading, spacing: 0) {
            heading(count: m.count)
            // Each number field totalled, "Story Points: 21", as GitHub's column footer words it.
            if !column.sums.isEmpty {
                Text(verbatim: zip(column.sums, m.sums).map { "\($0.name): \(projectSumText($1))" }.joined(separator: " · "))
                    .font(Theme.caption2).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.top, 2)
            }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let shown = column.cards.filter { $0.assigned(model.assignee) }
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, card in cardView(card) }
                    if shown.isEmpty { Text("No items").font(Theme.caption).foregroundStyle(Theme.tertiary) }
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
            }
            .padding(.top, 0)
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(lit ? Theme.accent.opacity(0.08) : Theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(lit ? Theme.accent : Theme.line, lineWidth: 1))
        .onDrop(of: [.plainText], isTargeted: Binding(get: { model.dropColumn == index }, set: { on in
            if on { model.dropColumn = index } else if model.dropColumn == index { model.dropColumn = nil }
        })) { providers in drop(providers) }
    }

    /// Its option's colour as a ring, its name and how many cards it holds.
    private func heading(count: Int) -> some View {
        HStack(spacing: 8) {
            Circle().strokeBorder(optionColor(column.color), lineWidth: 2).frame(width: 12, height: 12)
            Text(column.name).font(Theme.subheadlineSemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            Text(verbatim: "\(count)").font(Theme.captionSemibold).foregroundStyle(Theme.muted)
                .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(Theme.raise))
            Spacer(minLength: 0)
        }
        .frame(height: 24).padding(.horizontal, 10)
    }

    @ViewBuilder private func cardView(_ card: ProjectBoardCard) -> some View {
        let view = BoardCardView(card: card, repo: repo, pulls: projectCardPulls(card, repo: repo, issues: issues, pulls: pulls),
                                 opens: card.number > 0 && (card.repo != nil || safeWebURL(card.url)),
                                 open: { model.open(card, pulls: pulls) }, openPull: { model.openPull($0, pulls: pulls) })
        if model.movable(card), let id = card.id {
            view.onDrag {
                model.carriedFrom = index
                return NSItemProvider(object: (Self.dragPrefix + id) as NSString)
            }
        } else {
            view
        }
    }

    /// What a carried card says it is: its item id, marked so text dropped from elsewhere moves nothing.
    static let dragPrefix = "briareus-board-card:"
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        model.dropColumn = nil
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        let to = index
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, text.hasPrefix(Self.dragPrefix) else { return }
            let id = String(text.dropFirst(Self.dragPrefix.count))
            Task { @MainActor in model.move(cardID: id, to: to) }
        }
        return true
    }
}

/// A card as GitHub's board draws one: where it lives, its title, its fields, labels and epic, the pull requests closing
/// it, and who has it and when it was opened.
private struct BoardCardView: View {
    var card: ProjectBoardCard
    var repo: String
    var pulls: [BoardLink]
    var opens: Bool
    var open: () -> Void
    var openPull: (BoardLink) -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Group {
                    if card.type == "draft" { Circle().strokeBorder(stateColor, lineWidth: 1) } else { Circle().fill(stateColor) }
                }
                .frame(width: 8, height: 8)
                Text(reference).font(Theme.monoCaption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            }
            .frame(height: 15)
            Text(card.title ?? "Untitled").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            // The fields as GitHub's cards show them: single-selects as chips in their option's colour, the rest named.
            if !card.fields.isEmpty {
                Badges(specs: card.fields.map { f in
                    BadgeSpec(text: f.color != nil ? f.value : "\(f.name): \(f.value)", color: optionColor(f.color), chip: f.color != nil)
                }).padding(.top, 6)
            }
            if !card.labels.isEmpty { LabelChips(labels: card.labels).padding(.top, 6) }
            if let parent = card.parent { LinkedRow(link: parent, repo: repo).padding(.top, 4) }
            ForEach(Array(pulls.enumerated()), id: \.offset) { _, link in
                let here = !link.isForeign(repo) && Store.shared.supports("pull")
                LinkedRow(link: link, repo: repo, action: here || safeWebURL(link.url) ? { openPull(link) } : nil).padding(.top, 4)
            }
            if !meta.isEmpty {
                Text(meta).font(Theme.caption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail).padding(.top, 6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovered && opens ? Theme.field.opacity(0.5) : Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { if opens { open() } }
        .onHover { hovered = $0 }
    }

    /// "hq-core #123": the repository's name and the number; a draft and a private item say so.
    private var reference: String {
        if card.type == "draft" { return "Draft" }
        if card.type == "redacted" { return "Private item" }
        let name = card.repo.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        if let name, card.number > 0 { return "\(name) #\(card.number)" }
        return card.number > 0 ? "#\(card.number)" : ""
    }
    /// GitHub's own colours for an issue's or pull request's state: green open, purple done, grey not planned or a draft.
    private var stateColor: Color {
        if card.type == "draft" || card.type == "redacted" { return Theme.muted }
        if card.state == "merged" || (card.state == "closed" && card.type == "issue") { return Color(.sRGB, red: 0x89 / 255, green: 0x57 / 255, blue: 0xE5 / 255) }
        if card.state == "closed" { return Theme.danger }
        return Color(.sRGB, red: 0x1A / 255, green: 0x7F / 255, blue: 0x37 / 255)
    }
    /// Who has it and when it was opened.
    private var meta: String {
        var parts: [String] = []
        if !card.assignees.isEmpty { parts.append(people(card.assignees, limit: 3)) }
        if let at = card.createdAt { parts.append("opened \(formatDateAbbrev(at))") }
        return parts.joined(separator: " · ")
    }
}

/// A single-select option's colour, GitHub's named one, or the secondary colour.
private func optionColor(_ name: String?) -> Color {
    guard let c = projectColorRGB(name) else { return Theme.muted }
    return Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
}
