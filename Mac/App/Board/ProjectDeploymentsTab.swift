// A project's Deployments tab on its board (core /deployments, an Admin token's): which GitHub workflow deploys it and
// where, the deployments GitHub records with what is live per environment and the health check's answer, and a
// deployment asked for in two steps: Plan resolves the commit and its checks, Deploy runs that plan (within 5 minutes).
// The last request is acknowledged once it was checked in Actions, before another can go.
import SwiftUI

@MainActor
final class ProjectDeploymentsModel: ObservableObject {
    let repo: String
    @Published private(set) var overview: JSON?
    @Published private(set) var plan: JSON?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    /// The settings form's fields.
    @Published var environment = ""
    @Published var workflow = ""
    @Published var workflowRef = ""
    @Published var sourceRef = ""
    @Published var revisionInput = ""
    @Published var requireChecks = true
    @Published var healthURL = ""
    @Published var editing = false

    init(repo: String) { self.repo = repo }
    static var offered: Bool { Store.shared.isAdmin && Store.shared.supports("deployments") }

    // Not a ternary with `nil`: JSON takes a nil literal as JSON.null, which is not an absent value.
    var config: JSON? { guard let c = overview?["config"], c.isObject else { return Optional<JSON>.none }; return c }
    var attempt: JSON? { guard let a = overview?["attempt"], a.isObject else { return Optional<JSON>.none }; return a }
    var waitingAcknowledgement: Bool { attempt.map { !$0["acknowledged"].is(true) } ?? false }

    func open() { if !loaded { Task { await load() } } }
    func load() async {
        let r = await boardCall("deployments", ["repo": .string(repo)])
        loaded = true
        switch r {
        case .failure(let e): if e.kind != .cancelled { error = e.description }
        case .success(let v):
            overview = v; error = nil
            if config == nil { editing = true }
        }
    }
    func startEditing() {
        let c = config ?? [:]
        environment = c["environment"].string ?? "production"
        workflow = c["workflow"].string ?? ""
        workflowRef = c["workflowRef"].string ?? "main"
        sourceRef = c["sourceRef"].string ?? "main"
        revisionInput = c["revisionInput"].string ?? "sha"
        requireChecks = !c["requireChecks"].is(false)
        healthURL = c["healthUrl"].string ?? ""
        editing = true
    }
    func saveConfig() {
        guard Store.shared.supports("configure_deployments"), !busy else { return }
        guard ![environment, workflow, workflowRef, sourceRef, revisionInput].contains(where: { $0.cTrimmed.isEmpty }) else {
            error = "Fill in the environment, the workflow file, the refs and the input that takes the commit."; return
        }
        var body: JSON = ["repo": .string(repo), "environment": .string(environment.cTrimmed), "workflow": .string(workflow.cTrimmed),
                          "workflowRef": .string(workflowRef.cTrimmed), "sourceRef": .string(sourceRef.cTrimmed),
                          "revisionInput": .string(revisionInput.cTrimmed), "requireChecks": .bool(requireChecks)]
        if !healthURL.cTrimmed.isEmpty { body["healthUrl"] = .string(healthURL.cTrimmed) }
        run("configure_deployments", body) { [weak self] _ in self?.editing = false }
    }
    func makePlan() { run("plan_deployment", ["repo": .string(repo)]) { [weak self] v in self?.plan = v } }
    func deploy() {
        guard let p = plan, let id = p["id"].string else { return }
        let sha = String((p["sha"].string ?? "").prefix(8))
        guard Dialogs.confirm("Deploy \(sha) to \(p["config"]["environment"].string ?? "the environment")?",
                              "GitHub runs \(p["config"]["workflow"].string ?? "the workflow") on \(p["config"]["workflowRef"].string ?? "its ref") with this commit.",
                              continueLabel: "Deploy", destructive: true) else { return }
        run("dispatch_deployment", ["repo": .string(repo), "planId": .string(id)]) { [weak self] _ in self?.plan = nil }
    }
    func acknowledge() { run("acknowledge_deployment", ["repo": .string(repo)]) { _ in } }

    private func run(_ op: String, _ body: JSON, done: @escaping (JSON) -> Void) {
        guard Store.shared.supports(op), !busy else { return }
        busy = true; error = nil
        Task {
            let r = await boardCall(op, body)
            busy = false
            switch r {
            case .success(let v): done(v)
            case .failure(let e): error = e.message ?? e.description
            }
            await load()
        }
    }
}

