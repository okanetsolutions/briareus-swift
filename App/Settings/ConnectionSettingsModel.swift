// Connection settings intents keep token revocation and sign-out out of the section's drawing.
import SwiftUI

@MainActor
final class ConnectionSettingsModel: ObservableObject {
    @Published var confirm: ConnectionAction?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    enum ConnectionAction: Identifiable {
        case revoke, forget
        var id: Self { self }
    }
    private var store: Store { Store.shared }
    func run(_ action: ConnectionAction) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            // Named both ways: a token meant to be revoked must never be merely forgotten.
            do {
                switch action {
                case .revoke: try await store.revoke()
                case .forget: try store.forget()
                }
            } catch {
                self.error = failure(error)
            }
        }
    }

}
