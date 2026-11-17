// The GitHub accounts the settings sidebar lists (core #317), read with the other settings lists and again whenever a form
// saves or deletes one. The form also reads it to mark the projects another account already serves. Kept apart from
// SettingsModel, as the mail settings are, so that file does not grow.
import Foundation

@MainActor
final class GithubAccountsModel: ObservableObject {
    static let shared = GithubAccountsModel()

    /// The accounts as the server lists them (no defaults: a new account starts empty), and how the last read went.
    @Published private(set) var section = SettingsModel.Section()
    private let reader = SettingsListReader()

    private init() {
        NotificationCenter.default.addObserver(forName: .githubAccountsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in GithubAccountsModel.shared.load() }
        }
    }

    func load() {
        reader.read("settings_github_accounts", "accounts", update: { [weak self] change in if let self { change(&self.section) } })
    }

    /// The settings page opening: what an earlier connection read goes, and the section shows it is loading.
    func reset() { reader.cancelAll(); section = SettingsModel.Section() }

    func open(_ row: JSON) { Navigator.shared.show(.githubAccountSettings(row: row)) }
    func new() { Navigator.shared.show(.githubAccountSettings(row: nil)) }
}
