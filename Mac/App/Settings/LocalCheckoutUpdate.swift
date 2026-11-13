// How a project's local checkout last updated itself after a merge, and Update now, at the top of the Project tab of
// its settings (ProjectSettingsScreen) when it has a local checkout: read every 30 seconds, every 2 while one runs.
import SwiftUI

/// How the project's local checkout last updated itself after a merge, and Update now.
struct LocalCheckoutUpdate: View {
    var projectID: Double
    @State private var status: JSON = .null
    @State private var running = false
    @State private var error: String?
    @State private var showOutput = false
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Local checkout").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
                Text(line).font(Theme.footnote).foregroundStyle(state == "failed" ? Theme.danger : Theme.muted).lineLimit(1)
                Spacer()
                if status["output"].nonEmpty != nil {
                    Button(showOutput ? "Hide output" : "Output") { showOutput.toggle() }.buttonStyle(.plain).font(Theme.footnote).foregroundStyle(Theme.accent)
                }
                if store.supports("run_project_update") {
                    Button(busy ? "Updating…" : "Update now") { Task { await run() } }.dashButton(.bordered).disabled(busy)
                        .help("Pull its branch and run its update commands")
                }
            }
            if let e = error { Notice(message: e) }
            if showOutput, let out = status["output"].nonEmpty {
                ScrollView { Text(out).font(Theme.monoSmall).foregroundStyle(Theme.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180).padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
        .padding(.bottom, 16)
        .task(id: projectID) {
            while !Task.isCancelled {
                await read()
                try? await Task.sleep(nanoseconds: (busy ? 2 : 30) * 1_000_000_000)
            }
        }
    }

    private var state: String { status["state"].string ?? "" }
    private var busy: Bool { running || state == "running" || state == "waiting" }
    private var line: String {
        guard status.isObject else { return "has not updated itself yet" }
        var parts = [state]
        if let b = status["branch"].nonEmpty { parts.append(b) }
        if let from = status["from"].nonEmpty, let to = status["to"].nonEmpty, from != to { parts.append("\(from.prefix(7)) → \(to.prefix(7))") }
        if let r = status["reason"].nonEmpty { parts.append(r) }
        if let at = status["finishedAt"].string.flatMap({ ISO8601DateFormatter().date(from: $0) }) { parts.append(formatRelative(at)) }
        else if let ms = status["finishedAt"].number { parts.append(formatRelative(Date(timeIntervalSince1970: ms / 1000))) }
        return parts.joined(separator: " · ")
    }
    private func read() async {
        if let v = await boardCall("project_update", ["id": .number(projectID)]).value { status = v["status"] }
    }
    private func run() async {
        running = true; error = nil
        let r = await boardCall("run_project_update", ["id": .number(projectID)])
        running = false
        switch r {
        case .success(let v): status = v["status"]
        case .failure(let e): error = e.description
        }
    }
}
