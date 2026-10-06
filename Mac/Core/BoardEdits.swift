// Edits of a pull request or an issue (board.c board_names_parse and the rest): the labels and assignees an edit box holds,
// as the lists `update_pull` and `update_issue` send, and "Assign me".
import Foundation

/// What an edit box of labels or assignees holds, as the list `update_pull` and `update_issue` send: split at commas and
/// line breaks, trimmed, empty ones dropped and each name once, compared without case as GitHub does. A name in double
/// quotes keeps its commas (`""` is a quote inside it), so a label such as `needs: review, qa` makes the round trip.
/// `logins` also drops a leading `@`. An empty list clears what GitHub has.
func boardNamesParse(_ text: String?, logins: Bool) -> [String] {
    let bytes = Array((text ?? "").utf8)
    var out: [String] = []
    var p = 0
    func at(_ i: Int) -> UInt8 { i < bytes.count ? bytes[i] : 0 }
    let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
    while p < bytes.count {
        while at(p) == UInt8(ascii: " ") || at(p) == UInt8(ascii: "\t") { p += 1 }
        var raw: [UInt8] = []
        if at(p) == quote {
            // A quoted name keeps its commas; "" inside it is one quote.
            p += 1
            while p < bytes.count && !(at(p) == quote && at(p + 1) != quote) {
                raw.append(at(p))
                if at(p) == quote { p += 1 }
                p += 1
            }
            if p < bytes.count { p += 1 }
        }
        var n = 0
        while p + n < bytes.count && at(p + n) != comma && at(p + n) != cr && at(p + n) != lf { n += 1 }
        raw.append(contentsOf: bytes[p..<(p + n)])
        let name = String(decoding: raw, as: UTF8.self).cTrimmed
        let kept = logins && name.hasPrefix("@") ? String(name.dropFirst()) : name
        if !kept.isEmpty && !out.contains(where: { foldEqual($0, kept) }) { out.append(kept) }
        p += n
        if p < bytes.count { p += 1 }
    }
    return out
}

/// A name as an edit box holds it: quoted when a comma, a line break or a leading quote would split or change it.
private func boxName(_ name: String) -> String {
    guard name.contains(where: { $0 == "," || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) || name.hasPrefix("\"") else { return name }
    return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
/// The names as such a box shows them, comma separated, quoting those with a comma.
func boardNamesJoin(_ names: [String]) -> String { names.map(boxName).joined(separator: ", ") }
func boardLabelNamesJoin(_ labels: [PullLabel]) -> String { boardNamesJoin(labels.map(\.name)) }

/// The assignees with `login` added, or taken off when it is one of them already (`added` says which).
func boardAssigneesToggle(_ assignees: [String], login: String?) -> (assignees: [String], added: Bool) {
    var out: [String] = []
    var had = false
    for a in assignees {
        if foldEqual(a, login) && login != nil { had = true; continue }
        out.append(a)
    }
    if !had, let login, !login.isEmpty { out.append(login) }
    return (out, !had)
}

/// "Assign me" or "Unassign me" as the item's assignees stand, `me` being the user's own login.
func assignMeLabel(_ assignees: [String], me: String?) -> String {
    guard let me else { return "Assign me" }
    return assignees.contains { foldEqual($0, me) } ? "Unassign me" : "Assign me"
}

/// The title and description after an edit, as only the fields that changed; nil when nothing did. GitHub keeps a body as
/// it was typed, often with CRLF, which the edit box shows as plain line breaks.
func detailsEdited(title: String?, body: String?, newTitle: String, newBody: String) -> JSON? {
    var fields: JSON = [:]
    if newTitle != (title ?? "") { fields["title"] = .string(newTitle) }
    if newBody != (body ?? "").replacingOccurrences(of: "\r\n", with: "\n") { fields["body"] = .string(newBody) }
    // Not `fields.count > 0 ? fields : nil`: JSON takes `nil` as its own null.
    guard fields.count > 0 else { return Optional<JSON>.none }
    return fields
}
