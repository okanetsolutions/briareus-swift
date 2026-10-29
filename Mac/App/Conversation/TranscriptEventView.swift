// One transcript message, question, tool output or turn footer, compared independently as new events arrive.
import SwiftUI

/// A message's time: the clock today, else the day and the clock.
private struct EventTime: View {
    var event: Event
    var trailing = false
    var body: some View {
        if let when = event.time {
            SelectableText(formatEventTime(when), font: SelectableFont.system(11), color: Theme.muted, align: trailing ? .right : .left)
                .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                .padding(.top, 6)
        }
    }
}

/// One visible event: the user's message, the agent's reply in Markdown, a question with its options, a turn's footer,
/// or a log line.
struct TranscriptEventView: View, Equatable {
    var event: Event
    var canMessage: Bool
    var answer: (String) -> Void
    static func == (a: Self, b: Self) -> Bool { a.event == b.event && a.canMessage == b.canMessage }

    var body: some View {
        switch event.kind {
        case "user":
            // `rounded-xl border border-line bg-raise px-3.5 py-2.5`, the time right-aligned under the text.
            VStack(alignment: .leading, spacing: 0) {
                SelectableText(event.text ?? "", font: SelectableFont.system(15), color: Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array((event.attachments?.items ?? []).enumerated()), id: \.offset) { _, a in
                    Text(verbatim: "\u{1F4CE} \(a["name"].string ?? "Attachment")").font(Theme.caption).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.tail).padding(.top, 6)
                }
                EventTime(event: event, trailing: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
            .padding(.top, 18).padding(.bottom, 14)
        case "text":
            VStack(alignment: .leading, spacing: 0) {
                MarkdownView(source: event.text ?? "")
                EventTime(event: event)
            }
            .padding(.vertical, 10)
        case "ask":
            VStack(alignment: .leading, spacing: 0) {
                SelectableText("Your input is needed", font: SelectableFont.system(12), color: Theme.accent)
                MarkdownView(source: event.question ?? event.text ?? "").padding(.top, 8)
                if canMessage {
                    let labels = (event.options?.items ?? []).compactMap { $0["label"].string }
                    if !labels.isEmpty {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                                Button(label) { answer(label) }.dashButton(.bordered)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, lineWidth: 1))
            .padding(.vertical, 10)
        case "btw":
            // A side question (/btw): answered from a fork of the conversation the agent never sees.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("By the way").font(Theme.caption2).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6).frame(height: 16).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
                SelectableText(event.text ?? "", font: SelectableFont.system(14), color: Theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.top, 12).padding(.bottom, 4)
            .help("A side question: the agent does not see it or its answer")
        case "btw_answer":
            VStack(alignment: .leading, spacing: 4) {
                if event.isError == true {
                    SelectableText(event.text ?? "No answer", font: SelectableFont.system(13), color: Theme.danger)
                } else {
                    MarkdownView(source: event.text ?? "")
                }
                let cost = event.costUsd.map { String(format: "$%.4f", $0) }
                let secs = event.durationMs.map { "\(Int(($0 / 1000).rounded()))s" }
                if let line = [cost, secs].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text("side answer · \(line)").font(Theme.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.accentDim).frame(width: 2) }
            .padding(.bottom, 10)
        case "result":
            // "— $2.9565 · 455s · 57 turns · …", under a dashed rule.
            let text = turnFooterText(event)
            VStack(alignment: .leading, spacing: 0) {
                Line().stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
                Text(text).font(Theme.caption).foregroundStyle(event.isError == true ? Theme.danger : Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(height: 20).padding(.top, 8)
            }
            .padding(.top, 10).padding(.bottom, 4)
        default:
            if event.text != nil {
                TranscriptLogLine(text: logLineText(event), color: event.kind == "stderr" ? Theme.danger : Theme.muted)
            }
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); return p }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
