// The Files tab's navigation, as PhpStorm's: Search Everywhere (⇧⇧) with its Classes, Files, Symbols and Actions tabs
// (⌘O, ⇧⌘O, ⌥⌘O, ⇧⌘A), File Structure (⌘F12), a choice of declarations when a name has several, and Find in Files
// (⇧⌘F), which also lists Find Usages (⌥F7). The keys are caught while the tab is on show (FilesKeyMonitor). Classes,
// symbols, usages and Find in Files read the local index: the repository at the tree's commit, downloaded once
// (`repo_archive`) and unpacked into this Mac's caches without vendor/ and node_modules/ (RepoIndexStore).
import AppKit
import SwiftUI

// MARK: - The index on disk

enum RepoIndexStore {
    /// ~/Library/Caches/<app>/RepoIndex/<owner>__<name>/<sha>.
    static func directory(repo: String, sha: String) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let app = Bundle.main.bundleIdentifier ?? "Briareus"
        let safeRepo = repo.replacingOccurrences(of: "/", with: "__").filter { $0.isLetter || $0.isNumber || "_-.".contains($0) }
        let safeSha = sha.filter { $0.isHexDigit }
        return caches.appendingPathComponent(app).appendingPathComponent("RepoIndex").appendingPathComponent(safeRepo)
            .appendingPathComponent(safeSha.isEmpty ? "ref" : safeSha)
    }
    static func complete(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".briareus-complete").path)
    }

    /// Unpacks GitHub's tarball into `dir` (its top folder stripped, vendor/, node_modules/ and .git left out), then drops
    /// the other commits kept for the same repository. The archive is deleted either way.
    static func unpack(_ archive: URL, into dir: URL) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: archive) }
        let parent = dir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".unpacking-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", staging.path, "--strip-components", "1",
                         "--exclude", "*/vendor", "--exclude", "*/node_modules", "--exclude", "*/.git"]
        let err = Pipe()
        tar.standardError = err
        tar.standardOutput = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let why = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw APIError(.network, message: "The archive could not be unpacked. \(why.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        fm.createFile(atPath: staging.appendingPathComponent(".briareus-complete").path, contents: Data())
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: staging, to: dir)
        // One commit per repository is kept.
        for other in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] where other.lastPathComponent != dir.lastPathComponent {
            try? fm.removeItem(at: other)
        }
    }

    /// Every text file under `dir` that the index takes, read and indexed.
    static func read(_ dir: URL) -> RepoIndex {
        let fm = FileManager.default
        var texts: [String: String] = [:]
        let base = dir.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else { return RepoIndex(texts: [:]) }
        for case let url as URL in walker {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if !repoIndexIncludes(path) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, repoIndexIncludes(path), !path.hasPrefix(".briareus"),
                  (values.fileSize ?? 0) <= repoIndexMaxFileBytes,
                  let data = try? Data(contentsOf: url), let text = repoText(data) else { continue }
            texts[path] = text
        }
        return RepoIndex(texts: texts)
    }
}

// MARK: - State

enum NavigatorMode: Equatable {
    case all, classes, files, symbols, actions
    /// File Structure: the open file's declarations.
    case structure
    /// The places a name is declared, to pick one.
    case choose(title: String, [CodeSymbol])

    var title: String {
        switch self {
        case .all: return "All"
        case .classes: return "Classes"
        case .files: return "Files"
        case .symbols: return "Symbols"
        case .actions: return "Actions"
        case .structure: return "File Structure"
        case .choose(let title, _): return title
        }
    }
    static let tabs: [NavigatorMode] = [.all, .classes, .files, .symbols, .actions]
}

struct FindPanel {
    var query: TextQuery
    /// "Usages of x" for Find Usages; nil for Find in Files.
    var title: String?
    var results: [RepoMatch] = []
    var usages = false
    var searching = false
}

/// One of Find Action's actions, and the one-line shortcut beside it.
struct FileAction {
    var title: String
    var shortcut: String = ""
    var enabled = true
    var run: () -> Void
}

