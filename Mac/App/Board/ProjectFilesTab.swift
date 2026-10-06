// A project's Files tab, beside its pull requests and issues, laid out as PhpStorm's project view: the repository's tree
// at a branch down the left, with Go to File (⇧⌘O) over it, and the files opened from it as editor tabs on the right,
// each read-only with line numbers, its language's colours and the find bar (⌘F). The server reads GitHub with its own
// token (`repo_tree`, `repo_file`), so no checkout or token is needed on this Mac; the tree is pinned to the commit the
// branch pointed at when it was read, and every file is read at that commit, so what opens matches the tree.
import AppKit
import SwiftUI

@MainActor
final class ProjectFilesModel: ObservableObject {
    enum FileState {
        case loading
        case loaded(RepoFile, [[CodeToken]], CodeLanguage)
        case failed(String)
    }

    let repo: String
    @Published private(set) var tree: RepoTree?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// The branch on show; nil for the default one.
    @Published private(set) var branch: String?
    @Published private(set) var branches: [String] = []
    @Published private(set) var defaultBranch: String?
    @Published var expanded: Set<String> = []
    @Published var selected: String?
    /// The editor tabs, in the order they were opened, and the one on show.
    @Published private(set) var tabs: [String] = []
    @Published private(set) var active: String?
    @Published private(set) var files: [String: FileState] = [:]
    /// Go to File's query; while it holds anything, its matches stand in for the tree.
    @Published var query = ""
    private var reading: Task<Void, Never>?
    private var gen = 0

    init(repo: String) { self.repo = repo }

    /// Whether the server lists a repository's files for this token.
    static var offered: Bool { Store.shared.supports("repo_tree") && Store.shared.supports("repo_file") }

    var branchLabel: String { branch ?? tree?.ref ?? defaultBranch ?? "default branch" }
    var subtitle: String {
        guard let tree else { return loading ? "\(repo) · reading the tree…" : repo }
        let count = tree.entries.values.filter { !$0.folder }.count
        let sha = tree.sha.map { " @ \($0.prefix(7))" } ?? ""
        return "\(repo) · \(branchLabel)\(sha) · \(count) file\(count == 1 ? "" : "s")"
    }
    var matches: [String] { tree.map { repoFindFiles(query, in: $0.files) } ?? [] }

    // MARK: Reading

    /// Reads the tree once, and the branches for the picker.
    func load() {
        if tree != nil || reading != nil { return }
        read()
    }
    func refresh() {
        files = [:]
        read()
    }
    func pickBranch() {
        let list = branches.isEmpty ? [branchLabel] : branches
        let current = branchLabel
        let items = list.map { BoardPopupMenu.Item(title: $0 == defaultBranch ? "\($0)  (default)" : $0, checked: $0 == current) }
        guard let chosen = BoardPopupMenu.show(items), list.indices.contains(chosen), list[chosen] != current else { return }
        branch = list[chosen] == defaultBranch ? nil : list[chosen]
        // The open tabs stay, read again at the new branch's commit; folders that are not there any more close.
        files = [:]
        read()
    }

    private func read() {
        reading?.cancel()
        gen += 1
        let gen = gen
        loading = true
        error = nil
        reading = Task { [weak self] in
            guard let self else { return }
            if self.branches.isEmpty, Store.shared.supports("branches"),
               let v = (await boardCall("branches", ["repo": .string(self.repo)])).value, gen == self.gen {
                self.branches = v["branches"].items.compactMap(\.string)
                self.defaultBranch = v["defaultBranch"].string
            }
            var args: JSON = ["repo": .string(self.repo)]
            if let b = self.branch { args["ref"] = .string(b) }
            let r = await boardCall("repo_tree", args, timeout: 60)
            guard gen == self.gen, !Task.isCancelled else { return }
            self.loading = false
            self.reading = nil
            guard let v = r.value, let tree = RepoTree(v) else {
                if let e = r.error, e.kind != .cancelled { self.error = e.description }
                else if r.value != nil { self.error = "The server sent a tree this app cannot read." }
                return
            }
            self.tree = tree
            self.expanded = self.expanded.filter { tree.entries[$0]?.folder == true }
            // Tabs whose file this branch does not have close; the others read again.
            self.tabs = self.tabs.filter { tree.entries[$0]?.folder == false }
            if let a = self.active, !self.tabs.contains(a) { self.active = self.tabs.last }
            if let a = self.active { self.readFile(a) }
        }
    }

