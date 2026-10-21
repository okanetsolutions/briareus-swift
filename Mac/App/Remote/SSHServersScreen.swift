// The SSH servers page, opened from the sidebar foot's ❯: every SSH server registered in Settings, in a folder per
// project down the left, and every open SSH session as tabs over its terminal on the right. A click on a server opens a
// session to it under its project, so that project's SSH sessions tab shows it too (or returns to the one already open).
// Sessions run this Mac's OpenSSH client, as the project tab's do (TerminalSession).
import SwiftUI

struct SSHServersScreen: View {
    @ObservedObject private var model = SSHServersModel.shared
    @ObservedObject private var sessions = SSHSessions.shared
    @ObservedObject private var projects = ProjectsModel.shared

    var body: some View {
        let header = ProjectSSHTab.header(session: sessions.active, refresh: RemoteRegistry.offered ? { model.refresh() } : nil,
                                          refreshTip: "Read the SSH servers again")
        VStack(spacing: 0) {
            PaneHeader(title: "\u{276F} SSH servers", subtitle: header.subtitle, status: header.status, buttons: header.buttons)
            if RemoteRegistry.offered {
                content
            } else {
                Text(remoteNeedsAdmin).font(Theme.footnote).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.paneMargin).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { model.revisit() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
    }

    private var content: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
                SSHServerFolderList(model: model, folders: model.folders(projects: projects.projects))
                    .frame(width: min(ProjectSSHTab.listWidth, geo.size.width / 3))
                // A rule between the list and the sessions.
                Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 8).padding(.trailing, 9)
                // Every project's sessions in one row: a label two projects share says whose it is, and Ctrl+Tab steps
                // through them all.
                SSHSessionsPane(sessions: sessions.sessions, shown: sessions.active,
                                labels: sshSessionTabLabels(sessions.sessions.map(\.target), projects: projects.projects),
                                everyProject: true, select: { sessions.setActive($0) })
            }
            .frame(minHeight: 240)
        }
        .padding(.horizontal, Theme.paneMargin).padding(.vertical, 12)
    }
}
