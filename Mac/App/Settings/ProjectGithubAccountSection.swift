// A project's GitHub account at the top of its settings' Project tab (ProjectSettingsScreen), read-only: which server
// identity reads GitHub for it and, for an Admin token, Check GitHub account, which lists the token, scopes, repositories
// and rate limits the check found. The check runs only on a click; nothing polls and nothing is kept once the tab goes.
import SwiftUI

struct ProjectGithubAccountSection: View {
    @StateObject private var model: ProjectGithubAccountModel

    init(repo: String) { _model = StateObject(wrappedValue: ProjectGithubAccountModel(repo: repo)) }

    var body: some View {
        if model.canRead {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("GitHub account").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                    identity
                    Spacer()
                    if model.canCheck {
                        Button(model.checking ? "Checking…" : "Check GitHub account") { model.check() }
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
            .padding(12)
            .background(RoundedRectangle(cornerRadius: BriareusRadius.lg).fill(Theme.raise))
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

/// One line of the account or its check: a toned symbol, what it is about, and what was found on the right.
private struct GithubHealthLine: View {
    var symbol: String
    var tone: RowTone
    var title: String
    var value: String?
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Theme.color(tone)).accessibilityHidden(true)
            Text(title).foregroundStyle(Theme.ink).lineLimit(1).textSelection(.enabled)
            if let detail { Text(detail).foregroundStyle(Theme.muted).lineLimit(1) }
            if let value {
                Spacer(minLength: 8)
                Text(value).foregroundStyle(Theme.color(tone)).multilineTextAlignment(.trailing)
            }
        }
        .font(Theme.footnote)
        .accessibilityElement(children: .combine)
    }
}
