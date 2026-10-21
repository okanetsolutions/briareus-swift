// The SSH servers page's state: every SSH server registered in Settings (read through settings_ssh_servers), the search
// over them and the project folders folded shut. Kept while the app runs, so going back to the page keeps what it showed
// while the servers are read again.
import Combine
import Foundation

@MainActor
final class SSHServersModel: ObservableObject {
    static let shared = SSHServersModel()

    /// The servers as Settings has them, every project's.
    @Published private(set) var rows: [JSON] = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    /// What the search box holds.
    @Published var query = ""
    /// The projects whose folders are folded shut, by repository ("" for the servers with no project).
    @Published private(set) var folded: Set<String> = []
    private var task: Task<Void, Never>?
    /// Which read is the latest: an older one's answer, arriving after ⟳ started another, is dropped.
    private var generation = 0
    private var serversWatch: NSObjectProtocol?
    private var signOut: AnyCancellable?

    private init() {
        // The servers changed in Settings: the page reads them again once it has read them or is reading them (a read
        // under way may answer with the list from before the change, so it is dropped for a new one).
        serversWatch = NotificationCenter.default.addObserver(forName: .sshServersChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let model = SSHServersModel.shared
                if model.loaded || model.task != nil { model.refresh() }
            }
        }
        // Signing out (or a revoked token): the servers read from that server go with it.
        signOut = Store.shared.$client.map { $0 != nil }.removeDuplicates().dropFirst().sink { connected in
            guard !connected else { return }
            MainActor.assumeIsolated { SSHServersModel.shared.reset() }
        }
    }

    private func reset() {
        generation += 1
        task?.cancel(); task = nil
        rows = []
        loaded = false
        error = nil
        query = ""
        folded = []
    }

    /// The folders to show, in the sidebar's project order, kept to the search.
    func folders(projects: [Project]) -> [SSHServerFolder] { sshServerFolders(rows, projects: projects, query: query) }

    /// The page came on show: the servers are read, or read again behind what it shows.
    func revisit() { if task == nil { read() } }

    /// ⟳: the servers read again, the one under way dropped.
    func refresh() {
        task?.cancel(); task = nil
        read()
    }

    /// Whether a project's folder shows its servers (Core's sshServerFolderOpen).
    func isOpen(_ repo: String) -> Bool { sshServerFolderOpen(repo, folded: folded, query: query) }

    /// Folds a project's folder shut, or opens it; nothing while searching (Core's sshServerFolderToggled).
    func toggle(_ repo: String) { folded = sshServerFolderToggled(repo, folded: folded, query: query) }

    /// A click on a server: an SSH session to it under its project, or the one open to it on show.
    func connect(_ server: RemoteServer, repo: String) { SSHSessions.shared.connect(server, group: repo) }

    private func read() {
        guard RemoteRegistry.offered else { loaded = true; return }
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            let result: Result<JSON, Error>
            do { result = .success(try await Store.shared.call("settings_ssh_servers")) } catch { result = .failure(error) }
            guard let self, self.generation == mine else { return }
            self.task = nil
            switch result {
            case .success(let answer):
                self.error = nil
                self.rows = answer["servers"].items
            case .failure(let error):
                if error.isCancellation { return }
                self.error = errorText(error)
            }
            self.loaded = true
        }
    }
}
