// The SSH servers page's left column: the search box, then a folder per project (Core's sshServerFolders) with its
// servers under it, drawn as the project tab draws them (RemoteServerRow). A folder's line folds it shut or opens it.
import SwiftUI

struct SSHServerFolderList: View {
    @ObservedObject var model: SSHServersModel
    var folders: [SSHServerFolder]
    @ObservedObject private var sessions = SSHSessions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search servers or projects", text: $model.query).dashField()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = model.error { Notice(message: error).padding(.bottom, 8) }
                    if !model.loaded {
                        LoadingNote(text: "Loading servers\u{2026}")
                    } else if folders.isEmpty && model.error == nil {
                        empty
                    }
                    ForEach(folders) { folder in
                        SSHServerFolderLine(title: folder.title ?? "No project", servers: folder.servers.count,
                                            live: sessions.sessions.contains { $0.group == folder.repo && $0.running },
                                            open: model.isOpen(folder.repo)) { model.toggle(folder.repo) }
                        if model.isOpen(folder.repo) {
                            ForEach(folder.servers.map { RemoteServer(row: $0) }) { server in
                                RemoteServerRow(glyph: 0xE7F4, server: server, sessions: sessions.count(for: server.key("ssh")),
                                                live: sessions.live(server.key("ssh"))) { model.connect(server, repo: folder.repo) }
                                    .padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
    }

    /// No servers registered at all, or none matching the search (with a way to clear it).
    @ViewBuilder private var empty: some View {
        if model.rows.isEmpty {
            Text("No SSH servers yet. Register one under \u{2699} Settings.")
                .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No servers match the search.").font(Theme.footnote).foregroundStyle(Theme.muted)
                Button("Clear search") { model.query = "" }.dashButton(.bordered)
            }
            .padding(.horizontal, 6)
        }
    }
}

/// A project's folder line: the disclosure chevron, the folder, the project's name, a dot while one of its sessions is
/// connected, and how many servers it holds.
private struct SSHServerFolderLine: View {
    var title: String
    var servers: Int
    var live: Bool
    var open: Bool
    var toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: Glyph.symbol(open ? 0xE70D : 0xE76C)).font(Theme.caption2).foregroundStyle(Theme.muted)
                    .frame(width: 12)
                Image(systemName: Glyph.symbol(0xE8B7)).font(Theme.caption).foregroundStyle(Theme.muted)
                Text(title).font(Theme.subheadlineSemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if live { StatusDot(status: "idle") }
                Text(verbatim: "\(servers)").font(Theme.caption).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BriareusRadius.md).fill(hovered ? Theme.raise : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        // The count and the dot are read out with the name, as the line shows them.
        .accessibilityLabel("\(title), \(servers == 1 ? "1 server" : "\(servers) servers")\(live ? ", connected" : "")")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}