    private func readFile(_ path: String) {
        guard let tree else { return }
        if let state = files[path], case .loading = state { return }
        if let state = files[path], case .loaded = state { return }
        files[path] = .loading
        let sha = tree.sha ?? tree.ref
        let gen = gen
        Task { [weak self] in
            guard let self else { return }
            let r = await boardCall("repo_file", ["repo": .string(self.repo), "ref": .string(sha), "path": .string(path)], timeout: 60)
            guard gen == self.gen else { return }
            guard let v = r.value, let file = RepoFile(v) else {
                self.files[path] = .failed(r.error?.description ?? "The server sent a file this app cannot read.")
                return
            }
            let language = CodeLanguage.of(path)
            // Colouring a long file is kept off the main thread.
            let lines = await Task.detached(priority: .userInitiated) { codeHighlight(file.content ?? "", language: language) }.value
            guard gen == self.gen else { return }
            self.files[path] = .loaded(file, lines, language)
        }
    }

    // MARK: The tree and the tabs

    func toggle(_ folder: String) {
        if expanded.contains(folder) { expanded.remove(folder) } else { expanded.insert(folder) }
    }
    func open(_ path: String) {
        guard tree?.entries[path]?.folder == false else { return }
        if !tabs.contains(path) { tabs.append(path) }
        active = path
        selected = path
        readFile(path)
    }
    /// A tab chosen: the tree opens down to its file, as PhpStorm's "Always select opened file" does.
    func show(_ path: String) {
        active = path
        reveal(path)
        readFile(path)
    }
    func reveal(_ path: String) {
        guard let tree else { return }
        for folder in tree.ancestors(of: path) { expanded.insert(folder) }
        selected = path
    }
    func close(_ path: String) {
        guard let i = tabs.firstIndex(of: path) else { return }
        tabs.remove(at: i)
        files[path] = nil
        if active == path { active = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)] }
        if let a = active { selected = a }
    }
    func closeOthers(_ path: String) {
        for t in tabs where t != path { files[t] = nil }
        tabs = tabs.filter { $0 == path }
        active = tabs.first
    }
    func closeAll() {
        tabs = []; active = nil; files = [:]
    }
    func collapseAll() { expanded = [] }

    /// The file on GitHub at the tree's commit.
    func githubURL(_ path: String) -> String? {
        if let state = files[path], case .loaded(let f, _, _) = state, let url = f.url { return url }
        guard let tree else { return nil }
        let at = tree.sha ?? tree.ref
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return "https://github.com/\(repo)/blob/\(at)/\(encoded)"
    }

    var headerButtons: [HeaderButton] {
        var buttons = [HeaderButton(glyph: "arrow.triangle.branch", label: "\(branchLabel) ▾", tip: "Browse another branch", enabled: tree != nil || !branches.isEmpty) { [weak self] in self?.pickBranch() }]
        if let a = active {
            buttons.append(HeaderButton(glyph: "doc.on.doc", tip: "Copy the open file’s path") { Clipboard.copy(a) })
            buttons.append(HeaderButton(glyph: "safari", label: "GitHub", tip: "Open the file on GitHub") { [weak self] in openWebURL(self?.githubURL(a)) })
        }
        buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the tree from GitHub again", enabled: !loading) { [weak self] in self?.refresh() })
        return buttons
    }
}

// MARK: - The tab

struct ProjectFilesTab: View {
    @ObservedObject var model: ProjectFilesModel
    @FocusState private var searching: Bool
    @State private var hoveredMatch: Int?

