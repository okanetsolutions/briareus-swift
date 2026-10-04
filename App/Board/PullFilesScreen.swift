// A pull request's changed files on a phone (the Mac's PullFilesScreen): the files of one revision, read a page at a
// time, each opening its diff in monospaced type that wraps.
import SwiftUI

/// The changed files, read page by page and pinned to the revision page 1 named. A saved list shows first and is kept
/// when the server's first page says the revision has not moved.
@MainActor
final class PullFilesModel: ObservableObject {
    let repo: String
    let number: Int
    @Published private(set) var list = PullFileList()
    @Published private(set) var loading = false
    /// The pull request moved while it was being read, and the list started over on its latest revision.
    @Published private(set) var changed = false
    @Published private(set) var error: String?
    private var confirmed = false
    private var retried = false
    private var gen = 0

    init(repo: String, number: Int) {
        self.repo = repo; self.number = number
        if let saved = Store.shared.cache.value(key), let l = PullFileList(saved) { list = l }
    }

    private var key: String { "files:\(repo)#\(number)" }
    var shown: Bool { !list.pr.isNull }

    /// Reads the next page: page 1 first, which confirms or replaces a saved list.
    func load() async {
        guard !loading, Store.shared.supports("pull_files") else { return }
        guard let args = (confirmed ? list : PullFileList()).arguments(repo: repo, number: number) else { return }
        loading = true
        gen += 1
        let mine = gen
        do {
            let v = try await Store.shared.call("pull_files", args)
            guard mine == gen else { return }
            loading = false
            guard let page = PullFilesPage(v) else { error = APIError(.nonJSON).description; return }
            error = nil
            retried = false
            if !confirmed {
                confirmed = true
                // The same revision has the same files; only a push or rebase makes them worth reading again.
                if list.confirm(page) { return }
                list = PullFileList()
            }
            list.append(page)
            // Only whole lists are saved, so a saved one never waits on a page.
            if list.nextPage == nil { Store.shared.cache.store(list.json, key) }
        } catch {
            guard mine == gen else { return }
            loading = false
            guard let said = failure(error) else { return }
            // A push or rebase invalidates the pages already read; never mix two revisions.
            if let e = error as? APIError, e.kind == .http, e.status == 409, !retried {
                list = PullFileList(); changed = true; confirmed = true; retried = true
                await load()
                return
            }
            self.error = said
        }
    }
    /// Reads every page again from the first.
    func refresh() async {
        gen += 1; loading = false
        list = PullFileList(); changed = false; confirmed = true
        await load()
    }
}

struct PullFilesScreen: View {
    let repo: String
    let number: Int
    @StateObject private var model: PullFilesModel

    init(repo: String, number: Int) {
        self.repo = repo; self.number = number
        _model = StateObject(wrappedValue: PullFilesModel(repo: repo, number: number))
    }

