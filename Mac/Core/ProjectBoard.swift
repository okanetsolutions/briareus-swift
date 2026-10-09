// The project's GitHub Projects board (board.c's Projects board): what `project_board` answers, read into the columns and
// cards the Board tab draws, the assignee filter over them, a card moved to another column, and the project setting that
// names the board. Also the Status an issue has on its boards, which the pull request rows and screen show.
import Foundation

// MARK: - The board

/// One field set on a card: a single-select (with its option's colour), text, number, date or iteration, as text.
struct ProjectBoardField: Equatable, Sendable {
    var name: String
    var value: String
    /// GitHub's name for a single-select option's colour (GRAY, BLUE, …); nil for any other field.
    var color: String?

    /// Needs a name, and a value that is a string or a number.
    init?(_ j: JSON) {
        guard let name = j["name"].nonEmpty else { return nil }
        if let s = j["value"].string { value = s }
        else if let n = j["value"].number { value = projectSumText(n) }
        else { return nil }
        self.name = name; color = j["color"].string
    }
}

/// One card of a GitHub Projects v2 board. `type` is issue, pull, draft or redacted; a draft has no repo, number or url.
struct ProjectBoardCard: Equatable, Sendable {
    /// The project item's node id, what `project_board_move` moves.
    var id: String?
    var type: String
    var repo: String?
    var number: Int
    var title: String?
    var url: String?
    var state: String?
    var author: String?
    var createdAt: Date?
    var assignees: [String]
    var labels: [PullLabel]
    /// The epic it is a sub-issue of.
    var parent: BoardLink?
    var fields: [ProjectBoardField]

    init?(_ j: JSON) {
        guard j.isObject else { return nil }
        id = j["id"].string
        type = j["type"].string ?? "issue"
        repo = j["repo"].string
        number = j["number"].truncatedInt ?? 0
        title = j["title"].string; url = j["url"].string; state = j["state"].string
        author = j["author"].string
        createdAt = boardDateParse(j["createdAt"].string)
        assignees = j["assignees"].items.compactMap { $0["login"].nonEmpty ?? $0.nonEmpty }
        labels = PullLabel.parseList(j["labels"])
        parent = BoardLink(j["parent"])
        fields = j["fields"].items.compactMap(ProjectBoardField.init)
    }

    /// The card as a board row of its issue, the way the issue screen opens with one until it has read the rest.
    var issueJSON: JSON {
        var j: JSON = ["number": JSON(number), "title": JSON(title), "url": JSON(url), "author": JSON(author),
                       "assignees": JSON(assignees),
                       "labels": .array(labels.map { ["name": .string($0.name), "color": JSON($0.color)] })]
        if let at = createdAt { j["createdAt"] = .string(ISO8601DateFormatter().string(from: at)) }
        if let p = parent {
            j["parent"] = ["number": JSON(p.number), "title": .string(p.title), "url": JSON(p.url), "repo": JSON(p.repo), "state": JSON(p.state)]
        }
        return j
    }

    /// A field by name, compared without case, or nil.
    func field(_ name: String) -> ProjectBoardField? { fields.first { foldEqual($0.name, name) } }
    /// Whether the card passes the assignee filter: an empty pick passes every card, `projectNoAssignee` the unassigned
    /// ones, and a login (in any case) the cards assigned to it.
    func assigned(_ assignee: String?) -> Bool {
        guard let assignee, !assignee.isEmpty else { return true }
        if assignee == projectNoAssignee { return assignees.isEmpty }
        return assignees.contains { foldEqual($0, assignee) }
    }
}

/// A number field totalled over a column, such as Story Points.
struct ProjectBoardSum: Equatable, Sendable {
    var name: String
    var value: Double
}

struct ProjectBoardColumn: Equatable, Sendable {
    /// The single-select option or iteration it stands for; nil for the "No <field>" column.
    var id: String?
    var name: String
    /// GitHub's name for a single-select option's colour; nil for none.
    var color: String?
    var count: Int
    var sums: [ProjectBoardSum]
    var cards: [ProjectBoardCard]

    /// Needs a name.
    init?(_ j: JSON) {
        guard let name = j["name"].string else { return nil }
        id = j["id"].string; self.name = name; color = j["color"].string
        cards = j["items"].items.compactMap(ProjectBoardCard.init)
        count = j["count"].truncatedInt ?? cards.count
        sums = j["sums"].keys.compactMap { k in j["sums"][k].number.map { ProjectBoardSum(name: k, value: $0) } }
    }