    var body: some View {
        HSplitView {
            projectPane
                .frame(minWidth: 200, idealWidth: 290, maxWidth: 520)
            editorPane
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .onAppear { model.load() }
        .background {
            // ⇧⌘O, as in PhpStorm: Go to File.
            Button("") { searching = true }.keyboardShortcut("o", modifiers: [.command, .shift]).hidden()
        }
    }

    // MARK: The project pane

    private var projectPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.muted)
                TextField("Go to file  ⇧⌘O", text: $model.query)
                    .textFieldStyle(.plain).font(Theme.footnote)
                    .focused($searching)
                    .onSubmit { if let first = model.matches.first { pick(first) } }
                    .onExitCommand { model.query = ""; searching = false }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted)
                }
                Button { model.collapseAll() } label: { Image(systemName: "rectangle.compress.vertical").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Collapse all folders")
                    .disabled(model.expanded.isEmpty)
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .padding(.trailing, 10).padding(.bottom, 8)

            if let e = model.error { Notice(message: e).padding(.trailing, 10).padding(.bottom, 8) }
            if model.tree == nil {
                if model.loading { LoadingNote(text: "Reading the tree from GitHub…") }
                Spacer(minLength: 0)
            } else if !model.query.isEmpty {
                searchResults
            } else {
                treeList
            }
            if model.tree?.truncated == true {
                Text("This repository is larger than GitHub lists in one tree; some files are missing.")
                    .font(Theme.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6).padding(.trailing, 10)
            }
        }
        .padding(.bottom, 10)
    }

    private var treeList: some View {
        let lines = treeLines()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.path) { line in
                        let e = line.entry
                        FileTreeRow(name: e.name, folder: e.folder, expanded: model.expanded.contains(e.path), depth: line.depth,
                                    selected: model.selected == e.path, open: model.tabs.contains(e.path)) {
                            model.selected = e.path
                            if e.folder { model.toggle(e.path) } else { model.open(e.path) }
                        }
                        .id(e.path)
                        .contextMenu {
                            if !e.folder { Button("Open") { model.open(e.path) } }
                            Button("Copy path") { Clipboard.copy(e.path) }
                            Button("Open on GitHub") { openWebURL(model.githubURL(e.path)) }
                        }
                    }
                }
                .padding(.trailing, 10)
            }
            .onChange(of: model.active) { _, a in
                guard let a else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(a, anchor: .center) }
            }
        }
    }

    private struct TreeLine { var entry: RepoEntry; var depth: Int; var path: String { entry.path } }
    private func treeLines() -> [TreeLine] {
        guard let tree = model.tree else { return [] }
        var out: [TreeLine] = []
        func walk(_ folder: String, _ depth: Int) {
            for path in tree.children[folder] ?? [] {
                guard let e = tree.entries[path] else { continue }
                out.append(TreeLine(entry: e, depth: depth))
                if e.folder && model.expanded.contains(path) { walk(path, depth + 1) }
            }
        }
        walk("", 0)
        return out
    }

    private var searchResults: some View {
        let found = model.matches
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if found.isEmpty {
                    Text("No file matches.").font(Theme.footnote).foregroundStyle(Theme.muted).padding(8)
                }
                ForEach(Array(found.enumerated()), id: \.element) { i, path in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 16)
                        Text(repoBasename(path)).font(Theme.footnote).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(repoParent(path)).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(i == 0 || hoveredMatch == i ? Theme.raise : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { pick(path) }
                    .onHover { hoveredMatch = $0 ? i : (hoveredMatch == i ? nil : hoveredMatch) }
                }
            }
            .padding(.trailing, 10)
        }
    }

    private func pick(_ path: String) {
        model.query = ""
        searching = false
        model.open(path)
        model.reveal(path)
    }

    // MARK: The editor pane

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.tabs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30)).foregroundStyle(Theme.tertiary)
                    Text("Open a file from the tree").font(Theme.subheadline).foregroundStyle(Theme.muted)
                    Text("Go to File  ⇧⌘O    ·    Find in the file  ⌘F").font(Theme.caption).foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editorTabs
                if let a = model.active {
                    breadcrumb(a)
                    content(a)
                }
            }
        }
        .padding(.leading, 10).padding(.bottom, 10)
    }

    private var editorTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.tabs, id: \.self) { path in
                    EditorTab(name: repoBasename(path), path: path, active: model.active == path,
                              select: { model.show(path) }, close: { model.close(path) })
                        .contextMenu {
                            Button("Close") { model.close(path) }
                            Button("Close other tabs") { model.closeOthers(path) }.disabled(model.tabs.count < 2)
                            Button("Close all tabs") { model.closeAll() }
                            Divider()
                            Button("Select in the tree") { model.reveal(path) }
                            Button("Copy path") { Clipboard.copy(path) }
                        }
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func breadcrumb(_ path: String) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.tertiary) }
                Text(part).font(Theme.caption).foregroundStyle(i == parts.count - 1 ? Theme.ink : Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let state = model.files[path], case .loaded(let f, let lines, let language) = state {
                Text("\(language.name) · \(lines.count) line\(lines.count == 1 ? "" : "s") · \(repoFormatSize(f.size))")
                    .font(Theme.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).frame(height: 26)
    }

    @ViewBuilder private func content(_ path: String) -> some View {
        switch model.files[path] {
        case .loaded(let f, let lines, _):
            if let _ = f.content {
                CodeTextView(lines: lines, identity: "\(path)@\(f.ref)")
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(f.binary ? "A binary file of \(repoFormatSize(f.size)), not shown here." : "This file is \(repoFormatSize(f.size)), larger than the 1 MB shown here.")
                        .font(Theme.footnote).foregroundStyle(Theme.muted)
                    Button("Open on GitHub") { openWebURL(model.githubURL(path)) }.dashButton(.bordered)
                }
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .failed(let e):
            VStack(alignment: .leading, spacing: 8) {
                Notice(message: e)
                Button("Try again") { model.close(path); model.open(path) }.dashButton(.bordered)
            }
            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            LoadingNote(text: "Reading \(repoBasename(path))…").frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Rows

private struct FileTreeRow: View {
    var name: String
    var folder: Bool
    var expanded: Bool
    var depth: Int
    var selected: Bool
    var open: Bool
    var click: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 4 + CGFloat(depth) * 16)
            Group {
                if folder {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                } else { Color.clear }
            }
            .frame(width: 14)
            Image(systemName: folder ? (expanded ? "folder.fill" : "folder") : FileIcon.symbol(name))
                .font(.system(size: 12))
                .foregroundStyle(folder ? Theme.accent : FileIcon.color(name))
                .frame(width: 20)
            Text(name).font(open ? Theme.footnoteSemibold : Theme.footnote).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle).padding(.leading, 4)
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .background {
            if selected { RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.18)) }
            else if hovered { RoundedRectangle(cornerRadius: 5).fill(Theme.raise.opacity(0.6)) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: click)
        .onHover { hovered = $0 }
    }
}

