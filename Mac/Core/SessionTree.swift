// An orchestrator's workers drawn under it in a project's conversation list, as both apps' lists show them: each
// conversation's place, how deep it sits and how many workers it holds, and the list with a folded orchestrator's
// workers left out. No UI here.
import Foundation

/// A conversation's place in the nested list.
struct SessionNode: Equatable, Sendable {
    /// Its position in the list it was nested from.
    var index: Int
    /// 0 for a conversation of its own, 1 for a worker under its orchestrator, and so on.
    var depth: Int
    /// How many rows are drawn directly under it, so a conversation with no worker on the list offers nothing to fold.
    var workers = 0
}

/// Workers drawn under their orchestrator, depth first, each keeping the list's order among its siblings. Only an
/// orchestrator on the list itself nests its workers: one whose orchestrator is left out (closed, or not matching a
/// search) stays at the top level, and a cycle leaves its rows flat.
func sessionsNested(_ sessions: [Session]) -> [SessionNode] {
    var position: [String: Int] = [:]
    for (i, s) in sessions.enumerated() where position[s.id] == nil { position[s.id] = i }
    var under: [Int: [Int]] = [:]
    var top: [Int] = []
    for (i, s) in sessions.enumerated() {
        if let p = s.parentId.flatMap({ position[$0] }), p != i { under[p, default: []].append(i) } else { top.append(i) }
    }
    var rows: [SessionNode] = []
    var drawn = [Bool](repeating: false, count: sessions.count)
    func draw(_ index: Int, _ depth: Int) {
        if drawn[index] { return }
        drawn[index] = true
        let at = rows.count
        rows.append(SessionNode(index: index, depth: depth))
        for w in under[index] ?? [] where !drawn[w] {
            rows[at].workers += 1
            draw(w, depth + 1)
        }
    }
    for i in top { draw(i, 0) }
    // What a cycle kept from the top level.
    for i in sessions.indices { draw(i, 0) }
    return rows
}

/// The nested rows with everything under a folded orchestrator left out; `folded` holds conversation ids.
func sessionsFolded(_ rows: [SessionNode], _ sessions: [Session], folded: Set<String>) -> [SessionNode] {
    if folded.isEmpty { return rows }
    var out: [SessionNode] = []
    var hiding: Int?
    for row in rows {
        if let depth = hiding, row.depth > depth { continue }
        hiding = row.workers > 0 && folded.contains(sessions[row.index].id) ? row.depth : nil
        out.append(row)
    }
    return out
}
