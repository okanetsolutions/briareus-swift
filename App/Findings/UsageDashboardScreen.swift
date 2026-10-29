// The existing Usage destination hosts the ledger and resource tabs without pushing another screen.
import SwiftUI

struct UsageScreen: View {
    @StateObject private var usage = UsageModel()
    @StateObject private var server = ServerStatsModel()
    @ObservedObject private var store = Store.shared
    @State private var selection: UsageDashboardTab = .usage

    private var tabs: [UsageDashboardTab] { UsageDashboardTab.available(supports: store.supports) }

    var body: some View {
        VStack(spacing: 0) {
            DashboardTabStrip(tabs: tabs, selection: $selection, title: { $0.title })
            ZStack {
                UsageLedgerPanel(model: usage)
                    .opacity(selection == .usage ? 1 : 0)
                    .allowsHitTesting(selection == .usage)
                    .accessibilityHidden(selection != .usage)
                if selection == .ci {
                    CIDashboardScreen().id(store.client.map(ObjectIdentifier.init))
                } else if selection.serverTab != nil {
                    ServerStatsScreen(model: server, embedded: true)
                }
            }
        }
        .navigationTitle("Usage")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { OpenInWindowButton(page: .usage) }
            UsageLedgerToolbar(model: usage, active: selection == .usage)
        }
        .onChange(of: tabs) { _, offered in selection = selection.resolved(in: offered) }
        .onChange(of: server.tab) { _, tab in
            if selection.serverTab != nil { selection = UsageDashboardTab.server(tab).resolved(in: tabs) }
        }
        .onChange(of: selection) { _, tab in
            if let resource = tab.serverTab { server.tab = resource }
        }
    }
}
