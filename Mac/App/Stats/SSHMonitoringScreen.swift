// The registered SSH hosts and each host's rolling 24-hour telemetry.
import SwiftUI

struct SSHMonitoringScreen: View {
    @StateObject private var model: SSHMonitoringModel
    @State private var width: CGFloat = 0

    private let embedded: Bool
    private let selectServer: ((Double) -> Void)?

    init(serverID: Double? = nil, embedded: Bool = false, selectServer: ((Double) -> Void)? = nil) {
        _model = StateObject(wrappedValue: SSHMonitoringModel(serverID: serverID))
        self.embedded = embedded
        self.selectServer = selectServer
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                PaneHeader(title: model.title, buttons: [HeaderButton(glyph: "arrow.clockwise", tip: "Refresh") { Task { await model.load() } }])
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if embedded {
                        HStack {
                            Text(model.title).font(Theme.subheadlineSemibold).foregroundStyle(Theme.ink)
                            Spacer()
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }.dashButton(.plain)
                        }
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading).fdReadWidth($width).padding(Theme.paneMargin)
            }
        }
        .task { await model.follow() }
        .onDisappear { model.hideCredential() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await model.load() } }
    }
    @ViewBuilder private var content: some View {
        if let error = model.error { NoticeBox(message: error) }
        if !model.available { EmptyNote(title: "SSH monitoring is unavailable on this server or for this token.") }
        else if !model.loaded { LoadingNote() }
        else if model.serverID == nil {
            if model.servers.isEmpty { EmptyNote(title: "No SSH servers") }
            ForEach(model.servers) { server in
                Button { open(server.id) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(server.title).font(Theme.bodySemibold)
                            Text(server.repo).font(Theme.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text(server.state).font(Theme.caption).foregroundStyle(server.stale ? Theme.warn : Theme.muted)
                    }.padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        } else if let server = model.server {
            Text(server.repo).font(Theme.caption).foregroundStyle(Theme.muted)
            Text(server.state).font(Theme.body).foregroundStyle(server.stale ? Theme.warn : Theme.muted)
            if let at = server.measuredAt { Text("Last sample: \(at.formatted())").font(Theme.caption).foregroundStyle(Theme.muted) }
            if server.tiles.isEmpty { EmptyNote(title: "No metrics received yet.") }
            StatTiles(width: width, tiles: server.tiles)
            if model.history != nil { ForEach(model.charts) { StatsChartView(chart: $0) } }
            SSHMonitorControls(model: model)
        }
    }
    private func open(_ id: Double) {
        if let selectServer { selectServer(id) }
        else { Navigator.shared.push(.sshMonitoring(serverID: id)) }
    }
}

private struct SSHMonitorControls: View {
    @ObservedObject var model: SSHMonitoringModel
    var body: some View {
        if model.canIssue || model.canRevoke || model.canToggle {
            SectionTitle(title: "Monitoring settings")
            Text("Install Briareus Monitor on this server with the configuration issued here. It sends telemetry over HTTPS once a minute.")
                .font(Theme.caption).foregroundStyle(Theme.muted)
            HStack {
                if model.canIssue { Button("Issue or rotate token") { issue() }.dashButton(.bordered) }
                if model.canRevoke { Button("Revoke token") { revoke() }.dashButton(.destructive) }
                if model.canToggle { Button(model.server?.monitoringAction ?? "Monitoring") { model.toggleMonitoring() }.dashButton(.bordered) }
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.busy || model.loading || model.uncertain)
        }
        if model.uncertain {
            NoticeBox(message: "The request’s outcome is unknown. Check this server before making another change.")
            Button("I checked the outcome") { model.acknowledgeOutcome() }.dashButton(.bordered)
        }
        if let configuration = model.credential {
            SectionTitle(title: "Monitor configuration · shown once")
            Text(configuration).font(Theme.mono).textSelection(.enabled)
            HStack {
                ShareLink("Save configuration", item: configuration)
                Button("Copy configuration") { Clipboard.copy(configuration) }.dashButton(.bordered)
                Button("Hide configuration") { model.hideCredential() }.dashButton(.plain)
            }
            Text("Keep this configuration private; the server cannot show the token again.").font(Theme.caption).foregroundStyle(Theme.muted)
        }
    }
    private func issue() {
        guard Dialogs.confirm("Rotate this server’s monitor token?", "The previous credential stops working and telemetry is enabled.", continueLabel: "Rotate") else { return }
        model.issueToken()
    }
    private func revoke() {
        guard Dialogs.confirm("Revoke this server’s monitor token?", "Telemetry stops until a new token is installed.", continueLabel: "Revoke", destructive: true) else { return }
        model.revokeToken()
    }
}
