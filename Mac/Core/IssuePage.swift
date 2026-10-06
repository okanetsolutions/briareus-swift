// What the issue page works out without drawing anything: its state pill, the linked pull requests still open, and its
// timeline's events in GitHub's words (screen_pulls.c issue_state, issue_open_pulls and event_words).
import Foundation

// MARK: - State

/// The state pill: GitHub's green Open, purple Closed, grey for one closed as not planned or a duplicate, and "not on the
/// board" for one the board no longer lists that was not read on its own (yet).
enum IssuePageState: Equatable, Sendable {
    case open, closed, closedAside, offBoard

    /// `detail` is the issue's own read (null until it answers); `closedReason` is set once this screen closed it.
    init(detail: JSON, closedHere: Bool, closedReason: String?, gone: Bool) {
        var state = detail["state"].string, reason = detail["stateReason"].string
        if closedHere { state = "closed"; reason = closedReason }
        if state == "closed" { self = reason == "not_planned" || reason == "duplicate" ? .closedAside : .closed; return }
        self = detail.isNull && gone ? .offBoard : .open
    }
    var text: String { self == .open ? "open" : self == .offBoard ? "not on the board" : "closed" }
    var isClosed: Bool { self == .closed || self == .closedAside }
}

/// The pull requests still open among those linked to it; the full read lists merged and closed ones too.
func issueOpenPulls(_ issue: IssueSummary) -> Int { issue.pulls.filter { $0.state == nil || $0.state == "open" }.count }

// MARK: - Timeline

/// One run of an event's sentence, and how it is drawn.
struct TimelinePart: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        /// The actor, a login or a name: semibold ink.
        case strong
        /// GitHub's own words: muted.
        case muted
        /// The reference of an issue or pull request pointed to: semibold accent.
        case reference
        /// Its title, a commit's message: ink.
        case ink
        /// A label's name, in the accent as a chip.
        case label
        /// A commit's short sha, mono in the accent as a chip.
        case sha
        /// The title a rename started from, quoted: secondary.
        case quoted
        /// The title it was renamed to, quoted: semibold ink.
        case quotedStrong
    }
    var text: String
    var style: Style
}

/// An event as GitHub words it after its actor, with its badge's glyph (a Segoe Fluent Icons code point) and colour.
struct TimelineWords: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case muted, accent, ok }
    var glyph: UInt32 = 0xE8EC
    var tone = Tone.muted
    var parts: [TimelinePart] = []

    fileprivate mutating func strong(_ text: String?) { if let text { parts.append(TimelinePart(text: text + " ", style: .strong)) } }
    fileprivate mutating func muted(_ text: String) { parts.append(TimelinePart(text: text, style: .muted)) }
    /// An issue or pull request an event points to: `#12 Its title`, or `owner/name#12` from another repository.
    fileprivate mutating func reference(_ ref: JSON, repo: String?) {
        guard let link = BoardLink(ref) else { return }
        parts.append(TimelinePart(text: link.reference(repo) + " ", style: .reference))
        parts.append(TimelinePart(text: link.title + " ", style: .ink))
    }
}

