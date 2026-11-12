// The board's errands: what the server offers for a pull request, merged with the ones this app knows, what each one sends
// to start its paid session, and the question a code review refused at the round limit asks before it is sent again.
import Foundation

/// The question an errand asks before it starts.
struct ActionInput: Equatable, Sendable {
    var label: String
    var placeholder: String
    var required: Bool
}

/// An errand the board runs on a pull request: a paid session started with a prompt the server owns.
struct BoardAction: Equatable, Sendable {
    var id: String
    var label: String
    var hint: String
    var input: ActionInput?
    /// The one CLI it runs on, when the server restricts it (`binary`); nil runs on any provider.
    var binary: String?

    init(id: String, label: String, hint: String = "", input: ActionInput? = nil, binary: String? = nil) {
        self.id = id; self.label = label; self.hint = hint; self.input = input; self.binary = binary
    }

    /// The call that starts it: `serve_pull` for Run, and `action` (with the errand's id) for the rest.
    var operation: String { id == "run" ? "serve_pull" : "action" }
    /// Whether a provider of CLI `binary` may run it.
    func runs(on binary: String?) -> Bool { self.binary == nil || self.binary == binary }
    /// Run answers only once the workspace is prepared and serving, which takes longer than a request is given. Nil = default.
    var timeoutMs: Int? { id == "run" ? 170_000 : nil }
    /// Every errand looks the pull request up by number. Input is sent trimmed, and only to an errand that asks for it.
    /// `continueReview` asks a code review refused at the round limit for one more round on purpose; only a review sends it.
    func arguments(repo: String, number: Int, input: String? = nil, continueReview: Bool = false) -> JSON {
        var args: JSON = ["repo": .string(repo), "prNumber": JSON(number)]
        if id != "run" { args["action"] = .string(id) }
        if continueReview && id == "review" { args["continueReview"] = true }
        if self.input != nil, let input {
            let trimmed = input.cTrimmed
            if !trimmed.isEmpty { args["input"] = .string(trimmed) }
        }
        return args
    }

    /// What a person is asked when a code review is refused at the round limit: the server's account of what is unresolved,
    /// then the one more round it would cost. Both apps ask it before sending the review again.
    static func anotherRoundQuestion(_ refusal: APIError) -> String {
        let said = refusal.message?.cTrimmed ?? ""
        let lead = said.isEmpty ? "This pull request has used its review rounds." : said
        return lead + " Run one more round on purpose? It starts a paid session."
    }

    /// The board's errands, in the order the Windows client shows them.
    static let known: [BoardAction] = [
        BoardAction(id: "run", label: "Run", hint: "Prepare this pull request in a clean workspace and serve the app from it"),
        BoardAction(id: "review", label: "Code review", hint: "Review the pull request with the provider\u{2019}s own review command, publish the findings, then verify each one"),
        BoardAction(id: "solve-conflicts", label: "Solve conflicts", hint: "Merge the base branch in, resolve the conflicts and push the result"),
        BoardAction(id: "fix-checks", label: "Fix failing checks", hint: "Read this pull request\u{2019}s failing CI checks, fix what the branch broke and push the fixes"),
        BoardAction(id: "implement-feedback", label: "Implement feedback", hint: "Read the review feedback on this pull request, fix what holds up, push the fixes and reply on each thread"),
        BoardAction(id: "test-sheet", label: "Test sheet", hint: "Derive the manual QA checklist from this pull request\u{2019}s diff and post it as one editable comment"),
        BoardAction(id: "test-run", label: "Record QA", hint: "Execute this pull request\u{2019}s test sheet in a fresh workspace and record a video of every scenario"),
        BoardAction(id: "pr-body-summary", label: "PR body", hint: "Rewrite this pull request\u{2019}s description from its own diff, following the team template"),
        BoardAction(id: "delete-self-comments", label: "Delete my comments", hint: "Remove every comment and review the configured GitHub account left on this pull request"),
    ]
    /// Errands this app no longer offers, even when the server still lists them.
    private static let dropped: Set<String> = ["qa", "custom-feedback"]

    /// The errands worth offering on one pull request. `catalog` is what the server's `actions` lists; null or empty before it
    /// is known, when every errand this app knows is offered. `failedChecks` is the pull request's count of failed checks.
    static func offered(catalog: JSON, pull: PullSummary?, failedChecks: Int) -> [BoardAction] {
        // What the server lists, by id, in its order; a later entry for one id replaces the earlier one in its place.
        var served: [BoardAction] = []
        for entry in catalog.items {
            guard let id = entry["id"].string, let label = entry["label"].string else { continue }
            var a = BoardAction(id: id, label: label, hint: entry["hint"].string ?? "", binary: entry["binary"].nonEmpty)
            if let inputLabel = entry["input"]["label"].string {
                a.input = ActionInput(label: inputLabel, placeholder: entry["input"]["placeholder"].string ?? "", required: entry["input"]["required"].is(true))
            }
            if let k = served.firstIndex(where: { $0.id == id }) { served[k] = a } else { served.append(a) }
        }
        var out: [BoardAction] = []
        for k in known {
            let s = served.first { $0.id == k.id }
            let offered: Bool
            // Run has a route of its own; the rest are errands the server has to list.
            if !served.isEmpty && s == nil && k.id != "run" { offered = false }
            else if k.id == "solve-conflicts" { offered = pull?.hasConflicts ?? true }
            else if k.id == "fix-checks" { offered = failedChecks > 0 || (pull?.checksFailed ?? false) }
            else if k.id == "implement-feedback" { offered = pull?.awaitsFeedback ?? true }
            else { offered = true }
            guard offered else { continue }
            // The server words the question and adds errands this app predates.
            var a = k
            if let s, s.input != nil { a.input = s.input }
            if let s { a.binary = s.binary }
            out.append(a)
        }
        for s in served where !known.contains(where: { $0.id == s.id }) && !dropped.contains(s.id) { out.append(s) }
        return out
    }
}
