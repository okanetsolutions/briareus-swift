// What waits on your ruling, for the Status tab (the Mac's ◉ Status reads the same items from its AttentionModel): the
// SSH commands and Slack messages agents asked to run or send, and the pull requests waiting on a person's approval,
// from the server's attention inbox (core /attention), read with the projects' load. An agent's request is decided here
// (StatusAgentApprovals); a pull request is read out and approved in place by StatusReviewApprovals. Signing out clears
// them, as the Mac's inbox does, so another server never shows this one's requests.
import Combine
import Foundation

@MainActor
final class StatusApprovalsModel: ObservableObject {
    static let shared = StatusApprovalsModel()
    @Published private(set) var items: [AttentionItem] = []
    @Published private(set) var error: String?
    /// The requests a decision is on its way for, and what each came back with.
    @Published private(set) var deciding: Set<String> = []
    @Published private(set) var results: [String: String] = [:]

    /// Bumped by a reset, so a read or decision that began before it is dropped.
    private var generation = 0
    private var signOut: AnyCancellable?

    private init() {
        // Signing out (or a revoked token) takes what the last server was waiting on with it.
        signOut = Store.shared.$client.map { $0 != nil }.removeDuplicates().dropFirst().sink { connected in
            guard !connected else { return }
            MainActor.assumeIsolated { StatusApprovalsModel.shared.reset() }
        }
    }

    /// The inbox is an admin's, on a server that keeps one.
    private var offered: Bool { Store.shared.isAdmin && Store.shared.supports("attention") }

    /// The agents' requests, then the pull requests, each in the server's order.
    var agentRequests: [AttentionItem] { items.filter(\.isApproval) }
    var pulls: [AttentionItem] { items.filter { $0.approvalPull != nil } }

    /// This token may rule on `item` on this server.
    func canDecide(_ item: AttentionItem) -> Bool {
        guard let op = item.decisionOperation else { return false }
        return Store.shared.supports(op) && item.requestID != nil
    }

    private func reset() {
        generation += 1
        items = []; error = nil; deciding = []; results = [:]
    }

    /// Reads the inbox again; a token that may not see it (or a server without it) leaves nothing standing.
    func load() async {
        guard offered else {
            if !items.isEmpty || error != nil || !results.isEmpty || !deciding.isEmpty { reset() }
            return
        }
        let mine = generation
        do {
            let answer = try await Store.shared.call("attention")
            guard mine == generation else { return }
            let kept = AttentionItem.statusApprovals(AttentionItem.parse(answer))
            if kept != items { items = kept }
            error = nil
        } catch {
            guard mine == generation else { return }
            if let said = failure(error) { self.error = said }
        }
    }

    /// Approves (the command runs, the message goes out) or denies an agent's request, then reads the inbox again. The
    /// view asks first where `confirmsFirst(approve:)` says so.
    func decide(_ item: AttentionItem, approve: Bool) {
        guard canDecide(item), let op = item.decisionOperation, let args = item.decisionArguments(approve: approve),
              !deciding.contains(item.id) else { return }
        deciding.insert(item.id)
        let mine = generation
        Task {
            let said: String
            do {
                said = AttentionItem.decisionResult(try await Store.shared.call(op, args), approve: approve)
            } catch {
                said = failure(error) ?? ""
            }
            guard mine == generation else { return }
            deciding.remove(item.id)
            if !said.isEmpty { results[item.id] = said }
            await load()
        }
    }
}
