// The ledger controls appear only while Usage is selected; its content stays mounted.
import SwiftUI

struct UsageLedgerToolbar: ToolbarContent {
    @ObservedObject var model: UsageModel
    var active: Bool

    var body: some ToolbarContent {
        if active && model.available {
            ToolbarItem(placement: .topBarTrailing) {
                if model.overall {
                    Menu {
                        Picker("Window", selection: Binding(get: { model.query.period }, set: { model.setPeriod($0) })) {
                            ForEach(Usage.periods.indices, id: \.self) { Text(Usage.periods[$0].label).tag($0) }
                        }
                    } label: {
                        Label(model.query.periodLabel, systemImage: "calendar")
                    }
                    .accessibilityLabel("Window: \(model.query.periodLabel)")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
    }

    /// One submenu per filter: All, then the window's choices; the project and model pickers tick several.
    private var filterMenu: some View {
        let options = model.pickerOptions
        return Menu {
            ForEach(model.filters, id: \.self) { f in
                let list = options[f.options].items
                Menu(f.plural.asciiCapitalized) {
                    Button { model.choose(f, nil) } label: { check("All \(f.plural)", model.query.picked(f).isEmpty) }
                    let cap = 60   // the window's sessions can run to thousands
                    ForEach(Array(list.prefix(cap).enumerated()), id: \.offset) { _, o in
                        let key = Usage.optionKey(o)
                        Button { model.choose(f, key) } label: { check(Usage.optionLabel(f, o), model.query.isPicked(f, key)) }
                    }
                    if list.count > cap { Text("\(list.count - cap) more \(f.plural); a shorter window lists them") }
                    if list.isEmpty { Text("No usage in this period") }
                }
            }
            if model.query.anyPick {
                Divider()
                Button(role: .destructive) { model.clearFilters() } label: { Label("Clear filters", systemImage: "xmark.circle") }
            }
        } label: {
            Image(systemName: model.query.anyPick ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(model.query.anyPick ? "Filters, some on" : "Filters")
    }
    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

}