private struct EditorTab: View {
    var name: String
    var path: String
    var active: Bool
    var select: () -> Void
    var close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: FileIcon.symbol(name)).font(.system(size: 11)).foregroundStyle(FileIcon.color(name))
            Text(name).font(Theme.footnote).foregroundStyle(active || hovered ? Theme.ink : Theme.muted).lineLimit(1)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                .opacity(active || hovered ? 1 : 0)
                .help("Close")
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(active ? Theme.raise : .clear)
        .overlay(alignment: .bottom) { if active { Rectangle().fill(Theme.accent).frame(height: 2) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .help(path)
    }
}

/// A file's icon and its tint, by the kind of file its name says it is.
private enum FileIcon {
    static func symbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "bmp", "tiff", "heic": return "photo"
        case "svg": return "photo.artframe"
        case "md", "markdown", "txt", "rst": return "doc.plaintext"
        case "json", "yml", "yaml", "toml", "ini", "plist", "xml", "lock", "env", "conf", "cfg": return "gearshape"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "sql": return "cylinder"
        case "zip", "gz", "tar", "tgz", "rar", "7z": return "archivebox"
        case "pdf": return "doc.richtext"
        case "": return name.hasPrefix(".") ? "gearshape" : "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
    static func color(_ name: String) -> Color {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return Color(nsColor: NSColor(hex: 0xF05138))
        case "php": return Color(nsColor: NSColor(hex: 0x8892BF))
        case "js", "mjs", "cjs", "jsx": return Color(nsColor: NSColor(hex: 0xD6BA32))
        case "ts", "tsx": return Color(nsColor: NSColor(hex: 0x3178C6))
        case "py": return Color(nsColor: NSColor(hex: 0x4B8BBE))
        case "rb": return Color(nsColor: NSColor(hex: 0xCC342D))
        case "go": return Color(nsColor: NSColor(hex: 0x00ADD8))
        case "rs": return Color(nsColor: NSColor(hex: 0xDEA584))
        case "vue": return Color(nsColor: NSColor(hex: 0x41B883))
        case "html", "htm": return Color(nsColor: NSColor(hex: 0xE34C26))
        case "css", "scss", "sass", "less": return Color(nsColor: NSColor(hex: 0x563D7C))
        case "json", "yml", "yaml", "toml": return Theme.warn
        default: return Theme.muted
        }
    }
}

