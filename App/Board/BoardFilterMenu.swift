// The board's filter menu on a phone: a picker per author, reviewer, assignee and label, each option with how many rows it
// would show, and on the pull requests' list the toggles for later stacked pull requests and failing checks. What a pick
// keeps is BoardFilter's (Mac/Core/Board.swift).
import SwiftUI

/// The board's pickers in one menu. Each option says how many rows picking it would leave.
struct BoardFilterMenu: View {
    @Binding var filter: BoardFilter
    let rows: [BoardRow]
    let kinds: [FilterKind]
    /// The pull requests' list, which offers Hide later stacked PRs and Hide failing checks; issues have neither.
    var stacked = false
    var picked: () -> Void = {}

    var body: some View {
        Menu {
            ForEach(kinds, id: \.self) { kind in
                let options = filter.options(kind, rows: rows)
                Picker(selection: Binding(get: { filter[kind] }, set: { filter.set(kind, $0); picked() })) {
                    Text("All \(kind.name)s").tag("")
                    ForEach(options, id: \.value) { Text("\($0.text) (\($0.count))").tag($0.value) }
                } label: {
                    let name = kind.name.asciiCapitalized
                    Label(filter[kind].isEmpty ? name : "\(name): \(options.first { $0.value == filter[kind] }?.text ?? filter[kind])",
                          systemImage: kind == .author ? "person" : kind == .reviewer ? "eye" : kind == .assignee ? "person.crop.circle" : "tag")
                }
                .pickerStyle(.menu)
                .disabled(options.isEmpty)
            }
            if stacked {
                Toggle(isOn: Binding(get: { filter.hideLaterStacked }, set: { filter.hideLaterStacked = $0; picked() })) {
                    Label("Hide later stacked PRs", systemImage: "square.stack.3d.up")
                }
                Toggle(isOn: Binding(get: { filter.hideFailingChecks }, set: { filter.hideFailingChecks = $0; picked() })) {
                    Label("Hide failing checks", systemImage: ChecksState.failed.symbol)
                }
            }
            if filter.isOn {
                Button("Clear filters", systemImage: "xmark.circle", role: .destructive) { filter = BoardFilter(); picked() }
            }
        } label: {
            Image(systemName: filter.isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(filter.isOn ? "Filters, active" : "Filters")
    }
}
