// The board's Board tab on a phone (the Mac's ProjectBoardTab): the GitHub Projects board named in the project's settings,
// filtered and grouped the way its view is on GitHub (`project_board`). The columns are a strip of chips, each with its
// count, over the cards of the one picked, its number fields totalled (Story Points) above them. The toolbar's menu
// narrows the cards to one assignee. Only this project's cards are shown, so a board shared by several repositories reads
// as this one's. A card opens its issue or pull request on the app's own screens, and its menu (held, or swiped) moves
// it to another column through `project_board_move`, as dragging it on GitHub's board does: it shows there at once, and
// a refusal says why and puts the board back as GitHub has it.
import SwiftUI

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
    /// The column whose cards are shown.
    @Published var column = 0
    /// Why the last move failed, under the column strip until the next refresh, and in an alert when it comes back.
    @Published private(set) var moveError: String?
    @Published var moveAlert: String?
    @Published private(set) var moving = false
    /// The card the last move carried and where it was, until a board read shows it as GitHub has it.
    private var moved: (id: String, from: Int, at: Int)?
    private var readGen = 0

    init(repo: String) {
        self.repo = repo
        assignee = Store.shared.cache.value(filterKey)?["assignee"].nonEmpty
        if let saved = Store.shared.cache.value(cacheKey) { show(saved) }
    }

    /// Whether the project names a board and the server can read it.
    static func offered(_ repo: String) -> Bool {
        projectHasBoard(ProjectsModel.shared.raw, repo: repo) && Store.shared.supports("project_board")
    }

    private var cacheKey: String { "project-board:\(repo)" }

    // MARK: Filter, kept on disk per repository as the board's pickers are

    private var filterKey: String { "project-board-filter:\(repo)" }
    func setAssignee(_ value: String?) {
        assignee = (value ?? "").isEmpty ? nil : value
        var saved: JSON = [:]
        if let assignee { saved["assignee"] = .string(assignee) }
        Store.shared.cache.store(saved, filterKey)
    }
    var pickLabel: String { assignee == nil ? "All assignees" : assignee == projectNoAssignee ? "No assignee" : assignee! }

    // MARK: Reading

    private func show(_ answer: JSON) {
        guard var b = ProjectBoard(answer) else { return }
        b.keepRepo(repo)
        board = b
        if column >= b.columns.count { column = max(b.columns.count - 1, 0) }
    }

    /// Reads the board, the saved copy shown meanwhile; `fresh` reads it past the server's cache. While a card is moving,
    /// the read after the move is the next one.
    func load(fresh: Bool = false) async throws {
        guard Self.offered(repo), !moving else { return }
        readGen += 1
        let gen = readGen
        var args: JSON = ["repo": .string(repo)]
        if fresh { args["fresh"] = "1" }
        do {
            let v = try await Store.shared.call("project_board", args)
            guard gen == readGen else { return }
            loaded = true
            if !moving { moved = nil }
            error = nil
            // A card carried meanwhile is named by its id, so the new board landing under it moves the right one.
            show(v)
            // A refusal is not saved: the board last read stays the one shown the next time.
            if board != nil && board?.error == nil { Store.shared.cache.store(v, cacheKey) }
        } catch {
            guard gen == readGen else { throw error }
            guard let said = failure(error) else { throw error }
            loaded = true
            // A move GitHub refused and no board to show instead: the card goes back by hand.
            if !moving { undoMove() }
            self.error = said
            throw error
        }
    }
    /// Pulling down reads it past the server's cache, and drops the last move's reason.
    func refresh() async {
        moveError = nil
        _ = await reading { try await load(fresh: true) }
    }

    // MARK: Moving cards

    /// Whether the card can go to another column: this token may move cards, none is on its way already, and no failed
    /// move waits for the read that puts its card back.
    func movable(_ card: ProjectBoardCard) -> Bool {
        !moving && moved == nil && !(card.id ?? "").isEmpty && card.type != "redacted" && Store.shared.supports("project_board_move")
    }
    /// The card shows at the end of its new column at once; the board read after the server answers puts it in its place.
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
        Task {
            var refused = false
            do {
                try await Store.shared.call("project_board_move", args)
                moved = nil
            } catch {
                refused = true
                if let said = failure(error) { moveError = said; moveAlert = said }
            }
            moving = false
            // Moved or not, the board is read again as GitHub has it now: the server has dropped its saved copy.
            _ = await reading { try await load(fresh: refused) }
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

    /// Where a card of this repository opens on the app's own screens; nil for one that opens on GitHub, or nowhere.
    func destination(_ card: ProjectBoardCard, pulls: [PullSummary]) -> Destination? {
        guard card.repo.map({ foldEqual($0, repo) }) ?? false, card.number > 0 else { return nil }
        // The issue screen reads the rest from the board; the card gives it what to show until it has.
        if card.type == "issue" && Store.shared.supports("pulls") { return .issue(repo: repo, issue: card.issueJSON) }
        if card.type == "pull" && Store.shared.supports("pull") {
            return .pull(repo: repo, number: card.number, stack: nil, summary: pullsFind(pulls, card.number)?.raw)
        }
        return nil
    }
    /// Where a pull request closing a card opens: this project's on its screen, any other nowhere here.
    func destination(_ link: BoardLink, pulls: [PullSummary]) -> Destination? {
        guard !link.isForeign(repo), Store.shared.supports("pull") else { return nil }
        return .pull(repo: repo, number: link.number, stack: nil, summary: pullsFind(pulls, link.number)?.raw)
    }
}

