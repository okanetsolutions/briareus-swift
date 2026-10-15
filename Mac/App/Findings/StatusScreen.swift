// The ◉ Status screen, Quest's status panel: how many conversations need you, are working and are ready, then every one
// waiting for you, with the agent's question, its options as buttons and a reply field (a held review round links to its
// conversation to decide it), then what is working now. It reads the sessions the sidebar keeps live (the /events stream,
// or its poll), so it needs no loop of its own; only a waiting conversation's question is read from its transcript.
import SwiftUI

/// The questions the waiting conversations left, read from each transcript: the saved lines and what came since.
@MainActor
final class StatusQuestions: ObservableObject {
    static let shared = StatusQuestions()
    @Published private(set) var questions: [String: PendingQuestion] = [:]

    /// Reads the question `id` waits on; a conversation no longer waiting loses it.
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

struct StatusScreen: View {
    @ObservedObject private var projects = ProjectsModel.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        let o = projects.overview
        VStack(spacing: 0) {
            PaneHeader(title: "\u{25C9} Status", subtitle: subtitle(o), buttons: serverButton)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Color.clear.frame(height: 4)
                    HStack(spacing: 8) {
                        CountTile(label: "Need you", count: o.needsYouCount, color: Theme.accent)
                        CountTile(label: "Working", count: o.workingCount, color: Theme.warn)
                        CountTile(label: "Ready", count: o.ready, color: Theme.ok)
                    }
                    if !o.needingYou.isEmpty { heading("Waiting for you") }
                    ForEach(o.needingYou, id: \.id) { WaitingCard(session: $0) }
                    if !o.working.isEmpty { heading("Working") }
                    ForEach(o.working, id: \.id) { WorkingRow(session: $0) }
                    if o.quiet && projects.loaded {
                        Text("All quiet. Nothing is running and nothing waits for you.")
                            .font(Theme.footnote).foregroundStyle(Theme.muted)
                    }
                    if !projects.loaded { LoadingNote() }
                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, Theme.paneMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The sidebar's lists as they stand at once, read again from the server on opening and on ⌘R.
        .onAppear { projects.recount(); Task { await projects.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await projects.load() } }
    }

    /// What the machine spends on the sessions working here, on a server that reports it.
    private var serverButton: [HeaderButton] {
        guard store.supports("server_stats") else { return [] }
        return [HeaderButton(glyph: "gauge.with.dots.needle.33percent", label: "\u{25A4} Server", tip: "The server's CPU, memory and disks") {
            Navigator.shared.push(.serverStats)
        }]
    }
    private func subtitle(_ o: SessionOverview) -> String {
        if o.quiet { return "nothing waits for you" }
        return "\(o.needsYouCount) waiting for you \u{00B7} \(o.workingCount) working"
    }
    private func heading(_ text: String) -> some View {
        Text(text).font(Theme.captionSemibold).foregroundStyle(Theme.muted).padding(.top, 6)
    }
}

@MainActor private func openSession(_ s: Session) { Navigator.shared.push(.conversation(id: s.id, session: s.raw)) }
@MainActor private func projectTitle(_ s: Session) -> String { ProjectsModel.shared.project(s.repo)?.title ?? s.repo ?? "" }

/// A count over its label, coloured while it is not zero.
private struct CountTile: View {
    var label: String
    var count: Int
    var color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(count)").font(Theme.stat).foregroundStyle(count > 0 ? color : Theme.muted)
            Text(label).font(Theme.caption).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// A conversation's dot, title and second line, which opens it.
private struct SessionHeading: View {
    var session: Session
    var detail: String
    var detailColor: Color
    var body: some View {
        Button { openSession(session) } label: {
            HStack(spacing: 8) {
                StatusDot(status: session.state.needsYou ? "waiting" : session.sidebarState)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle).font(Theme.subheadline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    Text(detail).font(Theme.caption).foregroundStyle(detailColor).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FDKit.LinkStyle())
        .help("Open the conversation")
    }
}

/// A conversation waiting for you: the question and a quick reply, or a link to decide its findings.
private struct WaitingCard: View {
    var session: Session
    @ObservedObject private var questions = StatusQuestions.shared
    @ObservedObject private var store = Store.shared
    @State private var reply = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        let question = questions.questions[session.id]
        VStack(alignment: .leading, spacing: 8) {
            SessionHeading(session: session, detail: "\(projectTitle(session)) \u{00B7} \(session.state.label)", detailColor: Theme.accent)
            if let text = (question?.text).flatMap({ $0.isEmpty ? nil : $0 }) ?? session.raw["lastText"].nonEmpty {
                Text(text).font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(5).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.state == .findings {
                Button("Decide the findings \u{2192}") { openSession(session) }.dashButton(.bordered)
            } else if canAnswer {
                if let options = question?.options, !options.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, label in
                            Button(label) { send(label) }.dashButton(.bordered).disabled(sending)
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Reply", text: $reply, axis: .vertical).lineLimit(1...5).dashField()
                        .onSubmit { send(reply) }
                        .disabled(sending)
                    Button("Send") { send(reply) }.dashButton(.prominent)
                        .disabled(sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(session.state == .waiting ? Theme.accent : Theme.line, lineWidth: 1))
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
                _ = try await Store.shared.call("message", ["sessionId": .string(id), "text": .string(text)])
                if reply.trimmingCharacters(in: .whitespacesAndNewlines) == text { reply = "" }
                post(.sessionsChanged, repo.map { ["repo": $0] } ?? [:])
            } catch {
                self.error = errorText(error)
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
        SessionHeading(session: session, detail: detail.joined(separator: " \u{00B7} "), detailColor: Theme.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
    }
}
