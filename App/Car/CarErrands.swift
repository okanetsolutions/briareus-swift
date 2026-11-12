// The car needs the iOS 26.4 SDK, which came with the Swift 6.3 compiler.
#if os(iOS) && compiler(>=6.3)
import CarPlay

// A pull request's errands in the car: which ones it offers, and starting one, with a code review refused at the project's
// round limit asked about once more, as both apps ask, before it is sent again on purpose.
@available(iOS 26.4, *)
extension CarAssistant {
    /// The errands worth offering on the pull request in hand: an open one with a branch, to a token that may start them.
    var offered: [BoardAction] {
        guard case .pull = focus, store.canManage, pull["headRef"].string != nil, pull["state"].string == "open" else { return [] }
        return BoardAction.offered(catalog: catalog, pull: row, failedChecks: pull["checks"]["failed"].truncatedInt ?? 0)
            .filter { store.supports($0.operation) }
    }
    func run(_ action: BoardAction, input: String? = nil, continueReview: Bool = false) {
        guard case .pull(let number) = focus, let project, pull["headRef"].string != nil else { return }
        let args = action.arguments(repo: project.repo, number: number, input: input, continueReview: continueReview)
        perform { [weak self] in
            guard let self else { return nil }
            let answer: JSON
            do {
                answer = try await self.store.call(action.operation, args, timeout: action.timeoutMs.map { TimeInterval($0) / 1000 })
            } catch let refusal as APIError where refusal.isReviewRoundLimit && !continueReview {
                // Nothing started: ask, and send it again only on a yes.
                self.ask(CarText.variants(BoardAction.anotherRoundQuestion(refusal), before: "", after: ""), yes: "Run one more round") { [weak self] in
                    self?.run(action, input: input, continueReview: true)
                }
                return nil
            }
            await self.resync(project.repo)
            guard let started = Session(answer["session"]) else { return "\(action.label) started" }
            self.open(started)
            return nil
        }
    }
}
#endif
