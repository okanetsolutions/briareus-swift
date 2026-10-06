// A project's Forge tab, beside its pull requests and issues (the Windows client's project_forge.c): the servers of the
// Laravel Forge accounts the project may use (Settings → Forge accounts) down the left, and the server picked there on the
// right with its Forge sites, each with its domain, state, repository and branch, deployment and PHP. The server reads
// Forge with the account's token (/forge/accounts/{account}/servers and …/sites), so the token never reaches this Mac;
// both need an Admin token. A site opens in place of the list (ForgeSiteView).
import Combine
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
    /// The server on show, as "account:server".
    @Published private(set) var selected: String?
    /// "account:server" → its ForgeSite rows, once read in full.
    @Published private(set) var sites: [String: [JSON]] = [:]
    @Published private(set) var sitesError: String?
    /// The site open in place of the server's list, if any.
    @Published private(set) var site: ForgeSiteModel? {
        // What the site changes (its Save) redraws the header.
        didSet { siteSink = site?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
    private var siteSink: AnyCancellable?
    private var reading: Task<Void, Never>?
    private var readingSites: Task<Void, Never>?

    init(repo: String) { self.repo = repo }

    /// Whether this token may read the Forge accounts and, through them, their servers and sites (an Admin token).
    static var offered: Bool {
        Store.shared.supports("settings_forge_accounts") && Store.shared.supports("forge_servers") && Store.shared.supports("forge_sites")
    }

    private static func rowID(_ row: JSON) -> Double { row["id"].number.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
    static func key(_ server: JSON) -> String { String(format: "%.0f:%.0f", server["_account"].number ?? 0, rowID(server)) }
    var selectedServer: JSON? { selected.flatMap { k in servers.first { Self.key($0) == k } } }
    var selectedSites: [JSON]? { selected.flatMap { sites[$0] } }

    // MARK: - Loading

    /// Reads the accounts and their servers once; once every account is read, opens the first server unless one is picked.
    func load() {
        if loaded || reading != nil { return }
        guard Self.offered else { loaded = true; return }
        error = nil
        servers = []
        reading = Task { [weak self] in
            await self?.readAll()
            // A read ⟳ cancelled leaves the next one in place.
            if !Task.isCancelled { self?.reading = nil }
        }
    }
    private func readAll() async {
        let r = await boardCall("settings_forge_accounts", ["repo": .string(repo)])
        if Task.isCancelled { return }
        guard let v = r.value else {
            if let e = r.error, e.kind != .cancelled { error = e.description }
            loaded = true
            return
        }
        // Only an account with a token can be read; the server answers the others with a refusal.
        accounts = v["accounts"].items.filter { !$0["hasToken"].is(false) }
        for account in accounts {
            let label = account["label"].nonEmpty ?? account["organization"].string ?? ""
            var cursor: String?
            var pages = 0
            repeat {
                var args: JSON = ["account": .number(Self.rowID(account))]
                if let cursor { args["cursor"] = .string(cursor) }
                let page = await boardCall("forge_servers", args)
                if Task.isCancelled { return }
                guard let pv = page.value else {
                    // One account's refusal (a revoked token, Forge rate limiting) leaves the others' servers listed.
                    let why = page.error?.description ?? ""
                    error = (error.map { $0 + "\n" } ?? "") + "\(label): \(why)"
                    break
                }
                for row in pv["servers"].items where row.isObject {
                    var row = row
                    row["_account"] = .number(Self.rowID(account))
                    row["_accountLabel"] = .string(label)
                    servers.append(row)
                }
                cursor = pv["nextCursor"].nonEmpty
                pages += 1
            } while cursor != nil && pages < Self.maxPages
        }
        loaded = true
        if selectedServer == nil, let first = servers.first { selected = Self.key(first) }
        sitesLoad()
    }

    /// Reads the sites of the server on show, unless they are read already.
    private func sitesLoad() {
        guard let server = selectedServer, let key = selected, readingSites == nil, sites[key] == nil else { return }
        sitesError = nil
        readingSites = Task { [weak self] in
            var incoming: [JSON] = []
            var cursor: String?
            var pages = 0
            repeat {
                var args: JSON = ["account": server["_account"], "server": .number(Self.rowID(server))]
                if let cursor { args["cursor"] = .string(cursor) }
                let r = await boardCall("forge_sites", args)
                guard let self, !Task.isCancelled, self.selected == key else { return }
                guard let v = r.value else {
                    if let e = r.error, e.kind != .cancelled { self.sitesError = e.description }
                    self.readingSites = nil
                    return
                }
                incoming += v["sites"].items
                cursor = v["nextCursor"].nonEmpty
                pages += 1
            } while cursor != nil && pages < Self.maxPages
            guard let self else { return }
            self.sites[key] = incoming
            self.readingSites = nil
        }
    }

    /// ⟳: with a site open, the site's open tab read again; else the accounts, their servers and the sites.
    func refresh() {
        if let site { site.refresh(); return }
        reading?.cancel(); reading = nil
        readingSites?.cancel(); readingSites = nil
        sites = [:]
        sitesError = nil
        loaded = false
        load()
    }

    // MARK: - Actions

    /// Closes the open site, unless its unsaved changes are kept; true when none is open any more.
    @discardableResult func closeSite() -> Bool {
        guard let site else { return true }
        if !site.canLeave() { return false }
        site.close()
        self.site = nil
        return true
    }
    func pickServer(_ row: JSON) {
        guard closeSite() else { return }
        let key = Self.key(row)
        if key == selected { return }
        // The sites of the server left behind stop being read.
        readingSites?.cancel(); readingSites = nil
        sitesError = nil
        selected = key
        sitesLoad()
    }
    func openSite(_ s: JSON) {
        guard let server = selectedServer, s.isObject, closeSite() else { return }
        site = ForgeSiteModel(account: server["_account"].number ?? 0, server: server, site: s)
    }
    /// Whether the open site may be left, asking when it has unsaved changes.
    func canLeave() -> Bool { site?.canLeave() ?? true }

    // MARK: - The header

    /// The server on show in the line under the title.
    var subtitle: String? {
        guard let server = selectedServer else { return nil }
        let name = server["name"].nonEmpty ?? "server", detail = Forge.serverDetail(server)
        if site == nil, let list = selectedSites {
            return "Forge \(name) \u{00B7} \(detail) \u{00B7} \(list.count) site\(list.count == 1 ? "" : "s")"
        }
        return "Forge \(name) \u{00B7} \(detail)"
    }
    var headerButtons: [HeaderButton] { site?.headerButtons ?? [] }
}

struct ProjectForgeTab: View {
    @ObservedObject var model: ProjectForgeModel

    static let listWidth: CGFloat = 280
    /// A wide pane would spread each label and its value apart; the column stops at a reading width.
    static let readingWidth: CGFloat = 820

    var body: some View {
        Group {
            if !ProjectForgeModel.offered {
                Text("The Forge servers are read with the Forge accounts in Settings, which needs an Admin token. Issue one on the server with npm run create-token and connect with it.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                GeometryReader { geo in
                    let lw = min(Self.listWidth, geo.size.width / 3)
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { list.padding(.bottom, 14) }.frame(width: lw)
                        // A rule between the list and the server.
                        Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 8).padding(.trailing, 9).padding(.bottom, 14)
                        if let site = model.site {
                            ForgeSiteView(model: site, server: model.selectedServer) { model.closeSite() }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            ScrollView {
                                server.frame(maxWidth: Self.readingWidth, alignment: .topLeading).padding(.bottom, 14)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                }
                .frame(minHeight: 240)
            }
        }
        .onAppear { model.load() }
    }

    // MARK: - The servers

    /// The servers down the left, grouped by account when the project has more than one.
    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.error { Notice(message: e).padding(.bottom, 8) }
            let grouped = model.accounts.count > 1
            ForEach(Array(model.servers.enumerated()), id: \.offset) { i, row in
                if grouped && (i == 0 || model.servers[i - 1]["_account"] != row["_account"]) {
                    SectionTitle(title: row["_accountLabel"].string ?? "").padding(.horizontal, 6)
                }
                ForgeServerRow(server: row, selected: ProjectForgeModel.key(row) == model.selected) { model.pickServer(row) }
                    .padding(.bottom, 2)
            }
            if !model.loaded {
                LoadingNote(text: "Loading Forge servers…")
            } else if model.accounts.isEmpty && model.error == nil {
                hint("No Forge account is available to this project. Add one, or this project to one, under ⚙ Settings → Forge accounts.")
            } else if model.servers.isEmpty && model.error == nil {
                hint("This project’s Forge accounts have no servers.")
            }
        }
    }
    private func hint(_ text: String) -> some View {
        Text(text).font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
    }

    // MARK: - The server on show

    /// The server on show and its sites, the project's first.
    @ViewBuilder private var server: some View {
        if let server = model.selectedServer {
            VStack(alignment: .leading, spacing: 0) {
                Text(server["name"].nonEmpty ?? "Forge server").font(Theme.title3).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    .padding(.bottom, 4)
                Text(Forge.joined([server["ip_address"].string, server["provider"].string, server["region"].string,
                                   Forge.fieldText(server["php_version"]).map { "PHP \($0)" }, Forge.fieldText(server["ubuntu_version"]).map { "Ubuntu \($0)" },
                                   server["database_type"].string, server["_accountLabel"].string]))
                    .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if server["is_ready"].is(false) {
                    Text("Forge is still provisioning this server.").font(Theme.footnote).foregroundStyle(Theme.warn).padding(.top, 4)
                }
                Spacer().frame(height: 14)
                if let e = model.sitesError { Notice(message: e).padding(.bottom, 8) }
                if let sites = model.selectedSites {
                    Text("\(sites.count) site\(sites.count == 1 ? "" : "s")").font(Theme.captionSemibold).foregroundStyle(Theme.muted).padding(.bottom, 8)
                    if sites.isEmpty {
                        Text("No sites on this server.").font(Theme.footnote).foregroundStyle(Theme.muted)
                    }
                    // The project's own sites first, then the rest in Forge's order.
                    let mine = sites.filter { Forge.siteIsProject($0, repo: model.repo) }, rest = sites.filter { !Forge.siteIsProject($0, repo: model.repo) }
                    ForEach(Array((mine + rest).enumerated()), id: \.offset) { _, site in
                        ForgeSiteCard(site: site, mine: Forge.siteIsProject(site, repo: model.repo)) { model.openSite(site) }
                            .padding(.bottom, 10)
                    }
                } else if model.sitesError == nil {
                    LoadingNote(text: "Loading sites…").padding(.horizontal, -8)
                }
            }
        } else if model.loaded && !model.servers.isEmpty {
            EmptyNote(title: "No server picked", detail: "Click a server on the left to see its Forge sites.")
        }
    }
}

/// A server down the left: its glyph, its name, its address, cloud and region, and a dot, green once Forge has it ready.
private struct ForgeServerRow: View {
    var server: JSON
    var selected: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "server.rack").font(.system(size: 12)).foregroundStyle(selected ? Theme.accent : Theme.muted).frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(server["name"].nonEmpty ?? "Forge server").font(selected ? Theme.subheadlineSemibold : Theme.subheadline).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.tail).frame(height: 20, alignment: .leading)
                    Text(Forge.serverDetail(server)).font(Theme.caption2).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.tail).frame(height: 16, alignment: .leading)
                }
                .padding(.leading, 6)
                Spacer(minLength: 8)
                StatusDot(status: server["is_ready"].is(false) ? "waiting" : "idle")
            }
            .padding(.leading, 8).padding(.trailing, 10)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected || hovered ? Theme.raise : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.line : .clear, lineWidth: 1))
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Theme.accent).frame(width: 3).padding(.vertical, 8) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A site's state in its colour.
func forgeToneColor(_ state: String?) -> Color {
    switch Forge.tone(state) {
    case .danger: return Theme.danger
    case .ok: return Theme.ok
    case .accent: return Theme.accent
    case .muted: return Theme.muted
    }
}

