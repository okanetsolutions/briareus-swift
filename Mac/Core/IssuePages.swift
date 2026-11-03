// The Issues tab past what the board lists. A board read from GitHub stops after its first 100 open issues and says so
// (`issuesTruncated`); `GET /issues` serves the rest from the server's mirror a page at a time, in the board's order
// (most recently updated first). Both apps keep one of these beside the board and list the board's issues followed by
// the ones read here.
import Foundation

/// One page of `issues`: its rows as the board sends them, and where the next page starts (nil at the end).
struct IssuesPage: Equatable, Sendable {
    var issues: [JSON]
    var nextOffset: Int?

    init(_ j: JSON) {
        issues = j["issues"].items
        nextOffset = j["nextOffset"].int
    }
}

/// The issues read past the board's, where the next page starts, and why the last read failed. A failed page is read
/// again from the same offset, so Load more doubles as Retry.
struct IssuePages: Equatable, Sendable {
    static let pageSize = 50

    /// The rows read so far, none of them on the board when read and each number once, in the server's order.
    private(set) var rows: [JSON] = []
    /// Each row read once, as it arrived: the screens list them on every redraw.
    private(set) var summaries: [IssueSummary] = []
    /// Where the next page starts in the server's list; nil until a page answers, when it starts after the board's rows.
    private(set) var nextOffset: Int?
    /// The server said there is no page after the last one read.
    private(set) var ended = false
    /// Why the last read failed, shown above Load more.
    private(set) var error: String?

    /// The board stopped short of every open issue, and it could read them at all.
    static func offered(board: JSON) -> Bool { board["issuesTruncated"].is(true) && !board["issuesError"].isSet }

    /// Load more is offered while the board stopped short and the pages have not reached the end.
    func canLoadMore(board: JSON) -> Bool { Self.offered(board: board) && !ended }

    /// The next page's arguments: after the rows the board listed, then wherever the last page said.
    func query(repo: String, board: JSON) -> JSON {
        ["repo": .string(repo), "offset": JSON(nextOffset ?? board["issues"].count), "limit": JSON(Self.pageSize)]
    }

    /// A read is under way: the last failure goes, so the apps show progress rather than an old error.
    mutating func reading() { error = nil }

    /// Keeps the page's rows that neither the board nor an earlier page holds. The list moves between pages as issues
    /// are updated, so a row can come back; it is kept once, where it was first seen.
    mutating func receive(_ page: IssuesPage, board: JSON) {
        var held = Set(board["issues"].items.compactMap { $0["number"].int })
        held.formUnion(summaries.map(\.number))
        for row in page.issues {
            guard let issue = IssueSummary(row), held.insert(issue.number).inserted else { continue }
            rows.append(row)
            summaries.append(issue)
        }
        nextOffset = page.nextOffset
        ended = page.nextOffset == nil
        error = nil
    }

    mutating func fail(_ error: String) { self.error = error }

    /// The board's issues followed by the ones read here that it does not list now. A board that no longer stops short
    /// lists every open issue itself, so what was read is left out.
    func issues(after board: [(summary: IssueSummary, raw: JSON)], answer: JSON) -> [(summary: IssueSummary, raw: JSON)] {
        guard Self.offered(board: answer), !rows.isEmpty else { return board }
        let onBoard = Set(board.map(\.summary.number))
        return board + zip(summaries, rows).filter { !onBoard.contains($0.0.number) }.map { (summary: $0.0, raw: $0.1) }
    }
}
