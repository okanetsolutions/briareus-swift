// The held review round shown at the end of a conversation.
import AppKit
import SwiftUI

// MARK: - The held review round

/// A review round waiting for verdicts, completed from inside the conversation: each finding with Fix / Optional /
/// Dismiss, a note, and Complete.
struct TriageBox: View {
    unowned let model: ConversationModel
    var triage: JSON
    var decisions: [String: String]
    var note: String
    var enabled: Bool

    var body: some View {
        let takes = triageTakesVerdicts(triage)
        let findings = triage["findings"].items
        var fixes = 0
        for f in findings where takes && f["key"].string != nil && findingDecisionIndex(triageDecision(triage, f, picked: decisions)) == 0 { fixes += 1 }
        return VStack(alignment: .leading, spacing: 0) {
            Text(triageTitle(triage)).font(Theme.bodySemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                Rule().padding(.vertical, 8)
                finding(f, takes: takes)
            }
            Rule().padding(.vertical, 8)
            if takes {
                Button { model.editNote() } label: {
                    Text(note.isEmpty ? "A note for the pull request and the fix session (optional)" : note)
                        .font(Theme.caption2).foregroundStyle(note.isEmpty ? Theme.muted : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
            Button(triageCompleteTitle(takesVerdicts: takes, fixes: fixes)) { model.completeTriage(fixes: fixes) }
                .dashButton(.prominent).disabled(!enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder private func finding(_ f: JSON, takes: Bool) -> some View {
        let title = f["title"].string ?? "Finding"
        let url = f["url"].string
        if isSafeWebURL(url) {
            Button { openWebURL(url) } label: {
                Text(title).font(Theme.footnote).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        } else {
            SelectableText(title, font: SelectableFont.system(13), color: Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let location = findingLocation(f) {
            Text(location).font(Theme.monoCaption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail).padding(.top, 3)
        }
        if let why = f["parkedWhy"].string {
            SelectableText(why, font: SelectableFont.system(12), color: Theme.muted).padding(.top, 3)
        }
        if takes && f["key"].string != nil {
            Segments(titles: findingDecisionTitles, selected: findingDecisionIndex(triageDecision(triage, f, picked: decisions))) { i in
                model.pick(f, decision: i)
            }
            .disabled(!enabled)
            .padding(.top, 6)
        }
    }
}