extension ProjectFilesModel {
    var actions: [FileAction] {
        let a = active
        return [
            FileAction(title: "Search Everywhere", shortcut: "⇧⇧") { [weak self] in self?.navigator = .all },
            FileAction(title: "Go to File…", shortcut: "⇧⌘O") { [weak self] in self?.navigator = .files },
            FileAction(title: "Go to Class…", shortcut: "⌘O") { [weak self] in self?.navigator = .classes },
            FileAction(title: "Go to Symbol…", shortcut: "⌥⌘O") { [weak self] in self?.navigator = .symbols },
            FileAction(title: "Find in Files…", shortcut: "⇧⌘F") { [weak self] in self?.openFind() },
            FileAction(title: "File Structure", shortcut: "⌘F12", enabled: a != nil) { [weak self] in self?.openStructure() },
            FileAction(title: "Go to Declaration", shortcut: "⌘B", enabled: a != nil) { [weak self] in
                self?.caretAction { w, m, p in self?.goToDeclaration(w, member: m, from: p) }
            },
            FileAction(title: "Find Usages", shortcut: "⌥F7", enabled: a != nil) { [weak self] in
                self?.caretAction { w, _, _ in self?.findUsages(w) }
            },
            FileAction(title: "Find in File…", shortcut: "⌘F", enabled: a != nil) { [weak self] in self?.editor?.showFindBar() },
            FileAction(title: "Switch Branch…", enabled: tree != nil) { [weak self] in self?.pickBranch() },
            FileAction(title: "Select Opened File in the Tree", enabled: a != nil) { [weak self] in if let a { self?.reveal(a) } },
            FileAction(title: "Collapse All Folders") { [weak self] in self?.collapseAll() },
            FileAction(title: "Copy Path", enabled: a != nil) { if let a { Clipboard.copy(a) } },
            FileAction(title: "Open on GitHub", enabled: a != nil) { [weak self] in if let a { openWebURL(self?.githubURL(a)) } },
            FileAction(title: "Close Tab", enabled: a != nil) { [weak self] in if let a { self?.close(a) } },
            FileAction(title: "Close Other Tabs", enabled: a != nil && tabs.count > 1) { [weak self] in if let a { self?.closeOthers(a) } },
            FileAction(title: "Close All Tabs", enabled: !tabs.isEmpty) { [weak self] in self?.closeAll() },
            FileAction(title: "Reload the Tree from GitHub") { [weak self] in self?.refresh() },
            FileAction(title: "Rebuild the Index", enabled: Self.indexOffered && tree != nil) { [weak self] in self?.reindex() },
        ]
    }

    func openFind() {
        // The selection in the editor, when there is one on a line of its own, is what is looked for, as in PhpStorm.
        var query = findPanel?.query ?? TextQuery(text: "")
        if let editor, let selected = editor.selectedText(), !selected.isEmpty, !selected.contains("\n") { query.text = selected }
        findPanel = FindPanel(query: query)
        runFind()
    }
    func openStructure() {
        guard active != nil else { flash("Open a file first."); return }
        guard needsIndex() != nil else { return }
        navigator = .structure
    }

    /// Find in Files over the index, off the main thread; a newer query wins.
    func runFind() {
        guard var panel = findPanel, !panel.usages else { return }
        guard let index else {
            panel.results = []
            findPanel = panel
            flash(indexStatus ?? "The project is not indexed yet.")
            return
        }
        let query = panel.query
        panel.searching = !query.text.isEmpty
        if query.text.isEmpty { panel.results = [] }
        findPanel = panel
        guard !query.text.isEmpty else { return }
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { index.find(query) }.value
            guard let self, var current = self.findPanel, current.query == query, !current.usages else { return }
            current.results = found
            current.searching = false
            self.findPanel = current
        }
    }
}

// MARK: - Search Everywhere

