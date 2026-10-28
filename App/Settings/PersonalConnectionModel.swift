// Owns one personal connection form; secret input is cleared after writes and on leaving the screen.
import Foundation
import Combine

@MainActor
final class PersonalConnectionModel: ObservableObject {
    let kind: PersonalConnectionKind
    @Published var token = ""
    @Published var url = ""
    @Published private(set) var status: PersonalConnectionStatus?
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?
    init(kind: PersonalConnectionKind) { self.kind = kind }
    var available: Bool { Store.shared.supports(kind.read) }
    var canConnect: Bool { Store.shared.supports(kind.connect) }
    var canDisconnect: Bool { status?.connected == true && Store.shared.supports(kind.disconnect) }
    var dirty: Bool { !token.isEmpty || (status != nil && url != status?.url) }
    var canSave: Bool { status != nil && !token.cTrimmed.isEmpty && canConnect && !busy && !uncertain }

    func load() async {
        guard available, !busy else { loaded = true; return }
        busy = true
        defer { busy = false }
        do {
            let answer = try await Store.shared.call(kind.read)
            guard let status = PersonalConnectionStatus(answer) else { throw APIError(.nonJSON) }
            let wasDirty = dirty
            self.status = status
            if !wasDirty { url = status.url }
            error = nil
        } catch {
            if !error.isCancellation { self.error = errorText(error) }
        }
        loaded = true
    }
    func save() {
        guard canSave else { return }
        do { write(kind.connect, body: try kind.body(token: token, url: url)) }
        catch { self.error = errorText(error) }
    }
    func disconnect() {
        guard canDisconnect, !busy, !uncertain else { return }
        write(kind.disconnect)
    }
    private func write(_ operation: String, body: JSON = [:]) {
        busy = true; error = nil
        Task {
            defer { busy = false; token = "" }
            do {
                let answer = try await Store.shared.call(operation, body)
                guard let status = PersonalConnectionStatus(answer) else { throw APIError(.nonJSON) }
                self.status = status; url = status.url
            } catch {
                uncertain = !((error as? APIError)?.isRefusal ?? false)
                if !error.isCancellation { self.error = errorText(error) }
            }
        }
    }
    func discard() { token = ""; url = status?.url ?? "" }
    func checkOutcome() { uncertain = false; Task { await load() } }
}
