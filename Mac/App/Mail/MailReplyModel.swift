// The reply being written to the mail inbox's open message: a plain-text answer the server sends as the mailbox owner to
// the message's Reply-To (or sender), threaded on it, through POST /mail/accounts/{account}/messages/{id}/reply.
import Foundation

@MainActor
final class MailReplyModel: ObservableObject {
    /// The message being answered, by key; nil while no reply is open.
    @Published private(set) var target: String?
    @Published var text = ""
    @Published private(set) var sending = false
    @Published private(set) var error: String?
    /// The message last answered, by key, for a note under it once the provider took the reply.
    @Published private(set) var sent: String?

    var canSend: Bool { !sending && mailReplyBody(text) != nil }

    func start(_ m: MailMessage) {
        guard target != m.key else { return }
        target = m.key; text = ""; error = nil; sent = nil
    }
    /// Drops the reply unsent; one on its way still finishes.
    func cancel() {
        guard !sending else { return }
        target = nil; text = ""; error = nil
    }

    func send(_ m: MailMessage) {
        guard target == m.key, !sending, let body = mailReplyBody(text) else { return }
        var args = body
        args["account"] = JSON(m.accountID)
        args["id"] = .string(m.id)
        sending = true; error = nil
        Task {
            let r = await boardCall("reply_mail_message", args)
            sending = false
            switch r {
            case .failure(let e):
                if e.kind != .cancelled { error = mailReplyError(status: e.status) }
            case .success(let answer):
                guard mailReplyAccepted(answer) else { error = mailReplyError(status: 0); return }
                target = nil; text = ""; sent = m.key
            }
        }
    }
}