/// One row of the popup: a class or symbol, a file, or an action.
private enum NavItem: Identifiable {
    case symbol(CodeSymbol)
    case file(String)
    case action(FileAction)
    case header(String)

    var id: String {
        switch self {
        case .symbol(let s): return "s:\(s.path):\(s.line):\(s.name)"
        case .file(let p): return "f:" + p
        case .action(let a): return "a:" + a.title
        case .header(let h): return "h:" + h
        }
    }
    var selectable: Bool { if case .header = self { return false }; return true }
}

struct NavigatorPanel: View {
    @ObservedObject var model: ProjectFilesModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var mode: NavigatorMode { model.navigator ?? .all }

    var body: some View {
        let items = self.items
        VStack(alignment: .leading, spacing: 0) {
            if NavigatorMode.tabs.contains(mode) {
                HStack(spacing: 2) {
                    ForEach(NavigatorMode.tabs, id: \.title) { tab in
                        Button { model.navigator = tab; selection = 0 } label: {
                            Text(tab.title).font(Theme.caption).foregroundStyle(tab == mode ? Theme.ink : Theme.muted)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: 5).fill(tab == mode ? Theme.field : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 8)
                    Text(hint).font(Theme.caption2).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
            } else {
                Text(mode.title).font(Theme.captionSemibold).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.muted)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain).font(Theme.subheadline)
                    .focused($focused)
                    .onSubmit { pick(items) }
                    .onExitCommand { model.navigator = nil }
                    .onKeyPress(.downArrow) { move(1, items); return .handled }
                    .onKeyPress(.upArrow) { move(-1, items); return .handled }
                    .onKeyPress(.tab) { nextTab(); return .handled }
            }
            .padding(.horizontal, 14).frame(height: 36)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            if let status = blockedStatus {
                Text(status).font(Theme.footnote).foregroundStyle(Theme.muted).padding(14)
            } else if items.isEmpty {
                Text(query.isEmpty ? emptyPrompt : "Nothing found.").font(Theme.footnote).foregroundStyle(Theme.muted).padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == selection)
                                    .id(i)
                                    .contentShape(Rectangle())
                                    .onTapGesture { if item.selectable { selection = i; pick(items) } }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selection) { _, s in proxy.scrollTo(s) }
                }
            }
        }
        .frame(width: 680)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { focused = true; selection = firstSelectable(items) }
        .onChange(of: query) { _, _ in selection = firstSelectable(self.items) }
        .onChange(of: model.navigator) { _, _ in focused = true; selection = firstSelectable(self.items) }
    }

    private var hint: String {
        switch mode {
        case .classes: return "⌘O"
        case .files: return "⇧⌘O"
        case .symbols: return "⌥⌘O"
        case .actions: return "⇧⌘A"
        default: return "⇧⇧  ·  Tab for the next"
        }
    }
    private var placeholder: String {
        switch mode {
        case .classes: return "Class name, or Namespace\\Class"
        case .files: return "File name, or folder/file"
        case .symbols: return "Function, method or constant; Class.method"
        case .actions: return "Action name"
        case .structure: return "Filter this file’s declarations"
        case .choose: return "Filter"
        case .all: return "Classes, files, symbols and actions"
        }
    }
    private var emptyPrompt: String {
        switch mode {
        case .structure: return "Nothing declared in this file."
        default: return "Type to search."
        }
    }
    /// Why a mode that reads the index shows nothing yet.
    private var blockedStatus: String? {
        guard mode == .classes || mode == .symbols || mode == .structure, model.index == nil else { return nil }
        return model.indexStatus ?? "The project is not indexed yet."
    }

    private var items: [NavItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let index = model.index
        let files = model.tree?.files ?? []
        switch mode {
        case .classes: return (index?.search(q, typesOnly: true) ?? []).map(NavItem.symbol)
        case .symbols: return (index?.search(q, typesOnly: false) ?? []).map(NavItem.symbol)
        case .files: return repoFindFiles(q, in: files).map(NavItem.file)
        case .actions: return actions(q).map(NavItem.action)
        case .structure:
            let all = model.active.flatMap { index?.structure(of: $0) } ?? []
            return (q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }).map(NavItem.symbol)
        case .choose(_, let found):
            return (q.isEmpty ? found : found.filter { $0.path.localizedCaseInsensitiveContains(q) || $0.qualified.localizedCaseInsensitiveContains(q) }).map(NavItem.symbol)
        case .all:
            guard !q.isEmpty else { return [] }
            var out: [NavItem] = []
            let classes = index?.search(q, typesOnly: true, limit: 6) ?? []
            if !classes.isEmpty { out.append(.header("Classes")); out += classes.map(NavItem.symbol) }
            let matched = repoFindFiles(q, in: files, limit: 6)
            if !matched.isEmpty { out.append(.header("Files")); out += matched.map(NavItem.file) }
            let symbols = (index?.search(q, typesOnly: false, limit: 12) ?? []).filter { !$0.kind.isType }.prefix(6)
            if !symbols.isEmpty { out.append(.header("Symbols")); out += symbols.map(NavItem.symbol) }
            let acts = actions(q).prefix(4)
            if !acts.isEmpty { out.append(.header("Actions")); out += acts.map(NavItem.action) }
            return out
        }
    }
    private func actions(_ q: String) -> [FileAction] {
        let all = model.actions
        guard !q.isEmpty else { return all }
        let chars = Array(q.lowercased().filter { !$0.isWhitespace })
        return all.compactMap { a in repoMatchScore(chars, a.title.lowercased()).map { (a, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    @ViewBuilder private func row(_ item: NavItem, selected: Bool) -> some View {
        switch item {
        case .header(let title):
            Text(title).font(Theme.caption2).foregroundStyle(Theme.tertiary).padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
        case .symbol(let s):
            rowShell(selected: selected) {
                if case .structure = mode, s.container != nil { Spacer().frame(width: 14) }
                SymbolIcon(kind: s.kind)
                Text(s.name).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1)
                Text(secondary(s)).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Text("\(repoBasename(s.path)):\(s.line)").font(Theme.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
        case .file(let path):
            rowShell(selected: selected) {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 18)
                Text(repoBasename(path)).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1)
                Text(repoParent(path)).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
            }
        case .action(let a):
            rowShell(selected: selected) {
                Image(systemName: "bolt").font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 18)
                Text(a.title).font(Theme.footnote).foregroundStyle(a.enabled ? Theme.ink : Theme.tertiary).lineLimit(1)
                Spacer(minLength: 8)
                Text(a.shortcut).font(Theme.caption).foregroundStyle(Theme.tertiary)
            }
        }
    }
    private func rowShell<C: View>(selected: Bool, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accent.opacity(0.22) : .clear))
            .padding(.horizontal, 4)
    }
    private func secondary(_ s: CodeSymbol) -> String {
        if case .structure = mode { return s.kind.label }
        var parts: [String] = []
        if let c = s.container { parts.append(c) }
        if let ns = s.namespace { parts.insert(ns, at: 0) }
        return parts.isEmpty ? repoParent(s.path) : parts.joined(separator: "\\")
    }

    private func firstSelectable(_ items: [NavItem]) -> Int { items.firstIndex(where: \.selectable) ?? 0 }
    private func move(_ by: Int, _ items: [NavItem]) {
        guard !items.isEmpty else { return }
        var i = selection
        repeat { i = (i + by + items.count) % items.count } while !items[i].selectable && i != selection
        selection = i
    }
    private func nextTab() {
        guard let i = NavigatorMode.tabs.firstIndex(of: mode) else { return }
        model.navigator = NavigatorMode.tabs[(i + 1) % NavigatorMode.tabs.count]
    }
    private func pick(_ items: [NavItem]) {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        switch item {
        case .header: return
        case .symbol(let s): model.navigator = nil; model.go(to: s)
        case .file(let p): model.navigator = nil; model.open(p); model.reveal(p)
        case .action(let a):
            guard a.enabled else { return }
            model.navigator = nil
            // After the popup closes, so an action that opens another popup is not closed with it.
            DispatchQueue.main.async { a.run() }
        }
    }
}

