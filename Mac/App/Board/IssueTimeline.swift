// An issue's timeline (screen_pulls.c issue_layout_activity): comments in boxes as GitHub draws them, and every other event
// a line beside a round badge, worded by timelineEventWords; a page of 100 at a time, with Show more activity for the next.
import SwiftUI

struct IssueActivity: View {
    @ObservedObject var model: IssueModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        // The timeline is read once the issue is; when that read failed, there is none coming.
        if store.supports("issue_timeline") && !(model.events == nil && !model.readingTimeline && model.detailError != nil) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "Activity")
                if let e = model.timelineError { Notice(message: e).padding(.bottom, 10) }
                if let events = model.events {
                    let shown = events.indices.filter { events[$0]["kind"].string == "commented" || timelineEventWords(events[$0], repo: model.repo) != nil }
                    ForEach(Array(shown.enumerated()), id: \.element) { k, i in
                        let e = events[i]
                        if e["kind"].string == "commented" { comment(e).padding(.top, k > 0 ? 12 : 0) }
                        else if let words = timelineEventWords(e, repo: model.repo) { event(e, words).padding(.top, k > 0 ? 10 : 2) }
                    }
                    if shown.isEmpty { Text("No activity yet").font(Theme.callout).foregroundStyle(Theme.muted) }
                    if model.nextPage > 0 {
                        Button(model.readingTimeline ? "Loading…" : "Show more activity") { model.moreActivity() }
                            .dashButton(.bordered).disabled(model.readingTimeline).padding(.top, 14)
                    }
                } else if model.timelineError == nil {
                    LoadingNote(text: "Loading the timeline…").padding(.horizontal, -8)
                }
            }
        }
    }

    private func when(_ e: JSON) -> String? { boardDateParse(e["createdAt"].string).map { formatRelative($0) } }

    private func comment(_ e: JSON) -> some View {
        let did = when(e).map { "commented · \($0)" } ?? "commented"
        return CommentBox(head: CommentHead(author: e["actor"].string ?? "ghost", when: did), url: e["url"].string) {
            let t = visibleMarkdown(e["body"].string ?? "")
            if t.isEmpty { Text("No description provided.").font(Theme.callout.italic()).foregroundStyle(Theme.muted) }
            else { MarkdownView(source: t, size: .callout) }
        }
    }

    private func event(_ e: JSON, _ words: TimelineWords) -> some View {
        var runs = [FlowRun(text: (e["actor"].string ?? "ghost") + " ", font: Theme.footnoteSemibold, color: Theme.ink)]
        for p in words.parts { runs.append(run(p)) }
        if let at = when(e) { runs.append(FlowRun(text: at, font: Theme.footnote, color: Theme.muted)) }
        let target = timelineEventHasTarget(e)
        let tone: Color = words.tone == .accent ? Theme.accent : words.tone == .ok ? Theme.ok : Theme.muted
        return HStack(alignment: .top, spacing: 0) {
            Image(systemName: Glyph.symbol(words.glyph)).font(.system(size: 11)).foregroundStyle(tone)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.raise))
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                .padding(.leading, 14)
            WordFlow(runs: runs, lineHeight: 22).padding(.leading, 10).padding(.top, 2)
                .contentShape(Rectangle())
                .onTapGesture { if target { model.openEvent(e) } }
                .handCursor(target)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26, alignment: .top)
    }

    private func run(_ p: TimelinePart) -> FlowRun {
        switch p.style {
        case .strong: return FlowRun(text: p.text, font: Theme.footnoteSemibold, color: Theme.ink)
        case .muted: return FlowRun(text: p.text, font: Theme.footnote, color: Theme.muted)
        case .reference: return FlowRun(text: p.text, font: Theme.footnoteSemibold, color: Theme.accent)
        case .ink: return FlowRun(text: p.text, font: Theme.footnote, color: Theme.ink)
        case .label, .sha: return FlowRun(text: p.text, font: Theme.monoCaption2, color: Theme.accent, chip: true)
        case .quoted: return FlowRun(text: p.text, font: Theme.footnote, color: Theme.muted)
        case .quotedStrong: return FlowRun(text: p.text, font: Theme.footnoteSemibold, color: Theme.ink)
        }
    }
}
