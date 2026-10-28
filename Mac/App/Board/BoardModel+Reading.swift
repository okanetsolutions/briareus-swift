// Project and global reads use the same ordering, so a poll cannot overwrite a merge's newer reload.
import Foundation

extension BoardModel {
    func loadBoard(fresh: Bool = false, ifStale: Bool = false) async -> Result<JSON, APIError>? {
        readGen += 1
        let gen = readGen, client = Store.shared.client
        reading = true
        defer { if gen == readGen { reading = false } }
        // While the server's cooldown runs, retain the list and arrange to read it once the cooldown ends.
        guard let result = await PullsGate.read(repo, fresh: fresh, ifStale: ifStale) else {
            if gen == readGen { cooldownTick += 1 }
            return nil
        }
        guard Store.shared.client === client else { return .failure(APIError(.cancelled)) }
        // Return the accepted board to the global reader without publishing or caching the obsolete answer.
        guard gen == readGen else { return board["pulls"].isArray ? .success(board) : nil }
        switch result {
        case .success(let value):
            show(value, saved: false)
            error = nil
            // When the server read GitHub, not when its copy reached the app.
            syncedAt = boardDateParse(value["syncedAt"].string) ?? Date()
            Store.shared.cache.store(value, "pulls:\(repo)")
            issueStatus.next()
        case .failure(let failure):
            if failure.kind != .cancelled { error = failure.description; loaded = true }
        }
        return result
    }
}
