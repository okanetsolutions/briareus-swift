// Which errands a device can start on a pull request, which one its state suggests and which ones remove things: the same
// for the iPhone, the Mac and CarPlay. What the server offers is `BoardAction.offered`; this narrows it to what the token
// and server allow. Each app keeps its own errand symbols (the Mac's emoji mirror Windows; iPhone menus need SF Symbols).
import Foundation

extension BoardAction {
    /// The errands this device can start: what the server offers on the pull request, none on a token that cannot manage,
    /// and only those whose route the server's catalog lists.
    static func startable(catalog: JSON, pull: PullSummary?, failedChecks: Int, canManage: Bool,
                          supports: (String) -> Bool) -> [BoardAction] {
        guard canManage else { return [] }
        return offered(catalog: catalog, pull: pull, failedChecks: failedChecks).filter { supports($0.operation) }
    }

    /// The pull request's state asks for this one (`recommended`), so it is marked and drawn first among equals.
    func isSuggested(for pull: PullSummary?) -> Bool { pull?.recommended == id }

    /// It removes what was written on GitHub, so its button and confirmation are drawn as destructive.
    var isDestructive: Bool { id == "delete-self-comments" }
}
