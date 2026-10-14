// What the board's screens share on a phone: the errand catalog and the runner that starts an errand (its confirmation,
// its question in a sheet), the rows of pull requests, issues and conversations, and the badges and chips they carry.
import SwiftUI
import UIKit

// MARK: - Links

/// Opens an https address in Safari; anything else is refused.
@MainActor
func boardOpenWeb(_ url: String?) {
    guard safeWebURL(url), let url, let u = URL(string: url) else { return }
    UIApplication.shared.open(u)
}

// MARK: - Errands

/// The errands the server lists (`actions`), read once in a while and shared by every board screen.
@MainActor
final class ErrandCatalog: ObservableObject {
    static let shared = ErrandCatalog()
    @Published private(set) var catalog: JSON = []
    private var readAt: Date?
    private var reading = false

    private init() {
        if let saved = Store.shared.cache.value("actions") { catalog = saved["actions"] }
    }

    /// The list changes with a server release, so it is read again only after a few minutes.
    func load() async {
        guard Store.shared.canManage, Store.shared.supports("actions"), !reading else { return }
        if let readAt, Date().timeIntervalSince(readAt) < 300 { return }
        reading = true
        defer { reading = false }
        guard let v = try? await Store.shared.call("actions") else { return }
        readAt = Date()
        if v["actions"] != catalog { catalog = v["actions"] }
        Store.shared.cache.store(v, "actions")
    }
}

/// The errands this device can start on a pull request: what the server offers for it, less what the token or server lacks.
@MainActor
func boardErrands(catalog: JSON, pull: PullSummary?, failedChecks: Int) -> [BoardAction] {
    BoardAction.startable(catalog: catalog, pull: pull, failedChecks: failedChecks, canManage: Store.shared.canManage,
                          supports: { Store.shared.supports($0) })
}

/// The symbol before an errand's label.
func errandSymbol(_ id: String) -> String {
    switch id {
    case "run": return "play.fill"
    case "review": return "text.magnifyingglass"
    case "solve-conflicts": return "arrow.triangle.merge"
    case "fix-checks": return "wrench.and.screwdriver"
    case "implement-feedback": return "hammer"
    case "custom-feedback": return "square.and.pencil"
    case "test-sheet": return "checklist"
    case "test-run": return "video"
    case "pr-body-summary": return "doc.text"
    case "delete-self-comments": return "trash"
    default: return "bolt"
    }
}

/// One errand about to start on one pull request.
struct PendingErrand: Identifiable {
    var action: BoardAction
    var number: Int
    var branch: String
    var input: String?
    var id: String { "\(number):\(action.id)" }
}

/// Starts errands: every one is a paid session, so each asks first, in a dialog or in the sheet that takes its input. A
/// start that may have gone through (anything but a refusal) holds further starts until the user has looked.
@MainActor
final class ErrandRunner: ObservableObject {
    let repo: String
    @Published var confirming: PendingErrand?
    @Published var asking: PendingErrand?
    @Published private(set) var busy = false
    @Published private(set) var starting: PendingErrand?
    @Published var uncertain = false
    @Published var writeError: String?

    init(repo: String) { self.repo = repo }

    /// Asks for the errand's input when it takes one, else for a yes.
    func ask(_ action: BoardAction, number: Int, branch: String) {
        guard !busy, !uncertain, !branch.isEmpty else { return }
        let p = PendingErrand(action: action, number: number, branch: branch)
        if action.input != nil { asking = p } else { confirming = p }
    }

    /// Starts it; the session it started, when the server named one.
    func run(_ p: PendingErrand) async -> Session? {
        guard !busy, !uncertain else { return nil }
        busy = true; starting = p
        defer { busy = false; starting = nil }
        let args = p.action.arguments(repo: repo, number: p.number, branch: p.branch, input: p.input)
        do {
            let v = try await Store.shared.call(p.action.operation, args, timeout: p.action.timeoutMs.map { TimeInterval($0) / 1000 })
            writeError = nil
            if Store.shared.supports("sessions") { try? await Store.shared.feed(repo).loadSessions(fresh: true) }
            return Session(v["session"])
        } catch {
            guard let said = failure(error) else { return nil }
            writeError = said
            // A refusal is definite; anything else may have started the session.
            if (error as? APIError)?.isRefusal != true { uncertain = true }
            return nil
        }
    }

    /// Looking at the project's conversations is how an uncertain start is checked.
    func checked() { uncertain = false; writeError = nil }
}

extension View {
    /// The runner's dialog and input sheet; a started session is opened.
    func errandPrompts(_ runner: ErrandRunner) -> some View { modifier(ErrandPrompts(runner: runner)) }
}

private struct ErrandPrompts: ViewModifier {
    @ObservedObject var runner: ErrandRunner
    @Environment(\.navigate) private var navigate

