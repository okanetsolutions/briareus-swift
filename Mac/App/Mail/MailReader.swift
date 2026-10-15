// The open message beside the mail inbox's list (MailScreen.swift): its subject and people, its labels, Open at the
// provider, Reply and Move to Trash, its text and its attachments, described; and the reply being written to it.
import SwiftUI

/// The open message: its subject and people, its labels, the reply being written, its text and its attachments, described.
struct MailReader: View {
    @ObservedObject var model: MailInboxModel

    var body: some View {
        let m = model.body ?? model.selectedSummary
        VStack(alignment: .leading, spacing: 0) {
            MailReaderBar(model: model, message: m)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let m {
                        Text(m.shownSubject).font(Theme.title3).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        people(m)
                        if !m.labels.isEmpty {
                            FlowLayout(spacing: 4, lineSpacing: 4) {
                                ForEach(m.labels, id: \.self) { l in
                                    Text(l).font(Theme.caption2).foregroundStyle(Theme.muted).padding(.horizontal, 6).frame(height: 18)
                                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 1))
                                }
                            }
                        }
                        if let summary = model.selectedSummary { MailReplyBox(reply: model.reply, message: summary) }
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 6)
                    }
                    if let e = model.bodyError {
                        Notice(message: e)
                        if let s = model.selectedSummary {
                            Button("Try again") { Task { await model.loadBody(s) } }.dashButton(.bordered).disabled(model.readingBody || model.coolingDown)
                        }
                    }
                    if model.readingBody { LoadingNote(text: "Loading the message…") }
                    if let b = model.body {
                        if b.truncated { Notice(message: "The server cut this message short. Open it at the provider to read all of it.") }
                        // Its text as text: no HTML, images, scripts or live links.
                        SelectableText(expandTabs(b.text?.isEmpty == false ? b.text! : "This message has no text in the synced copy."),
                                       font: SelectableFont.system(14), color: b.text?.isEmpty == false ? Theme.ink : Theme.muted)
                        if !b.attachments.isEmpty {
                            Text("Attachments (described only; their content is not synced)").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).padding(.top, 14)
                            ForEach(Array(b.attachments.enumerated()), id: \.offset) { _, a in
                                HStack(spacing: 6) {
                                    Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                    Text("\(a.name) · \(a.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))")
                                        .font(Theme.footnote).foregroundStyle(Theme.muted).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func people(_ m: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            line("From", m.sender)
            if !m.to.isEmpty { line("To", m.to) }
            if !m.cc.isEmpty { line("Cc", m.cc) }
            if !m.replyTo.isEmpty { line("Reply-To", m.replyTo) }
            line("Received", m.receivedAt.map { formatEventTime($0) } ?? "unknown")
            if let a = model.accounts.find(m.accountID) { line("Mailbox", a.title) }
        }
    }
    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Theme.footnote).foregroundStyle(Theme.muted).frame(width: 70, alignment: .leading)
            Text(value).font(Theme.footnote).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Over the open message: Open at the provider, Reply, Move to Trash and Close.
private struct MailReaderBar: View {
    @ObservedObject var model: MailInboxModel
    @ObservedObject var reply: MailReplyModel
    let message: MailMessage?

    init(model: MailInboxModel, message: MailMessage?) {
        self.model = model; self.reply = model.reply; self.message = message
    }

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            if let url = model.body?.webURL {
                Button("Open at \(model.accounts.find(message?.accountID ?? 0)?.providerName ?? "the provider") ↗") { openWebURL(url) }.dashButton(.bordered)
            }
            if let m = model.selectedSummary, model.canReply(m) {
                Button("Reply") { reply.start(m) }
                    .dashButton(.bordered).disabled(reply.target == m.key)
                    .help("Answer the sender in plain text, in this message's thread")
            }
            if let m = message, model.canTrash(m) {
                Button(model.trashing == m.key ? "Moving…" : "Move to Trash") { model.trash(m) }
                    .dashButton(.bordered).disabled(model.trashing != nil)
                    .help("Move this message to the provider's trash")
            }
            Button { model.close() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("Close the message")
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }
}

/// The reply to the open message while one is written, or a note once the provider took it.
private struct MailReplyBox: View {
    @ObservedObject var reply: MailReplyModel
    let message: MailMessage

    var body: some View {
        if reply.target == message.key {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reply to \(message.replyTo.isEmpty ? message.sender : message.replyTo)")
                    .font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                TextEditor(text: $reply.text)
                    .font(Theme.body).frame(minHeight: 120)
                    .disabled(reply.sending)
                    .overlay(RoundedRectangle(cornerRadius: BriareusRadius.md).strokeBorder(Theme.line, lineWidth: 1))
                if let e = reply.error { Notice(message: e) }
                HStack(spacing: 8) {
                    Button(reply.sending ? "Sending…" : "Send") { reply.send(message) }
                        .dashButton(.prominent).disabled(!reply.canSend)
                    Button("Cancel") { reply.cancel() }.dashButton(.bordered).disabled(reply.sending)
                    Text("Plain text, sent as the mailbox's owner.").font(Theme.footnote).foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 8)
        } else if reply.sent == message.key {
            Label("Reply sent.", systemImage: "checkmark").font(Theme.footnote).foregroundStyle(Theme.ok).padding(.top, 6)
        }
    }
}
