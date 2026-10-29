// What is waiting for you and what is working, across every project: each conversation's state as the overview reads it,
// the counts of those needing you, working and ready, and the question an agent left waiting. Top-level conversations
// only; an orchestrator's workers (with a `parentId`) count under it. No UI here.
import Foundation

/// Where a conversation stands for its user, as Quest's status panel reads it.
enum SessionState: String, Equatable, Sendable {
    /// Idle, its agent waiting for an answer to a question.
    case waiting
    /// A turn is queued, preparing or running.
    case working
    /// Idle with nothing asked: done with its turn.
    case ready
    case failed
    case closed

    var label: String {
        switch self {
        case .waiting: return "Needs your answer"
        case .working: return "Working"
        case .ready: return "Ready"
        case .failed: return "Failed"
        case .closed: return "Closed"
        }
    }
    /// It waits on its user's answer.
    var needsYou: Bool { self == .waiting }
}

extension Session {
    /// The orchestrator a worker belongs to; nil for a conversation of its own.
    var parentId: String? { raw["parentId"].nonEmpty }
    var awaitingAnswer: Bool { raw["awaitingAnswer"].is(true) }

    var state: SessionState {
        if status == "idle" && awaitingAnswer { return .waiting }
        if isActive { return .working }
        if status == "idle" { return .ready }
        if status == "failed" { return .failed }
        return .closed
    }
}

/// The counts and lists of the overview, from every session the app holds.
struct SessionOverview: Equatable, Sendable {
    /// Waiting for an answer or a decision, the longest-waiting first.
    var needingYou: [Session]
    /// Working now, by title.
    var working: [Session]
    /// Idle and done with their turn.
    var ready: Int

    init(_ sessions: [Session]) {
        let top = sessions.filter { $0.parentId == nil }
        // Since the turn that asked ended (or the conversation began), oldest first; equal times keep the list's order.
        func since(_ s: Session) -> Int { boardDateEpoch(s.raw["endedAt"].string) ?? boardDateEpoch(s.raw["createdAt"].string) ?? 0 }
        needingYou = top.enumerated().filter { $0.element.state.needsYou }
            .sorted { since($0.element) != since($1.element) ? since($0.element) < since($1.element) : $0.offset < $1.offset }
            .map(\.element)
        working = top.filter(\.isActive)
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        ready = top.filter { $0.state == .ready }.count
    }

    var needsYouCount: Int { needingYou.count }
    var workingCount: Int { working.count }
    /// Nothing is running and nothing waits.
    var quiet: Bool { needingYou.isEmpty && working.isEmpty }
}

/// The question an agent left, with the answers it offered.
struct PendingQuestion: Equatable, Sendable {
    var text: String
    var options: [String]
}

extension Transcript {
    /// The last question the agent asked, while no message has answered it since; nil otherwise.
    var pendingQuestion: PendingQuestion? {
        guard let i = events.lastIndex(where: { $0.kind == "ask" }),
              !events[(i + 1)...].contains(where: { $0.kind == "user" }) else { return nil }
        let ask = events[i]
        let options = (ask.options?.items ?? []).compactMap { $0["label"].nonEmpty }
        return PendingQuestion(text: ask.question ?? ask.text ?? "", options: options)
    }
}
