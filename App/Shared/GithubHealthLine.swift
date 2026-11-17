// One line about a project's GitHub account or its check, on a phone: a toned symbol, what it is about and what was
// found. A project's settings draw its account and health check with it (ProjectGithubAccountSection), and a pull
// request draws the account that serves its project (PullGithubAccountSection).
import SwiftUI

/// One line of the account or its check: a toned symbol, what it is about, and what was found on the right.
struct GithubHealthLine: View {
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
