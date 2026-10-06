// A project's Database tab, beside its SSH and SFTP sessions (the Windows client's project_db.c), laid out as a database
// browser: the project's SSH servers down the left as a tree (a server opens to its databases, a database to its tables),
// and the table clicked on the right as a grid of its first rows. Nothing goes through the Briareus server but the
// database login stored with the SSH server (GET …/db-credentials): every query is the server's own `mysql` client run
// over SSH from this Mac (SSHQuery). The tabs stay put; the tree and the grid scroll apart.
import AppKit
import SwiftUI

@MainActor
final class ProjectDBModel: ObservableObject {
    struct DB {
        var name: String
        var open = false, loading = false, loaded = false
        var error: String?
        var tables: [String] = []
    }
    struct Server {
        var server: RemoteServer
        /// Its DbCredentials, once read.
        var login: JSON?
        var open = false, loading = false, loaded = false
        var error: String?
        var dbs: [DB] = []
    }
    /// A table in the tree.
    struct Pick: Equatable { var server: Int, db: Int, table: Int }

    static let rowLimit = 200

    let repo: String
    @Published private(set) var servers: [Server] = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    /// The table on show on the right.
    @Published private(set) var selected: Pick?
    @Published private(set) var grid = SQLTable() { didSet { widths = Self.measure(grid) } }
    /// Each column's width: the widest of its cells, up to the cap, measured once per answer.
    @Published private(set) var widths: [CGFloat] = []
    @Published private(set) var gridLoading = false
    @Published private(set) var gridError: String?
    private var reading: Task<Void, Never>?
    /// The queries under way, ended when the servers are read again.
    private var queries: [Task<Void, Never>] = []
    /// Which list of servers the answers are for: one read again drops the answers to the old one.
    private var generation = 0

    init(repo: String) { self.repo = repo }

    /// Whether this token may read the SSH servers and their database logins (an Admin token, on a server that stores them).
    static var offered: Bool { Store.shared.supports("settings_ssh_servers") && Store.shared.supports("ssh_server_db_credentials") }

    func db(_ s: Int, _ d: Int) -> DB? { servers.indices.contains(s) && servers[s].dbs.indices.contains(d) ? servers[s].dbs[d] : nil }
    var selectedTitle: String? {
        guard let p = selected, let db = db(p.server, p.db), db.tables.indices.contains(p.table) else { return nil }
        return "\(db.name).\(db.tables[p.table])"
    }

    // MARK: - Loading

    func load() {
        if loaded || reading != nil { return }
        guard Self.offered else { loaded = true; return }
        reading = Task { [weak self] in
            let r = await boardCall("settings_ssh_servers")
            guard let self, !Task.isCancelled else { return }
            self.reading = nil
            self.loaded = true
            switch r {
            case .failure(let e):
                if e.kind == .cancelled { self.loaded = false; return }
                self.error = e.description
            case .success(let v):
                self.error = nil
                self.clear()
                self.servers = v["servers"].items.filter { $0["repo"].string == self.repo }.map { Server(server: RemoteServer(row: $0)) }
            }
        }
    }
    func refresh() {
        reading?.cancel(); reading = nil
        loaded = false
        load()
    }
    private func clear() {
        generation += 1
        queries.forEach { $0.cancel() }; queries = []
        servers = []
        selected = nil
        grid = SQLTable(); gridError = nil; gridLoading = false
    }

    // MARK: - Queries

    /// Runs `sql` on server `s` with its database login; `done` takes the answer unless the servers were read again since.
    private func run(_ s: Int, _ sql: String, done: @escaping (SSHQuery.Answer) -> Void) {
        let n = servers[s], login = n.login ?? .null
        let target = n.server.target("db", group: repo)
        let sl = SQLLogin(host: login["host"].string ?? "", port: login["port"].int ?? 3306,
                          user: login["username"].string ?? "", password: login["password"].string ?? "")
        let gen = generation
        queries.append(Task { [weak self] in
            let answer = await SSHQuery.run(target, login: sl, sql: sql)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            done(answer)
        })
    }
    static let cellMax: CGFloat = 260
    private static func measure(_ t: SQLTable) -> [CGFloat] {
        guard t.rows > 0 else { return [] }
        let head = NSFont.systemFont(ofSize: 12, weight: .semibold), cell = NSFont.systemFont(ofSize: 12)
        return (0..<t.cols).map { c in
            var w = (t.cell(0, c) as NSString).size(withAttributes: [.font: head]).width
            for r in 1..<t.rows where w < cellMax {
                w = max(w, (t.cell(r, c) as NSString).size(withAttributes: [.font: cell]).width)
            }
            return ceil(min(w, cellMax)) + 12
        }
    }
    /// The first column of every row after the header: the names SHOW DATABASES and SHOW TABLES answer with.
    private static func firstColumn(_ out: String) -> [String] {
        let t = SQLTable(out)
        return t.rows > 1 ? (1..<t.rows).map { t.cell($0, 0) } : []
    }
    /// The server's databases, once its login is known.
    private func loadDatabases(_ s: Int) {
        servers[s].loading = true
        run(s, "SHOW DATABASES;") { [weak self] a in
            guard let self, self.servers.indices.contains(s) else { return }
            self.servers[s].loading = false
            self.servers[s].loaded = a.ok
            self.servers[s].error = a.ok ? nil : a.out
            if a.ok { self.servers[s].dbs = Self.firstColumn(a.out).map { DB(name: $0) } }
        }
    }
    private func loadTables(_ s: Int, _ d: Int) {
        guard let db = db(s, d) else { return }
        servers[s].dbs[d].loading = true
        run(s, "SHOW TABLES FROM \(sqlIdent(db.name));") { [weak self] a in
            guard let self, self.db(s, d) != nil else { return }
            self.servers[s].dbs[d].loading = false
            self.servers[s].dbs[d].loaded = a.ok
            self.servers[s].dbs[d].error = a.ok ? nil : a.out
            if a.ok { self.servers[s].dbs[d].tables = Self.firstColumn(a.out) }
        }
    }
    func loadRows() {
        guard let p = selected, let db = db(p.server, p.db), db.tables.indices.contains(p.table) else { return }
        grid = SQLTable(); gridError = nil
        gridLoading = true
        run(p.server, "SELECT * FROM \(sqlIdent(db.name)).\(sqlIdent(db.tables[p.table])) LIMIT \(Self.rowLimit);") { [weak self] a in
            // Only the table still selected takes the answer.
            guard let self, self.selected == p else { return }
            self.gridLoading = false
            if a.ok { self.grid = SQLTable(a.out) } else { self.gridError = a.out }
        }
    }

