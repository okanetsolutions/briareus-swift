// ◉ Status at the top of the Findings tab, the Mac's Status screen laid out for a phone: how many conversations need you,
// are working and are ready, then every one waiting for your answer, with the agent's question, its options as buttons
// and a reply field, then what is working now. The review rounds held for a decision are the tab's queue below it, each
// opening its triage card. It reads the sessions the projects' feeds already keep (the tab's own reading of every
// project), so it needs no loop of its own; only a waiting conversation's question is read from its transcript.
import SwiftUI

/// The questions the waiting conversations left, read from each transcript: the saved lines and what came since.
@MainActor
final class StatusQuestions: ObservableObject {
    static let shared = StatusQuestions()
    @Published private(set) var questions: [String: PendingQuestion] = [:]

    /// Reads the question `s` waits on; a conversation no longer waiting loses it.
    func load(_ s: Session) async {
        guard s.state == .waiting, Store.shared.supports("session") else { questions[s.id] = nil; return }
        var transcript = Transcript()
        transcript.append(.array(Store.shared.cache.lines("transcript:\(s.id)")))
        do {
            let answer = try await Store.shared.call("session", ["sessionId": .string(s.id), "since": JSON(transcript.cursor)])
            transcript.append(answer["events"])
        } catch {
            // The saved lines alone, when the server cannot be read.
        }
        let question = transcript.pendingQuestion
        if questions[s.id] != question { questions[s.id] = question }
    }
}

/// The counts, the conversations waiting for an answer and those working, as sections of the Findings list.
struct StatusSections: View {
    @ObservedObject private var projects = ProjectsModel.shared

    var body: some View {
        let o = projects.overview
        let waiting = o.needingYou.filter { $0.state == .waiting }
        Section {
            HStack(spacing: 8) {
                CountTile(label: "Need you", count: o.needsYouCount, color: Theme.accent)
                CountTile(label: "Working", count: o.workingCount, color: Theme.warn)
                CountTile(label: "Ready", count: o.ready, color: Theme.ok)
            }
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
        if !waiting.isEmpty {
            Section("Waiting for your answer") {
                ForEach(waiting, id: \.id) { WaitingRow(session: $0).listRowBackground(Theme.row) }
            }
        }
        if !o.working.isEmpty {
            Section("Working") {
                ForEach(o.working, id: \.id) { WorkingRow(session: $0).listRowBackground(Theme.row) }
            }
        }
    }
}

@MainActor private func projectTitle(_ s: Session) -> String { ProjectsModel.shared.project(s.repo)?.title ?? s.repo ?? "" }

/// A count over its label, coloured while it is not zero.
private struct CountTile: View {
    var label: String
    var count: Int
    var color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(count)").font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(count > 0 ? color : .secondary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// A conversation's dot, title and second line, which opens it.
private struct SessionHeading: View {
    var session: Session
    var detail: String
    var detailColor: Color
    @Environment(\.navigate) private var navigate
    var body: some View {
        Button { navigate(.conversation(id: session.id, session: session.raw)) } label: {
            HStack(spacing: 10) {
                StatusDot(status: session.state == .waiting ? "waiting" : session.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(detailColor).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Opens the conversation")
    }
}

/// A conversation waiting for your answer: the question, its options and a reply, for a token that may send one.
private struct WaitingRow: View {
    var session: Session
    @ObservedObject private var questions = StatusQuestions.shared
    @EnvironmentObject private var store: Store
    @State private var reply = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        let question = questions.questions[session.id]
        VStack(alignment: .leading, spacing: 10) {
            SessionHeading(session: session, detail: "\(projectTitle(session)) \u{00B7} \(session.state.label)", detailColor: Theme.accent)
            if let text = (question?.text).flatMap({ $0.isEmpty ? nil : $0 }) ?? session.raw["lastText"].nonEmpty {
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(6)
            }
            if canAnswer {
                ForEach(Array((question?.options ?? []).enumerated()), id: \.offset) { _, label in
                    Button { send(label) } label: {
                        HStack {
                            Text(label).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.turn.down.left").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).foregroundStyle(.primary)
                    .disabled(sending)
                    .accessibilityHint("Sends this answer")
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Reply", text: $reply, axis: .vertical).lineLimit(1...5)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .disabled(sending)
                    Button { send(reply) } label: {
                        if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
        }
        .padding(.vertical, 4)
        // Read again whenever the conversation asks anew.
        .task(id: "\(session.id) \(session.awaitingAnswer) \(session.raw["endedAt"].string ?? "")") { await questions.load(session) }
    }

    /// A token that may write a message, on a server that takes one, answers here; a read-only one only reads.
    private var canAnswer: Bool { store.supports("message") }

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, canAnswer else { return }
        sending = true; error = nil
        let id = session.id, repo = session.repo
        Task {
            do {
                try await Store.shared.call("message", ["sessionId": .string(id), "text": .string(text)])
                if reply.trimmingCharacters(in: .whitespacesAndNewlines) == text { reply = "" }
                // The answered conversation leaves the list once its project's conversations are read again.
                if let repo { try? await Store.shared.feed(repo).loadSessions(fresh: true) }
            } catch {
                self.error = failure(error)
            }
            sending = false
        }
    }
}

/// A conversation working now: its project and the tool it is on.
private struct WorkingRow: View {
    var session: Session
    var body: some View {
        let detail = [projectTitle(session), session.raw["lastTool"].nonEmpty].compactMap { $0 }.filter { !$0.isEmpty }
        SessionHeading(session: session, detail: detail.joined(separator: " \u{00B7} "), detailColor: .secondary)
            .padding(.vertical, 2)
    }
}