struct ProjectDeploymentsTab: View {
    @ObservedObject var model: ProjectDeploymentsModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let e = model.error { NoticeBox(message: e) }
                if !model.loaded { LoadingNote(text: "Reading the deployments from GitHub…") }
                if let a = model.attempt { attempt(a) }
                if model.editing { settings } else if let c = model.config { summary(c) }
                if model.config != nil && !model.editing { request }
                if let o = model.overview { history(o) }
            }
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onAppear { model.open() }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func attempt(_ a: JSON) -> some View {
        card {
            HStack {
                Text("Last request").font(Theme.bodySemibold)
                Text("\(String((a["sha"].string ?? "").prefix(8))) → \(a["environment"].string ?? "") · \(a["state"].string ?? "")").font(Theme.footnote).foregroundStyle(Theme.muted)
                Spacer()
                if let u = a["url"].string, safeWebURL(u) { Button("Actions ↗") { openWebURL(u) }.buttonStyle(.plain).font(Theme.footnote).foregroundStyle(Theme.accent) }
            }
            if model.waitingAcknowledgement {
                Text("Check it in GitHub Actions, then acknowledge it: no other deployment can be asked for until then.").font(Theme.footnote).foregroundStyle(Theme.warn)
                if store.supports("acknowledge_deployment") { Button("Acknowledge") { model.acknowledge() }.dashButton(.bordered).disabled(model.busy) }
            }
        }
    }

    private func summary(_ c: JSON) -> some View {
        card {
            HStack {
                Text("Deploys with").font(Theme.bodySemibold)
                Spacer()
                if store.supports("configure_deployments") { Button("Change…") { model.startEditing() }.dashButton(.bordered).disabled(model.waitingAcknowledgement) }
            }
            Text("\(c["workflow"].string ?? "") on \(c["workflowRef"].string ?? "") · \(c["sourceRef"].string ?? "") into input \(c["revisionInput"].string ?? "") · environment \(c["environment"].string ?? "")\(c["requireChecks"].is(false) ? "" : " · green checks required")")
                .font(Theme.footnote).foregroundStyle(Theme.muted)
            if let h = model.overview?["health"], h["state"].string != "not-configured" {
                Text("Health: \(h["state"].string ?? "")\(h["status"].int32.map { " (HTTP \($0))" } ?? "") · \(c["healthUrl"].string ?? "")").font(Theme.footnote)
                    .foregroundStyle(h["state"].string == "healthy" ? Theme.ok : Theme.danger)
            }
        }
    }

    private var settings: some View {
        card {
            Text(model.config == nil ? "Set which GitHub workflow deploys this project" : "Deployment settings").font(Theme.bodySemibold)
            HStack(spacing: 10) {
                field("Workflow file", "deploy.yml", $model.workflow)
                field("Environment", "production", $model.environment)
            }
            HStack(spacing: 10) {
                field("Workflow runs from", "main", $model.workflowRef)
                field("Deploys", "main", $model.sourceRef)
                field("Input taking the commit", "sha", $model.revisionInput)
            }
            field("Health check URL (optional)", "https://example.com/up", $model.healthURL)
            Toggle("Refuse a commit whose checks are not green", isOn: $model.requireChecks).toggleStyle(.checkbox).font(Theme.footnote)
            HStack {
                Button(model.busy ? "Saving…" : "Save") { model.saveConfig() }.dashButton(.prominent).disabled(model.busy || !store.supports("configure_deployments"))
                if model.config != nil { Button("Cancel") { model.editing = false }.dashButton(.bordered) }
            }
        }
    }
    private func field(_ title: String, _ cue: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.muted)
            TextField(cue, text: text).textFieldStyle(.roundedBorder).font(Theme.mono)
        }
    }

    private var request: some View {
        card {
            HStack {
                Text("Deploy").font(Theme.bodySemibold)
                Spacer()
                if store.supports("plan_deployment") {
                    Button(model.plan == nil ? "Plan…" : "Plan again") { model.makePlan() }.dashButton(.bordered).disabled(model.busy || model.waitingAcknowledgement)
                }
            }
            if let p = model.plan {
                let green = p["checksPassed"].is(true)
                Text("\(String((p["sha"].string ?? "").prefix(8))) from \(p["config"]["sourceRef"].string ?? "") · checks \(green ? "green" : "not green")").font(Theme.footnote)
                    .foregroundStyle(green ? Theme.ok : Theme.warn)
                if let exp = p["expiresAt"].number { Text("This plan expires at \(formatEventTime(Date(timeIntervalSince1970: exp / 1000))).").font(Theme.caption).foregroundStyle(Theme.muted) }
                if store.supports("dispatch_deployment") {
                    Button(model.busy ? "Requesting…" : "Deploy this commit") { model.deploy() }.dashButton(.prominent)
                        .disabled(model.busy || (!green && !model.config!["requireChecks"].is(false)))
                }
            } else {
                Text("Plan resolves the commit to deploy and its checks; Deploy then asks GitHub to run the workflow with it.").font(Theme.footnote).foregroundStyle(Theme.muted)
            }
        }
    }

    private func history(_ o: JSON) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Deployments").font(Theme.bodySemibold)
            if o["history"].items.isEmpty { Text("GitHub records none.").font(Theme.footnote).foregroundStyle(Theme.muted) }
            ForEach(Array(o["history"].items.enumerated()), id: \.offset) { _, d in
                let live = o["active"].items.contains { $0["id"] == d["id"] }
                HStack(spacing: 8) {
                    Text(d["state"].string ?? "").font(Theme.caption2).foregroundStyle(d["state"].string == "success" ? Theme.ok : d["state"].string == "failure" || d["state"].string == "error" ? Theme.danger : Theme.muted).frame(width: 70, alignment: .leading)
                    Text(String((d["sha"].string ?? "").prefix(8))).font(Theme.monoSmall)
                    Text(d["environment"].string ?? "").font(Theme.footnote)
                    if live { Text("live").font(Theme.caption2).foregroundStyle(Theme.onAccent).padding(.horizontal, 5).background(Capsule().fill(Theme.ok)) }
                    Spacer()
                    if let at = (d["updatedAt"].string ?? d["createdAt"].string).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                        Text(formatRelative(at)).font(Theme.caption).foregroundStyle(Theme.muted)
                    }
                    if let u = d["logUrl"].string ?? d["url"].string, safeWebURL(u) { Button("↗") { openWebURL(u) }.buttonStyle(.plain).foregroundStyle(Theme.accent) }
                }
            }
        }
    }
}