/// A declaration's kind as PhpStorm marks it: a letter in a coloured circle.
struct SymbolIcon: View {
    var kind: CodeSymbolKind
    var body: some View {
        let (letter, color): (String, Color) = {
            switch kind {
            case .class: return ("C", Color(nsColor: NSColor(hex: 0x3592C4)))
            case .interface, .protocol: return ("I", Color(nsColor: NSColor(hex: 0x62B543)))
            case .trait, .module: return ("T", Color(nsColor: NSColor(hex: 0xB99BF8)))
            case .enum: return ("E", Color(nsColor: NSColor(hex: 0xE0AF68)))
            case .struct, .type: return ("S", Color(nsColor: NSColor(hex: 0x3592C4)))
            case .function: return ("f", Color(nsColor: NSColor(hex: 0xF08C36)))
            case .method: return ("m", Color(nsColor: NSColor(hex: 0xF08C36)))
            case .constant: return ("c", Color(nsColor: NSColor(hex: 0xB99BF8)))
            case .property: return ("p", Color(nsColor: NSColor(hex: 0x9AA7B0)))
            }
        }()
        Text(letter).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            .frame(width: 15, height: 15).background(Circle().fill(color)).frame(width: 18)
    }
}

// MARK: - Find in Files

struct FindPanelView: View {
    @ObservedObject var model: ProjectFilesModel
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let panel = model.findPanel ?? FindPanel(query: TextQuery(text: ""))
        let results = panel.results
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture { model.findPanel = nil }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(panel.title ?? "Find in Files").font(Theme.captionSemibold).foregroundStyle(Theme.ink)
                    Text(summary(panel)).font(Theme.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    Button { model.findPanel = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Close (Esc)")
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
                if !panel.usages {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        TextField("Text to find (vendor/ and node_modules/ are not searched)", text: binding(\.text))
                            .textFieldStyle(.plain).font(Theme.mono)
                            .focused($focused)
                            .onSubmit { open(results) }
                            .onExitCommand { model.findPanel = nil }
                            .onKeyPress(.downArrow) { selection = min(selection + 1, max(results.count - 1, 0)); return .handled }
                            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                        Toggle("Aa", isOn: binding(\.matchCase)).help("Match case")
                        Toggle("W", isOn: binding(\.wholeWord)).help("Words")
                        Toggle(".*", isOn: binding(\.regex)).help("Regular expression")
                    }
                    .toggleStyle(.button).controlSize(.small)
                    .padding(.horizontal, 14).frame(height: 36)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.offset) { i, m in
                                MatchRow(match: m, selected: i == selection).id(i)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = i; open(results) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selection) { _, s in proxy.scrollTo(s) }
                }
            }
            .frame(width: 820, height: 520)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.lineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.top, 30)
        }
        .onAppear { focused = true }
        .onKeyPress(.escape) { model.findPanel = nil; return .handled }
        .onChange(of: model.findPanel?.query) { _, _ in selection = 0 }
    }

    private func summary(_ p: FindPanel) -> String {
        if p.searching { return "Searching…" }
        if p.query.text.isEmpty { return "" }
        let files = Set(p.results.map(\.path)).count
        let capped = p.results.count >= 2000 ? " (the first 2,000)" : ""
        return "\(p.results.count) match\(p.results.count == 1 ? "" : "es") in \(files) file\(files == 1 ? "" : "s")\(capped)"
    }
    private func binding<T>(_ key: WritableKeyPath<TextQuery, T>) -> Binding<T> {
        Binding(get: { (model.findPanel?.query ?? TextQuery(text: ""))[keyPath: key] },
                set: { v in
                    guard var p = model.findPanel else { return }
                    p.query[keyPath: key] = v
                    model.findPanel = p
                    model.runFind()
                })
    }
    private func open(_ results: [RepoMatch]) {
        guard results.indices.contains(selection) else { return }
        let m = results[selection]
        model.findPanel = nil
        model.open(m.path, line: m.line)
    }
}

