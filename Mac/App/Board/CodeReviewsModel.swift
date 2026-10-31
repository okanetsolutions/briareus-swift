// A pull request's stored code reviews (the iPhone's CodeReviewsModel): the `code_reviews` list as read and saved with
// the pull request, and the two writes a person makes on it, marking a review handled (or reopening it) and overruling a
// finding's verdict with the reason. CodeReviewLogic words the bodies and folds each answer back into the list.
import Combine
import Foundation

@MainActor
final class CodeReviewsModel: ObservableObject {
    let repo: String
    let number: Int
    /// The stored code reviews, newest first, and the `code_reviews` list as read, which is saved with the pull request.
    @Published private(set) var reviews: [CodeReview] = []
    private(set) var raw: JSON = []
    /// The code reviews have been read (or restored) once, and why the last read failed.
    @Published private(set) var read = false
    @Published private(set) var error: String?
    /// The review or finding being saved (`review:5`, `finding:7`).
    @Published private(set) var saving: String?
    /// Why the last Mark handled or Reopen failed, shown on the tab.
    @Published private(set) var saveError: String?
    /// The finding whose verdict is being overruled, in its editor under the finding; nil when none is open.
    @Published private(set) var editing: CodeReviewFindingEdit?
    /// Why the last verdict save failed, shown in the editor.
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
    /// The open editor, when it is on this finding of this review.
    func editor(for finding: CodeReviewFinding, of review: CodeReview) -> CodeReviewFindingEdit? {
        guard let editing, editing.reviewID == review.id, editing.findingID == finding.id else { return nil }
        return editing
    }

    // MARK: Reading

    /// The list as read or restored; an answer that is not a list leaves the reviews as they were. A read that began at
    /// a `writes` mark since passed is dropped. Taking the list clears what the last read or handling save said went wrong.
    func take(_ list: JSON, readAt mark: Int? = nil) {
        guard list.isArray, writes.holds(mark) else { return }
        raw = list
        read = true
        error = nil; saveError = nil
        let parsed = CodeReview.parse(["codeReviews": list])
        if parsed != reviews { reviews = parsed }
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

    /// Opens the editor on a finding of a review that has stopped running.
    func edit(_ finding: CodeReviewFinding, of review: CodeReview) {
        guard canEdit(review), !busy else { return }
        editError = nil
        editing = CodeReviewFindingEdit(finding, review: review.id)
    }
    func cancelEdit() {
        guard saving == nil else { return }
        editing = nil; editError = nil
    }
    /// Saves an overruled verdict; the editor closes once the server took it, and stays open with the reason when not.
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

    /// One write, its answer folded into the list, then `done` with whether the server took it; a failure lands on
    /// `failure`. It counts as saving from the click, so a second click waits.
    private func write(_ key: String, _ call: String, _ args: JSON, failure: ReferenceWritableKeyPath<CodeReviewsModel, String?>,
                       fold: @escaping (JSON, JSON) -> JSON, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        saving = key; saveError = nil; editError = nil
        writes.begin()
        Task { done(await send(call, args, failure: failure, fold: fold)) }
    }
    private func send(_ call: String, _ args: JSON, failure key: ReferenceWritableKeyPath<CodeReviewsModel, String?>,
                      fold: (JSON, JSON) -> JSON) async -> Bool {
        defer { saving = nil; writes.end() }
        switch await boardCall(call, args) {
        case .success(let answer):
            take(fold(answer, raw))
            changed()
            return true
        case .failure(let e):
            if e.kind != .cancelled { self[keyPath: key] = SettingsWritePolicy.failureText(e.description, e) }
            return false
        }
    }
}
