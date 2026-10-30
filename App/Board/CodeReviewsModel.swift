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
    /// Whether the reviews have been read, or restored from the last visit: until then the tab is loading.
    @Published private(set) var read = false
    @Published var error: String?
    /// The review or finding being saved (`review:5`, `finding:7`), and why the last save failed.
    @Published private(set) var saving: String?
    @Published var saveError: String?
    /// The finding whose verdict is being overruled, in its editor; nil when none is open.
    @Published var editing: CodeReviewFindingEdit?
    /// Called once a write changed the list, so the pull request's snapshot keeps it.
    var changed: @MainActor () -> Void = {}

    init(repo: String, number: Int) { self.repo = repo; self.number = number }

    var canHandle: Bool { Store.shared.supports("update_code_review") }
    var canEditFindings: Bool { Store.shared.supports("update_code_review_finding") }

    // MARK: Reading

    /// The list as read or restored; anything but an array reads as none.
    func take(_ list: JSON) {
        raw = list.isArray ? list : []
        let parsed = CodeReview.parse(["codeReviews": raw])
        if parsed != reviews { reviews = parsed }
        read = true
        error = nil
    }
    func failed(_ message: String) { error = message; read = true }
    /// The pull request itself could not be read: there is nothing more to wait for.
    func gaveUp() { read = true }

    // MARK: Writing

    func setHandled(_ review: CodeReview, _ handled: Bool) {
        guard saving == nil, canHandle, review.canChangeHandling else { return }
        let args = review.handlingArguments(repo: repo, number: number, handled: handled)
        Task { _ = await write("review:\(review.id)", "update_code_review", args) { CodeReview.replacing(review: $0["review"], in: $1) } }
    }

    /// Opens the editor on a finding of a review that has stopped running.
    func edit(_ finding: CodeReviewFinding, of review: CodeReview) {
        guard saving == nil, canEditFindings, review.canEditFindings else { return }
        saveError = nil
        editing = CodeReviewFindingEdit(finding, review: review.id)
    }
    /// Saves an overruled verdict; the editor closes once the server took it, and stays open with the reason when not.
    func save(_ edit: CodeReviewFindingEdit) {
        guard saving == nil, canEditFindings, edit.canSave else { return }
        editing = edit
        let args = edit.arguments(repo: repo, number: number)
        Task {
            let saved = await write("finding:\(edit.findingID)", "update_code_review_finding", args) {
                CodeReview.replacing(finding: $0["finding"], inReview: edit.reviewID, in: $1)
            }
            if saved, editing?.id == edit.id { editing = nil }
        }
    }

    /// One write, its answer folded into the list. A failure that is not a refusal may still have been saved.
    private func write(_ key: String, _ call: String, _ args: JSON, fold: (JSON, JSON) -> JSON) async -> Bool {
        saving = key; saveError = nil
        defer { saving = nil }
        do {
            let answer = try await Store.shared.call(call, args)
            take(fold(answer, raw))
            changed()
            return true
        } catch {
            guard let said = failure(error) else { return false }
            saveError = SettingsWritePolicy.isUncertain(error) ? "\(said) It may still have been saved; refresh before trying again." : said
            return false
        }
    }
}
