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
            if selection == .usage {
                UsageLedgerPanel(model: usage)
            } else {
                ServerStatsScreen(model: server, embedded: true)
            }
        }
        .navigationTitle("Usage")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { OpenInWindowButton(page: .usage) } }
        .onChange(of: selection) { _, tab in
            if let resource = tab.serverTab { server.tab = resource }
        }
    }
}
