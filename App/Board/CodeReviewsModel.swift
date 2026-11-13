// A pull request's stored code reviews on a phone (the Mac's CodeReviewsModel): the `code_reviews` list as read and saved
// with the pull request, and the two writes a person makes on it, marking a review handled (or reopening it) and
// overruling a finding's verdict with the reason. CodeReviewLogic words the bodies and folds each answer back into the list.
import Combine
import Foundation

@MainActor
final class CodeReviewsModel: ObservableObject {
    let repo: String
    let number: Int
    /// The stored code reviews, newest first, and the `code_reviews` list they were read from (saved with the snapshot).
    @Published private(set) var reviews: [CodeReview] = []
    private(set) var raw: JSON = []
    /// What the reviews amount to (`ReviewOutcome`), and the outcome and rounds it was read from, saved with the
    /// pull request; nil before a server sends one.
    @Published private(set) var outcome: ReviewOutcome?
    private(set) var outcomeRaw: JSON = .null
    /// Whether the reviews have been read, or restored from the last visit: until then the tab is loading.
    @Published private(set) var read = false
    @Published private(set) var error: String?
    /// The review or finding being saved (`review:5`, `finding:7`).
    @Published private(set) var saving: String?
    /// Why the last Mark handled or Reopen failed, shown on the tab.
    @Published private(set) var saveError: String?
    /// The finding whose verdict is being overruled, in its sheet; nil when none is open. Closing it drops its error.
    @Published var editing: CodeReviewFindingEdit? { didSet { if editing == nil { editError = nil } } }
    /// Why the last approval or withdrawal failed, shown under the approvals.
    @Published private(set) var approvalError: String?
    /// Why the last verdict save failed, shown in the sheet.
    @Published private(set) var editError: String?
    /// Each write's start and end. A `code_reviews` read that began before a write, or while one was under way, may
    /// predate it and would put back what it changed; the mark it began at tells (`take(_:readAt:)`).
    private(set) var writes = WriteMarks()
    /// Called once a write changed the list, so the pull request's snapshot keeps it.
    var changed: @MainActor () -> Void = {}

    init(repo: String, number: Int) { self.repo = repo; self.number = number }

    /// The server offers each write and this token may make it.
    private var canHandle: Bool { Store.shared.supports("update_code_review") }
    private var canEditFindings: Bool { Store.shared.supports("update_code_review_finding") }
    /// The user this token acts as, which tells one's own approvals from other people's.
    private var me: Int? { Store.shared.device?.userId }

    /// What the tab says went wrong: the read first, then the last handling save.
    var notice: String? { error ?? saveError }
    /// Mark handled or Reopen, when this token and server can change the review's handling.
    func handlingAction(for review: CodeReview) -> CodeReviewHandlingAction? { canHandle ? review.handlingAction : nil }
    func isSaving(_ review: CodeReview) -> Bool { saving == "review:\(review.id)" }
    /// Change verdict is offered on a stopped review's findings; `busy` holds it while another save is under way.
    func canEdit(_ review: CodeReview) -> Bool { canEditFindings && review.canEditFindings }
    var busy: Bool { saving != nil }
    /// Save is offered while this token may write verdicts, the edit can be saved and its review has not started again.
    func canSave(_ edit: CodeReviewFindingEdit) -> Bool { canEditFindings && reviews.allowsSaving(edit) }

    /// Approve is offered while this token may record one and the requirement waits on a person for a reviewed head.
    var canApprove: Bool { Store.shared.supports("approve_pull") && outcome?.approvals?.canApprove(me: me) == true }
    func canWithdraw(_ approval: ReviewApproval) -> Bool {
        Store.shared.supports("withdraw_pull_approval") && approval.canWithdraw(me: me)
    }
    var isApproving: Bool { saving == "approve" }
    func isWithdrawing(_ approval: ReviewApproval) -> Bool { saving == "approval:\(approval.id)" }

    // MARK: Reading