    /// How many of its cards pass the assignee filter, and each of its number fields totalled over them, in `sums` order.
    func matching(_ assignee: String?) -> (count: Int, sums: [Double]) {
        var totals = [Double](repeating: 0, count: sums.count)
        var n = 0
        for card in cards where card.assigned(assignee) {
            n += 1
            for (s, sum) in sums.enumerated() { if let f = card.field(sum.name) { totals[s] += leadingDouble(f.value) } }
        }
        return (n, totals)
    }
    /// Adds a card's number fields to the totals, or takes them away for a `sign` of -1.
    fileprivate mutating func add(_ card: ProjectBoardCard, _ sign: Double) {
        count += Int(sign)
        for s in sums.indices { if let f = card.field(sums[s].name) { sums[s].value += sign * leadingDouble(f.value) } }
    }
}

/// The assignee filter's pick for the cards nobody has; GitHub logins never start with a hyphen.
let projectNoAssignee = "-"

/// What `project_board` answers: a project's board, filtered and grouped the way its view is on GitHub.
struct ProjectBoard: Equatable, Sendable {
    var title: String?
    var url: String?
    var viewName: String?
    var viewURL: String?
    var filter: String?
    var groupBy: String?
    var columns: [ProjectBoardColumn]
    var truncated: Bool
    /// `projectsError`: why GitHub would not show the board, when it would not.
    var error: String?

    init?(_ j: JSON) {
        guard j.isObject else { return nil }
        title = j["project"]["title"].string; url = j["project"]["url"].string
        viewName = j["view"]["name"].string; viewURL = j["view"]["url"].string
        filter = j["view"]["filter"].string
        groupBy = j["groupBy"].string
        columns = j["columns"].items.compactMap(ProjectBoardColumn.init)
        truncated = j["truncated"].is(true)
        error = j["projectsError"].nonEmpty
    }

    /// The address the board opens at on GitHub: its view's, else the project's.
    var webURL: String? { safeWebURL(viewURL) ? viewURL : url }
    /// How many cards it holds: every item on it, or those the picked assignee has.
    func items(_ assignee: String?) -> Int {
        columns.reduce(0) { $0 + ((assignee ?? "").isEmpty ? $1.count : $1.matching(assignee).count) }
    }

    /// Moves card `card` of column `from` to the end of column `to`, as a drop shows it before the server answers: both
    /// columns' counts and number fields' totals follow it. False when an index is out of range or the columns are one.
    @discardableResult
    mutating func move(from: Int, card: Int, to: Int) -> Bool {
        guard from != to, columns.indices.contains(from), columns.indices.contains(to), columns[from].cards.indices.contains(card) else { return false }
        let moved = columns[from].cards.remove(at: card)
        columns[to].cards.append(moved)
        columns[from].add(moved, -1)
        columns[to].add(moved, 1)
        return true
    }

    /// The column and position of the card with item id `id`.
    func find(_ id: String) -> (column: Int, card: Int)? {
        for (c, column) in columns.enumerated() {
            if let i = column.cards.firstIndex(where: { $0.id == id }) { return (c, i) }
        }
        return nil
    }
    /// The column standing for option `id` (nil: the "No <field>" column).
    func columnIndex(_ id: String?) -> Int? { columns.firstIndex { $0.id == id } }

    /// Drops the cards that are not `repo`'s (drafts and private items among them), as a board shared by several
    /// repositories shows one project only its own. A column that lost cards has its count and totals redone over the rest.
    mutating func keepRepo(_ repo: String?) {
        guard let repo, !repo.isEmpty else { return }
        for c in columns.indices {
            let kept = columns[c].cards.filter { $0.repo.map { foldEqual($0, repo) } ?? false }
            if kept.count == columns[c].cards.count { continue }
            columns[c].cards = kept
            let m = columns[c].matching(nil)
            columns[c].count = m.count
            for s in columns[c].sums.indices { columns[c].sums[s].value = m.sums[s] }
        }
    }

