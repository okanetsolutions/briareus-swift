// The Usage tab's model: the window and filters a reading is narrowed by, the `usage/all` payload (or each project's
// own month for a token without it) and the providers' quota, loaded through the Store.
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    /// The window is a preference, kept while the app runs; the filters are not, so a fresh visit shows everything.
    private static var period = 0
    private static var range: UsageRange?

    @Published var query = UsageQuery(period: UsageModel.period, range: UsageModel.range)
    /// Whether the custom range's day pickers are up.
    @Published var editingRange = false
    /// The `usage/all` payload on screen, and the query it answered: a pick shows the loader until its own answer lands.
    @Published private(set) var data: JSON?
    private var dataKey: String?
    /// What the pickers offer, from the last payload: the whole window's, never the pick's.
    @Published private(set) var options: JSON?
    /// Each project's own month, by repository, for a token without `usage/all`.
    @Published private(set) var perProject: [String: JSON] = [:]
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var generation = 0
    /// Every provider sessions start on (`GET /providers`), each account with its login and quota windows.
    @Published private(set) var providers: [JSON] = []
    @Published private(set) var providersError: String?
    @Published private(set) var providersLoading = false
    /// Whether the last read went past the server's cache, so only Check again says it is checking.
    @Published private(set) var providersFresh = false

    private var store: Store { Store.shared }
    /// Whether the token reads every project's ledger at once.
    var overall: Bool { store.supports("usage_all") }
    var available: Bool { overall || store.supports("usage") }

    init() { restore() }

    /// The payload drawn: the answer to the current window and picks, or the projects' months added up.
    var shown: JSON? {
        if overall { return data != nil && dataKey == query.key ? data : nil }
        let picked = query.picked(.project)
        let rows = ProjectsModel.shared.projects.compactMap { p -> (project: Project, usage: JSON)? in
            guard picked.isEmpty || picked.contains(p.repo), let u = perProject[p.repo] else { return nil }
            return (p, u)
        }
        return rows.isEmpty && perProject.isEmpty ? nil : PhoneUsage.combine(rows)
    }
    /// The picker's choices: the window's, or the projects this token reads.
    var pickerOptions: JSON {
        if overall { return options ?? .null }
        return ["projects": .array(ProjectsModel.shared.projects.map { ["key": .string($0.repo), "label": .string($0.title)] })]
    }
    var filters: [Usage.Filter] { overall ? Usage.Filter.allCases : [.project] }

    private func restore() {
        if overall {
            guard let key = query.cacheKey, let saved = store.cache.value(key), saved.isObject else { return }
            data = saved; dataKey = query.key
            if saved["options"].isObject { options = saved["options"] }
        } else {
            for p in ProjectsModel.shared.projects {
                if let saved = store.cache.value("usage:project:\(p.repo)"), saved.isObject { perProject[p.repo] = saved }
            }
        }
    }

    func load() async -> APIError? {
        guard available else { return nil }
        generation += 1
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            if overall { try await loadOverall(gen) } else { try await loadProjects(gen) }
            if gen == generation { error = nil }
            return nil
        } catch {
            guard gen == generation, !error.isCancellation else { return nil }
            self.error = errorText(error)
            return error as? APIError ?? APIError(.nonJSON)
        }
    }
    private func loadOverall(_ gen: Int) async throws {
        let args = query.args, key = query.key, cacheKey = query.anyPick ? nil : query.cacheKey
        let answer = try await store.call("usage_all", args, timeout: 60)
        guard gen == generation else { return }
        guard answer.isObject else { throw APIError(.nonJSON) }
        data = answer; dataKey = key
        if answer["options"].isObject { options = answer["options"] }
        if let cacheKey { store.cache.store(answer, cacheKey) }
    }
    /// Every project's month at once; a project that fails keeps what was read of it before, and its error is shown.
    private func loadProjects(_ gen: Int) async throws {
        if !ProjectsModel.shared.loaded || ProjectsModel.shared.projects.isEmpty { try await ProjectsModel.shared.load() }
        let repos = ProjectsModel.shared.projects.map(\.repo)
        var failure: Error?
        let answers = await withTaskGroup(of: (String, Result<JSON, Error>).self) { group in
            for repo in repos {
                group.addTask { @MainActor in
                    do { return (repo, .success(try await Store.shared.call("usage", ["repo": .string(repo)], timeout: 60))) }
                    catch { return (repo, .failure(error)) }
                }
            }
            var out: [(String, Result<JSON, Error>)] = []
            for await a in group { out.append(a) }
            return out
        }
        guard gen == generation else { return }
        var next = perProject.filter { repos.contains($0.key) }
        for (repo, result) in answers {
            switch result {
            case .success(let u) where u.isObject:
                next[repo] = u
                store.cache.store(u, "usage:project:\(repo)")
            case .success: failure = failure ?? APIError(.nonJSON)
            case .failure(let e): failure = failure ?? e
            }
        }
        perProject = next
        if let failure { throw failure }
    }

    /// The providers' accounts and quota; `fresh` reads them again past the server's cache, as Check again does.
    func loadProviders(fresh: Bool) async {
        guard store.supports("providers"), !providersLoading else { return }
        providersLoading = true; providersFresh = fresh
        defer { providersLoading = false }
        do {
            providers = ProviderQuota.providers(try await store.call("providers", fresh ? ["fresh": "1"] : [:], timeout: 60))
            providersError = nil
        } catch {
            if !error.isCancellation { providersError = errorText(error) }
        }
    }

    /// A new window or pick: straight to the loader, so the page never reads as the old pick's, and ask again.
    func repick() {
        error = nil
        if overall { Task { _ = await load() } }
    }
    /// A named period is read at once; the custom one asks for its days first, even when it is the window already.
    func setPeriod(_ p: Int) {
        if p == Usage.customPeriod { editingRange = true; return }
        guard p != query.period, Usage.periods.indices.contains(p) else { return }
        UsageModel.period = p
        query.setPeriod(p)
        repick()
    }
    func setRange(_ r: UsageRange) {
        editingRange = false
        UsageModel.period = Usage.customPeriod; UsageModel.range = r
        query.setPeriod(Usage.customPeriod, range: r)
        repick()
    }
    func choose(_ f: Usage.Filter, _ key: String?) {
        if let key { guard query.choose(f, key) else { return } }
        else { guard !query.picked(f).isEmpty else { return }; query.clear(f) }
        repick()
    }
    func clearFilters() { query.clearAll(); repick() }
    func pickRow(_ f: Usage.Filter, _ row: JSON) { query.only(f, Usage.rowKey(f, row)); repick() }
    /// The ledger knows a session's id, title and project; the conversation reads the rest itself.
    func topSession(_ r: JSON) -> (id: String, raw: JSON)? {
        guard let id = r["key"].nonEmpty else { return nil }
        var raw: JSON = ["id": .string(id), "status": "idle", "repo": .string(orNull: r["repo"].string)]
        if let label = r["label"].nonEmpty, label != id { raw["title"] = .string(label) }
        return (id, raw)
    }
}
