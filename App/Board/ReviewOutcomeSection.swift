// What a pull request's code review amounts to, at the top of its Code reviews tab (the Mac's ReviewOutcomeCard): the
// outcome and the rounds used, whether it is ready, stale or still to reach GitHub, why, and the security pass and the
// approvals the change's risk asks for. The words and tones are ReviewOutcomeLogic's.
import SwiftUI

struct ReviewOutcomeSection: View {
    let outcome: ReviewOutcome

    var body: some View {
        Section {
            HStack(spacing: 8) {
                BoardBadge(text: outcome.outcome.title, systemImage: outcome.outcome.symbol, color: Theme.color(outcome.outcome.tone))
                Spacer(minLength: 8)
                if let rounds = outcome.rounds {
                    Text(rounds.line).font(.caption).foregroundStyle(Theme.color(rounds.tone))
                }
            }
            .accessibilityElement(children: .combine)
            ForEach([outcome.readyNote, outcome.staleNote, outcome.statusNote].compactMap { $0 }, id: \.self) { note in
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(outcome.listedReasons) { reason in
                Text(reason.message).font(.footnote).foregroundStyle(reason.isNote ? .secondary : Theme.color(reason.tone))
            }
            if let security = outcome.security, security.shown {
                LabeledContent("Security") { Text(security.line).foregroundStyle(Theme.color(security.tone)) }
            }
            if let approvals = outcome.approvals, approvals.shown {
                LabeledContent("Approvals") { Text(approvals.line).foregroundStyle(Theme.color(approvals.tone)) }
                if let explanation = approvals.explanation { Text(explanation).font(.footnote).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Review outcome")
        }
        .listRowBackground(Theme.row)
    }
}
