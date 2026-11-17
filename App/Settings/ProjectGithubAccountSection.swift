// A project's GitHub account in its settings (ProjectSettingsScreen's Project tab), read-only: which server identity reads
// GitHub for it and, for an Admin token, Check GitHub account, which lists the token, scopes, repositories and rate limits
// the check found. The check runs only on a tap; nothing polls and nothing is kept once the screen goes.
import SwiftUI

struct ProjectGithubAccountSection: View {
    @StateObject private var model: ProjectGithubAccountModel

    init(repo: String) { _model = StateObject(wrappedValue: ProjectGithubAccountModel(repo: repo)) }

    var body: some View {
        if model.canRead {
            Group {
                Section {
                    identity
                    if model.canCheck { checkButton }
                    if let error = model.checkError { ErrorNotice(message: error) }
                } header: {
                    Text("GitHub account")
                }
                .listRowBackground(Theme.row)
                .task { await model.load() }
                if let health = model.health { GithubHealthResults(health: health) }
            }
        }
    }

    @ViewBuilder private var identity: some View {
        if let account = model.identity {
            GithubHealthLine(symbol: account.symbol, tone: account.tone, title: account.line, detail: account.detail)
        } else if let error = model.loadError {
            ErrorNotice(message: error)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Reading the account…").foregroundStyle(.secondary)
            }
        }
    }

    private var checkButton: some View {
        Button { model.check() } label: {
            HStack {
                Label(model.checking ? "Checking…" : "Check GitHub account", systemImage: "stethoscope")
                if model.checking { Spacer(); ProgressView() }
            }
        }
        .disabled(model.checking)
    }
}

/// What a check found: its verdict, then its rows section by section.
private struct GithubHealthResults: View {
    let health: GithubAccountHealth

    var body: some View {
        let verdict = health.verdict
        Section {
            GithubHealthLine(symbol: verdict.symbol, tone: verdict.tone, title: verdict.title)
        }
        .listRowBackground(Theme.row)
        ForEach(health.groups()) { group in
            Section {
                ForEach(group.rows) { row in
                    GithubHealthLine(symbol: row.symbol, tone: row.tone, title: row.title, value: row.value, detail: row.detail)
                }
            } header: {
                Text(group.section.title)
            }
            .listRowBackground(Theme.row)
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.color(tone)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.ink).textSelection(.enabled)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            if let value {
                Spacer(minLength: 8)
                Text(value).foregroundStyle(Theme.color(tone)).multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