// MARK: - The code view

/// The file's text in an NSTextView, as an editor shows it: read-only, monospaced, not wrapped, line numbers in a gutter,
/// the language's colours, and the find bar (⌘F, ⌘G).
private struct CodeTextView: NSViewRepresentable {
    var lines: [[CodeToken]]
    /// The file and its revision: the text is set again only when it changes.
    var identity: String

    final class Coordinator { var identity: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CodeEditorView { CodeEditorView() }

    func updateNSView(_ view: CodeEditorView, context: Context) {
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        view.show(Self.attributed(lines), lineCount: lines.count)
    }

    static func attributed(_ lines: [[CodeToken]]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.minimumLineHeight = CodePalette.lineHeight
        paragraph.maximumLineHeight = CodePalette.lineHeight
        let base: [NSAttributedString.Key: Any] = [.font: CodePalette.font, .foregroundColor: CodePalette.color(.plain), .paragraphStyle: paragraph]
        out.beginEditing()
        for (i, line) in lines.enumerated() {
            for token in line {
                var attrs = base
                attrs[.foregroundColor] = CodePalette.color(token.kind)
                if token.kind == .comment { attrs[.font] = CodePalette.italic }
                if token.kind == .keyword { attrs[.font] = CodePalette.bold }
                out.append(NSAttributedString(string: token.text, attributes: attrs))
            }
            if i < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        out.endEditing()
        return out
    }
}

/// The gutter and the scrolling text side by side. The gutter is a view of its own rather than the scroll view's ruler:
/// macOS floats a ruler over the text behind content insets it sets after layout, which a file wider than the view then
/// starts under.
private final class CodeEditorView: NSView {
    let scroll = NSScrollView()
    let text = NSTextView(usingTextLayoutManager: false)
    let gutter = LineGutter()

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.drawsBackground = true
        text.backgroundColor = CodePalette.background
        text.selectedTextAttributes = [.backgroundColor: CodePalette.selection]
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = []
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.lineFragmentPadding = 4

        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = CodePalette.background
        scroll.contentView.postsBoundsChangedNotifications = true
        gutter.textView = text
        addSubview(gutter)
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled() { gutter.needsDisplay = true }

    override func layout() {
        super.layout()
        let w = gutter.width
        gutter.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        scroll.frame = NSRect(x: w, y: 0, width: max(bounds.width - w, 0), height: bounds.height)
        sizeText()
    }