private struct MatchRow: View {
    var match: RepoMatch
    var selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(preview).font(Theme.monoSmall).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(repoBasename(match.path)) \(match.line)").font(Theme.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accent.opacity(0.22) : .clear))
        .padding(.horizontal, 4)
        .help(match.path)
    }
    /// The line, leading space trimmed, with the matches in bold and the accent.
    private var preview: AttributedString {
        let ns = match.preview as NSString
        var lead = 0
        while lead < ns.length, let c = Unicode.Scalar(ns.character(at: lead)), c == " " || c == "\t" { lead += 1 }
        var out = AttributedString()
        var at = lead
        for r in match.ranges.sorted(by: { $0.location < $1.location }) where r.location >= at {
            var plain = AttributedString(ns.substring(with: NSRange(location: at, length: r.location - at)))
            plain.foregroundColor = Theme.muted
            out += plain
            var hit = AttributedString(ns.substring(with: r))
            hit.foregroundColor = Theme.ink
            hit.backgroundColor = Theme.accent.opacity(0.3)
            out += hit
            at = NSMaxRange(r)
        }
        if at < ns.length {
            var rest = AttributedString(ns.substring(from: at))
            rest.foregroundColor = Theme.muted
            out += rest
        }
        return out
    }
}

// MARK: - The keys

