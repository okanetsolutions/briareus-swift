// One session's pane in sleep mode: who it is, the file it touches typed out line by line, and its last command.
import SwiftUI

struct SleepPaneView: View {
    let pane: SleepPane

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(status: pane.status)
                Text(pane.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text([pane.repo, pane.branch].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            if let path = pane.path {
                Label(path, systemImage: pane.writes ? "pencil" : "doc.text")
                    .font(.caption.monospaced()).foregroundStyle(Theme.accent).lineLimit(1).truncationMode(.head)
            }
            SleepCode(pane: pane)
            if let command = pane.command {
                Text("$ \(command)").font(.caption.monospaced()).foregroundStyle(Theme.ok).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: BriareusRadius.xxl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BriareusRadius.xxl, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
        .opacity(pane.replay ? 0.7 : 1)
    }
}

/// The file's lines as typed so far, as many of the last ones as fit, with a cursor where the typing is.
private struct SleepCode: View {
    let pane: SleepPane
    @ScaledMetric(relativeTo: .caption2) private var lineHeight = 14

    var body: some View {
        GeometryReader { geo in
            Group {
                if pane.path == nil {
                    note("Waiting for its first file")
                } else if pane.code == nil {
                    note("Reading…")
                } else if pane.code?.isEmpty == true {
                    note("Nothing to show for this file")
                } else {
                    let lines = pane.visibleLines(rows: max(Int(geo.size.height / lineHeight), 1))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            row(line, cursor: line.id == lines.last?.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .clipped()
    }

    private func row(_ line: SleepLine, cursor: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(line.number)").foregroundStyle(Theme.muted.opacity(0.5)).frame(minWidth: 24, alignment: .trailing)
            line.tokens.reduce(Text("")) { $0 + Text($1.text).foregroundStyle(Self.color($1.kind)) }
                + (cursor ? Text("▌").foregroundStyle(Theme.accent) : Text(""))
        }
        .font(.caption2.monospaced())
        .lineLimit(1)
        .frame(height: lineHeight, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func color(_ kind: CodeTokenKind) -> Color {
        switch kind {
        case .keyword: return Theme.accent
        case .string: return Theme.ok
        case .comment: return Theme.muted
        case .number: return Theme.warn
        case .type: return Theme.series(2)
        case .variable: return Theme.series(4)
        case .plain: return Theme.ink
        }
    }
}
