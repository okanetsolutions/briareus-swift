// The users and grants for one resource. Selection stays locked while a membership edit is unsaved.
import Foundation
import Combine

@MainActor
final class SharingModel: ObservableObject {
    @Published var kind: ShareKind = .project
    @Published var resourceID = ""
    @Published private(set) var resources: [ShareResource] = []
    @Published private(set) var users: [SharingUser] = []
    @Published private var form = SharingFormState()
    var picked: Set<Int> { form.picked }
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?
    private var shares: JSON = []
    init() { kind = ShareKind.allCases.first { Store.shared.supports($0.operation) } ?? .project }
    var available: Bool { Store.shared.supports("shares") && Store.shared.supports("users") && !kinds.isEmpty }
    var kinds: [ShareKind] { ShareKind.allCases.filter { Store.shared.supports($0.operation) } }
    var dirty: Bool { form.dirty }
    var canSave: Bool { available && loaded && !resourceID.isEmpty && dirty && !busy && !uncertain && Store.shared.supports("update_shares") }

    func load() async {
        guard available, !busy, !dirty else { return }
        let requested = kind
        busy = true; loaded = false; error = nil
        defer { busy = false }
        do {
            async let u = Store.shared.call("users")
            async let s = Store.shared.call("shares")
            async let r = Store.shared.call(requested.operation)
            let (people, grants, records) = try await (u, s, r)
            guard people["users"].isArray, grants["shares"].isArray, records[requested.listKey].isArray else { throw APIError(.nonJSON) }
            guard kind == requested else { return }
            users = people["users"].items.compactMap(SharingUser.init)
            shares = grants["shares"]
            resources = records[requested.listKey].items.compactMap(ShareResource.init)
            if !resources.contains(where: { $0.id == resourceID }) { resourceID = resources.first?.id ?? "" }
            selectResource(resourceID)
            loaded = true
        } catch {
            if !error.isCancellation { self.error = errorText(error) }
        }
    }
    func selectResource(_ id: String) {
        guard !dirty, resources.contains(where: { $0.id == id }) else { return }
        resourceID = id
        form.select(kind.members(shares, resourceID: id))
    }
    func toggle(_ user: SharingUser) {
        guard Store.shared.supports("update_shares"), !busy, !uncertain else { return }
        form.toggle(user.id)
    }
    func discard() { form.discard() }
    func save() {
        guard canSave else { return }
        let requested = kind, id = resourceID, selection = picked
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let answer = try await Store.shared.call("update_shares", requested.body(resourceID: id, users: selection))
                guard answer["kind"].string == requested.rawValue, answer["id"].string == id, let ids = answer["userIds"].array else { throw APIError(.nonJSON) }
                form.select(Set(ids.compactMap(\.int)))
                shares = .array(shares.items.filter { $0["kind"].string != requested.rawValue || $0["id"].string != id }
                    + form.original.map { ["kind": .string(requested.rawValue), "id": .string(id), "userId": JSON($0)] })
            } catch {
                uncertain = !((error as? APIError)?.isRefusal ?? false)
                if !error.isCancellation { self.error = errorText(error) }
            }
        }
    }
    func checkOutcome() { uncertain = false; discard(); Task { await load() } }
}
