// Usage and server resources share the existing Usage dashboard, with one row of tabs under its header.
import SwiftUI

struct UsageScreen: View {
    @StateObject private var usage = UsageModel.kept()
    @StateObject private var server = ServerStatsModel()
    @ObservedObject private var store = Store.shared
    @State private var selection: UsageDashboardTab = .usage

    private var tabs: [UsageDashboardTab] { UsageDashboardTab.available(supports: store.supports) }
    private var subtitle: String? {
        guard selection == .usage, let reading = usage.shown else { return nil }
        return usage.query.subtitle(reading, options: usage.options ?? .null)
    }
    private var buttons: [HeaderButton] {
        if selection != .usage {
            guard selection.serverTab != .sshServers else { return [] }
            return [HeaderButton(glyph: "arrow.clockwise", tip: "Refresh this tab") { Task { await server.load() } }]
        }
        guard store.supports("usage_all") else { return [] }
        return [
            HeaderButton(glyph: Glyph.symbol(0xE787), label: "\(usage.query.periodLabel) \u{25BE}", tip: "The window every number on this page is over") { usage.pickPeriod() },
            HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the usage ledger again", enabled: !usage.loading) { usage.load() },
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "\u{1F4CA} Usage", subtitle: subtitle, buttons: buttons)
            TabNav {
                ForEach(tabs) { tab in
                    TabNavItem(title: tab.title, active: selection == tab) { selection = tab }
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }.padding(.horizontal, Theme.paneMargin)
            ZStack {
                UsageLedgerPanel(model: usage)
                    .opacity(selection == .usage ? 1 : 0)
                    .allowsHitTesting(selection == .usage)
                    .accessibilityHidden(selection != .usage)
                if selection != .usage {
                    ServerStatsScreen(model: server, embedded: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in
            if selection == .usage { usage.load() }
        }
        .onChange(of: tabs) { _, offered in selection = selection.resolved(in: offered) }
        .onChange(of: server.tab) { _, tab in
            if selection != .usage { selection = UsageDashboardTab.server(tab).resolved(in: tabs) }
        }
        .onChange(of: selection) { _, tab in
            if let resource = tab.serverTab { server.tab = resource }
        }
    }
}