    /// What the assignee filter offers: everyone the board's cards are assigned to, by name, each with how many cards they
    /// have, then "No assignee" when some card has nobody. A pick the board no longer holds still lists itself.
    func assignees(pick: String?) -> [FilterOption] {
        var options: [FilterOption] = []
        var nobody = 0
        for column in columns {
            for card in column.cards {
                if card.assignees.isEmpty { nobody += 1 }
                for (a, login) in card.assignees.enumerated() {
                    // A login twice on one card, however it is written, counts once.
                    if card.assignees[..<a].contains(where: { foldEqual($0, login) }) { continue }
                    if let i = options.firstIndex(where: { foldEqual($0.text, login) }) { options[i].count += 1 }
                    else { options.append(FilterOption(value: login, text: login, count: 1)) }
                }
            }
        }
        if let pick, !pick.isEmpty, pick != projectNoAssignee, !options.contains(where: { foldEqual($0.value, pick) }) {
            options.append(FilterOption(value: pick, text: pick, count: 0))
        }
        options.sort { a, b in
            let fa = a.text.asciiFolded, fb = b.text.asciiFolded
            if !fa.utf8.elementsEqual(fb.utf8) { return fa.bytesPrecede(fb) }
            return a.text.bytesPrecede(b.text)
        }
        if nobody > 0 || pick == projectNoAssignee { options.append(FilterOption(value: projectNoAssignee, text: "No assignee", count: nobody)) }
        return options
    }
}

/// The pull requests linked to close an issue card of `repo`, from the `pulls` board read: those its issue row names,
/// then the rows of `pulls` that name it. None for a card of another repository or one that is not an issue.
func projectCardPulls(_ card: ProjectBoardCard, repo: String?, issues: [IssueSummary], pulls: [PullSummary]) -> [BoardLink] {
    guard card.type == "issue", let cardRepo = card.repo, foldEqual(cardRepo, repo), card.number >= 1 else { return [] }
    var out = issuesFind(issues, card.number)?.pulls ?? []
    for pull in pulls {
        let closes = pull.issues.contains { $0.number == card.number && !$0.isForeign(repo) }
        let listed = out.contains { $0.number == pull.number && !$0.isForeign(repo) }
        guard closes, !listed else { continue }
        let link: JSON = ["number": JSON(pull.number), "title": .string(pull.title), "url": JSON(pull.url), "state": "open", "draft": .bool(pull.draft)]
        if let l = BoardLink(link) { out.append(l) }
    }
    return out
}

/// GitHub's named colours for single-select options as red, green and blue; nil for a name it does not use.
func projectColorRGB(_ name: String?) -> (red: Int, green: Int, blue: Int)? {
    // GitHub's Primer colours behind the option colours, as its board draws them.
    let colors: [(String, (Int, Int, Int))] = [
        ("GRAY", (0x9A, 0xA0, 0xA6)), ("BLUE", (0x40, 0x8C, 0xFF)), ("GREEN", (0x3F, 0xB9, 0x50)),
        ("YELLOW", (0xD2, 0x99, 0x22)), ("ORANGE", (0xDB, 0x6D, 0x28)), ("RED", (0xF8, 0x51, 0x49)),
        ("PINK", (0xDB, 0x61, 0xA2)), ("PURPLE", (0xA3, 0x71, 0xF7)),
    ]
    guard let name, let c = colors.first(where: { foldEqual($0.0, name) }) else { return nil }
    return (c.1.0, c.1.1, c.1.2)
}

