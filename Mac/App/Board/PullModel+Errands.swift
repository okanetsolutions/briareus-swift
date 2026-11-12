// A pull request's errands as its screen starts them: the errand's input asked first when it takes one, the paid session
// started, and a code review refused at the project's round limit offered once more on purpose.
import Foundation

extension PullModel {
    func startAction(_ action: BoardAction, input: String?, continueReview: Bool = false) {
        guard !busy, !uncertain, pr["headRef"].string != nil else { return }
        busy = true
        let args = action.arguments(repo: repo, number: number, input: input, continueReview: continueReview)
        Task {
            let r = await boardCall(action.operation, args, timeout: action.timeoutMs.map { TimeInterval($0) / 1000 })
            busy = false
            switch r {
            case .success:
                writeError = nil
                // The pull request stays shown; the new session joins its runs.
                post(.sessionsChanged, ["repo": repo])
                if Store.shared.supports("sessions") { await loadSessions() }
            case .failure(let e):
                writeError = e.description
                // A refusal is definite; anything else may have started the session.
                if !e.isRefusal { uncertain = true }
                if !continueReview, e.isReviewRoundLimit {
                    dialogOpen = true
                    let again = Dialogs.confirmAnotherRound(e)
                    dialogOpen = false
                    if again { startAction(action, input: input, continueReview: true) }
                }
            }
        }
    }
    func act(_ action: BoardAction) {
        afterThisEvent { [self] in
            dialogOpen = true
            let answer = actionPrompt(action, repo: repo, number: number)
            dialogOpen = false
            if let input = answer { startAction(action, input: input) }
        }
    }
}
