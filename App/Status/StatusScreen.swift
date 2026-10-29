// The Status tab, as the Mac's ◉ Status: what waits for you and what is working across every project (StatusSections),
// with the Server dashboard and the CI/CD history a tap away. It reads the projects and their conversations through
// ProjectsModel, again every time the conversations are polled.
import SwiftUI

struct StatusScreen: View {
    @ObservedObject private var projects = ProjectsModel.shared
    @EnvironmentObject private var store: Store
    @Environment(\.navigate) private var navigate

    var body: some View {
        List {
            if let error = projects.error ?? projects.sessionsError {
                ErrorNotice(message: error).listRowBackground(Theme.row)
            }
            if projects.loaded {
                StatusSections()
            } else {
                ProgressView("Loading status…").frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle("Status")
        .toolbar {
            // The Mac's ◉ Status has the same: what the machine spends on the sessions working here, and the CI history.
            if store.supports("ci_stats") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { navigate(.ciStats) } label: { Image(systemName: "checkmark.seal") }
                        .accessibilityLabel("CI/CD")
                }
            }
            if store.supports("server_stats") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { navigate(.serverStats) } label: { Image(systemName: "gauge.with.dots.needle.33percent") }
                        .accessibilityLabel("Server")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { OpenInWindowButton(page: .status) }
        }
        .refreshable { try? await projects.load() }
        .task { await poll(every: ProjectFeed.sessionsEvery) { await reading { try await projects.load() } } }
    }
}
