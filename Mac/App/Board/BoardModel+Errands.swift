// The board's errands as a pull request row starts them: Run opens the Run tab, the others ask their input first when they
// take one and start a paid session, and a code review refused at the project's round limit is offered once more on purpose.
import Foundation

extension BoardModel: ErrandDialogHost {
    func start(_ pull: PullSummary, _ action: BoardAction, input: String?, continueReview: Bool = false) {
        guard !busy, !uncertain, !pull.branch.isEmpty else { return }
        busy = true; startingNumber = pull.number; startingID = action.id
        let args = action.arguments(repo: repo, number: pull.number, input: input, continueReview: continueReview)
        Task {
            let r = await boardCall(action.operation, args, timeout: action.timeoutMs.map { TimeInterval($0) / 1000 })
            busy = false
            switch r {
            case .success:
                writeError = nil
                // The list stays shown; the new session joins the runs counted on its pull request.
                post(.sessionsChanged, ["repo": repo])
                if Store.shared.supports("sessions") { await loadRuns() }
            case .failure(let e):
                writeError = e.description
                // A refusal is definite; anything else may have started the session.
                if !e.isRefusal { uncertain = true }
                offerAnotherRound(after: e, continued: continueReview) { [self] in start(pull, action, input: input, continueReview: true) }
            }
        }
    }
    func act(_ pull: PullSummary, _ action: BoardAction) {
        guard !busy, !uncertain else { return }
        if action.id == "run" { openRun(pull); return }
        afterThisEvent { [self] in
            dialogOpen = true
            let answer = actionPrompt(action, repo: repo, number: pull.number)
            dialogOpen = false
            if let input = answer { start(pull, action, input: input) }
        }
    }
}
