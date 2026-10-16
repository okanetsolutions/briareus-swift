// A session's ⚡ Webhook form as both apps' screens draw it: its three switches, the two caps with their ranges and
// defaults, what the server's Webhook record fills them with, and the body Save sends to PUT /sessions/{id}/webhook.
import Foundation

/// The two caps, each a whole number in its range. `maxTurns` 0 lets deliveries start turns without limit.
enum WebhookField: String, CaseIterable, Hashable, Sendable {
    case perHour, maxTurns

    /// The key it is read and sent under.
    var key: String { rawValue }
    var label: String { self == .perHour ? "Deliveries an hour" : "Turns in a row" }
    var hint: String {
        self == .perHour ? "Past it a sender is answered 429 with Retry-After. From 1 to 600."
            : "Turns deliveries may start with no word from you; past it the webhook pauses until you say anything in the conversation (or save this form). From 0 to 1000; 0 means no limit."
    }
    var range: ClosedRange<Int> { self == .perHour ? 1...600 : 0...1000 }
    /// The server's default, for a record that lacks the cap.
    var fallback: Int { self == .perHour ? 30 : 10 }
    /// Why a value outside `range` is refused.
    var invalid: String { "\(label) must be a whole number from \(range.lowerBound) to \(range.upperBound)." }

    func def(_ kind: SettingsFieldKind) -> SettingsField { SettingsField(key: key, kind: kind, label: label, hint: hint) }

    /// The text the form opens with for a Webhook record.
    func text(_ hook: JSON) -> String { String(hook[key].int ?? fallback) }
}

/// The three switches, by the key they are read and sent under.
enum WebhookToggle: String, CaseIterable, Hashable, Sendable {
    case armed, instructions, sshUnattended
}

/// What Save sends, or the first cap that cannot be sent.
enum WebhookSave: Equatable, Sendable {
    case body(JSON)
    case invalid(WebhookField)
}

/// The PUT body from the switches and the caps as typed; a switch not given is sent off.
func webhookSave(switches: [WebhookToggle: Bool], caps: [WebhookField: String]) -> WebhookSave {
    var body: JSON = [:]
    for t in WebhookToggle.allCases { body[t.rawValue] = .bool(switches[t] ?? false) }
    for f in WebhookField.allCases {
        guard let n = Int((caps[f] ?? "").cTrimmed), f.range.contains(n) else { return .invalid(f) }
        body[f.key] = JSON(n)
    }
    return .body(body)
}
