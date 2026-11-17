// One line about a project's GitHub account or its check, on the Mac: a toned symbol, what it is about and what was
// found. A project's settings draw its account and health check with it (ProjectGithubAccountSection), and the board and a
// pull request's sidebar draw the account that serves the project (GithubAccountItem).
import SwiftUI

/// One line of the account or its check: a toned symbol, what it is about, and what was found on the right.
struct GithubHealthLine: View {
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
