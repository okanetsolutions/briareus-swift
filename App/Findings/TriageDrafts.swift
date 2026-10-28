// A review round held on a conversation, as a card: each finding with its severity, place and words, a verdict and a
// comment on the user's own pull request (Reply and Delete on somebody else's), a note for the fix session, Save comments
// and Complete. The Findings tab shows it in a sheet and the conversation inline; both share what was typed.
import SwiftUI

/// What was picked and typed on a round's card before it was sent, kept while the app runs so a card closed and opened
/// again (or seen from the conversation and from the Findings tab) shows the same; and the lines a completion leaves once
/// its card is gone.
@MainActor
final class TriageDrafts: ObservableObject {
    static let shared = TriageDrafts()

    struct Round: Equatable {
        var picked: [String: String] = [:]
        var reasons: [String: String] = [:]
        var note: String?
    }
    /// What a completion came back with, for the Findings tab once the card is gone.
    struct Outcome: Identifiable, Equatable {
        var id = UUID()
        var sessionID: String
        var title: String
        var text: String
        var danger: Bool
    }

    @Published private var rounds: [String: Round] = [:]
    @Published var outcomes: [Outcome] = []

    static func key(_ session: Session, _ triage: JSON) -> String { "\(session.id)#\(triage["round"].truncatedInt ?? 0)" }
    func round(_ key: String) -> Round { rounds[key] ?? Round() }
    func update(_ key: String, _ change: (inout Round) -> Void) {
        var r = round(key)
        change(&r)
        rounds[key] = r
    }
    func drop(_ key: String) { rounds[key] = nil }
    func report(_ outcome: Outcome) {
        outcomes.removeAll { $0.sessionID == outcome.sessionID }
        outcomes.append(outcome)
    }
}

/// A finding's severity pill colour: CRIT and HIGH red, MED amber, LOW grey.
func triageSeverityColor(_ severity: String?) -> Color {
    switch findingSeverityLabel(severity) {
    case "CRIT", "HIGH": return Theme.danger
    case "LOW": return .secondary
    default: return Theme.warn
    }
}