    /// The list as read or restored; anything but an array reads as none. A read that began at a `writes` mark since
    /// passed is dropped. Taking the list clears what the last read or handling save said went wrong.
    func take(_ list: JSON, answer: JSON? = nil, readAt mark: Int? = nil) {
        guard writes.holds(mark) else { return }
        raw = list.isArray ? list : []
        if let answer { takeOutcome(answer, from: .read) }
        let parsed = CodeReview.parse(["codeReviews": raw])
        if parsed != reviews { reviews = parsed }
        read = true
        error = nil; saveError = nil
    }
    /// The outcome and rounds `answer` carries (a read, a restored snapshot or a save's answer), over the ones kept.
    private func takeOutcome(_ answer: JSON, from source: ReviewOutcome.Source) {
        outcomeRaw = ReviewOutcome.state(answer, from: source, over: outcomeRaw)
        let parsed = ReviewOutcome(outcomeRaw)
        if parsed != outcome { outcome = parsed }
    }
    func failed(_ message: String) { error = message; read = true }
    /// The pull request itself could not be read: there is nothing more to wait for.
    func gaveUp() { read = true }

    // MARK: Writing

    func setHandled(_ review: CodeReview) {
        guard saving == nil, let action = handlingAction(for: review) else { return }
        let args = review.handlingArguments(repo: repo, number: number, action)
        write("review:\(review.id)", "update_code_review", args, failure: \.saveError) {
            CodeReview.replacing(review: $0["review"], in: $1)
        }
    }

    /// Opens the sheet on a finding of a review that has stopped running.
    func edit(_ finding: CodeReviewFinding, of review: CodeReview) {
        guard canEdit(review), !busy else { return }
        editError = nil
        editing = CodeReviewFindingEdit(finding, review: review.id)
    }
    /// Saves an overruled verdict; the sheet closes once the server took it, and stays open with the reason when not.
    func save(_ edit: CodeReviewFindingEdit) {
        guard saving == nil, canSave(edit) else { return }
        editing = edit
        let args = edit.arguments(repo: repo, number: number)
        write("finding:\(edit.findingID)", "update_code_review_finding", args, failure: \.editError, fold: {
            CodeReview.replacing(finding: $0["finding"], inReview: edit.reviewID, in: $1)
        }, done: { [weak self] saved in
            if saved, self?.editing?.id == edit.id { self?.editing = nil }
        })
    }

    /// Records this person's approval of the head the requirement names; `done` says whether the server took it.
    func approve(note: String, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard saving == nil, canApprove, let head = outcome?.approvals?.headSha else { return }
        let args = ReviewApprovalWrite.approveArguments(repo: repo, number: number, headSha: head, note: note)
        write("approve", "approve_pull", args, failure: \.approvalError, fold: { $1 }, done: done)
    }
    /// Withdraws one of this person's approvals; it stays on record and no longer counts.
    func withdraw(_ approval: ReviewApproval, note: String, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard saving == nil, canWithdraw(approval) else { return }
        let args = ReviewApprovalWrite.withdrawArguments(repo: repo, number: number, approval: approval, note: note)
        write("approval:\(approval.id)", "withdraw_pull_approval", args, failure: \.approvalError, fold: { $1 }, done: done)
    }

    /// One write, its answer folded into the list, then `done` with whether the server took it; a failure lands on
    /// `failure`. It counts as saving from the tap, so a second tap waits.
    private func write(_ key: String, _ call: String, _ args: JSON, failure: ReferenceWritableKeyPath<CodeReviewsModel, String?>,
                       fold: @escaping (JSON, JSON) -> JSON, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        saving = key; saveError = nil; editError = nil; approvalError = nil
        writes.begin()
        Task { done(await send(call, args, failure: failure, fold: fold)) }
    }
    private func send(_ call: String, _ args: JSON, failure key: ReferenceWritableKeyPath<CodeReviewsModel, String?>,
                      fold: (JSON, JSON) -> JSON) async -> Bool {
        defer { saving = nil; writes.end() }
        do {
            let answer = try await Store.shared.call(call, args)
            take(fold(answer, raw))
            takeOutcome(answer, from: ReviewOutcome.source(after: call))
            changed()
            return true
        } catch {
            if let said = failure(error) { self[keyPath: key] = SettingsWritePolicy.failureText(said, error) }
            return false
        }
    }
}