    // MARK: - The tree

    /// Opens a server: its login read once, then its databases listed.
    func toggleServer(_ s: Int) {
        guard servers.indices.contains(s) else { return }
        servers[s].open.toggle()
        let n = servers[s]
        if !n.open || n.loaded || n.loading { return }
        servers[s].error = nil
        if !n.server.row["hasDbCredentials"].is(true) {
            servers[s].error = "No database login is stored for this server. Add one to it under ⚙ Settings → SSH servers."
            return
        }
        if n.login != nil { loadDatabases(s); return }
        servers[s].loading = true
        let gen = generation
        let id = n.server.row["id"]
        Task { [weak self] in
            let r = await boardCall("ssh_server_db_credentials", ["id": id])
            guard let self, gen == self.generation, self.servers.indices.contains(s) else { return }
            switch r {
            case .failure(let e):
                self.servers[s].loading = false
                if e.kind != .cancelled { self.servers[s].error = e.description }
            case .success(let v):
                self.servers[s].login = v["credentials"].isObject ? v["credentials"] : v
                self.loadDatabases(s)
            }
        }
    }
    func toggleDB(_ s: Int, _ d: Int) {
        guard let db = db(s, d) else { return }
        servers[s].dbs[d].open.toggle()
        if !servers[s].dbs[d].open || db.loaded || db.loading { return }
        servers[s].dbs[d].error = nil
        loadTables(s, d)
    }
    func pick(_ p: Pick) {
        guard db(p.server, p.db) != nil else { return }
        selected = p
        loadRows()
    }
}

struct ProjectDBTab: View {
    @ObservedObject var model: ProjectDBModel

    static let listWidth: CGFloat = 300

