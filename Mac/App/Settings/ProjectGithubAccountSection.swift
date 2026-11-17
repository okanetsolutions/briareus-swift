// A project's GitHub account at the top of its settings' Project tab (ProjectSettingsScreen), read-only: which server
// identity reads GitHub for it and, for an Admin token, Check GitHub account, which lists the token, scopes, repositories
// and rate limits the check found. The check runs only on a click; nothing polls. The screen keeps this section for as
// long as the project's settings are open and it draws only on the Project tab, so its identity and last check stay
// across tab changes, as on the iPhone; another project, or a saved change of repository, starts it afresh.
import SwiftUI

struct ProjectGithubAccountSection: View {
    @StateObject private var model: ProjectGithubAccountModel
    /// Whether the Project tab is open; on any other tab the section draws nothing and keeps what it read.
    let shown: Bool

    init(repo: String, shown: Bool) {
        _model = StateObject(wrappedValue: ProjectGithubAccountModel(repo: repo))
        self.shown = shown
    }

    var body: some View {
        if shown && model.canRead {
            Card(radius: BriareusRadius.lg) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("GitHub account").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                        identity
                        Spacer()
                        if model.canCheck {
                            Button { model.check() } label: {
                                Label(model.checking ? "Checking…" : "Check GitHub account", systemImage: "stethoscope")
                            }
                            .dashButton(.bordered).disabled(model.checking)
                            .help("Check its token, scopes, repositories and rate limits against GitHub")
                        }
                    }
                    if let detail = model.identity?.detail {
                        Text(detail).font(Theme.footnote).foregroundStyle(Theme.muted)
                    }
                    if let error = model.checkError { Notice(message: error) }
                    if let health = model.health { GithubHealthResults(health: health) }
                }
            }
            .padding(.bottom, 16)
            .task { await model.load() }
        }
    }

    @ViewBuilder private var identity: some View {
        if let account = model.identity {
            GithubHealthLine(symbol: account.symbol, tone: account.tone, title: account.line)
        } else if let error = model.loadError {
            Notice(message: error)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// What a check found: its verdict, then its rows section by section.
private struct GithubHealthResults: View {
    let health: GithubAccountHealth

    var body: some View {
        let verdict = health.verdict
        VStack(alignment: .leading, spacing: 4) {
            GithubHealthLine(symbol: verdict.symbol, tone: verdict.tone, title: verdict.title).padding(.top, 4)
            ForEach(health.groups()) { group in
                SectionTitle(title: group.section.title)
                ForEach(group.rows) { row in
                    GithubHealthLine(symbol: row.symbol, tone: row.tone, title: row.title, value: row.value, detail: row.detail)
                }
            }
        }
    }
}
