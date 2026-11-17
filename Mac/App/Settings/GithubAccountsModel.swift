// The GitHub accounts the settings sidebar lists (core #317), read with the other settings lists and again whenever a form
// saves or deletes one. The form also reads it to mark the projects another account already serves. Kept apart from
// SettingsModel, as the mail settings are, so that file does not grow.
import Foundation

@MainActor
final class GithubAccountsModel: ObservableObject {
    static let shared = GithubAccountsModel()

    /// The accounts as the server lists them (no defaults: a new account starts empty), and how the last read went.
    @Published private(set) var section = SettingsModel.Section()
    private var task: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(forName: .githubAccountsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in GithubAccountsModel.shared.load() }
        }
    }

    func load() {
        task?.cancel()
        guard Store.shared.supports("settings_github_accounts") else { section = SettingsModel.Section(loaded: true); return }
        task = Task { [weak self] in
            do {
                let r = try await Store.shared.call("settings_github_accounts")
                guard let self, !Task.isCancelled else { return }
                self.section = SettingsModel.Section(list: r["accounts"].items, loaded: true)
            } catch {
                guard let self, !error.isCancellation else { return }
                self.section.loaded = true
                self.section.error = errorText(error)
            }
        }
    }

    /// The settings page opening: what an earlier connection read goes, and the section shows it is loading.
    func reset() { task?.cancel(); section = SettingsModel.Section() }

    func open(_ row: JSON) { Navigator.shared.show(.githubAccountSettings(row: row)) }
    func new() { Navigator.shared.show(.githubAccountSettings(row: nil)) }
}
