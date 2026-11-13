// The pull requests waiting on a person's approval, for the Status tab (the Mac's ◉ Status reads the same items from its
// AttentionModel): the `review-approval` items of the server's attention inbox (core /attention), read with the
// projects' poll. Each is read out and approved in place by StatusReviewApprovals.
import Foundation

@MainActor
final class StatusApprovalsModel: ObservableObject {
    static let shared = StatusApprovalsModel()
    @Published private(set) var items: [AttentionItem] = []
    @Published private(set) var error: String?

    /// The inbox is an admin's, on a server that keeps one.
    private var offered: Bool { Store.shared.isAdmin && Store.shared.supports("attention") }

    /// Reads the inbox again; a token that may not see it (or a server without it) leaves nothing standing.
    func load() async {
        guard offered else {
            if !items.isEmpty || error != nil { items = []; error = nil }
            return
        }
        do {
            let pulls = AttentionItem.approvalPulls(AttentionItem.parse(try await Store.shared.call("attention")))
            if pulls != items { items = pulls }
            error = nil
        } catch {
            if let said = failure(error) { self.error = said }
        }
    }
}
