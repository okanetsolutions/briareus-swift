// The Issues tab past what the board lists. A board read from GitHub stops after its first 100 open issues and says so
// (`issuesTruncated`); `GET /issues` serves the rest from the server's mirror a page at a time, in the board's order
// (most recently updated first). Both apps keep one of these beside the board and list the board's issues followed by
// the ones read here.
import Foundation

/// One page of `issues`: its rows as the board sends them, where the next page starts (nil at the end), and whether
/// the server's mirror itself stopped short (`issuesTruncated`), when the end of the pages is not the end of the open issues.
struct IssuesPage: Equatable, Sendable {
    var issues: [JSON]
    var nextOffset: Int?
    var truncated: Bool

    init(_ j: JSON) {
        issues = j["issues"].items
        nextOffset = j["nextOffset"].int
        truncated = j["issuesTruncated"].is(true)
    }
}

/// The issues read past the board's, where the next page starts, and why the last read failed. A failed page is read
/// again from the same offset, so Load more doubles as Retry.
struct IssuePages: Equatable, Sendable {
    static let pageSize = 50
    /// How far each page reaches back before where the last one (or the board) ended. The list shifts between reads as
    /// issues are opened, updated or closed, and a row pushed across the edge would otherwise be read by neither.
    static let overlap = 10

    /// The rows read so far, each number once, in the server's order. Rows the board lists too are kept, so one a newer
    /// board pushes off its first 100 stays listed.
    private(set) var rows: [JSON] = []
    /// Each row read once, as it arrived: the screens list them on every redraw.
    private(set) var summaries: [IssueSummary] = []
    /// Where the next page starts in the server's list; nil until a page answers, when it starts after the board's rows.
    private(set) var nextOffset: Int?
    /// The server said there is no page after the last one read.
    private(set) var ended = false
    /// The last page said the server's mirror stopped short, so its end is not the end of the open issues.
    private(set) var mirrorCut = false
    /// Why the last read failed, shown above Load more.
    private(set) var error: String?

    /// The board stopped short of every open issue, and it could read them at all.
    static func offered(board: JSON) -> Bool { board["issuesTruncated"].is(true) && !board["issuesError"].isSet }

    /// Load more is offered while the board stopped short, the pages have not reached the end, and the server has
    /// `GET /issues` (`routed`).
    func canLoadMore(board: JSON, routed: Bool) -> Bool { routed && Self.offered(board: board) && !ended }

    /// The board stopped short and nothing reads past it: the server has no `GET /issues` (`routed`), or its pages
    /// ended without a row the board lacks or with the mirror itself cut, so the list says it is cut.
    func cutShort(board: JSON, routed: Bool) -> Bool {
        guard Self.offered(board: board) else { return false }
        guard routed else { return true }
        guard ended else { return false }
        let onBoard = Set(board["issues"].items.compactMap { $0["number"].int })
        return mirrorCut || summaries.allSatisfy { onBoard.contains($0.number) }
    }

    /// Load more reads a failed page again.
    var retries: Bool { error != nil }

    /// Why the last read failed, while Load more is there to read it again; a board that no longer stops short drops it.
    func retryError(board: JSON, routed: Bool) -> String? { canLoadMore(board: board, routed: routed) ? error : nil }

    /// The next page's arguments: after the rows the board listed, then wherever the last page said, but never further
    /// inside the board's rows (which a newer board may hold more of) than `overlap` reaches back.
    func query(repo: String, board: JSON) -> JSON {
        let offset = max(0, max(nextOffset ?? 0, board["issues"].count) - Self.overlap)
        return ["repo": .string(repo), "offset": JSON(offset), "limit": JSON(Self.pageSize)]
    }

    /// A read is under way: the last failure goes, so the apps show progress rather than an old error.
    mutating func reading() { error = nil }

    /// Keeps the page's rows that no earlier page holds. The list moves between pages as issues are updated, so a row
    /// can come back; it is kept once, where it was first seen. Rows on the board are kept too and left out when listed.
    mutating func receive(_ page: IssuesPage) {
        var held = Set(summaries.map(\.number))
        for row in page.issues {
            guard let issue = IssueSummary(row), held.insert(issue.number).inserted else { continue }
            rows.append(row)
            summaries.append(issue)
        }
        nextOffset = page.nextOffset
        ended = page.nextOffset == nil
        mirrorCut = page.truncated
        error = nil
    }

    /// The page could not be read; Load more reads it again from the same offset.
    mutating func fail(_ error: String) { self.error = error }

    /// An issue the app closed: the board drops it on its next read, but a row read here is listed until a refresh unless
    /// it goes too.
    mutating func drop(_ number: Int) {
        guard let at = summaries.firstIndex(where: { $0.number == number }) else { return }
        summaries.remove(at: at)
        rows.remove(at: at)
    }

    /// The board's issues followed by the ones read here that it does not list now. A board that no longer stops short
    /// lists every open issue itself, so what was read is left out.
    func issues(after board: [(summary: IssueSummary, raw: JSON)], answer: JSON) -> [(summary: IssueSummary, raw: JSON)] {
        guard Self.offered(board: answer), !rows.isEmpty else { return board }
        let onBoard = Set(board.map(\.summary.number))
        return board + zip(summaries, rows).filter { !onBoard.contains($0.0.number) }.map { (summary: $0.0, raw: $0.1) }
    }
}
