// Shared cooldown and cache-aware reads of the pull request list.
import Foundation

/// Every read of a repository's pull request list goes through here, so a cooldown the server asked for holds for all of
/// them: while it runs the read is not made (nil), and a 429 or another failure sets the next one.
@MainActor
enum PullsGate {
    private(set) static var cooldown = PullsCooldown()
    static func deadline(_ repo: String) -> Date? { cooldown.deadline(repo) }

    static func read(_ repo: String, fresh: Bool = false, ifStale: Bool = false) async -> Result<JSON, APIError>? {
        guard cooldown.mayRead(repo) else { return nil }
        let r: Result<JSON, APIError>
        if ifStale {
            do {
                r = .success(try await readPulls(fresh: fresh, now: { Store.shared.client?.serverNow }) { fresh in
                    try await boardCall("pulls", fresh ? ["repo": .string(repo), "fresh": "1"] : ["repo": .string(repo)]).get()
                })
            } catch let e as APIError { r = .failure(e) }
            catch { r = .failure(APIError(.cancelled)) }
        } else {
            r = await readPulls(fresh: fresh) { fresh in
                var args: JSON = ["repo": .string(repo)]
                if fresh { args["fresh"] = "1" }
                return await boardCall("pulls", args)
            }
        }
        switch r {
        case .success: cooldown.succeeded(repo)
        case .failure(let e): cooldown.failed(repo, error: e)
        }
        post(.pullsCooldownChanged, ["repo": repo])
        return r
    }
}