/// PhpStorm's keys while the Files tab is on show: ⇧⇧ Search Everywhere, ⌘O Go to Class, ⇧⌘O Go to File, ⌥⌘O Go to
/// Symbol, ⇧⌘A Find Action, ⇧⌘F Find in Files, ⌘F12 File Structure, ⌘B Go to Declaration, ⌥F7 Find Usages.
struct FilesKeyMonitor: NSViewRepresentable {
    var model: ProjectFilesModel

    final class Coordinator {
        var monitor: Any?
        var lastShiftUp: Date?
        var shiftAlone = false
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let c = context.coordinator
        let model = model
        c.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak view] event in
            guard let view, let window = view.window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return event }
            return MainActor.assumeIsolated { Self.handle(event, model: model, c) } ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }

    @MainActor private static func handle(_ event: NSEvent, model: ProjectFilesModel, _ c: Coordinator) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .flagsChanged {
            // Double Shift: Shift pressed and let go on its own twice within 0.35 s.
            if flags == .shift { c.shiftAlone = true; return false }
            if flags.isEmpty && c.shiftAlone {
                c.shiftAlone = false
                let now = Date()
                if let last = c.lastShiftUp, now.timeIntervalSince(last) < 0.35 {
                    c.lastShiftUp = nil
                    model.navigator = model.navigator == .all ? nil : .all
                    return false
                }
                c.lastShiftUp = now
                return false
            }
            c.shiftAlone = false
            return false
        }
        c.shiftAlone = false
        c.lastShiftUp = nil
        switch (event.keyCode, flags) {
        case (31, [.command]): model.navigator = .classes                    // ⌘O
        case (31, [.command, .shift]): model.navigator = .files              // ⇧⌘O
        case (31, [.command, .option]): model.navigator = .symbols           // ⌥⌘O
        case (0, [.command, .shift]): model.navigator = .actions             // ⇧⌘A
        case (3, [.command, .shift]): model.navigator = nil; model.openFind() // ⇧⌘F
        case (111, [.command]): model.openStructure()                        // ⌘F12
        case (11, [.command]):                                               // ⌘B
            model.caretAction { w, m, p in model.goToDeclaration(w, member: m, from: p) }
        case (98, [.option]):                                                // ⌥F7
            model.caretAction { w, _, _ in model.findUsages(w) }
        default: return false
        }
        return true
    }
}
