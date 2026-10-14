// The board's filter pickers on the Mac: each picker's menu, the toggles for later stacked pull requests and failing
// checks, and Clear filters. What a pick keeps is BoardFilter's (Mac/Core/Board.swift).
import SwiftUI

extension BoardModel {
    /// One picker's menu: `All <kind>s`, then each option with how many rows it would show.
    func pick(_ kind: FilterKind) {
        var f = filter
        let options = f.options(kind, rows: rows)
        let current = f[kind]
        var items = [BoardPopupMenu.Item(title: "All \(kind.name)s", checked: current.isEmpty)]
        for o in options { items.append(BoardPopupMenu.Item(title: "\(o.text) (\(o.count))", checked: current == o.value)) }
        guard let chosen = BoardPopupMenu.show(items, rightAligned: true) else { return }
        f.set(kind, chosen == 0 ? "" : options[chosen - 1].value)
        filter = f
        picked()
    }
    /// Hide later stacked PRs, or show them again.
    func toggleLaterStacked() {
        pullFilter.hideLaterStacked.toggle()
        picked()
    }
    /// Hide the pull requests whose checks failed, or show them again.
    func toggleFailingChecks() {
        pullFilter.hideFailingChecks.toggle()
        picked()
    }
    func clearFilters() {
        filter = BoardFilter()
        picked()
    }
}
