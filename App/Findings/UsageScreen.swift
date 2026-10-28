// The Usage tab: what the projects spent over a window, as the Mac's 📊 Usage screen draws it from the usage ledger. An Admin
// token reads every project at once (`GET /usage/all`) over any window, narrowed by six filters, with insights and the
// costliest sessions; any other token reads each of its projects' own month (`GET /usage`), added up here. The totals
// are tiles, tokens and cost per day are bars, and each breakdown is a list of rows with a ring of its share of tokens;
// a row is a filter.
import Charts
import SwiftUI

struct UsageLedgerPanel: View {
    @ObservedObject var model: UsageModel
    @ObservedObject private var store = Store.shared
    @ObservedObject private var projects = ProjectsModel.shared
    @Environment(\.navigate) private var navigate

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden).background(Theme.canvas)
            .navigationTitle("Usage")
            .toolbar { toolbar }
            .refreshable {
                async let providers: Void = model.loadProviders(fresh: false)
                _ = await model.load()
                await providers
            }
            .task { await poll(every: 60) { await model.load() } }
            .task { await model.loadProviders(fresh: false) }
            .sheet(isPresented: $model.editingRange) { UsageRangeSheet(current: model.query.range) { model.setRange($0) } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.available {
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

    @ViewBuilder private var content: some View {
        if store.supports("providers") { providerSections }
        if !model.available {
            Text(adminNeeded).font(.callout).foregroundStyle(.secondary).listRowBackground(Theme.row)
        } else if let u = model.shown {
            page(u)
        } else if let error = model.error {
            ErrorNotice(message: error).listRowBackground(Theme.row)
        } else {
            ProgressView("Loading the usage ledger…").frame(maxWidth: .infinity).listRowBackground(Color.clear)
        }
    }

    /// Every provider sessions start on, as the Mac's Accounts and quota: a section each, with a dot for how it stands,
    /// and under it each account with whom it is logged in as and its plan's quota windows, so a spent account shows
    /// before a session fails on it.
    @ViewBuilder private var providerSections: some View {
        if let error = model.providersError {
            Section("Accounts and quota") { ErrorNotice(message: error) }.listRowBackground(Theme.row)
        } else if model.providers.isEmpty {
            Section("Accounts and quota") {
                if model.providersLoading {
                    HStack(spacing: 10) { ProgressView(); Text("Reading the providers' accounts…").foregroundStyle(.secondary) }
                } else {
                    Text("No providers on this server.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Theme.row)
        }
        ForEach(Array(model.providers.enumerated()), id: \.offset) { i, p in
            Section {
                ForEach(Array(ProviderQuota.accounts(p).enumerated()), id: \.offset) { _, a in providerAccount(a, of: p) }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    if i == 0 { Text("Accounts and quota") }
                    providerHeader(p)
                }
            }
            .listRowBackground(Theme.row)
        }
        if !model.providers.isEmpty || model.providersError != nil {
            Section {
                Button {
                    Task { await model.loadProviders(fresh: true) }
                } label: {
                    HStack(spacing: 8) {
                        if model.providersLoading && model.providersFresh { ProgressView() }
                        Text(model.providersLoading && model.providersFresh ? "Checking…" : "Check again")
                    }
                }
                .disabled(model.providersLoading)
            } footer: {
                Text("Check again reads every account and its quota again rather than the server's last answer.")
            }
            .listRowBackground(Theme.row)
        }
    }

    private func providerHeader(_ p: JSON) -> some View {
        let health = ProviderQuota.health(p)
        return HStack(spacing: 8) {
            Circle().fill(health == .missing ? Theme.danger : health == .loggedOut ? Theme.warn : Theme.ok)
                .frame(width: 8, height: 8).accessibilityHidden(true)
            Text(ProviderQuota.title(p))
            if health == .missing { Text("CLI not installed").foregroundStyle(Theme.danger) }
            Spacer()
            if let m = p["defaultModel"].nonEmpty { Text(m).lineLimit(1) }
        }
        .textCase(nil)
    }

    /// One login: whom it is logged in as, then its quota windows, or why it has none.
    @ViewBuilder private func providerAccount(_ a: JSON, of p: JSON) -> some View {
        let login = ProviderQuota.login(a)
        let name = ProviderQuota.accountName(a, of: p)
        if name != nil || !login.text.isEmpty {
            HStack(spacing: 6) {
                if let name { Text(name).font(.subheadline.weight(.medium)) }
                Text(login.text).font(.subheadline).foregroundStyle(login.loggedOut ? Theme.danger : .secondary).lineLimit(1)
            }
        }
        ForEach(Array(ProviderQuota.windows(a).enumerated()), id: \.offset) { _, w in ProviderQuotaBar(window: w) }
        if let note = ProviderQuota.windowsNote(a) { Text(note).font(.footnote).foregroundStyle(.secondary) }
    }

    private var adminNeeded: String {
        "This server does not offer the usage ledger to this device. An Admin token reads every project's spend; issue one on the server with `npm run create-token`."
    }

    @ViewBuilder private func page(_ u: JSON) -> some View {
        let options = model.pickerOptions
        Section {
            if model.query.anyPick {
                ForEach(model.filters.filter { !model.query.picked($0).isEmpty }, id: \.self) { f in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.plural.asciiCapitalized).font(.caption).foregroundStyle(.secondary)
                            Text(model.query.picksLabel(f, options: options)).font(.subheadline).lineLimit(2)
                        }
                        Spacer()
                        Button { model.choose(f, nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear the \(f.plural) filter")
                    }
                    .listRowBackground(Theme.row)
                }
            }
            if let error = model.error { ErrorNotice(message: error).listRowBackground(Theme.row) }
        } header: {
            Text(model.query.subtitle(u, options: options)).textCase(nil)
        } footer: {
            if !model.overall {
                Text("This device reads each of its projects' own spend, this month. An Admin token shows every window, filter and the costliest sessions.")
            }
        }
        if Usage.count(u, "turns") == 0 {
            Section {
                Text(verbatim: "No usage recorded in \(Usage.windowName(u, periodLabel: model.query.periodLabel))\(model.query.anyPick ? " for these filters" : "").")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    .listRowBackground(Color.clear)
            }
            insights(u)
            projectSection(u)
        } else {
            let month = u["unit"].string == "month"
            Section {
                StatTiles(tiles: usageTiles([
                    ("Cost", Usage.costOrDash(u), Usage.costNote(u)),
                    ("Tokens", Usage.tokens(Usage.num(u, "totalTokens")),
                     "\(Usage.tokens(Usage.num(u, "inputTokens"))) in · \(Usage.tokens(Usage.num(u, "outputTokens"))) out"),
                    ("Sessions", "\(Usage.count(u, "sessions"))", "\(Usage.count(u, "turns")) turn\(Usage.plural(Usage.count(u, "turns")))"),
                    ("Agent time", Usage.durationOrDash(Usage.num(u, "durationMs")), "summed over every turn"),
                ]))
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            if UsageBars.plots(u, "totalTokens") {
                Section(month ? "Tokens per month" : "Tokens per day") {
                    UsageBars(u: u, metric: "totalTokens").listRowBackground(Theme.row)
                }
            }
            insights(u)
            projectSection(u)
            breakdown(u, .activity)
            breakdown(u, .provider)
            breakdown(u, .model)
        }
    }

    /// The averages, how the window compares with the one before, cost per bucket and the costliest sessions (`usage/all` only).
    @ViewBuilder private func insights(_ u: JSON) -> some View {
        if model.overall {
            let ins = u["insights"]
            let coverage = Usage.pricingCoverage(u)
            let month = u["unit"].string == "month"
            Section {
                StatTiles(tiles: usageTiles([
                    ("Cost / session", Usage.insightCost(u, "costPerSession"), "within this selection"),
                    ("Cost / turn", Usage.insightCost(u, "costPerTurn"), "within this selection"),
                    ("Average turn", ins["averageDurationMs"].number.map(formatDurationMs) ?? "—", "\(Usage.count(ins, "timedTurns")) turns with timing"),
                    ("Pricing coverage", coverage.value, coverage.sub),
                ]))
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } footer: {
                if let line = Usage.comparisonLine(u) { Text(line) }
            }
            Section(month ? "Cost per month" : "Cost per day") {
                if UsageBars.plots(u, "costUsd") { UsageBars(u: u, metric: "costUsd").listRowBackground(Theme.row) }
                else { Text("No priced spend to plot in this selection.").font(.callout).foregroundStyle(.secondary).listRowBackground(Theme.row) }
            }
            let top = u["topSessions"].items
            if !top.isEmpty {
                Section {
                    ForEach(Array(top.enumerated()), id: \.offset) { _, r in topRow(r) }
                } header: {
                    Text("Most expensive sessions")
                } footer: {
                    Text("Top 10 by known cost. Deleted sessions keep their usage but cannot be reopened.")
                }
            }
        }
    }

    private func topRow(_ r: JSON) -> some View {
        let label = r["label"].nonEmpty ?? Usage.optionKey(r)
        let line = VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer(minLength: 8)
                Text(Usage.costOrDash(r)).font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Text([r["repo"].nonEmpty.map { projects.project($0)?.title ?? $0 },
                  "\(Usage.count(r, "turns")) turn\(Usage.plural(Usage.count(r, "turns")))",
                  "\(Usage.tokens(Usage.num(r, "totalTokens"))) tok"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        return Group {
            if let open = model.topSession(r) {
                Button { navigate(.conversation(id: open.id, session: open.raw)) } label: {
                    line.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the conversation")
            } else { line }
        }
        .listRowBackground(Theme.row)
    }

    // MARK: Breakdowns

    @ViewBuilder private func projectSection(_ u: JSON) -> some View {
        let rows = u["projects"].items
        if !rows.isEmpty {
            let ring = Usage.shareSeries(rows)
            let busiest = max(1, rows.map { Usage.num($0, "totalTokens") }.max() ?? 1)
            Section("By project") {
                if let ring { UsageRing(ring: ring).listRowBackground(Theme.row) }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, p in
                    let label = p["label"].nonEmpty ?? "unknown"
                    let gone = p["gone"].is(true)
                    // A project that ran nothing, or one no longer in Settings, is greyed out; it still adds up into the totals.
                    breakdownRow(gone ? "\(label) (removed)" : label, p, dim: gone || Usage.count(p, "turns") == 0,
                                 swatch: nil, bar: (Usage.num(p, "totalTokens") / busiest, ring?.slots[i].map(Theme.series) ?? Theme.accent),
                                 on: model.query.isPicked(.project, Usage.optionKey(p))) { model.pickRow(.project, p) }
                }
            }
        }
    }

    @ViewBuilder private func breakdown(_ u: JSON, _ f: Usage.Filter) -> some View {
        let rows = u[f.rows].items
        if !rows.isEmpty {
            let ring = Usage.shareSeries(rows)
            Section(f == .activity ? "By activity" : f == .provider ? "By provider" : "By model") {
                if let ring { UsageRing(ring: ring).listRowBackground(Theme.row) }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    let (name, dim) = breakdownName(f, r)
                    breakdownRow(name, r, dim: dim, swatch: ring?.slots[i].map(Theme.series), bar: nil,
                                 on: model.query.isPicked(f, Usage.rowKey(f, r)),
                                 pick: model.overall ? { model.pickRow(f, r) } : nil)
                }
            }
        }
    }
    private func breakdownName(_ f: Usage.Filter, _ r: JSON) -> (String, Bool) {
        switch f {
        case .activity:
            let a = r["activity"].nonEmpty
            return (Usage.activityLabel(a ?? "unknown"), a == nil)
        case .provider:
            let p = r["provider"].nonEmpty
            return (p ?? "unknown", p == nil)
        default:
            return (Usage.modelLabel(r), r["model"].nonEmpty == nil)
        }
    }

    /// A breakdown row: its name (with its slice's swatch), the cost and tokens on the right, the counts under it, and on the
    /// project rows a bar of its share of the busiest. Tapping it filters by it; tapping it again clears that.
    private func breakdownRow(_ name: String, _ r: JSON, dim: Bool, swatch: Color?, bar: (Double, Color)?, on: Bool,
                              pick: (() -> Void)?) -> some View {
        let line = VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 9, height: 9) }
                Text(name).font(.subheadline.weight(.medium)).foregroundStyle(dim ? .secondary : .primary).lineLimit(2)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Usage.costOrDash(r)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(dim ? .secondary : .primary)
                    Text("\(Usage.tokens(Usage.num(r, "totalTokens"))) tok").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if on { Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Theme.accent).accessibilityLabel("Filtered by this") }
            }
            if let bar {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.sunken)
                        if bar.0 > 0 { Capsule().fill(bar.1).frame(width: max(g.size.width * bar.0, 6)) }
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            Text(counts(r)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        return Group {
            if let pick {
                Button(action: pick) { line.contentShape(Rectangle()) }.buttonStyle(.plain)
                    .accessibilityHint(on ? "Clears this filter" : "Shows only this")
            } else { line }
        }
        .listRowBackground(on ? Theme.row(selected: true) : Theme.row)
    }
    private func counts(_ u: JSON) -> String {
        let s = Usage.count(u, "sessions"), t = Usage.count(u, "turns")
        return "\(s) session\(Usage.plural(s)) · \(t) turn\(Usage.plural(t)) · \(Usage.tokens(Usage.num(u, "inputTokens"))) in / \(Usage.tokens(Usage.num(u, "outputTokens"))) out · \(Usage.durationOrDash(Usage.num(u, "durationMs")))"
    }
}

// MARK: - Pieces

/// The ledger's figures as tiles, without gauges.
private func usageTiles(_ tiles: [(label: String, value: String, sub: String)]) -> [StatTile] {
    tiles.map { StatTile(id: $0.label, label: $0.label, value: $0.value, detail: $0.sub, fraction: nil) }
}

/// One bar per bucket the server's calendar has reached; touching a bar names it above the chart.
private struct UsageBars: View {
    var u: JSON
    var metric: String
    @State private var selected: Date?

    static func plots(_ u: JSON, _ metric: String) -> Bool {
        Usage.visibleBuckets(u).contains { Usage.num($0, metric) > 0 }
    }

    var body: some View {
        let month = u["unit"].string == "month"
        let points = Usage.visibleBuckets(u).compactMap { b -> (date: Date, value: Double, bucket: JSON)? in
            PhoneUsage.bucketDate(b["date"].string).map { ($0, Usage.num(b, metric), b) }
        }
        let unit: Calendar.Component = month ? .month : .day
        let picked = selected.flatMap { s in points.first { Calendar.current.isDate($0.date, equalTo: s, toGranularity: unit) } }
        VStack(alignment: .leading, spacing: 8) {
            Text(picked.map { Usage.barTip($0.bucket, month: month) } ?? "Touch a bar for its figures")
                .font(.caption).foregroundStyle(picked == nil ? .secondary : .primary).lineLimit(1)
            Chart(points, id: \.date) { p in
                BarMark(x: .value(month ? "Month" : "Day", p.date, unit: unit), y: .value(metric == "costUsd" ? "Cost" : "Tokens", p.value))
                    .foregroundStyle(picked == nil || picked?.date == p.date ? Theme.accent : Theme.accent.opacity(0.35))
                    .cornerRadius(3)
            }
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(metric == "costUsd" ? formatCost(d) : Usage.tokens(d)) } }
                }
            }
            .chartXAxis {
                // A label on the buckets themselves, at most six: automatic ticks on a short window fall between
                // days and repeat each one's name.
                AxisMarks(values: stride(from: 0, to: points.count, by: max(1, (points.count + 5) / 6)).map { points[$0].date }) { _ in
                    AxisValueLabel(format: month ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 160)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric == "costUsd" ? "Cost over time" : "Tokens over time")
        .accessibilityValue(points.map { Usage.barTip($0.bucket, month: month) }.joined(separator: ", "))
    }
}

/// The ring of each row's share of the tokens.
private struct UsageRing: View {
    var ring: Usage.Ring
    var body: some View {
        VStack(spacing: 6) {
            Chart(Array(ring.slices.enumerated()), id: \.offset) { _, s in
                SectorMark(angle: .value("Share", s.share), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .foregroundStyle(Theme.series(s.slot))
            }
            .frame(width: 120, height: 120)
            Text("share of tokens").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }
}