    func body(content: Content) -> some View {
        content
            .alert(runner.confirming.map { "Start \($0.action.label) on #\($0.number)?" } ?? "",
                   isPresented: Binding(get: { runner.confirming != nil }, set: { if !$0 { runner.confirming = nil } }), presenting: runner.confirming) { p in
                Button("Start paid session", role: p.action.isDestructive ? .destructive : nil) { start(p) }
                Button("Cancel", role: .cancel) {}
            } message: { p in
                Text(paidNote(p))
            }
            .sheet(item: $runner.asking) { p in
                ErrandInputSheet(pending: p) { text in
                    var p = p
                    p.input = text
                    start(p)
                }
                .presentationDetents([.medium, .large])
            }
    }

    private func start(_ p: PendingErrand) {
        Task {
            if let s = await runner.run(p) { navigate(.conversation(id: s.id, session: s.raw)) }
        }
    }
}

private func paidNote(_ p: PendingErrand) -> String {
    let hint = p.action.hint.isEmpty ? "" : "\(p.action.hint). "
    return "\(hint)This runs a paid agent on pull request #\(p.number) and may write to GitHub."
}

/// The errand's question: a box for the answer, what it costs, and Start, off while a required answer is empty.
private struct ErrandInputSheet: View {
    let pending: PendingErrand
    let start: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    private var trimmed: String { text.cTrimmed }
    private var input: ActionInput? { pending.action.input }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(input.flatMap { $0.placeholder.isEmpty ? nil : $0.placeholder } ?? input?.label ?? "", text: $text, axis: .vertical)
                        .lineLimit(5...14).focused($focused)
                } header: {
                    Text(input?.label ?? "")
                } footer: {
                    Text(paidNote(pending))
                }
                .listRowBackground(Theme.row)
            }
            .scrollContentBackground(.hidden).background(Theme.canvas)
            .navigationTitle(pending.action.label).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { dismiss(); start(trimmed) }.bold()
                        .disabled(trimmed.isEmpty && input?.required == true)
                }
            }
            .onAppear { focused = true }
        }
    }
}

/// What an errand start left to say: why it failed, and whether it may have started anyway.
struct ErrandNotice: View {
    @ObservedObject var runner: ErrandRunner
    var place: String
    var body: some View {
        if let e = runner.writeError {
            Section {
                ErrorNotice(message: e)
                if runner.uncertain {
                    Text("The request may have completed. Look for its conversation \(place) before starting another agent.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("I have checked") { runner.checked() }.font(.callout)
                }
            }
            .listRowBackground(Theme.row)
        }
    }
}

// MARK: - Badges and chips

/// A small capsule: a symbol and a word in one colour on its tint.
struct BoardBadge: View {
    let text: String
    let systemImage: String?
    let color: Color
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 9
    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: iconSize, weight: .semibold)) }
            Text(text).font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Lays its subviews out left to right, wrapping when a line is full.
struct BoardFlowLayout: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, f) in zip(subviews, arrange(subviews, width: bounds.width)) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let ideal = v.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, width), height: ideal.height)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; row = max(row, size.height)
        }
        return frames
    }
}

/// GitHub labels as chips: the label's colour tints the chip, the name stays in the text colour so a pale one still reads.
struct BoardLabelChips: View {
    let labels: [PullLabel]
    var body: some View {
        BoardFlowLayout(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                let color = Theme.color(label)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(label.name).font(.caption2.weight(.medium)).lineLimit(1)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(color.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
                .accessibilityElement(children: .ignore).accessibilityLabel("Label \(label.name)")
            }
        }
    }
}

/// A review verdict's symbol and colour.
func reviewStyle(_ status: ReviewStatus) -> (symbol: String, color: Color) {
    let color = Theme.color(status.tone)
    switch status {
    case .approved: return ("checkmark.seal.fill", color)
    case .changesRequested: return ("xmark.octagon.fill", color)
    case .feedback: return ("text.bubble.fill", color)
    case .requested, .none: return ("clock", color)
    }
}

/// The symbol before a pull request's mark.
func markSymbol(_ mark: PullMark) -> String {
    switch mark {
    case .running: return "bolt.fill"
    case .conflicts: return "exclamationmark.triangle.fill"
    case .checks(.passed): return "checkmark"
    case .checks(.failed): return "xmark"
    case .checks(.pending): return "clock"
    case .stack: return "square.stack.3d.up.fill"
    case .review(let status): return reviewStyle(status).symbol
    case .draft: return "pencil"
    case .suggested: return "sparkles"
    }
}

