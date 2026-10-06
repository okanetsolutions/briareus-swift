// A project's Laravel Forge, as the Mac's Forge tab (ProjectForgeTab.swift) on a phone: the servers of the Forge accounts
// the project may use (Settings › Forge accounts), a section each, grouped by account when it has more than one, with the
// server's sites under it, the project's own first. The server reads Forge with the account's token
// (/forge/accounts/{account}/servers and …/sites), so the token never reaches the phone; both need an Admin token. A site
// opens its own screen (ForgeSiteScreen). Opened from the project screen's menu.
import SwiftUI

@MainActor
final class ProjectForgeModel: ObservableObject {
    static let maxPages = 20

    let repo: String
    /// The ForgeAccount rows available to the project.
    @Published private(set) var accounts: [JSON] = []
    /// Every account's ForgeServer rows, each with `_account` and `_accountLabel` added.
    @Published private(set) var servers: [JSON] = []
    @Published private(set) var loaded = false
    /// The accounts' or a server list's.
    @Published private(set) var error: String?
    /// "account:server" → its ForgeSite rows, once read in full.
    @Published private(set) var sites: [String: [JSON]] = [:]
    /// "account:server" → why its sites could not be read.
    @Published private(set) var sitesErrors: [String: String] = [:]
    private var readingSites: Set<String> = []
    private var reading = false

    init(repo: String) { self.repo = repo }

    /// Whether this token may read the Forge accounts and, through them, their servers and sites (an Admin token).
    static var offered: Bool {
        Store.shared.supports("settings_forge_accounts") && Store.shared.supports("forge_servers") && Store.shared.supports("forge_sites")
    }

    static func rowID(_ row: JSON) -> Double { row["id"].number.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
    static func key(_ server: JSON) -> String { String(format: "%.0f:%.0f", server["_account"].number ?? 0, rowID(server)) }

    /// The accounts and their servers, read again; the sites already read are read again as their sections show.
    func load() async {
        guard Self.offered else { loaded = true; return }
        guard !reading else { return }
        reading = true
        defer { reading = false }
        var next: [JSON] = []
        var problems: [String] = []
        do {
            let v = try await Store.shared.call("settings_forge_accounts", ["repo": .string(repo)])
            // Only an account with a token can be read; the server answers the others with a refusal.
            accounts = v["accounts"].items.filter { !$0["hasToken"].is(false) }
        } catch {
            if let text = failure(error) { self.error = text }
            loaded = true
            return
        }
        for account in accounts {
            let label = account["label"].nonEmpty ?? account["organization"].string ?? ""
            var cursor: String?
            var pages = 0
            repeat {
                var args: JSON = ["account": .number(Self.rowID(account))]
                if let cursor { args["cursor"] = .string(cursor) }
                do {
                    let pv = try await Store.shared.call("forge_servers", args)
                    for row in pv["servers"].items where row.isObject {
                        var row = row
                        row["_account"] = .number(Self.rowID(account))
                        row["_accountLabel"] = .string(label)
                        next.append(row)
                    }
                    cursor = pv["nextCursor"].nonEmpty
                    pages += 1
                } catch {
                    if error.isCancellation { return }
                    // One account's refusal (a revoked token, Forge rate limiting) leaves the others' servers listed.
                    problems.append("\(label): \(errorText(error))")
                    break
                }
            } while cursor != nil && pages < Self.maxPages
        }
        servers = next
        error = problems.isEmpty ? nil : problems.joined(separator: "\n")
        sites = [:]
        sitesErrors = [:]
        loaded = true
    }

    /// Reads a server's sites, unless they are read or being read.
    func loadSites(_ server: JSON) {
        let key = Self.key(server)
        guard sites[key] == nil, !readingSites.contains(key) else { return }
        readingSites.insert(key)
        sitesErrors[key] = nil
        Task {
            defer { readingSites.remove(key) }
            var incoming: [JSON] = []
            var cursor: String?
            var pages = 0
            repeat {
                var args: JSON = ["account": server["_account"], "server": .number(Self.rowID(server))]
                if let cursor { args["cursor"] = .string(cursor) }
                do {
                    let v = try await Store.shared.call("forge_sites", args)
                    incoming += v["sites"].items
                    cursor = v["nextCursor"].nonEmpty
                    pages += 1
                } catch {
                    if let text = failure(error) { sitesErrors[key] = text }
                    return
                }
            } while cursor != nil && pages < Self.maxPages
            // The project's own sites first, then the rest in Forge's order.
            let mine = incoming.filter { Forge.siteIsProject($0, repo: repo) }
            sites[key] = mine + incoming.filter { !Forge.siteIsProject($0, repo: repo) }
        }
    }
}

struct ProjectForgeScreen: View {
    let repo: String
    @StateObject private var model: ProjectForgeModel
    @EnvironmentObject private var store: Store