    /// The text view as wide as its longest line and as tall as its lines, and never smaller than what shows it.
    private func sizeText() {
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let inset = text.textContainerInset
        let visible = scroll.contentSize
        text.frame.size = NSSize(width: max(ceil(used.width + inset.width * 2 + 8), visible.width),
                                 height: max(ceil(used.height + inset.height * 2), visible.height))
    }

    func show(_ string: NSAttributedString, lineCount: Int) {
        text.textStorage?.setAttributedString(string)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        gutter.lineCount = lineCount
        needsLayout = true
        layoutSubtreeIfNeeded()
        sizeText()
        // Back to the first line and column.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        gutter.needsDisplay = true
    }
}

/// The gutter: each line's number beside it, for the lines in view, following the text as it scrolls.
private final class LineGutter: NSView {
    weak var textView: NSTextView?
    var lineCount = 0 {
        didSet { if width != oldValue.gutterWidth { superview?.needsLayout = true } }
    }
    var width: CGFloat { lineCount.gutterWidth }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        CodePalette.gutter.setFill()
        bounds.fill()
        CodePalette.gutterRule.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer,
              let clip = text.enclosingScrollView?.contentView else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: CodePalette.gutterText]
        let string = text.string as NSString
        let visible = clip.bounds
        // Where the text's top is in this view: the clip view scrolled by `visible.minY`.
        let offset = text.textContainerInset.height - visible.minY
        if string.length == 0 {
            draw("1", top: offset, height: CodePalette.lineHeight, attrs: attrs)
            return
        }
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // The number of the first line in view: the newlines before it.
        var line = 1
        string.enumerateSubstrings(in: NSRange(location: 0, length: chars.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        var index = chars.location
        let end = min(NSMaxRange(chars), string.length)
        repeat {
            let lineRange = string.lineRange(for: NSRange(location: min(index, string.length - 1), length: 0))
            let frag = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: lineRange.location), effectiveRange: nil)
            draw(String(line), top: frag.minY + offset, height: frag.height, attrs: attrs)
            line += 1
            index = NSMaxRange(lineRange)
        } while index < end
        // A text ending in a newline has an empty last line, which has no characters to find.
        if index >= string.length && string.hasSuffix("\n") {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { draw(String(line), top: extra.minY + offset, height: extra.height, attrs: attrs) }
        }
    }

    private func draw(_ label: String, top: CGFloat, height: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let s = label as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: bounds.width - size.width - 10, y: top + (height - size.height) / 2), withAttributes: attrs)
    }
}

private extension Int {
    /// The gutter's width for this many lines: room for the longest number, three digits at least.
    var gutterWidth: CGFloat { CGFloat(Swift.max(3, String(Swift.max(self, 1)).count)) * 7.5 + 20 }
}

/// The editor's colours: PhpStorm's Darcula in the dark and its light scheme in the light.
private enum CodePalette {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    static let lineHeight: CGFloat = 17
    static let background = Theme.nsDynamic(0x1E1F22, 0xFFFFFF)
    static let gutter = Theme.nsDynamic(0x1E1F22, 0xF7F8FA)
    static let gutterText = Theme.nsDynamic(0x4B5059, 0xAEB3C2)
    static let gutterRule = Theme.nsDynamic(0x2B2D30, 0xEBECF0)
    static let selection = Theme.nsDynamic(0x214283, 0xA6D2FF)
    static func color(_ kind: CodeTokenKind) -> NSColor {
        switch kind {
        case .plain: return Theme.nsDynamic(0xBCBEC4, 0x080808)
        case .keyword: return Theme.nsDynamic(0xCF8E6D, 0x0033B3)
        case .string: return Theme.nsDynamic(0x6AAB73, 0x067D17)
        case .comment: return Theme.nsDynamic(0x7A7E85, 0x8C8C8C)
        case .number: return Theme.nsDynamic(0x2AACB8, 0x1750EB)
        case .type: return Theme.nsDynamic(0x56A8F5, 0x00627A)
        case .variable: return Theme.nsDynamic(0xC77DBB, 0x871094)
        }
    }
}