/// The words of a timeline event other than a comment; nil for a comment and for a kind this app does not draw.
func timelineEventWords(_ e: JSON, repo: String?) -> TimelineWords? {
    let kind = e["kind"].string ?? ""
    var w = TimelineWords()
    switch kind {
    case "labeled", "unlabeled":
        w.muted(kind == "labeled" ? "added the " : "removed the ")
        if let name = e["label"]["name"].string { w.parts.append(TimelinePart(text: name, style: .label)) }
        w.muted("label ")
    case "assigned", "unassigned":
        let who = e["assignee"].string
        let isSelf = who != nil && foldEqual(who, e["actor"].string)
        w.glyph = 0xE77B
        if kind == "assigned" {
            if isSelf { w.muted("self-assigned this ") } else { w.muted("assigned "); w.strong(who) }
        } else if isSelf { w.muted("removed their assignment ") }
        else { w.muted("unassigned "); w.strong(who) }
    case "milestoned", "demilestoned":
        w.glyph = 0xE7C1
        w.muted(kind == "milestoned" ? "added this to the " : "removed this from the ")
        w.strong(e["milestone"].string)
        w.muted("milestone ")
    case "renamed":
        w.glyph = 0xE70F
        w.muted("changed the title ")
        if let from = e["from"].string { w.parts.append(TimelinePart(text: "\u{201C}\(from)\u{201D} ", style: .quoted)) }
        w.muted("to ")
        if let to = e["to"].string { w.parts.append(TimelinePart(text: "\u{201C}\(to)\u{201D} ", style: .quotedStrong)) }
    case "closed":
        let reason = e["stateReason"].string
        let aside = reason == "not_planned" || reason == "duplicate"
        w.glyph = aside ? 0xE711 : 0xE73E; w.tone = aside ? .muted : .accent
        w.muted(reason == "not_planned" ? "closed this as not planned " : reason == "duplicate" ? "closed this as a duplicate "
                : reason == "completed" ? "closed this as completed " : "closed this ")
    case "reopened":
        w.glyph = 0xE72C; w.tone = .ok
        w.muted("reopened this ")
    case "cross-referenced":
        w.glyph = 0xE71B
        w.muted("mentioned this in ")
        w.reference(e["source"], repo: repo)
    case "connected", "disconnected":
        w.glyph = 0xE71B
        w.muted(kind == "connected" ? "linked a pull request that will close this issue " : "removed a link to a pull request ")
        w.reference(e["source"], repo: repo)
    case "referenced":
        w.glyph = 0xE8EE
        w.muted("referenced this in commit ")
        if let sha = e["commit"]["sha"].string { w.parts.append(TimelinePart(text: String(sha.prefix(7)), style: .sha)) }
        if let message = e["commit"]["message"].string { w.parts.append(TimelinePart(text: message + " ", style: .ink)) }
    case "parent_issue_added", "parent_issue_removed":
        w.glyph = 0xE71B
        w.muted(kind == "parent_issue_added" ? "added a parent issue " : "removed a parent issue ")
        w.reference(e["issue"], repo: repo)
    case "sub_issue_added", "sub_issue_removed":
        w.glyph = 0xE71B
        w.muted(kind == "sub_issue_added" ? "added a sub-issue " : "removed a sub-issue ")
        w.reference(e["issue"], repo: repo)
    case "issue_type_added", "issue_type_removed", "issue_type_changed":
        let type = e["type"].string
        if kind == "issue_type_changed" {
            w.muted("changed the issue type from "); w.strong(e["previousType"].string); w.muted("to "); w.strong(type)
        } else {
            w.muted(kind == "issue_type_added" ? "added the " : "removed the "); w.strong(type); w.muted("issue type ")
        }
    case "added_to_project_v2", "removed_from_project_v2", "project_v2_item_status_changed":
        let project = e["project"].string
        let moved = kind == "project_v2_item_status_changed"
        w.glyph = 0xE8FD
        if moved {
            w.muted("moved this ")
            if let before = e["previousStatus"].string { w.muted("from "); w.strong(before) }
            w.muted("to "); w.strong(e["status"].string ?? "No status")
        } else { w.muted(kind == "added_to_project_v2" ? "added this to " : "removed this from ") }
        if let project { if moved { w.muted("in ") }; w.strong(project) }
        else if !moved { w.muted("a project ") }
    default:
        return nil
    }
    return w
}

/// Whether clicking an event goes somewhere: a comment's place on GitHub, the issue, pull request or commit it points to.
func timelineEventHasTarget(_ e: JSON) -> Bool {
    if e["kind"].string == "commented" { return safeWebURL(e["url"].string) }
    if e["source"]["number"].number != nil || e["issue"]["number"].number != nil { return true }
    return safeWebURL(e["commit"]["url"].string)
}
