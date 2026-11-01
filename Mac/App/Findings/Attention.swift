// What the server says waits on the operator (core /attention): approvals an agent asked for, a command over SSH or a
// Slack message to send as you, to rule on at once, and questions and failures to open. The ◉ Status screen lists them
// and the sidebar strip counts the approvals; the projects' poll reads them.
import Combine
import SwiftUI

/// What the server says waits on the operator: approvals to rule on at once, and questions and failures to open.
@MainActor
final class AttentionModel: ObservableObject {
    static let shared = AttentionModel()
    @Published private(set) var items: [AttentionItem] = []
    @Published private(set) var error: String?
    /// The approvals a decision is on its way for, and what each came back with.
    @Published private(set) var deciding: Set<String> = []
    @Published private(set) var results: [String: String] = [:]

    private var generation = 0
    private var signOut: AnyCancellable?

    private init() {
        // Signing out (or a revoked token) takes what the last server was waiting on with it.
        signOut = Store.shared.$client.map { $0 != nil }.removeDuplicates().dropFirst().sink { connected in
            guard !connected else { return }
            MainActor.assumeIsolated { AttentionModel.shared.reset() }
        }
    }

    static var offered: Bool { Store.shared.isAdmin && Store.shared.supports("attention") }
    /// The approvals waiting, which the strip's ◉ counts beside the conversations needing you.
    var approvals: Int { items.filter(\.isApproval).count }

    private func reset() {
        generation += 1
        items = []; error = nil; deciding = []; results = [:]
    }

    func load() async -> APIError? {
        // A token that may not see them (or a server without them) leaves nothing from the last one standing.
        guard Self.offered else {
            if !items.isEmpty || error != nil || !results.isEmpty || !deciding.isEmpty { reset() }
            return nil
        }
        let mine = generation
        let r = await boardCall("attention")
        guard mine == generation else { return nil }
        switch r {
        case .success(let v):
            items = AttentionItem.parse(v)
            error = nil
            return nil
        case .failure(let e):
            if e.kind != .cancelled { error = e.description }
            return e
        }
    }

    /// Approves (the command runs, the message goes out) or denies an agent's request.
    func decide(_ item: AttentionItem, approve: Bool) {
        let op = item.kind == "ssh" ? "ssh_decision" : "slack_decision"
        guard let rid = item.requestID, Store.shared.supports(op), !deciding.contains(item.id) else { return }
        if approve && item.kind == "slack" {
            guard Dialogs.confirm("Send this Slack message as you?", item.summary, continueLabel: "Send") else { return }
        }
        deciding.insert(item.id)
        let mine = generation
        Task {
            let r = await boardCall(op, ["id": .string(rid), "decision": .string(approve ? "approve" : "deny")])
            guard mine == generation else { return }
            deciding.remove(item.id)
            switch r {
            case .success(let v):
                let status = v["request"]["status"].string ?? (approve ? "approved" : "denied")
                results[item.id] = v["request"]["error"].nonEmpty.map { "\(status): \($0)" } ?? status
            case .failure(let e):
                results[item.id] = e.description
            }
            _ = await load()
        }
    }
}

/// The Waiting on you list: each item with its kind, what it asks, and for an approval Run/Send it and Deny.
struct AttentionSection: View {
    @ObservedObject var model: AttentionModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        if AttentionModel.offered && (!model.items.isEmpty || model.error != nil) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Waiting on you").font(Theme.bodySemibold).foregroundStyle(Theme.ink)
                if let e = model.error { Notice(message: e) }
                ForEach(model.items) { item in row(item) }
            }
            .padding(.bottom, 22)
        }
    }

    private func row(_ item: AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.label).font(Theme.caption2).foregroundStyle(item.isApproval ? Theme.onAccent : Theme.ink)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: BriareusRadius.sm).fill(item.isApproval ? Theme.accent : Theme.raise))
                Text(item.title).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                if let at = item.at { Text(formatRelative(at)).font(Theme.caption).foregroundStyle(Theme.muted) }
            }
            if !item.detail.isEmpty { Text(item.detail).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(2) }
            if item.kind == "ssh" {
                Text(item.summary).font(Theme.mono).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: BriareusRadius.md).fill(Theme.sunken))
            } else {
                Text(item.summary).font(Theme.footnote).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if item.isApproval {
                    let op = item.kind == "ssh" ? "ssh_decision" : "slack_decision"
                    let busy = model.deciding.contains(item.id)
                    Button(item.kind == "ssh" ? "Run it" : "Send it") { model.decide(item, approve: true) }
                        .dashButton(.prominent).disabled(busy || !store.supports(op))
                    Button("Deny") { model.decide(item, approve: false) }.dashButton(.destructive).disabled(busy || !store.supports(op))
                    if let exp = item.expiresAt { Text("expires \(formatEventTime(exp))").font(Theme.caption).foregroundStyle(Theme.muted) }
                }
                if let sid = item.sessionID {
                    Button("Open the conversation") { Navigator.shared.push(.conversation(id: sid, session: nil)) }
                        .buttonStyle(.plain).font(Theme.footnote).foregroundStyle(Theme.accent)
                }
                if let r = model.results[item.id] { Text(r).font(Theme.caption).foregroundStyle(Theme.muted) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BriareusRadius.xl).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: BriareusRadius.xl).strokeBorder(item.isApproval ? Theme.accentDim : Theme.line, lineWidth: 1))
    }
}