/// When a row last changed, short.
struct BoardUpdated: View {
    let date: Date?
    var body: some View {
        if let date { Text(formatRelative(date)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
    }
}

// MARK: - Rows

/// An issue or pull request named under a row, with the state that says whether it is still open work, and `status` (an
/// issue's Status on its project board) as a chip after it. A pull request's row leaves the state of the issues it closes
/// out (`showState`).
struct BoardLinkedRow: View {
    let link: BoardLink
    let repo: String
    var status: String? = nil
    var showState = true
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
            Text(link.reference(repo)).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(link.title).font(.caption).lineLimit(1)
            if showState, let state = linkedStateText(link) {
                Text(state).font(.caption2).foregroundStyle(state == "open" ? Theme.ok : state == "closed" ? Color.secondary : Theme.warn)
            }
            if let status, !status.isEmpty {
                Text(status).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.field, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 0.5))
                    .accessibilityLabel("Status \(status)")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A pull request as the board shows it: title and number, its standing as badges, the errand it asks for, its labels, who
/// holds, wrote and reviews it split by pipes, and the issues it closes.
struct BoardPullRow: View {
    let pull: PullSummary
    let stack: StackPosition?
    let repo: String
    /// The conversations at work on it right now.
    var activeRuns = 0
    /// The label of the errand its state asks for, when this device could start it.
    var suggested: String? = nil
    /// The project Status of each issue it closes, in its order; nil or "" for none.
    var issueStatus: [String?] = []
    var showsIssues = true

    private var content: PullRowContent { PullRowContent(pull: pull, stack: stack, activeRuns: activeRuns, suggested: suggested) }
    private var tint: Color { pull.hasConflicts ? Theme.danger : pull.draft ? .secondary : Theme.ok }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.pull").font(.subheadline).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(pull.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The branch is the pull request's page's to show.
                    Text(verbatim: "#\(pull.number)").font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 4)
                    BoardUpdated(date: pull.updatedAt)
                }
                let content = content
                if !content.marks.isEmpty {
                    BoardFlowLayout(spacing: 5) {
                        ForEach(Array(content.marks.enumerated()), id: \.offset) { _, mark in
                            BoardBadge(text: mark.text, systemImage: markSymbol(mark), color: Theme.color(mark.tone))
                                .accessibilityLabel(mark.spoken)
                        }
                    }
                }
                if !pull.labels.isEmpty { BoardLabelChips(labels: pull.labels) }
                Text(content.who.joined(separator: " | ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if showsIssues {
                    ForEach(Array(pull.issues.enumerated()), id: \.offset) { i, link in
                        BoardLinkedRow(link: link, repo: repo, status: i < issueStatus.count ? issueStatus[i] : nil, showState: false)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// How much of an epic is done, over every sub-issue GitHub knows, which may be more than the rows under it.
struct BoardEpicProgress: View {
    let progress: SubIssueProgress
    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.fraction).tint(Theme.accent).frame(width: 70)
            Text(progress.text).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.spoken)
    }
}

/// An issue as the board shows it: who holds it, the epic's progress, its labels, its epic, and what answers it.
struct BoardIssueRow: View {
    let issue: IssueSummary
    let repo: String
    /// Set on a row drawn under its epic, where the indent already says whose it is.
    var nested = false
    /// Whether the sub-issues under it are hidden; nil for a row with none to hide.
    var folded: Bool?
    var fold: (() -> Void)?
    var body: some View {
        let content = IssueRowContent(issue: issue, repo: repo, nested: nested)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: issue.isEpic ? "square.stack.3d.up" : "smallcircle.filled.circle").font(.subheadline)
                .foregroundStyle(content.answered ? Theme.accent : Theme.ok).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(issue.title).font(.body.weight(.medium)).lineLimit(2)
                    if let folded, let fold {
                        Spacer(minLength: 4)
                        Button(action: fold) {
                            Image(systemName: folded ? "chevron.right.circle" : "chevron.down.circle").font(.body)
                                .foregroundStyle(.secondary).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(folded ? "Show sub-issues" : "Hide sub-issues")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    factLine(content.facts).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    BoardUpdated(date: issue.updatedAt)
                }
                if let progress = content.progress { BoardEpicProgress(progress: progress) }
                if !issue.labels.isEmpty { BoardLabelChips(labels: issue.labels) }
                if let parentLine = content.parentLine {
                    Label(parentLine, systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(Array(issue.pulls.enumerated()), id: \.offset) { _, link in BoardLinkedRow(link: link, repo: repo) }
            }
        }
        .padding(.vertical, 3)
    }
}

/// A row's facts as one line, " · " between them, each in its tone.
func factLine(_ facts: [RowFact]) -> Text {
    facts.enumerated().reduce(Text(verbatim: "")) { line, item in
        let fact = Text(verbatim: item.element.text).foregroundColor(Theme.color(item.element.tone))
        return item.offset == 0 ? fact : line + Text(verbatim: " · ").foregroundColor(.secondary) + fact
    }
}

/// A conversation run on a pull request or issue: its status, title, and status · model.
struct BoardSessionRow: View {
    let session: Session
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(status: session.status).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle).lineLimit(2).foregroundStyle(session.status == "closed" ? .secondary : .primary)
                Text(sessionSubtitle(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
