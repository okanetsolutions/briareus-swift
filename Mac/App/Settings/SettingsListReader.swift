// How the settings page reads one of its lists (the projects, providers, servers and accounts the sidebar shows): a new
// read of a list cancels the one before it, a list the connection cannot read counts as read, and a failed read keeps the
// rows it had and says why. SettingsModel and GithubAccountsModel both read their lists through it.
import Foundation

@MainActor
final class SettingsListReader {
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Every read on its way stops, as the settings page opening again reads everything afresh.
    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }

    /// Reads `call`'s `listKey` list into the section `update` hands its change to; `done` runs after a good read.
    func read(_ call: String, _ listKey: String,
              update: @escaping @MainActor ((inout SettingsModel.Section) -> Void) -> Void,
              done: @escaping @MainActor () -> Void = {}) {
        tasks[call]?.cancel()
        guard Store.shared.supports(call) else { update { $0.loaded = true }; return }
        tasks[call] = Task {
            do {
                let r = try await Store.shared.call(call)
                guard !Task.isCancelled else { return }
                update { $0 = SettingsModel.Section(list: r[listKey].items, defaults: r["defaults"], loaded: true, error: nil) }
                done()
            } catch {
                guard !error.isCancellation else { return }
                update { $0.loaded = true; $0.error = errorText(error) }
            }
        }
    }
}