/// One site: its domain and state, then what Forge says about it, Deploy script & .env, and Open site. The card opens the
/// site's page; Open site opens the site itself.
private struct ForgeSiteCard: View {
    var site: JSON
    var mine: Bool
    var open: () -> Void

    var body: some View {
        BoardBox(padding: 14, border: mine ? Theme.accent : Theme.line, radius: 10) {
            Text(site["name"].nonEmpty ?? "Forge site").font(Theme.headline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                .padding(.bottom, 6)
            let badges = specs
            if !badges.isEmpty { Badges(specs: badges).padding(.bottom, 4) }
            let repo = site["repository"]
            field("URL", site["url"])
            if repo.isObject {
                field("Repository", repo["url"].nonEmpty != nil ? repo["url"] : repo["name"])
                field("Branch", repo["branch"])
                field("Provider", repo["provider"])
            } else { field("Repository", repo) }
            field("PHP", site["php_version"])
            field("App type", site["app_type"])
            field("Web directory", site["web_directory"])
            field("Forge id", site["id"])
            HStack(spacing: 8) {
                GlyphButton(glyph: Glyph.symbol(0xE70F), title: "Deploy script & .env ›", kind: .prominent, action: open)
                if let url = Forge.siteURL(site) { GlyphButton(glyph: Glyph.symbol(0xE8A7), title: "Open site") { openWebURL(url) } }
            }
            .padding(.top, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    private var specs: [BadgeSpec] {
        var out: [BadgeSpec] = []
        if let state = site["status"].nonEmpty { out.append(BadgeSpec(text: state, color: forgeToneColor(state), chip: true)) }
        if let deploy = site["deployment_status"].nonEmpty {
            out.append(BadgeSpec(glyph: Glyph.symbol(0xE895), text: "Deployment \(deploy)", color: forgeToneColor(deploy)))
        }
        if site["quick_deploy"].is(true) { out.append(BadgeSpec(glyph: "bolt", text: "Quick deploy", color: Theme.ok)) }
        if mine { out.append(BadgeSpec(glyph: "books.vertical", text: "This project", color: Theme.accent)) }
        return out
    }

    @ViewBuilder private func field(_ label: String, _ value: JSON) -> some View {
        if let text = Forge.fieldText(value) { LabeledRow(label: label, value: text).padding(.top, 4) }
    }
}
