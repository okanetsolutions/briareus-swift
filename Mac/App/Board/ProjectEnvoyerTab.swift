// A project's Envoyer tab on its board (core /envoyer): the Envoyer accounts available to it, each account's Envoyer
// projects, and a project's servers and recent deployments, with Deploy (its own branch, or one typed).
import SwiftUI

@MainActor
final class ProjectEnvoyerModel: ObservableObject {
    let repo: String
    @Published private(set) var accounts: [JSON] = []
    @Published private(set) var projects: [JSON] = []
    @Published private(set) var servers: [JSON] = []
    @Published private(set) var deployments: [JSON] = []
    @Published var account: Int?
    @Published var project: Int?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    private var loaded = false

    init(repo: String) { self.repo = repo }
    static var offered: Bool { Store.shared.canManage && Store.shared.supports("envoyer_accounts") }

    func open() { if !loaded { loaded = true; Task { await loadAccounts() } } }
    func loadAccounts() async {
        switch await boardCall("envoyer_accounts", ["repo": .string(repo)]) {
        case .failure(let e): error = e.description
        case .success(let v):
            accounts = v["accounts"].items; error = nil
            if account == nil, let first = accounts.first?["id"].truncatedInt { pickAccount(first) }
        }
    }
    func pickAccount(_ id: Int) {
        account = id; project = nil; projects = []; servers = []; deployments = []
        Task {
            switch await boardCall("envoyer_projects", ["id": JSON(id), "repo": .string(repo)]) {
            case .failure(let e): error = e.message ?? e.description
            case .success(let v):
                projects = v["projects"].items; error = nil
                if projects.count == 1, let p = projects[0]["id"].truncatedInt { pickProject(p) }
            }
        }
    }
    func pickProject(_ id: Int) {
        project = id
        Task { await loadProject() }
    }
    func loadProject() async {
        guard let a = account, let p = project else { return }
        let args: JSON = ["id": JSON(a), "project": JSON(p), "repo": .string(repo)]
        async let s = boardCall("envoyer_servers", args)
        async let d = boardCall("envoyer_deployments", args)
        let (sr, dr) = await (s, d)
        servers = sr.value?["servers"].items ?? []
        deployments = dr.value?["deployments"].items ?? []
        if let e = dr.error ?? sr.error { error = e.message ?? e.description } else { error = nil }
    }
    func deploy() {
        guard let a = account, let p = project, Store.shared.supports("envoyer_deploy"), !busy else { return }
        let name = projects.first { $0["id"].truncatedInt == p }?["name"].string ?? "this project"
        guard let branch = Dialogs.text("Deploy \(name)?", label: "The branch to deploy; empty deploys the project's own branch.", okLabel: "Deploy") else { return }
        var body: JSON = ["id": JSON(a), "project": JSON(p), "repo": .string(repo)]
        if !branch.cTrimmed.isEmpty { body["branch"] = .string(branch.cTrimmed) }
        busy = true
        Task {
            let r = await boardCall("envoyer_deploy", body)
            busy = false
            if let e = r.error { error = e.message ?? e.description } else { notice = "Envoyer queued it; it shows below once it runs." }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await loadProject()
        }
    }
}

struct ProjectEnvoyerTab: View {
    @ObservedObject var model: ProjectEnvoyerModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let e = model.error { NoticeBox(message: e) }
                if let n = model.notice { Text(n).font(Theme.footnote).foregroundStyle(Theme.muted) }
                if model.accounts.isEmpty {
                    Text("No Envoyer account is available to this project. Add one in Settings › Envoyer accounts.").font(Theme.footnote).foregroundStyle(Theme.muted)
                } else {
                    HStack(spacing: 10) {
                        Picker("Account", selection: Binding(get: { model.account ?? 0 }, set: { model.pickAccount($0) })) {
                            ForEach(model.accounts, id: \.self) { a in Text(a["label"].string ?? "Account").tag(a["id"].truncatedInt ?? 0) }
                        }
                        .frame(maxWidth: 280)
                        Picker("Project", selection: Binding(get: { model.project ?? 0 }, set: { model.pickProject($0) })) {
                            Text("Choose…").tag(0)
                            ForEach(model.projects, id: \.self) { p in Text(p["name"].string ?? "Project").tag(p["id"].truncatedInt ?? 0) }
                        }
                        .frame(maxWidth: 320)
                        Spacer()
                        if model.project != nil && store.supports("envoyer_deploy") {
                            Button(model.busy ? "Deploying…" : "Deploy…") { model.deploy() }.dashButton(.prominent).disabled(model.busy)
                        }
                    }
                }
                if !model.servers.isEmpty {
                    Text("Servers").font(Theme.bodySemibold)
                    ForEach(Array(model.servers.enumerated()), id: \.offset) { _, s in
                        Text("\(s["name"].string ?? "Server") · \(s["ip_address"].string ?? s["ipAddress"].string ?? "")\(s["connection_status"].string.map { " · \($0)" } ?? "")")
                            .font(Theme.footnote).foregroundStyle(Theme.muted)
                    }
                }
                if model.project != nil {
                    Text("Deployments").font(Theme.bodySemibold)
                    if model.deployments.isEmpty { Text("None yet.").font(Theme.footnote).foregroundStyle(Theme.muted) }
                    ForEach(Array(model.deployments.enumerated()), id: \.offset) { _, d in
                        let status = d["status"].string ?? ""
                        HStack(spacing: 8) {
                            Text(status).font(Theme.caption2).foregroundStyle(status == "finished" ? Theme.ok : status == "failed" ? Theme.danger : Theme.muted).frame(width: 64, alignment: .leading)
                            Text(String((d["commit_hash"].string ?? d["commitHash"].string ?? "").prefix(8))).font(Theme.monoSmall)
                            Text(d["commit_message"].string ?? d["commitMessage"].string ?? "").font(Theme.footnote).lineLimit(1)
                            Spacer()
                            Text(d["commit_branch"].string ?? d["branch"].string ?? "").font(Theme.caption).foregroundStyle(Theme.muted)
                            Text(d["created_at"].string ?? d["createdAt"].string ?? "").font(Theme.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear { model.open() }
    }
}
