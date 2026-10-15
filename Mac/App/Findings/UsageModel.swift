// The 📊 Usage screen's model: the window and filters a reading is narrowed by and the `usage/all` payload that answers
// them, kept while Usage is on the stack.
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    /// The window is a preference, kept while the app runs; the filters are not, so a fresh visit shows everything.
    private static var period = 0
    private static var range: UsageRange?

    @Published var query = UsageQuery(period: UsageModel.period, range: UsageModel.range)
    /// The payload on screen, and the query it answered: a pick shows the loader until its own answer lands.
    @Published private(set) var data: JSON?
    private var dataKey: String?
    /// What the pickers offer, from the last payload: the whole window's, never the pick's.
    @Published private(set) var options: JSON?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var task: Task<APIError?, Never>?
    private var generation = 0

    init() { restore() }

    /// The screen's model while Usage is on the stack, so the picks survive a session opened from it.
    private static let keeper = FDKit.Keeper<UsageModel>(.usage)
    static func kept() -> UsageModel { keeper.obtain(UsageModel.init) { $0.stop() } }

    /// The payload drawn: only the one that answered the current window and picks.
    var shown: JSON? { data != nil && dataKey == query.key ? data : nil }

    private func restore() {
        guard let key = query.cacheKey, let saved = Store.shared.cache.value(key), saved.isObject else { return }
        data = saved; dataKey = query.key
        if saved["options"].isObject { options = saved["options"] }
    }

    @discardableResult
    func load() -> Task<APIError?, Never>? {
        task?.cancel(); task = nil
        generation += 1
        guard Store.shared.supports("usage_all") else { loading = false; return nil }
        let gen = generation, args = query.args, key = query.key, cacheKey = query.anyPick ? nil : query.cacheKey
        loading = true
        let t = Task { [weak self] () -> APIError? in
            guard let self else { return nil }
            var failure: APIError?
            do {
                let answer = try await Store.shared.call("usage_all", args, timeout: 60)
                guard gen == self.generation else { return nil }
                guard answer.isObject else { throw APIError(.nonJSON) }
                self.data = answer; self.dataKey = key
                if answer["options"].isObject { self.options = answer["options"] }
                if let cacheKey { Store.shared.cache.store(answer, cacheKey) }
                self.error = nil
            } catch {
                guard gen == self.generation, !error.isCancellation else { return nil }
                self.error = errorText(error)
                failure = error as? APIError ?? APIError(.nonJSON)
            }
            self.loading = false
            self.task = nil
            return failure
        }
        task = t
        return t
    }
    /// A poll's tick: a read under way answers it.
    func tick() async -> APIError? {
        if task != nil { return nil }
        return await load()?.value
    }
    func stop() { task?.cancel(); task = nil; generation += 1; loading = false }

    /// A new window or pick: straight to the loader, so the page never reads as the old pick's, and ask again.
    func repick() { error = nil; load() }

    func pickPeriod() {
        let items = Usage.periods.enumerated().map { FDKit.Menu.Item(title: $0.element.label, checked: $0.offset == query.period) }
        guard let chosen = FDKit.Menu.show(items, rightAligned: true) else { return }
        // The custom period asks for its days, even when it is the window already.
        if chosen == Usage.customPeriod { pickRange(); return }
        guard chosen != query.period else { return }
        UsageModel.period = chosen
        query.setPeriod(chosen)
        repick()
    }
    private func pickRange() {
        let start = (query.range ?? .lastWeek()).dates() ?? (Date(), Date())
        guard let (a, b) = Dialogs.dateRange("Custom range", from: start.from, to: start.to) else { return }
        guard let r = UsageRange.make(a, b) else {
            Dialogs.alert("Choose a shorter range", "Usage is read over at most \(UsageRange.maxDays) days at once.")
            return
        }
        UsageModel.period = Usage.customPeriod; UsageModel.range = r
        query.setPeriod(Usage.customPeriod, range: r)
        repick()
    }
    /// One picker's menu: All, then the window's options. The project and model pickers tick several; the others take one.
    func pickFilter(_ f: Usage.Filter) {
        let menuCap = 60   // the window's sessions can run to thousands
        let list = (options ?? .null)[f.options].items
        let listed = min(list.count, menuCap)
        var items = [FDKit.Menu.Item(title: "All \(f.plural)", checked: query.picked(f).isEmpty)]
        if !list.isEmpty { items.append(.separatorItem) }
        let first = items.count
        for o in list.prefix(listed) {
            items.append(.init(title: Usage.optionLabel(f, o), checked: query.isPicked(f, Usage.optionKey(o))))
        }
        if listed < list.count { items.append(.init(title: "\(list.count - listed) more \(f.plural); a shorter window lists them", enabled: false)) }
        if list.isEmpty { items.append(.init(title: "No usage in this period", enabled: false)) }
        guard let chosen = FDKit.Menu.show(items) else { return }
        if chosen == 0 {
            if query.picked(f).isEmpty { return }
            query.clear(f)
        } else if chosen >= first && chosen - first < listed {
            if !query.choose(f, Usage.optionKey(list[chosen - first])) { return }
        } else { return }
        repick()
    }
    func clearFilters() { query.clearAll(); repick() }
    func pickRow(_ f: Usage.Filter, _ row: JSON) { query.only(f, Usage.rowKey(f, row)); repick() }
    func openTopSession(_ r: JSON) {
        guard let id = r["key"].nonEmpty else { return }
        // The ledger knows the id, title and project; the conversation reads the rest itself.
        var raw: JSON = ["id": .string(id), "status": "idle", "repo": .string(orNull: r["repo"].string)]
        if let label = r["label"].nonEmpty, label != id { raw["title"] = .string(label) }
        Navigator.shared.push(.conversation(id: id, session: raw))
    }
}