// MARK: - The tab

/// The Board tab's rows in the board screen's list. `issues` and `pulls` are the board's `pulls` read, which names the
/// pull requests closing each issue card.
struct ProjectBoardSection: View {
    @ObservedObject var model: ProjectBoardModel
    var issues: [IssueSummary]
    var pulls: [PullSummary]
    @Environment(\.navigate) private var navigate
    @State private var moving: ProjectBoardCard?

    var body: some View {
        if let e = model.error { Section { ErrorNotice(message: e) }.listRowBackground(Theme.row) }
        if let e = model.moveError { Section { ErrorNotice(message: e) }.listRowBackground(Theme.row) }
        if let b = model.board {
            notes(b)
            if b.columns.isEmpty {
                if b.error == nil {
                    ContentUnavailableView("Nothing on the board", systemImage: "rectangle.split.3x1",
                                           description: Text("No item on this board matches its view's filter."))
                        .listRowBackground(Color.clear)
                }
            } else {
                columnStrip(b).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                cards(b)
            }
        } else if model.error == nil {
            ProgressView("Loading the board…").frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear)
        }
    }

    /// What stands above the columns: GitHub's refusal, the view and its filter, a cut-off board, and the assignee's share.
    @ViewBuilder private func notes(_ b: ProjectBoard) -> some View {
        if let refused = b.error {
            Section {
                ErrorNotice(message: refused)
                Text("Reading a board needs Projects: read on the server's GitHub token (read:project on a classic token), and a project and view GitHub can find. The board is named in Settings, on the project's form.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .listRowBackground(Theme.row)
        }
        let filter = b.filter.flatMap { $0.isEmpty ? nil : $0 }
        if b.title != nil || b.viewName != nil || filter != nil || b.truncated {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    let items = b.items(model.assignee)
                    Text([b.title ?? "Project", b.viewName].compactMap { $0 }.joined(separator: " · ") + " · \(items) item\(items == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium))
                    if let filter { Text(verbatim: "Filtered by \(filter)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if b.truncated { Text("Only the board's first 2,000 items are shown.").font(.caption).foregroundStyle(Theme.warning) }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
        if model.assignee != nil && !b.columns.isEmpty {
            HStack {
                Text("Showing \(b.items(model.assignee)) of \(b.items(nil)) · \(model.pickLabel)").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Clear filter") { model.setAssignee(nil) }.font(.footnote).buttonStyle(.borderless)
            }
            .listRowBackground(Color.clear)
        }
    }

    /// Each column's count and totals, the cards the filter shows: GitHub's own are filtered the same way.
    private func shown(_ column: ProjectBoardColumn) -> (count: Int, sums: [Double]) {
        model.assignee == nil ? (column.count, column.sums.map(\.value)) : column.matching(model.assignee)
    }

    /// The columns as chips that scroll sideways, each with its option's colour and its count, the picked one filled.
    private func columnStrip(_ b: ProjectBoard) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(b.columns.enumerated()), id: \.offset) { i, column in
                        let on = model.column == i
                        Button { withAnimation(.snappy) { model.column = i } } label: {
                            HStack(spacing: 6) {
                                Circle().strokeBorder(projectOptionColor(column.color), lineWidth: 2).frame(width: 10, height: 10)
                                Text(column.name).font(.subheadline.weight(on ? .semibold : .regular)).lineLimit(1)
                                Text("\(shown(column).count)").font(.caption.monospacedDigit()).foregroundStyle(on ? .white.opacity(0.85) : .secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(on ? .white : .primary)
                            .background(on ? Theme.accent : Theme.elevated, in: Capsule())
                            .overlay(Capsule().stroke(on ? Color.clear : Theme.border, lineWidth: 0.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                        .accessibilityLabel("\(column.name), \(shown(column).count) item\(shown(column).count == 1 ? "" : "s")")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear { proxy.scrollTo(model.column, anchor: .center) }
            .onChange(of: model.column) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
        }
    }

    /// The picked column's cards, its number fields totalled in the header, as GitHub's column footer words them.
    @ViewBuilder private func cards(_ b: ProjectBoard) -> some View {
        let i = min(model.column, b.columns.count - 1)
        let column = b.columns[i]
        let m = shown(column)
        let list = column.cards.filter { $0.assigned(model.assignee) }
        Section {
            ForEach(Array(list.enumerated()), id: \.offset) { _, card in cardRow(card, b: b, from: i) }
            if list.isEmpty { Text("No items").foregroundStyle(.secondary) }
        } header: {
            if !column.sums.isEmpty {
                Text(verbatim: zip(column.sums, m.sums).map { "\($0.name): \(projectSumText($1))" }.joined(separator: " · "))
            }
        } footer: {
            if list.contains(where: model.movable) { Text("Hold a card, or swipe it, to move it to another column.") }
        }
        .listRowBackground(Theme.row)
        .confirmationDialog(moving.map { "Move \(cardName($0)) to…" } ?? "", isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
                            titleVisibility: .visible, presenting: moving) { card in
            ForEach(Array(b.columns.enumerated()), id: \.offset) { k, c in
                if k != i { Button(c.name) { if let id = card.id { model.move(cardID: id, to: k) } } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private func cardRow(_ card: ProjectBoardCard, b: ProjectBoard, from: Int) -> some View {
        let closing = projectCardPulls(card, repo: model.repo, issues: issues, pulls: pulls)
        let view = ProjectBoardCardRow(card: card, repo: model.repo, pulls: closing)
        Group {
            if let d = model.destination(card, pulls: pulls) {
                DestinationLink(destination: d) { view }
            } else if safeWebURL(card.url) {
                Button { boardOpenWeb(card.url) } label: { view }.foregroundStyle(.primary)
            } else {
                view
            }
        }
        .contextMenu {
            if model.movable(card), let id = card.id {
                Menu {
                    ForEach(Array(b.columns.enumerated()), id: \.offset) { k, c in
                        if k != from { Button(c.name) { model.move(cardID: id, to: k) } }
                    }
                } label: { Label("Move to…", systemImage: "arrow.right.square") }
            }
            ForEach(Array(closing.enumerated()), id: \.offset) { _, link in
                if let d = model.destination(link, pulls: pulls) {
                    Button { navigate(d) } label: { Label("Open pull request #\(link.number)", systemImage: "arrow.triangle.pull") }
                } else if safeWebURL(link.url) {
                    Button { boardOpenWeb(link.url) } label: { Label("Open \(link.reference(model.repo)) on GitHub", systemImage: "arrow.triangle.pull") }
                }
            }
            if safeWebURL(card.url) {
                Button { boardOpenWeb(card.url) } label: { Label("Open on GitHub", systemImage: "safari") }
                Button { Pasteboard.copy(card.url ?? "") } label: { Label("Copy link", systemImage: "link") }
            }
        }
        .swipeActions(edge: .leading) {
            if model.movable(card) {
                Button { moving = card } label: { Label("Move", systemImage: "arrow.right.square") }.tint(Theme.accent)
            }
        }
    }

    private func cardName(_ card: ProjectBoardCard) -> String {
        card.number > 0 ? "#\(card.number)" : "\u{201C}\(card.title ?? "Untitled")\u{201D}"
    }
}

/// A card as GitHub's board draws one: where it lives, its title, its fields, labels and epic, the pull requests closing
/// it, and who has it and when it was opened.
private struct ProjectBoardCardRow: View {
    let card: ProjectBoardCard
    let repo: String
    let pulls: [BoardLink]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if card.type == "draft" { Circle().strokeBorder(stateColor, lineWidth: 1.5) } else { Circle().fill(stateColor) }
            }
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(card.title ?? "Untitled").font(.body.weight(.medium)).lineLimit(3)
                if !reference.isEmpty { Text(reference).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                // The fields as GitHub's cards show them: single-selects as chips in their option's colour, the rest named.
                if !card.fields.isEmpty {
                    BoardFlowLayout(spacing: 5) {
                        ForEach(Array(card.fields.enumerated()), id: \.offset) { _, f in
                            if f.color != nil {
                                BoardBadge(text: f.value, systemImage: nil, color: projectOptionColor(f.color))
                            } else {
                                Text("\(f.name): \(f.value)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                            }
                        }
                    }
                }
                if !card.labels.isEmpty { BoardLabelChips(labels: card.labels) }
                if let parent = card.parent {
                    Label("Part of \(parent.reference(repo)) \(parent.title)", systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(Array(pulls.enumerated()), id: \.offset) { _, link in BoardLinkedRow(link: link, repo: repo) }
                if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(.vertical, 3)
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
        if card.type == "draft" || card.type == "redacted" { return .secondary }
        if card.state == "merged" || (card.state == "closed" && card.type == "issue") { return Color(.sRGB, red: 0x89 / 255, green: 0x57 / 255, blue: 0xE5 / 255) }
        if card.state == "closed" { return Theme.danger }
        return Theme.success
    }
    /// Who has it and when it was opened.
    private var meta: String {
        var parts: [String] = []
        if !card.assignees.isEmpty { parts.append(people(card.assignees, limit: 3)) }
        if let at = card.createdAt { parts.append("opened \(formatDateAbbrev(at))") }
        return parts.joined(separator: " · ")
    }
}

/// The toolbar's menu on the Board tab: everyone, or one assignee with how many cards they have; and the board on GitHub.
struct ProjectBoardMenu: View {
    @ObservedObject var model: ProjectBoardModel
    var body: some View {
        Menu {
            if let b = model.board, !b.columns.isEmpty {
                Picker(selection: Binding(get: { model.assignee ?? "" }, set: { model.setAssignee($0) })) {
                    Text("All assignees").tag("")
                    ForEach(b.assignees(pick: model.assignee), id: \.value) { o in Text("\(o.text) (\(o.count))").tag(o.value) }
                } label: {
                    Label("Assignee: \(model.pickLabel)", systemImage: "person")
                }
                .pickerStyle(.menu)
            }
            if model.assignee != nil {
                Button("Clear filter", systemImage: "xmark.circle", role: .destructive) { model.setAssignee(nil) }
            }
            if safeWebURL(model.board?.webURL) {
                Button { boardOpenWeb(model.board?.webURL) } label: { Label("Open the board on GitHub", systemImage: "safari") }
            }
        } label: {
            Image(systemName: model.assignee != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(model.assignee != nil ? "Board filter, active" : "Board filter")
    }
}

/// A single-select option's colour, GitHub's named one, or the secondary colour.
func projectOptionColor(_ name: String?) -> Color {
    guard let c = projectColorRGB(name) else { return .secondary }
    return Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
}
