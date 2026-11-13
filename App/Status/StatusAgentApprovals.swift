// The SSH commands and Slack messages agents asked to run or send as you, as a section of the Status list (the Mac's
// ◉ Status → Waiting on you, AttentionSection): each with its kind, where it comes from and goes, the command or message,
// Run it or Send it and Deny for a token that may rule on it, when it expires, its conversation, and what the decision
// came back with, and why the inbox could not be read. Sending a Slack message as you asks first. The words and rules
// are AttentionLogic's.
import SwiftUI

struct StatusAgentApprovals: View {
    @ObservedObject var model: StatusApprovalsModel

    var body: some View {
        let requests = model.agentRequests
        if let error = model.error { Section { ErrorNotice(message: error) }.listRowBackground(Theme.row) }
        if !requests.isEmpty {
            Section("Waiting on you") {
                ForEach(requests) { AgentApprovalRow(item: $0, model: model).listRowBackground(Theme.row) }
            }
        }
    }
}

/// One request: what it is, the command or message, and the decision.
private struct AgentApprovalRow: View {
    let item: AttentionItem
    @ObservedObject var model: StatusApprovalsModel
    @Environment(\.navigate) private var navigate
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.label).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let at = item.at { Text(formatRelative(at)).font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary) }
            if item.kind == "ssh" {
                CodeBlock(language: "shell", text: item.summary)
            } else {
                Text(item.summary).font(.footnote).textSelection(.enabled)
            }
            if model.canDecide(item) { decision }
            if let sid = item.sessionID {
                Button("Open the conversation") { navigate(.conversation(id: sid, session: nil)) }
                    .buttonStyle(.borderless).font(.footnote)
            }
            if let result = model.results[item.id] { Text(result).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
        .alert("Send this Slack message as you?", isPresented: $confirming) {
            Button("Send") { model.decide(item, approve: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(item.summary)
        }
    }

    /// Run it or Send it, Deny, and when the request expires.
    private var decision: some View {
        let busy = model.deciding.contains(item.id)
        return HStack(spacing: 10) {
            Button(item.kind == "ssh" ? "Run it" : "Send it") {
                if item.confirmsFirst(approve: true) { confirming = true } else { model.decide(item, approve: true) }
            }
            .buttonStyle(.borderedProminent)
            Button("Deny", role: .destructive) { model.decide(item, approve: false) }.buttonStyle(.bordered)
            if busy { ProgressView() }
            Spacer(minLength: 0)
            if let exp = item.expiresAt { Text("expires \(formatEventTime(exp))").font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(busy)
    }
}
