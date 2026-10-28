// One finding and its manual verdict or thread actions.
import SwiftUI


/// One finding: its severity, its title and place (which open it on the pull request), the loop's advice, and the verdict
/// and comment on the user's own pull request, or Reply and Delete on somebody else's.
struct FindingView: View {
    @ObservedObject var model: FindingsModel
    var session: Session
    var held: JSON
    var finding: JSON
    var mine: Bool
    @ObservedObject private var store = Store.shared

    private func open() {
        let url = finding["url"].string
        if safeWebURL(url) { openWebURL(url) }
        else if let pr = session.heldRoundPRURL(held) { openWebURL("\(pr)/files") }
    }

    var body: some View {
        let sid = session.id, round = FindingsModel.roundNumber(held)
        let key = finding["key"].string, title = finding["title"].string
        let busy = model.busy
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Color.clear.frame(height: 8)
            HStack(alignment: .top, spacing: 6) {
                let sev = finding["severity"].string
                Badge(text: findingSeverityLabel(sev), color: severityColor(sev), background: Theme.raise)
                Button(action: open) {
                    Text(title ?? "Finding").font(Theme.footnote).foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(FDKit.LinkStyle())
                Spacer(minLength: 0)
            }
            if let loc = Findings.location(finding) {
                Button(action: open) {
                    Text(loc).font(Theme.monoCaption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(FDKit.LinkStyle())
                .padding(.top, 4)
            }
            if let details = FeedbackAssessmentDetails(finding) { FeedbackAssessmentView(details: details) }
            if let advice = Findings.parkedAdvice(finding) {
                Text(advice).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            }
            if store.canManage, let key {
                if mine {
                    if store.supports("complete_findings") {
                        Segments(titles: findingDecisionTitles, selected: findingDecisionIndex(model.decision(sid, round, key))) {
                            model.setVerdict(sid, round, key: key, segment: $0)
                        }
                        .disabled(busy)
                        .padding(.top, 4)
                        let reason = model.reason(sid, round, key)
                        Button { model.comment(sid, round, key: key, title: title) } label: {
                            Text(reason.isEmpty ? "Comment (saved to the pull request)" : reason)
                                .font(Theme.caption2).foregroundStyle(reason.isEmpty ? Theme.muted : Theme.ink)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(FDKit.LinkStyle())
                        .disabled(busy)
                        .padding(.top, 4)
                    }
                } else {
                    othersControls(sid, round, key, title)
                }
            }
        }
    }

    @ViewBuilder
    private func othersControls(_ sid: String, _ round: Int, _ key: String, _ title: String?) -> some View {
        let reply = store.supports("reply_finding"), delete = store.supports("delete_finding")
        if reply || delete {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if reply {
                    GlyphButton(glyph: Glyph.symbol(0xE97A), title: model.writing(.reply, sid, key) ? "Replying\u{2026}" : "Reply") {
                        model.reply(sid, round, key: key, title: title)
                    }
                }
                if delete {
                    GlyphButton(glyph: Glyph.symbol(0xE74D), title: model.writing(.delete, sid, key) ? "Deleting\u{2026}" : "Delete from the review",
                                kind: .destructive) {
                        model.delete(sid, round, key: key, title: title, pr: heldRoundPRNumber(held) ?? 0)
                    }
                }
            }
            .disabled(model.busy)
            .padding(.top, 6)
        }
        if let rp = model.repliedOn(sid, key) {
            Group {
                if let e = rp.error {
                    Text(verbatim: "Not replied: \(e)").font(Theme.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                } else if let url = rp.url {
                    Button { openWebURL(url) } label: {
                        Text("Replied \u{00B7} on the pull request \u{2197}").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .buttonStyle(FDKit.LinkStyle())
                } else {
                    Text("Replied").font(Theme.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 4)
        }
    }
}
