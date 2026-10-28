// The conversation's `#messages` (screen_conversation.c conversation_layout): the errors, the transcript with workspace
// preparation and tool calls folded into blocks, why the session failed, the queued messages, the held review round and
// the working line.
import AppKit
import SwiftUI

/// Whether a link is one the app opens: https with a host and no credentials.
func isSafeWebURL(_ url: String?) -> Bool {
    guard let url, let u = URL(string: url), u.scheme?.lowercased() == "https", u.host != nil, u.user == nil, u.password == nil else { return false }
    return true
}

/// The transcript's column. Its inputs are compared, so typing in the composer or a poll that changed nothing does not
/// lay it out again; and it is lazy, so a long conversation makes and measures only the messages near the screen
/// instead of every one each time the agent adds a line.
struct TranscriptColumn: View, Equatable {
    unowned let model: ConversationModel
    var blocks: TranscriptRows
    var session: Session
    var expanded: Set<Int>
    var decisions: [String: String]
    var triageNote: String
    var loaded: Bool
    var error: String?
    var writeError: String?
    var busy: Bool
    var loading: Bool
    var uncertain: Bool
    var canMessage: Bool

    static func == (a: TranscriptColumn, b: TranscriptColumn) -> Bool {
        a.blocks == b.blocks && sameShown(a.session, b.session) && a.expanded == b.expanded && a.decisions == b.decisions
            && a.triageNote == b.triageNote && a.loaded == b.loaded && a.error == b.error && a.writeError == b.writeError
            && a.busy == b.busy && a.loading == b.loading && a.uncertain == b.uncertain && a.canMessage == b.canMessage
    }

    /// The parts of the session the column shows: a poll that changed only the rest does not lay it out again.
    private static func sameShown(_ a: Session, _ b: Session) -> Bool {
        a.raw["error"] == b.raw["error"] && a.status == b.status && a.queued == b.queued && a.heldTriage == b.heldTriage
            && a.backgroundTasks == b.backgroundTasks
    }

    private var can: Bool { !busy && !uncertain }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let error { DangerBox { DangerText(error) }.padding(.bottom, 12) }
            if let writeError {
                DangerBox(bottom: 10) {
                    DangerText(writeError)
                    SelectableText("The action may have completed. Check the latest conversation before trying again.",
                                   font: SelectableFont.system(12), color: Theme.muted)
                        .padding(.top, 4)
                    Button("Refresh and check outcome") { model.refreshOutcome() }
                        .dashButton(.bordered).disabled(loading || busy).padding(.top, 8)
                }
                .padding(.bottom, 12)
            }
            if blocks.isEmpty && error == nil {
                SelectableText(loaded ? "No messages yet." : "Waiting for the conversation\u{2026}", font: SelectableFont.system(13), color: Theme.muted)
            }
            ForEach(blocks, id: \.seq) { block in
                VStack(alignment: .leading, spacing: 0) { blockView(block) }.environment(\.findBlock, block.seq)
            }
            // Why the session failed: the Windows client's `⚠ error` in the head, said where the transcript stops.
            if let failure = session.raw["error"].nonEmpty {
                DangerBox { DangerText("\u{26A0} \(failure)") }.padding(.top, 10)
            }
            queued
            if let triage = session.heldTriage, Store.shared.supports("complete_findings") {
                TriageBox(model: model, triage: triage, decisions: decisions, note: triageNote, enabled: can).padding(.top, 14)
            }
            if session.isActive { WorkingLine(status: session.status, background: session.backgroundTasks, answered: transcriptAnswered(blocks)).padding(.top, 12) }
            // Keep the target in the lazy stack so jumping to it also lays out the latest messages.
            Color.clear.frame(height: 1).id("end")
                .background(GeometryReader { g in
                    Color.clear.preference(key: TranscriptEndKey.self, value: g.frame(in: .named("transcript")).maxY)
                })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: TranscriptBlock) -> some View {
        switch block {
        case .preparation(let events):
            Folded(summary: block.summary ?? "", open: expanded.contains(block.seq), toggle: { toggle(block.seq) }) {
                ForEach(events, id: \.seq) { e in TranscriptLogLine(text: logLineText(e), color: Theme.muted) }
            }
        case .tools(let events):
            Folded(summary: block.summary ?? "", open: expanded.contains(block.seq), toggle: { toggle(block.seq) }) {
                ForEach(events, id: \.seq) { e in ToolStep(event: e) }
            }
        case .event(let e):
            TranscriptEventView(event: e, canMessage: canMessage, answer: { model.answer($0) }).equatable()
        }
    }
    private func toggle(_ seq: Int) {
        if model.expanded.contains(seq) { model.expanded.remove(seq) } else { model.expanded.insert(seq) }
    }

    @ViewBuilder private var queued: some View {
        let items = session.queued.items
        let removable = Store.shared.supports("drop_message") && can
        ForEach(Array(items.enumerated()), id: \.offset) { q, item in
            let text = item["text"].string ?? "Message"
            VStack(alignment: .leading, spacing: 0) {
                SelectableText(text, font: SelectableFont.system(15), color: Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [1, 2])))
                HStack(spacing: 0) {
                    SelectableText("Queued for the next turn", font: SelectableFont.system(11), color: Theme.muted)
                    Spacer(minLength: 0)
                    if removable {
                        Button { model.mutate("drop_message", ["index": JSON(q)]) } label: {
                            Text("Remove").font(Theme.caption2).foregroundStyle(Theme.danger)
                        }
                        .buttonStyle(.plain)
                        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                        .fixedSize()
                    }
                }
                .frame(height: 18)
                .padding(.top, 4)
            }
            .padding(.top, 10)
        }
    }
}

// MARK: - Pieces

/// `doc_notice_box`: danger text on a danger tint with a danger border, 8px corners.
private struct DangerBox<Content: View>: View {
    var bottom: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.danger, lineWidth: 1))
    }
}
private struct DangerText: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        SelectableText(text, font: SelectableFont.system(13), color: Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.ev-log`: a 12px mono line.
struct TranscriptLogLine: View {
    var text: String
    var color: Color
    var body: some View {
        SelectableText(text, font: SelectableFont.mono(12), color: color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
    }
}

/// A `<details>`: its 13px muted summary with ▸/▾ (ink on hover); open, its lines indented 12px beside a 2px rule.
private struct Folded<Content: View>: View {
    var summary: String
    var open: Bool
    var toggle: () -> Void
    @ViewBuilder var content: Content
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                Text(verbatim: "\(open ? "\u{25BE}" : "\u{25B8}") \(summary)").font(Theme.footnote).foregroundStyle(hovered ? Theme.ink : Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            if open { content }
        }
        .padding(.leading, open ? 12 : 0)
        .overlay(alignment: .leading) { if open { Rectangle().fill(Theme.line).frame(width: 2) } }
        .padding(.vertical, 8)
    }
}

/// One step of a tool block: the tool's name in a chip, then what it did, in mono, on one line.
private struct ToolStep: View {
    var event: Event
    var body: some View {
        let error = event.kind == "tool_error"
        let summary = firstLine(event.detail)
        HStack(spacing: 8) {
            Text(toolTitle(event)).font(Theme.caption).foregroundStyle(error ? Theme.danger : Theme.ink).lineLimit(1)
                .padding(.horizontal, 6).frame(height: 19)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(error ? Theme.danger : Theme.line, lineWidth: 1))
                .fixedSize()
            Text(summary).font(Theme.monoSmall).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: 19)
        .padding(.vertical, 3)
    }
}

/// A 1px rule in the line colour.
struct Rule: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}
