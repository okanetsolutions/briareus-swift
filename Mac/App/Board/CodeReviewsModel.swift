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
    @Published var error: String?
    /// The review or finding being saved (`review:5`, `finding:7`), and why the last save failed.
    @Published private(set) var saving: String?
    @Published var saveError: String?
    /// The finding whose verdict is being overruled, in its editor under the finding; nil when none is open.
    @Published private(set) var editing: CodeReviewFindingEdit?
    /// Counts each write's start and end. A `code_reviews` read that began before a write, or while one was under way,
    /// may predate it and would put back what it changed; the mark it began at tells (`take(_:readAt:)`).
    private(set) var writes = 0
    /// Called once a write changed the list, so the pull request's snapshot keeps it.
    var changed: @MainActor () -> Void = {}

    init(repo: String, number: Int) { self.repo = repo; self.number = number }

    var canHandle: Bool { Store.shared.supports("update_code_review") }
    var canEditFindings: Bool { Store.shared.supports("update_code_review_finding") }

    // MARK: Reading

    /// The list as read or restored; an answer that is not a list leaves the reviews as they were. A read that began at
    /// a `writes` mark since passed is dropped.
    func take(_ list: JSON, readAt mark: Int? = nil) {
        guard list.isArray, mark == nil || mark == writes else { return }
        raw = list
        read = true
        error = nil
        let parsed = CodeReview.parse(["codeReviews": list])
        if parsed != reviews { reviews = parsed }
    }
    func failed(_ message: String) { error = message; read = true }
    /// The pull request itself could not be read: there is nothing more to wait for.
    func gaveUp() { read = true }

    // MARK: Writing

    func setHandled(_ review: CodeReview, _ handled: Bool) {
        guard saving == nil, canHandle, review.canChangeHandling else { return }
        let args = review.handlingArguments(repo: repo, number: number, handled: handled)
        write("review:\(review.id)", "update_code_review", args) { CodeReview.replacing(review: $0["review"], in: $1) }
    }

    /// Opens the editor on a finding of a review that has stopped running.
    func edit(_ finding: CodeReviewFinding, of review: CodeReview) {
        guard saving == nil, canEditFindings, review.canEditFindings else { return }
        saveError = nil
        editing = CodeReviewFindingEdit(finding, review: review.id)
    }
    func cancelEdit() {
        guard saving == nil else { return }
        editing = nil; saveError = nil
    }
    /// Saves an overruled verdict; the editor closes once the server took it, and stays open with the reason when not.
    func save(_ edit: CodeReviewFindingEdit) {
        guard saving == nil, canEditFindings, edit.canSave else { return }
        editing = edit
        let args = edit.arguments(repo: repo, number: number)
        write("finding:\(edit.findingID)", "update_code_review_finding", args, fold: {
            CodeReview.replacing(finding: $0["finding"], inReview: edit.reviewID, in: $1)
        }, done: { [weak self] saved in
            if saved, self?.editing?.id == edit.id { self?.editing = nil }
        })
    }

    /// One write, its answer folded into the list, then `done` with whether the server took it. It counts as saving from
    /// the tap, so a second tap waits. A failure that is not a refusal may still have been saved.
    private func write(_ key: String, _ call: String, _ args: JSON, fold: @escaping (JSON, JSON) -> JSON,
                       done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        saving = key; saveError = nil
        writes += 1
        Task { done(await send(call, args, fold: fold)) }
    }
    private func send(_ call: String, _ args: JSON, fold: (JSON, JSON) -> JSON) async -> Bool {
        defer { saving = nil; writes += 1 }
        switch await boardCall(call, args) {
        case .success(let answer):
            take(fold(answer, raw))
            changed()
            return true
        case .failure(let e):
            if e.kind != .cancelled {
                saveError = e.isRefusal ? e.description : "\(e.description) It may still have been saved; refresh before trying again."
            }
            return false
        }
    }
}
