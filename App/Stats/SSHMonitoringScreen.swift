// The registered SSH hosts and each host's rolling 24-hour telemetry.
import SwiftUI

struct SSHMonitoringScreen: View {
    @StateObject private var model: SSHMonitoringModel
    @Environment(\.navigate) private var navigate

    private let embedded: Bool
    private let selectServer: ((Double) -> Void)?

    init(serverID: Double? = nil, embedded: Bool = false, selectServer: ((Double) -> Void)? = nil) {
        _model = StateObject(wrappedValue: SSHMonitoringModel(serverID: serverID))
        self.embedded = embedded
        self.selectServer = selectServer
    }

    var body: some View {
        Group {
            if embedded { serverList }
            else { serverList.navigationTitle(model.title) }
        }
        .task { await model.follow() }
        .refreshable { await model.load() }
        .onDisappear { model.hideCredential() }
    }

    private var serverList: some View {
        List {
            if let error = model.error { ErrorNotice(message: error) }
            if !model.available {
                Text("SSH monitoring is unavailable on this server or for this token.")
            } else if !model.loaded {
                ProgressView()
            } else if model.serverID == nil {
                if model.servers.isEmpty { ContentUnavailableView("No SSH servers", systemImage: "server.rack") }
                ForEach(model.servers) { server in
                    Button { open(server.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.title).font(.headline)
                            Text(server.repo).font(.caption).foregroundStyle(.secondary)
                            Text(server.state).font(.caption).foregroundStyle(server.stale ? Theme.warn : Theme.muted)
                        }
                    }.tint(.primary)
                }
            } else if let server = model.server {
                Section {
                    Text(server.state).foregroundStyle(server.stale ? Theme.warn : Theme.muted)
                    if let at = server.measuredAt { LabeledContent("Last sample", value: at.formatted()) }
                    if server.tiles.isEmpty { Text("No metrics received yet.") }
                    StatTiles(tiles: server.tiles)
                } header: {
                    if embedded { Text(model.title) }
                    Text(server.repo)
                }
                if !model.charts.isEmpty {
                    Section("Last 24 hours") { ForEach(model.charts) { StatsChartView(chart: $0) } }
                }
                SSHMonitorControls(model: model)
            }
        }
    }
    private func open(_ id: Double) {
        if let selectServer { selectServer(id) }
        else { navigate(.sshMonitoring(serverID: id)) }
    }
}

private struct SSHMonitorControls: View {
    @ObservedObject var model: SSHMonitoringModel
    @State private var action: String?

    var body: some View {
        if model.canIssue || model.canRevoke || model.canToggle {
            Section("Monitoring settings") {
                Text("Install Briareus Monitor on this server and give it the configuration issued here. It sends telemetry over HTTPS once a minute.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.canIssue { Button("Issue or rotate monitor token") { action = "issue" } }
                if model.canRevoke { Button("Revoke monitor token", role: .destructive) { action = "revoke" } }
                if model.canToggle { Button(model.server?.monitoringAction ?? "Monitoring") { model.toggleMonitoring() } }
                if model.busy { ProgressView() }
            }
            .disabled(model.busy || model.loading || model.uncertain)
            .confirmationDialog("Change this server’s monitor credential?", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
                if action == "issue" { Button("Rotate token and enable telemetry") { model.issueToken() } }
                else { Button("Revoke token and disable telemetry", role: .destructive) { model.revokeToken() } }
            } message: { Text("The monitor’s previous credential stops working.") }
        }
        if model.uncertain {
            Section { Text("The request’s outcome is unknown. Check this server before making another change."); Button("I checked the outcome") { model.acknowledgeOutcome() } }
        }
        if let configuration = model.credential {
            Section("Monitor configuration · shown once") {
                Text(configuration).font(.caption.monospaced()).textSelection(.enabled)
                ShareLink("Save configuration", item: configuration)
                Button("Hide configuration") { model.hideCredential() }
                Text("Keep this configuration private; the server cannot show the token again.").font(.caption)
            }
        }
    }
}