    init(repo: String) {
        self.repo = repo
        _model = StateObject(wrappedValue: ProjectForgeModel(repo: repo))
    }

    var body: some View {
        Group {
            if !ProjectForgeModel.offered {
                SettingsUnavailableView(text: "The Forge servers are read with the Forge accounts in Settings, which needs an Admin token. Issue one on the server with npm run create-token and connect with it.")
            } else {
                list
            }
        }
        .navigationTitle("Forge").navigationBarTitleDisplayMode(.inline)
    }

    private var list: some View {
        List {
            if let e = model.error { Section { ErrorNotice(message: e) }.listRowBackground(Theme.row) }
            let grouped = model.accounts.count > 1
            ForEach(Array(model.servers.enumerated()), id: \.offset) { i, server in
                let first = i == 0 || model.servers[i - 1]["_account"] != server["_account"]
                serverSection(server, account: grouped && first ? server["_accountLabel"].string : nil)
            }
            if !model.loaded {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }.listRowBackground(Color.clear)
            } else if model.accounts.isEmpty && model.error == nil {
                Section {
                    Text("No Forge account is available to this project. Add one, or this project to one, under Settings › Forge accounts.")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Theme.row)
            } else if model.servers.isEmpty && model.error == nil {
                Section { Text("This project\u{2019}s Forge accounts have no servers.").foregroundStyle(.secondary) }.listRowBackground(Theme.row)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .refreshable { await model.load() }
        .task { if !model.loaded { await model.load() } }
    }

    /// A server: its name, address, cloud and region in the header, then its sites.
    private func serverSection(_ server: JSON, account: String?) -> some View {
        let key = ProjectForgeModel.key(server)
        return Section {
            if let sites = model.sites[key] {
                ForEach(Array(sites.enumerated()), id: \.offset) { _, site in
                    DestinationLink(destination: .forgeSite(repo: repo, account: server["_account"].number ?? 0, server: server, site: site)) {
                        ForgeSiteRow(site: site, mine: Forge.siteIsProject(site, repo: repo))
                    }
                }
                if sites.isEmpty { Text("No sites on this server.").foregroundStyle(.secondary) }
            } else if let e = model.sitesErrors[key] {
                ErrorNotice(message: e)
                Button("Try Again") { model.loadSites(server) }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .onAppear { model.loadSites(server) }
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                if let account { Text(account).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent).padding(.bottom, 4) }
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                    Text(server["name"].nonEmpty ?? "Forge server").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if server["is_ready"].is(false) { Text("Provisioning").font(.caption).foregroundStyle(Theme.warning) }
                }
                let detail = Forge.joined([Forge.serverDetail(server), Forge.fieldText(server["php_version"]).map { "PHP \($0)" },
                                           Forge.fieldText(server["ubuntu_version"]).map { "Ubuntu \($0)" }, server["database_type"].string])
                if !detail.isEmpty { Text(detail).font(.caption) }
            }
            .textCase(nil)
        }
        .listRowBackground(Theme.row)
    }
}

/// A site's state in its colour.
func forgeToneColor(_ state: String?) -> Color {
    switch Forge.tone(state) {
    case .danger: return Theme.danger
    case .ok: return Theme.success
    case .accent: return Theme.accent
    case .muted: return .secondary
    }
}

/// A site in its server's section: its domain, state and deployment, and its repository and branch.
private struct ForgeSiteRow: View {
    let site: JSON
    let mine: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(site["name"].nonEmpty ?? "Forge site").font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if mine {
                    Text("This project").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent.opacity(0.12), in: Capsule())
                }
            }
            HStack(spacing: 8) {
                if let state = site["status"].nonEmpty { Text(state).foregroundStyle(forgeToneColor(state)) }
                if let deploy = site["deployment_status"].nonEmpty { Text("Deployment \(deploy)").foregroundStyle(forgeToneColor(deploy)) }
                if site["quick_deploy"].is(true) { Label("Quick deploy", systemImage: "bolt").foregroundStyle(Theme.success) }
            }
            .font(.caption)
            let repo = site["repository"]
            let detail = repo.isObject
                ? Forge.joined([Forge.fieldText(repo["name"]) ?? Forge.fieldText(repo["url"]), Forge.fieldText(repo["branch"]),
                                Forge.fieldText(site["php_version"])])
                : Forge.joined([Forge.fieldText(repo), Forge.fieldText(site["php_version"])])
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
