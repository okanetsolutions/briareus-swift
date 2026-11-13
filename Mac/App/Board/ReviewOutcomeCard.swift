// What a pull request's code review amounts to, at the top of its Code reviews tab (the iPhone's ReviewOutcomeSection):
// the outcome and the rounds used, whether it is ready, stale or still to reach GitHub, why, and the security pass. The
// approvals the change's risk asks for follow in ReviewApprovalsCard. The words and tones are ReviewOutcomeLogic's.
import SwiftUI

struct ReviewOutcomeCard: View {
    var outcome: ReviewOutcome

    var body: some View {
        BoardBox(padding: 12, radius: BriareusRadius.lg) {
            HStack(spacing: 8) {
                Text("Review outcome").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                Badge(glyph: outcome.outcome.symbol, text: outcome.outcome.title, color: Theme.color(outcome.outcome.tone))
                Spacer(minLength: 8)
                if let rounds = outcome.rounds {
                    Text(rounds.line).font(Theme.caption).foregroundStyle(Theme.color(rounds.tone)).lineLimit(1)
                }
            }
            ForEach([outcome.readyNote, outcome.staleNote, outcome.statusNote].compactMap { $0 }, id: \.self) { note in
                Text(note).font(Theme.footnote).foregroundStyle(Theme.muted).padding(.top, 6)
            }
            if !outcome.listedReasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outcome.listedReasons) { reason in
                        Text(reason.message).font(Theme.footnote).textSelection(.enabled)
                            .foregroundStyle(reason.isNote ? Theme.muted : Theme.color(reason.tone))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            }
            ReviewOutcomeFacts(outcome: outcome)
        }
    }
}

/// The security pass with its own reasons, when the project asks for it.
private struct ReviewOutcomeFacts: View {
    var outcome: ReviewOutcome

    var body: some View {
        if let security = outcome.security, security.shown {
            fact("Security", security.line, Theme.color(security.tone))
            ForEach(security.listedReasons) { reason in
                Text(reason.message).font(Theme.footnote).padding(.top, 2)
                    .foregroundStyle(reason.isNote ? Theme.muted : Theme.color(reason.tone))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fact(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
            Text(value).font(Theme.footnote).foregroundStyle(color)
        }
        .padding(.top, 8)
    }
}
