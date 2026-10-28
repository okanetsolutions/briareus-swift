// The board's filter pickers on the Mac: each picker's menu, the toggles for later stacked pull requests and failing
// checks, and Clear filters. What a pick keeps is BoardFilter's (Mac/Core/Board.swift).
import SwiftUI

extension BoardModel {
    /// One picker's menu: `All <kind>s`, then each option with how many rows it would show.
    func pick(_ kind: FilterKind) {
        guard let selected = BoardFilterControls.pick(kind, filter: filter, rows: rows) else { return }
        filter = selected
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

/// The global board uses the same menus and toggles as a project's board.
extension GlobalPullsModel {
    func pick(_ kind: FilterKind) {
        guard let selected = BoardFilterControls.pick(kind, filter: currentFilter, rows: filterRows) else { return }
        currentFilter = selected
    }
    func toggleLaterStacked() { currentFilter.hideLaterStacked.toggle() }
    func toggleFailingChecks() { currentFilter.hideFailingChecks.toggle() }
}

/// Shared drawing and native popup menus for the project and global board headers.
@MainActor
enum BoardFilterControls {
    static func pick(_ kind: FilterKind, filter: BoardFilter, rows: [BoardRow]) -> BoardFilter? {
        let options = filter.options(kind, rows: rows)
        let current = filter[kind]
        var items = [BoardPopupMenu.Item(title: "All \(kind.name)s", checked: current.isEmpty)]
        for option in options {
            items.append(BoardPopupMenu.Item(title: "\(option.text) (\(option.count))", checked: current == option.value))
        }
        guard let chosen = BoardPopupMenu.show(items, rightAligned: true) else { return nil }
        var selected = filter
        selected.set(kind, chosen == 0 ? "" : options[chosen - 1].value)
        return selected
    }

    static func headerButtons(filter: BoardFilter, kinds: [FilterKind], stacked: Bool, enabled: Bool,
                              pick: @escaping (FilterKind) -> Void, toggleLaterStacked: @escaping () -> Void,
                              toggleFailingChecks: @escaping () -> Void) -> [HeaderButton] {
        var buttons = kinds.map { kind in
            HeaderButton(glyph: glyph(kind), label: "\(label(kind, filter: filter)) ▾", enabled: enabled) { pick(kind) }
        }
        if stacked {
            buttons.append(HeaderButton(glyph: "square.stack.3d.up", label: filter.hideLaterStacked ? "Show later stacked PRs" : "Hide later stacked PRs",
                                        tip: "Hide or show stacked pull requests after position 1; keep standalone pull requests visible",
                                        enabled: enabled, action: toggleLaterStacked))
            buttons.append(HeaderButton(glyph: ChecksState.failed.symbol, label: filter.hideFailingChecks ? "Show failing checks" : "Hide failing checks",
                                        tip: "Hide or show pull requests whose checks failed; keep those passing, still running or without checks",
                                        enabled: enabled, action: toggleFailingChecks))
        }
        return buttons
    }

    private static func glyph(_ kind: FilterKind) -> String {
        switch kind {
        case .author: return "line.3.horizontal.decrease"
        case .reviewer: return "person.crop.circle.badge.checkmark"
        case .assignee: return "person.crop.circle"
        case .label: return "tag"
        }
    }

    private static func label(_ kind: FilterKind, filter: BoardFilter) -> String {
        let value = filter[kind]
        if value.isEmpty { return "All \(kind.name)s" }
        if kind == .assignee && value == BoardFilter.noAssignee { return "No assignee" }
        return value
    }
}