/// A number as a column's total shows it: whole numbers without decimals, the rest with up to two.
func projectSumText(_ value: Double) -> String {
    if value.isFinite, value == value.rounded(.towardZero), abs(value) < 9e18 { return String(Int64(value)) }
    var text = String(format: "%.2f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

/// The number at the start of a field's text, as strtod reads it; 0 when there is none.
private func leadingDouble(_ text: String) -> Double {
    if let n = Double(text) { return n }
    var end = text.startIndex
    var best = 0.0
    while end < text.endIndex {
        end = text.index(after: end)
        if let n = Double(text[..<end].trimmingCharacters(in: .whitespaces)) { best = n }
    }
    return best
}

// MARK: - The setting that names it

/// The project setting that names a board, `{ owner, ownerType, number, view }`, from its address on GitHub
/// (https://github.com/orgs/<org>/projects/<n>[/views/<v>] or …/users/<login>/projects/<n>…). Nil when it is not one.
func projectBoardSetting(fromURL url: String?) -> JSON? {
    guard let url else { return nil }
    var p = Substring(url.drop { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
    if p.hasPrefix("https://") { p = p.dropFirst(8) } else if p.hasPrefix("http://") { p = p.dropFirst(7) }
    guard p.hasPrefix("github.com/") else { return nil }
    p = p.dropFirst(11)
    let type: String
    if p.hasPrefix("orgs/") { type = "organization"; p = p.dropFirst(5) }
    else if p.hasPrefix("users/") { type = "user"; p = p.dropFirst(6) }
    else { return nil }
    // orgs/<owner>/projects/<n>[/views/<v>], with anything after a ? or # left alone.
    let path = p.prefix { !"?# \t\r\n".contains($0) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    func whole(_ s: String) -> Int { s.isEmpty || s.count > 9 || !s.allSatisfy({ $0.isASCII && $0.isNumber }) ? 0 : Int(s) ?? 0 }
    let n = parts.count
    let number = n >= 3 && parts[1] == "projects" ? whole(parts[2]) : 0
    let view = n >= 5 && parts[3] == "views" ? whole(parts[4]) : 0
    guard n > 0, !parts[0].isEmpty, number > 0,
          n == 3 || (n == 4 && parts[3].isEmpty) || (view > 0 && (n == 5 || (n == 6 && parts[5].isEmpty))) else { return nil }
    return ["owner": .string(parts[0]), "ownerType": .string(type), "number": JSON(number), "view": view > 0 ? JSON(view) : .null]
}
/// The board's address on GitHub, from the setting; nil when the setting names none.
func projectBoardSettingURL(_ setting: JSON) -> String? {
    guard let owner = setting["owner"].nonEmpty else { return nil }
    let number = setting["number"].truncatedInt ?? 0, view = setting["view"].truncatedInt ?? 0
    guard number >= 1 else { return nil }
    let kind = setting["ownerType"].string == "user" ? "users" : "orgs"
    return view > 0 ? "https://github.com/\(kind)/\(owner)/projects/\(number)/views/\(view)" : "https://github.com/\(kind)/\(owner)/projects/\(number)"
}

/// Whether `projects` (the object or its array) says the project names a board (`hasBoard`).
func projectHasBoard(_ projects: JSON, repo: String) -> Bool {
    listOf(projects, "projects").items.first { $0["repo"].string == repo }?["hasBoard"].is(true) ?? false
}

// MARK: - An issue's Status

/// Where the issue screen keeps its read of issue `number`, which the board and the pull request screen share.
func savedIssueKey(_ repo: String, _ number: Int) -> String { "issue:\(repo)#\(number)" }
/// An issue's Status on the first of its project boards that gives it one (from what `issue` answers for it); nil on none.
func issueProjectStatus(_ issue: JSON) -> String? {
    issue["projects"].items.lazy.compactMap { $0["status"].nonEmpty }.first
}

// MARK: - Moves settling

/// A card GitHub moved on a repository's board, every column it was carried from while it settles and the one it went to
/// (nil for the "No <field>" column). The board's cards are read through its view's filter, a GitHub search that lags
/// behind a move by seconds: a read just after one still shows the card where it was, and the server keeps that read for
/// 45 seconds. So for two minutes a read that has it in a column it came from is corrected by hand.
struct SettlingMove: Equatable, Sendable {
    static let seconds: TimeInterval = 120
    var repo: String
    var id: String
    var from: [String?]
    var column: String?
    var until: Date
}

/// Records a move GitHub accepted. A card moved again before it settled keeps the columns it came from before, so a read
/// behind both moves is still corrected.
func settlingRecord(_ moves: [SettlingMove], repo: String, id: String, from: String?, to: String?, now: Date = Date()) -> [SettlingMove] {
    var rest = moves
    var origins: [String?] = []
    if let i = rest.firstIndex(where: { $0.repo == repo && $0.id == id }) { origins = rest.remove(at: i).from }
    origins.append(from)
    rest.append(SettlingMove(repo: repo, id: id, from: origins, column: to, until: now.addingTimeInterval(SettlingMove.seconds)))
    return rest
}

/// Puts the cards GitHub moved lately in their new columns on a read of `repo`'s board that still has them in a column
/// they came from, and returns the moves still settling. One the read shows where it went, or anywhere but where it came
/// from (moved again since, by someone else), is GitHub's own and settled; so is one past its two minutes.
func settlingApply(_ moves: [SettlingMove], to board: inout ProjectBoard, repo: String, now: Date = Date()) -> [SettlingMove] {
    var rest: [SettlingMove] = []
    for m in moves {
        if now > m.until { continue }
        guard m.repo == repo else { rest.append(m); continue }
        guard let (column, card) = board.find(m.id) else { rest.append(m); continue }
        let to = board.columnIndex(m.column)
        let stale = m.from.contains { $0 == board.columns[column].id }
        if column == to || !stale { continue }
        if let to { board.move(from: column, card: card, to: to) }
        rest.append(m)
    }
    return rest
}