    var body: some View {
        let list = model.list
        List {
            if model.changed {
                Label("This pull request changed while reading. Showing its latest revision.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary).listRowBackground(Theme.row)
            }
            if let e = model.error {
                Section {
                    ErrorNotice(message: e)
                    Button("Try again") { Task { await model.load() } }.disabled(model.loading)
                }
                .listRowBackground(Theme.row)
            }
            if model.shown {
                Section {
                    ForEach(Array(list.files.enumerated()), id: \.element.filename) { index, file in
                        NavigationLink { PullFileDiffScreen(model: model, index: index) } label: { FileRow(file: file) }
                            .listRowBackground(Theme.row)
                    }
                    if list.nextPage != nil && !list.files.isEmpty && model.error == nil {
                        ProgressView().frame(maxWidth: .infinity).listRowBackground(Theme.row)
                            .task { await model.load() }
                    }
                    if list.files.isEmpty && list.nextPage == nil {
                        Text("No files changed").foregroundStyle(.secondary).listRowBackground(Theme.row)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(list.pr["changedFiles"].int.map { "\($0) file\($0 == 1 ? "" : "s") changed" } ?? "Files changed")
                        Spacer()
                        if let add = list.pr["additions"].int, let del = list.pr["deletions"].int {
                            Text("+\(add)").foregroundStyle(Theme.success)
                            Text("\u{2212}\(del)").foregroundStyle(Theme.danger)
                        }
                    }
                    .font(.caption.monospacedDigit()).textCase(nil)
                } footer: {
                    if list.truncated { Text("GitHub lists only the first 3,000 files of this pull request.") }
                }
            } else if model.error == nil {
                ProgressView("Loading changes…").frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(Text(verbatim: "#\(number) files")).navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .task { if !model.loading && model.error == nil { await model.load() } }
    }
}

/// A changed file: its status, name and folder, where it was renamed from, and its line counts.
private struct FileRow: View {
    let file: PullFile
    private var mark: (icon: String, color: Color) {
        switch file.status {
        case "added": return ("plus.square.fill", Theme.success)
        case "removed": return ("minus.square.fill", Theme.danger)
        case "renamed", "copied": return ("arrow.right.square.fill", Theme.accent)
        default: return ("square.and.pencil", Theme.warning)
        }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: mark.icon).font(.subheadline).foregroundStyle(mark.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline.monospaced().weight(.medium)).lineLimit(1).truncationMode(.middle)
                if !file.directory.isEmpty {
                    Text(file.directory).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                if let previous = file.previousFilename {
                    Text("from \(previous)").font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Text("+\(file.additions ?? 0)").foregroundStyle(Theme.success)
                Text("\u{2212}\(file.deletions ?? 0)").foregroundStyle(Theme.danger)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.filename), \(file.status ?? "modified"), \(file.additions ?? 0) additions, \(file.deletions ?? 0) deletions")
    }
}

/// One file's diff, with long lines wrapped; the arrows step to the previous or next changed file.
struct PullFileDiffScreen: View {
    @ObservedObject var model: PullFilesModel
    @State private var index: Int
    @State private var lines: [DiffLine]?

    init(model: PullFilesModel, index: Int) {
        self.model = model
        _index = State(initialValue: index)
    }

    private var files: [PullFile] { model.list.files }

    var body: some View {
        if files.indices.contains(index) { diff(files[index]) } else { Color.clear.background(Theme.background) }
    }

    private func diff(_ file: PullFile) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.filename).font(.footnote.monospaced().weight(.medium)).textSelection(.enabled)
                    if let previous = file.previousFilename {
                        Text("Renamed from \(previous)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("+\(file.additions ?? 0)").foregroundStyle(Theme.success)
                        Text("\u{2212}\(file.deletions ?? 0)").foregroundStyle(Theme.danger)
                    }
                    .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                if file.patch == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No diff available", systemImage: "doc.questionmark").font(.subheadline.weight(.medium))
                        Text("GitHub returns no patch for binary files and very large changes.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                ForEach(lines ?? [], id: \.id) { DiffRow(line: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(file.filename)
        .background(Theme.background)
        .navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { index -= 1 } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .accessibilityLabel("Previous file")
                Button { index += 1 } label: { Image(systemName: "chevron.down") }
                    .disabled(index + 1 >= files.count)
                    .accessibilityLabel("Next file")
            }
        }
        .task(id: file.filename) {
            lines = diffParse(file.patch)
            // Reaching the last file read so far reads the next page, so the next arrow can keep going.
            if index + 1 >= files.count, model.list.nextPage != nil, model.error == nil { await model.load() }
        }
    }
}

/// One line of the patch: its number, its sign and its text on the added or removed tint; a hunk header on a band.
private struct DiffRow: View {
    let line: DiffLine
    private var tint: Color {
        switch line.kind {
        case .added: return Theme.success
        case .removed: return Theme.danger
        default: return .clear
        }
    }
    private var sign: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "\u{2212}"
        default: return " "
        }
    }
    private var text: String { line.text.replacingOccurrences(of: "\t", with: "    ") }
    var body: some View {
        switch line.kind {
        case .hunk, .note:
            Text(text).font(.caption2.monospaced()).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, line.kind == .hunk ? 6 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(line.kind == .hunk ? Theme.surface : Color.clear)
        default:
            let n = line.newLine != 0 ? line.newLine : line.oldLine
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n != 0 ? String(n) : "").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                Text(sign).font(.caption.monospaced()).foregroundStyle(line.kind == .context ? Color.secondary : tint)
                Text(text.isEmpty ? " " : text).font(.caption.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.trailing, 12).padding(.vertical, 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.13))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(line.kind == .added ? "Added" : line.kind == .removed ? "Removed" : "Line") \(line.text)")
        }
    }
}
