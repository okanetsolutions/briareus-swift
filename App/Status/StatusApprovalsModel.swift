// The pull requests waiting on a person's approval, for the Status tab (the Mac's ◉ Status reads the same items from its
// AttentionModel): the `review-approval` items of the server's attention inbox (core /attention), read with the
// projects' load. Each is read out and approved in place by StatusReviewApprovals. Signing out clears them, as the
// Mac's inbox does, so another server never shows this one's pull requests.
import Combine
import Foundation

@MainActor
final class StatusApprovalsModel: ObservableObject {
    static let shared = StatusApprovalsModel()
    @Published private(set) var items: [AttentionItem] = []
    @Published private(set) var error: String?

    /// Bumped by a reset, so a read that began before it is dropped.
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

    private func reset() {
        generation += 1
        items = []; error = nil
    }

    /// Reads the inbox again; a token that may not see it (or a server without it) leaves nothing standing.
    func load() async {
        guard offered else {
            if !items.isEmpty || error != nil { reset() }
            return
        }
        let mine = generation
        do {
            let answer = try await Store.shared.call("attention")
            guard mine == generation else { return }
            let pulls = AttentionItem.approvalPulls(AttentionItem.parse(answer))
            if pulls != items { items = pulls }
            error = nil
        } catch {
            guard mine == generation else { return }
            if let said = failure(error) { self.error = said }
        }
    }
}