    var body: some View {
        Group {
            if !ProjectDBModel.offered {
                Text("The SSH servers and their database logins are read from Settings, which needs an Admin token on a server that stores database logins. Issue one on the server with npm run create-token and connect with it.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                GeometryReader { geo in
                    let lw = min(Self.listWidth, geo.size.width / 3)
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { tree.padding(.bottom, 14) }.frame(width: lw)
                        // A rule between the tree and the grid.
                        Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 8).padding(.trailing, 9).padding(.bottom, 14)
                        DBGrid(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(minHeight: 240)
            }
        }
        .onAppear { model.load() }
    }

    // MARK: - The tree

    @ViewBuilder private var tree: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.error { Notice(message: e).padding(.bottom, 8) }
            if !model.loaded {
                LoadingNote(text: "Loading servers…")
            } else {
                ForEach(Array(model.servers.enumerated()), id: \.offset) { s, n in
                    DBNode(name: n.server.name, sub: "\(n.server.user)@\(n.server.host):\(n.server.port)", depth: 0, glyph: Glyph.symbol(0xE1D3),
                           chevron: true, open: n.open, selected: false, dim: !n.server.row["hasDbCredentials"].is(true)) { model.toggleServer(s) }
                    if n.open {
                        if n.loading { note("Connecting…", depth: 1) }
                        if let e = n.error { note(e, depth: 1, error: true) }
                        if n.loaded && n.dbs.isEmpty { note("No databases.", depth: 1) }
                        ForEach(Array(n.dbs.enumerated()), id: \.offset) { d, db in
                            DBNode(name: db.name, depth: 1, glyph: Glyph.symbol(0xE8B7), chevron: true, open: db.open) { model.toggleDB(s, d) }
                            if db.open {
                                if db.loading { note("Loading tables…", depth: 2) }
                                if let e = db.error { note(e, depth: 2, error: true) }
                                if db.loaded && db.tables.isEmpty { note("No tables.", depth: 2) }
                                ForEach(Array(db.tables.enumerated()), id: \.offset) { t, table in
                                    let p = ProjectDBModel.Pick(server: s, db: d, table: t)
                                    DBNode(name: table, depth: 2, glyph: Glyph.symbol(0xE8FD), selected: model.selected == p) { model.pick(p) }
                                }
                            }
                        }
                    }
                }
                if model.servers.isEmpty && model.error == nil {
                    Text("No SSH servers for this project. Register one, with its database login, under ⚙ Settings.")
                        .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    /// A line under an open node: loading, an error or nothing there, indented to its children.
    private func note(_ text: String, depth: Int, error: Bool = false) -> some View {
        Text(text).font(Theme.caption).foregroundStyle(error ? Theme.danger : Theme.muted)
            .lineLimit(error ? nil : 1).truncationMode(.tail).fixedSize(horizontal: false, vertical: error)
            .textSelection(.enabled)
            .padding(.leading, 4 + CGFloat(depth) * 16 + 22)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One node of the tree: a chevron when it opens, its glyph and its name (with user@host:port under a server's).
private struct DBNode: View {
    var name: String
    var sub: String? = nil
    var depth: Int
    var glyph: String
    var chevron = false
    var open = false
    var selected = false
    var dim = false
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Group {
                    if chevron { Image(systemName: Glyph.symbol(open ? 0xE70D : 0xE76C)).font(.system(size: 9)).foregroundStyle(Theme.muted) }
                }
                .frame(width: 14)
                Image(systemName: glyph).font(.system(size: 11)).foregroundStyle(dim ? Theme.muted : Theme.accent)
                    .frame(width: 20).padding(.leading, 2)
                VStack(alignment: .leading, spacing: 0) {
                    if let sub {
                        Text(name).font(Theme.subheadline).foregroundStyle(dim ? Theme.muted : Theme.ink)
                            .lineLimit(1).truncationMode(.tail).frame(height: 20, alignment: .leading)
                        Text(sub).font(Theme.caption2).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.tail).frame(height: 16, alignment: .leading)
                    } else {
                        Text(name).font(selected ? Theme.footnoteSemibold : Theme.footnote).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.leading, 6)
                Spacer(minLength: 8)
            }
            .padding(.leading, 4 + CGFloat(depth) * 16)
            .frame(height: sub != nil ? 46 : 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected || hovered ? Theme.raise : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The table on show: its name and Reload, how many rows, and the rows as a grid, numbered, its columns as wide as what
/// they hold up to a cap; NULL in the muted colour.
private struct DBGrid: View {
    @ObservedObject var model: ProjectDBModel

    static let numberWidth: CGFloat = 44
    static let rowHeight: CGFloat = 24

    var body: some View {
        if let title = model.selectedTitle {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(Theme.headline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Button("Reload") { model.loadRows() }.dashButton(.bordered).frame(width: 96).disabled(model.gridLoading)
                }
                .padding(.bottom, 6)
                if model.gridLoading {
                    LoadingNote(text: "Running the query…").padding(.horizontal, -8)
                } else if let e = model.gridError {
                    Notice(message: e)
                } else {
                    let rows = max(model.grid.rows - 1, 0)
                    Text(rows >= ProjectDBModel.rowLimit ? "The first \(ProjectDBModel.rowLimit) rows" : "\(rows) row\(rows == 1 ? "" : "s")")
                        .font(Theme.caption).foregroundStyle(Theme.muted).padding(.bottom, 8)
                    if model.grid.rows > 0 { table }
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)
        } else {
            EmptyNote(title: "No table selected",
                      detail: "Click a server on the left to see its databases, a database to see its tables, and a table to see its rows here. The queries run on the server’s own mysql client over SSH from this Mac, with the database login stored for the server.")
                .padding(.top, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var table: some View {
        let t = model.grid
        let w = model.widths
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<t.rows, id: \.self) { r in row(t, r, w) }
            }
        }
    }

    private func row(_ t: SQLTable, _ r: Int, _ w: [CGFloat]) -> some View {
        let header = r == 0
        return HStack(spacing: 0) {
            // The row's number first, as DBeaver's grid shows it.
            Text(header ? "" : "\(r)").font(Theme.caption).foregroundStyle(Theme.muted)
                .frame(width: Self.numberWidth - 8, alignment: .trailing).padding(.trailing, 8)
            ForEach(0..<t.cols, id: \.self) { c in
                let v = t.cell(r, c)
                let null = !header && v == "NULL"
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    Text(v).font(header ? Theme.captionSemibold : Theme.caption)
                        .foregroundStyle(header ? Theme.ink : null ? Theme.muted : Theme.ink)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: w[c])
            }
        }
        .frame(height: Self.rowHeight)
        .background(header ? Theme.raise : r % 2 == 0 ? Theme.raise.opacity(0.35) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .textSelection(.enabled)
    }
}
